package com.setbeam.receiver.core;

import java.net.URI;
import java.net.URISyntaxException;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * The one Mac this receiver is paired with: an http(s) base URL pointing at a Setbeam short
 * address, such as {@code http://setbeam.local/}, plus the receiver's chosen label.
 *
 * <p>The URL is the root of the ask-only short address. It never carries a viewing-link code,
 * credentials, query, or fragment, so the stored pairing is not a media credential. The name is a
 * label the operator sees as unverified; it is not an identity.
 */
public final class HostConfig {
    public static final int MAX_NAME = 40;
    private static final Pattern HOST_LABELS = Pattern.compile("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$");
    private static final Pattern IPV4 = Pattern.compile("^(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)(\\.(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){3}$");

    public final String scheme;
    public final String host;
    public final int port;
    public final String name;

    private HostConfig(String scheme, String host, int port, String name) {
        this.scheme = scheme; this.host = host; this.port = port; this.name = name;
    }

    /** Thrown with a message suitable for the setup screen. */
    public static final class Invalid extends Exception {
        public Invalid(String message) { super(message); }
    }

    /**
     * Validates a typed or provisioned host. A bare name such as {@code setbeam.local} means
     * {@code http://setbeam.local/}. Only the root path is accepted: a full viewing link would put
     * the link's private code, which is also a media credential, into saved settings.
     */
    public static HostConfig parse(String rawHost, String rawName) throws Invalid {
        String name = cleanName(rawName);
        if (name == null) throw new Invalid("Enter a name the operator will recognize.");
        if (rawHost == null || rawHost.trim().isEmpty()) throw new Invalid("Enter the Mac's address, such as setbeam.local.");
        String text = rawHost.trim();
        if (!text.contains("://")) text = "http://" + text;
        URI uri;
        try { uri = new URI(text); } catch (URISyntaxException e) { throw new Invalid("That address is not valid."); }
        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.ROOT);
        if (!scheme.equals("http") && !scheme.equals("https")) throw new Invalid("Use an http:// or https:// address.");
        if (uri.getRawUserInfo() != null) throw new Invalid("The address cannot contain a user name or password.");
        if (uri.getRawQuery() != null || uri.getRawFragment() != null) throw new Invalid("Use the Mac's short address only, without a code.");
        String path = uri.getRawPath();
        if (path != null && !path.isEmpty() && !path.equals("/")) throw new Invalid("Use the Mac's short address only, such as http://setbeam.local/. Viewing links with a code are not saved.");
        String host = uri.getHost();
        if (host == null) throw new Invalid("That address has no host name.");
        host = normalizeHost(host);
        if (!isIpv4Literal(host) && !HOST_LABELS.matcher(host).matches()) throw new Invalid("That host name is not valid.");
        int port = uri.getPort();
        if (port == -1) port = scheme.equals("https") ? 443 : 80;
        if (port < 1 || port > 65535) throw new Invalid("That port is not valid.");
        return new HostConfig(scheme, host, port, name);
    }

    /** Lowercase, without a trailing dot. */
    public static String normalizeHost(String host) {
        String value = host.trim().toLowerCase(Locale.ROOT);
        while (value.endsWith(".")) value = value.substring(0, value.length() - 1);
        return value;
    }

    public static boolean isIpv4Literal(String host) { return host != null && IPV4.matcher(host).matches(); }

    public boolean isIpLiteral() { return isIpv4Literal(host); }

    public boolean defaultPort() { return port == (scheme.equals("https") ? 443 : 80); }

    /** The canonical base URL that identifies this pairing, such as {@code http://setbeam.local/}. */
    public String baseUrl() { return scheme + "://" + host + (defaultPort() ? "" : ":" + port) + "/"; }

    /** The {@code Host} header for the root request. */
    public String hostHeader() { return host + (defaultPort() ? "" : ":" + port); }

    /**
     * Same rules as the gateway's viewer names: control characters removed, whitespace collapsed,
     * at most 40 characters. Returns null when nothing remains.
     */
    public static String cleanName(String value) { return cleanLabel(value, MAX_NAME); }

    /** Plain-text label: control and format characters removed, whitespace collapsed, bounded. */
    public static String cleanLabel(String value, int max) {
        if (value == null) return null;
        StringBuilder clean = new StringBuilder();
        value.codePoints().forEach(cp -> {
            if (Character.isWhitespace(cp) || cp == 0x00A0) clean.append(' ');
            else if (Character.getType(cp) != Character.CONTROL && Character.getType(cp) != Character.FORMAT) clean.appendCodePoint(cp);
        });
        String collapsed = clean.toString().trim().replaceAll(" +", " ");
        int[] points = collapsed.codePoints().limit(max).toArray();
        String name = new String(points, 0, points.length).trim();
        return name.isEmpty() ? null : name;
    }

    @Override public boolean equals(Object other) {
        if (!(other instanceof HostConfig)) return false;
        HostConfig o = (HostConfig) other;
        return scheme.equals(o.scheme) && host.equals(o.host) && port == o.port && name.equals(o.name);
    }
    @Override public int hashCode() { return baseUrl().hashCode() * 31 + name.hashCode(); }
    @Override public String toString() { return baseUrl(); }
}
