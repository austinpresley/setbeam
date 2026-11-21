package com.setbeam.receiver.core;

import java.net.InetAddress;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.UnknownHostException;
import java.util.Locale;

/**
 * The media endpoint from an admitted session's {@code config.json}. It must be the numeric WHEP
 * URL on the same Mac address the gateway was reached at, so a gateway response cannot send the
 * receiver's media credentials to another host.
 */
public final class WhepTarget {
    public static final String PATH = "/live/whep";

    public final MiniHttp.Route route;
    public final String path;

    private WhepTarget(MiniHttp.Route route, String path) { this.route = route; this.path = path; }

    public static WhepTarget validate(String whepURL, MiniHttp.Route gateway) throws AskPath.Rejected {
        if (whepURL == null || whepURL.length() > 512) throw new AskPath.Rejected("Missing playback address");
        URI uri;
        try { uri = new URI(whepURL); } catch (URISyntaxException e) { throw new AskPath.Rejected("Invalid playback address"); }
        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.ROOT);
        if (!scheme.equals("http") && !scheme.equals("https")) throw new AskPath.Rejected("Invalid playback scheme");
        // Never weaker than the gateway: an https pairing cannot send media credentials over http.
        if (!scheme.equals(gateway.scheme)) throw new AskPath.Rejected("Playback address changes the scheme");
        if (uri.getRawUserInfo() != null || uri.getRawQuery() != null || uri.getRawFragment() != null) throw new AskPath.Rejected("Invalid playback address");
        String host = uri.getHost() == null ? "" : HostConfig.normalizeHost(uri.getHost());
        if (!HostConfig.isIpv4Literal(host)) throw new AskPath.Rejected("Playback address is not numeric");
        if (!host.equals(gateway.address.getHostAddress())) throw new AskPath.Rejected("Playback address is not the paired Mac");
        int port = uri.getPort();
        if (port < 1 || port > 65535) throw new AskPath.Rejected("Playback address has no port");
        if (!PATH.equals(uri.getRawPath())) throw new AskPath.Rejected("Unexpected playback path");
        InetAddress address;
        try { address = InetAddress.getByAddress(host, gateway.address.getAddress()); } catch (UnknownHostException e) { throw new AskPath.Rejected("Invalid playback address"); }
        String hostHeader = host + ":" + port;
        return new WhepTarget(new MiniHttp.Route(scheme, address, port, hostHeader, host), PATH);
    }

    /**
     * The WHEP session resource from a {@code 201 Created} Location, relative or absolute. It
     * must stay on the same origin under the WHEP path; otherwise there is nothing to delete.
     */
    public String sessionPath(String location) {
        if (location == null || location.isEmpty() || location.length() > 512) return null;
        try {
            URI base = new URI(route.scheme, null, route.address.getHostAddress(), route.port, path, null, null);
            URI resolved = base.resolve(location.trim()).normalize();
            if (!route.scheme.equals(resolved.getScheme()) || resolved.getPort() != route.port) return null;
            if (resolved.getHost() == null || !resolved.getHost().equals(route.address.getHostAddress())) return null;
            String target = resolved.getRawPath();
            if (target == null || !target.startsWith(path + "/") || target.contains("..") || resolved.getRawQuery() != null) return null;
            return target;
        } catch (URISyntaxException | IllegalArgumentException e) {
            return null;
        }
    }
}
