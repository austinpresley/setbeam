package com.setbeam.receiver.core;

import java.net.URI;
import java.net.URISyntaxException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * The ask-only gateway path the short address redirects to: {@code /s/<64 hex>/} on the Mac's
 * gateway port. The code is distinct from the viewing link, is never a media credential, and
 * changes with every new share. Receivers key their per-share request state by a digest of it.
 */
public final class AskPath {
    private static final Pattern PATH = Pattern.compile("^/s/([0-9a-f]{64})/$");

    public final MiniHttp.Route route;
    public final String path;
    /** SHA-256 of the code, used as the persisted key. The code itself is never stored or shown. */
    public final String key;

    private AskPath(MiniHttp.Route route, String path, String key) { this.route = route; this.path = path; this.key = key; }

    public static final class Rejected extends Exception {
        public Rejected(String message) { super(message); }
    }

    /**
     * Validates the root's redirect. Only a 302 to the same scheme and the same host that was
     * sent, on an explicit port, with exactly an ask path is accepted; anything else could send the
     * receiver to a different server or leak a code into the wrong place.
     */
    public static AskPath fromRedirect(MiniHttp.Route root, int status, String location) throws Rejected {
        if (status != 302) throw new Rejected("Unexpected reply " + status);
        if (location == null || location.isEmpty() || location.length() > 512) throw new Rejected("Redirect without a location");
        URI uri;
        try { uri = new URI(location.trim()); } catch (URISyntaxException e) { throw new Rejected("Invalid redirect"); }
        if (!uri.isAbsolute() || uri.getScheme() == null || !uri.getScheme().toLowerCase(Locale.ROOT).equals(root.scheme))
            throw new Rejected("Redirect changes the scheme");
        if (uri.getRawUserInfo() != null || uri.getRawQuery() != null || uri.getRawFragment() != null) throw new Rejected("Invalid redirect");
        String host = uri.getHost() == null ? null : HostConfig.normalizeHost(uri.getHost());
        if (host == null || !host.equals(hostOnly(root.hostHeader))) throw new Rejected("Redirect names a different host");
        int port = uri.getPort();
        if (port < 1 || port > 65535) throw new Rejected("Redirect has no gateway port");
        String path = uri.getRawPath();
        java.util.regex.Matcher match = path == null ? null : PATH.matcher(path);
        if (match == null || !match.matches()) throw new Rejected("Redirect is not an ask path");
        MiniHttp.Route gateway = root.withPort(port, host + ":" + port);
        return new AskPath(gateway, path, digest(match.group(1)));
    }

    static AskPath restore(HostConfig host, String ipv4, String authority, String path) throws java.net.UnknownHostException, Rejected {
        String name = hostOnly(authority);
        if (!name.equals(host.host) && !(host.scheme.equals("http") && name.equals(ipv4))) throw new Rejected("Invalid saved host");
        MiniHttp.Route root = new MiniHttp.Route(host.scheme, java.net.InetAddress.getByName(ipv4), host.port, name, host.host);
        return fromRedirect(root, 302, host.scheme + "://" + authority + path);
    }

    /** Joins an endpoint name, such as {@code join}, to this path. */
    public String endpoint(String name) { return path + name; }

    /** A short, non-secret label for diagnostics. */
    public String label() { return key.substring(0, 8); }

    public boolean sameShare(AskPath other) { return other != null && key.equals(other.key); }

    static String hostOnly(String hostHeader) {
        String value = hostHeader;
        int colon = value.lastIndexOf(':');
        if (colon > 0 && value.indexOf(':') == colon) value = value.substring(0, colon);
        return HostConfig.normalizeHost(value);
    }

    static String digest(String code) {
        try {
            byte[] hash = MessageDigest.getInstance("SHA-256").digest(("setbeam-ask-v1:" + code).getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder();
            for (byte b : hash) hex.append(String.format(Locale.ROOT, "%02x", b));
            return hex.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
