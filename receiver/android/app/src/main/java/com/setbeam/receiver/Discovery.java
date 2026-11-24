package com.setbeam.receiver;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;

import com.setbeam.receiver.core.HostConfig;
import com.setbeam.receiver.core.HostMatcher;
import com.setbeam.receiver.core.HttpGateway;

import java.io.IOException;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Future;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/**
 * Finds addresses for the paired Mac only.
 *
 * <p>The configured host is tried first and always: an IPv4 literal, or a name through the system
 * resolver with a bounded wait. {@code _setbeam._tcp} DNS-SD is only a fallback for when the name
 * does not resolve (common for {@code .local} on Android). A service is used only if it matches
 * the configured name or address, or the id hint ({@link HostMatcher}); it is reached at its
 * numeric IPv4 address with that address as {@code Host}. Other Macs appear only in diagnostics.
 *
 * <p>TXT names and ids are unverified hints that anyone on the network can copy; they are not
 * authentication, and the operator's Admit on the Mac remains the access decision. An id is
 * recorded as a hint only when the configured name, resolved by the system resolver, points at
 * the same address as the advertising service, so a copied advertisement cannot pin itself.
 */
final class Discovery implements HttpGateway.Candidates {
    private static final String TAG = "SetbeamDiscovery";
    private static final String TYPE = "_setbeam._tcp";
    private static final long STALE_MS = 120_000;

    private final NsdManager nsd;
    private final Settings settings;
    private final Runnable onMatch;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ThreadPoolExecutor lookups = new ThreadPoolExecutor(0, 2, 10, TimeUnit.SECONDS, new SynchronousQueue<>());

    private final Map<String, Seen> services = new LinkedHashMap<>();
    private final Map<String, Integer> retries = new HashMap<>();
    private final ArrayDeque<NsdServiceInfo> resolveQueue = new ArrayDeque<>();
    private boolean resolving;
    private NsdManager.DiscoveryListener listener;
    private boolean wanted;
    private String status = "Not started";
    /** Setup's list of nearby Macs; runs on the main thread after the list changes. */
    private volatile Runnable onChange;

    private static final class Seen {
        final HostMatcher.Service service; final long at;
        Seen(HostMatcher.Service service, long at) { this.service = service; this.at = at; }
    }

    Discovery(Context context, Settings settings, Runnable onMatch) {
        this.nsd = (NsdManager) context.getApplicationContext().getSystemService(Context.NSD_SERVICE);
        this.settings = settings;
        this.onMatch = onMatch;
    }

    void setOnChange(Runnable value) { onChange = value; }

    /** Every Setbeam service seen so far, for setup's list. Unverified advertisements. */
    synchronized List<HostMatcher.Service> seen() {
        List<HostMatcher.Service> list = new ArrayList<>();
        for (Seen item : services.values()) list.add(item.service);
        return list;
    }

    private void changed() {
        Runnable callback = onChange;
        if (callback != null) main.post(callback);
    }

    synchronized void start() {
        wanted = true;
        if (listener != null || nsd == null) return;
        NsdManager.DiscoveryListener l = new NsdManager.DiscoveryListener() {
            @Override public void onStartDiscoveryFailed(String type, int code) { failed(this, "Bonjour browse failed (" + code + ")"); }
            @Override public void onStopDiscoveryFailed(String type, int code) { }
            @Override public void onDiscoveryStarted(String type) { setStatus("Browsing " + TYPE); }
            @Override public void onDiscoveryStopped(String type) { }
            @Override public void onServiceFound(NsdServiceInfo info) { enqueue(info); }
            @Override public void onServiceLost(NsdServiceInfo info) { lost(info.getServiceName()); }
        };
        listener = l;
        try {
            nsd.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, l);
        } catch (RuntimeException e) {
            failed(l, "Bonjour unavailable");
        }
    }

    synchronized void stop() {
        wanted = false;
        NsdManager.DiscoveryListener l = listener;
        listener = null;
        resolveQueue.clear();
        services.clear();
        retries.clear();
        if (l != null) {
            try { nsd.stopServiceDiscovery(l); } catch (RuntimeException ignored) { }
        }
    }

    private void failed(NsdManager.DiscoveryListener l, String why) {
        synchronized (this) {
            if (listener == l) listener = null;
            status = why;
        }
        // Multicast may be filtered; the configured host still works. Try browsing again later.
        main.postDelayed(() -> { synchronized (Discovery.this) { if (wanted) start(); } }, 15_000);
    }

    private synchronized void setStatus(String value) { status = value; }

    synchronized String status() {
        StringBuilder text = new StringBuilder(status);
        HostConfig host = settings.host();
        for (Seen seen : services.values()) {
            HostMatcher.Verdict verdict = HostMatcher.match(host, settings.pinnedMacId(), seen.service);
            text.append("\n  ").append(seen.service.instance).append(" ").append(seen.service.ipv4)
                    .append(seen.service.ipv4 == null ? " — no IPv4 address yet"
                            : verdict == HostMatcher.Verdict.MATCH ? " — matches the pairing (unverified hint)"
                            : verdict == HostMatcher.Verdict.OTHER_MAC ? " — other Mac, ignored" : " — not usable");
        }
        return text.toString();
    }

    private synchronized void enqueue(NsdServiceInfo info) {
        if (!wanted) return;
        for (NsdServiceInfo queued : resolveQueue) if (queued.getServiceName().equals(info.getServiceName())) return;
        if (resolveQueue.size() >= 16) return;
        resolveQueue.add(info);
        resolveNext();
    }

    private void lost(String name) {
        synchronized (this) { services.remove(name); retries.remove(name); }
        changed();
    }

    /** Re-resolves a service later, a bounded number of times (busy resolver, IPv6-only answer). */
    private void retryLater(NsdServiceInfo info) {
        synchronized (this) {
            int count = retries.getOrDefault(info.getServiceName(), 0);
            if (!wanted || count >= 3) return;
            retries.put(info.getServiceName(), count + 1);
        }
        main.postDelayed(() -> enqueue(info), 5000);
    }

    @SuppressWarnings("deprecation")
    private synchronized void resolveNext() {
        if (resolving || resolveQueue.isEmpty() || !wanted) return;
        NsdServiceInfo next = resolveQueue.poll();
        resolving = true;
        try {
            nsd.resolveService(next, new NsdManager.ResolveListener() {
                @Override public void onResolveFailed(NsdServiceInfo info, int code) { resolvedDone(null); retryLater(next); }
                @Override public void onServiceResolved(NsdServiceInfo info) { resolvedDone(info); }
            });
        } catch (RuntimeException e) {
            // Keep the queue moving: later services still resolve, and this one is retried.
            resolving = false;
            main.post(this::resolveNext);
            retryLater(next);
        }
    }

    @SuppressWarnings("deprecation")
    private void resolvedDone(NsdServiceInfo info) {
        boolean matched = false;
        NsdServiceInfo ipv6Only = null;
        synchronized (this) {
            resolving = false;
            if (info != null && wanted) {
                String ipv4 = null;
                if (Build.VERSION.SDK_INT >= 34) {
                    for (InetAddress address : info.getHostAddresses()) if (address instanceof Inet4Address) { ipv4 = address.getHostAddress(); break; }
                } else if (info.getHost() instanceof Inet4Address) {
                    ipv4 = info.getHost().getHostAddress();
                }
                Map<String, String> txt = new HashMap<>();
                for (Map.Entry<String, byte[]> entry : info.getAttributes().entrySet()) {
                    if (entry.getValue() != null && entry.getValue().length <= 255) txt.put(entry.getKey(), new String(entry.getValue(), StandardCharsets.UTF_8));
                }
                // Before Android 14 NSD reports one address, which can be IPv6; ask again later for IPv4.
                if (ipv4 == null) ipv6Only = info;
                HostMatcher.Service service = new HostMatcher.Service(info.getServiceName(), ipv4, info.getPort(), txt);
                if (services.size() < 32 || services.containsKey(info.getServiceName())) {
                    services.put(info.getServiceName(), new Seen(service, SystemClock.elapsedRealtime()));
                }
                matched = HostMatcher.match(settings.host(), settings.pinnedMacId(), service) == HostMatcher.Verdict.MATCH;
            }
            resolveNext();
        }
        if (ipv6Only != null) retryLater(ipv6Only);
        if (matched) main.post(onMatch);
        if (info != null) changed();
    }

    @Override
    public List<HttpGateway.Candidate> find(HostConfig host) throws IOException {
        // The configured name through the system resolver first, with a bounded wait.
        List<InetAddress> resolved = new ArrayList<>();
        if (!host.isIpLiteral()) {
            try {
                Future<InetAddress[]> lookup = lookups.submit(() -> InetAddress.getAllByName(host.host));
                InetAddress[] addresses;
                try { addresses = lookup.get(3, TimeUnit.SECONDS); }
                catch (Exception e) { lookup.cancel(true); addresses = new InetAddress[0]; }
                for (InetAddress address : addresses) if (address instanceof Inet4Address && !resolved.contains(address)) resolved.add(address);
            } catch (java.util.concurrent.RejectedExecutionException e) {
                Log.w(TAG, "Name lookups busy; using discovery only");
            }
        }
        List<HostMatcher.Service> seenServices = new ArrayList<>();
        List<NsdServiceInfo> refresh = new ArrayList<>();
        synchronized (this) {
            long now = SystemClock.elapsedRealtime();
            for (Seen seen : services.values()) {
                if (now - seen.at <= STALE_MS) seenServices.add(seen.service);
                else {
                    NsdServiceInfo info = new NsdServiceInfo();
                    info.setServiceName(seen.service.instance); info.setServiceType(TYPE);
                    refresh.add(info);
                }
            }
        }
        for (NsdServiceInfo info : refresh) enqueue(info);
        return HostMatcher.plan(host, settings.pinnedMacId(), resolved, seenServices);
    }
}
