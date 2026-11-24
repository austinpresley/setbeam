package com.setbeam.receiver.core;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Decides whether a discovered {@code _setbeam._tcp} service is the paired Mac. Discovery only
 * re-finds the configured host; it never connects to the first Mac that happens to answer.
 *
 * <p>With an id hint recorded, only a service advertising that id matches, whatever its label.
 * Without one, the service's TXT {@code host} must be the configured name, or its address must be
 * the configured IPv4 literal. Names and ids are unverified hints that anyone on the network
 * could copy; they are not authentication, and the operator's Admit on the Mac remains the
 * access decision. {@link #plan} always tries the configured name's own address first.
 */
public final class HostMatcher {
    private HostMatcher() {}

    public static final class Service {
        public final String instance;
        public final String ipv4;
        public final int port;
        public final Map<String, String> txt;
        public Service(String instance, String ipv4, int port, Map<String, String> txt) {
            this.instance = instance; this.ipv4 = ipv4; this.port = port; this.txt = txt;
        }
        public String id() {
            String id = txt.get("id");
            return id != null && id.matches("^[0-9a-f]{32}$") ? id : null;
        }
    }

    public enum Verdict { MATCH, OTHER_MAC, NOT_SETBEAM }

    public static Verdict match(HostConfig host, String pinnedId, Service service) {
        if (host == null || service == null) return Verdict.NOT_SETBEAM;
        if (!"1".equals(service.txt.get("v")) || !"/".equals(service.txt.get("path"))) return Verdict.NOT_SETBEAM;
        if (service.ipv4 == null || !HostConfig.isIpv4Literal(service.ipv4) || service.port != 80) return Verdict.NOT_SETBEAM;
        // The short address is plain HTTP on port 80; an https or custom-port pairing is direct only.
        if (!host.scheme.equals("http") || host.port != 80) return Verdict.OTHER_MAC;
        String id = service.id();
        if (pinnedId != null) return pinnedId.equals(id) ? Verdict.MATCH : Verdict.OTHER_MAC;
        if (host.isIpLiteral()) return host.host.equals(service.ipv4) ? Verdict.MATCH : Verdict.OTHER_MAC;
        String advertised = service.txt.get("host");
        if (advertised != null && HostConfig.normalizeHost(advertised).equals(host.host)) return Verdict.MATCH;
        return Verdict.OTHER_MAC;
    }

    /**
     * The configured host's own system-resolved IPv4 addresses come first; matching DNS-SD
     * services are only a fallback, reached at their numeric address. A direct route with an
     * advertisement that contradicts an existing pin is skipped. Only a DNS-corroborated direct
     * candidate may supply a new pin.
     */
    public static List<HttpGateway.Candidate> plan(HostConfig host, String pinnedId, List<InetAddress> resolved, List<Service> services) throws UnknownHostException {
        List<HttpGateway.Candidate> result = new ArrayList<>();
        if (host.isIpLiteral()) resolved = List.of(InetAddress.getByName(host.host));
        for (InetAddress address : resolved) {
            if (address.getAddress().length != 4) continue;
            boolean duplicate = false;
            for (HttpGateway.Candidate c : result) duplicate |= c.address.equals(address);
            if (duplicate) continue;
            String id = null;
            boolean conflicts = false;
            for (Service service : services) {
                if (!address.getHostAddress().equals(service.ipv4) || service.id() == null) continue;
                if (pinnedId != null && !pinnedId.equals(service.id())
                        && match(host, null, service) == Verdict.MATCH) {
                    conflicts = true;
                }
                if (match(host, pinnedId, service) != Verdict.MATCH) continue;
                if (id != null && !id.equals(service.id())) conflicts = true;
                id = service.id();
            }
            if (!conflicts) result.add(new HttpGateway.Candidate(address, host.port, host.hostHeader(), "configured address", id));
            else if (pinnedId == null) result.add(new HttpGateway.Candidate(address, host.port, host.hostHeader(), "configured address", null));
        }
        for (Service service : services) {
            if (match(host, pinnedId, service) != Verdict.MATCH) continue;
            InetAddress address = InetAddress.getByName(service.ipv4);
            boolean duplicate = false;
            for (HttpGateway.Candidate c : result) duplicate |= c.address.equals(address);
            if (!duplicate) result.add(new HttpGateway.Candidate(address, service.port, service.ipv4, "Bonjour", pinnedId));
        }
        return result;
    }
}
