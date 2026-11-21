package com.setbeam.receiver.core;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Setup's list of Setbeam Macs currently offering a short address on this network.
 *
 * <p>Choosing one pairs the TV with that address. Each share still needs the operator's Admit. The advertised name is preferred, such as
 * {@code http://setbeam.local/}, so the pairing follows the Mac across address changes. The
 * service's numeric address is offered only when its name is unusable. Advertised names are
 * unverified labels anyone on the network could copy.
 */
public final class NearbyMacs {
    public static final int MAX_CHOICES = 8;

    private NearbyMacs() {}

    public static final class Choice {
        /** What the list shows, such as "setbeam.local". */
        public final String title;
        /** Secondary text, such as "192.168.1.20". */
        public final String detail;
        /** The address to pair with. */
        public final String address;
        Choice(String title, String detail, String address) { this.title = title; this.detail = detail; this.address = address; }
    }

    public static List<Choice> choices(List<HostMatcher.Service> services) {
        Map<String, Choice> unique = new LinkedHashMap<>();
        for (HostMatcher.Service service : services) {
            if (service == null || !"1".equals(service.txt.get("v")) || !"/".equals(service.txt.get("path"))) continue;
            // The short address answers only on port 80; anything else is not a Setbeam short address.
            if (service.port != 80) continue;
            String name = service.txt.get("host");
            String address = null, title = null;
            if (name != null) {
                try {
                    HostConfig parsed = HostConfig.parse(name, "x");
                    if (parsed.defaultPort() && parsed.scheme.equals("http") && !parsed.isIpLiteral()) { address = parsed.baseUrl(); title = parsed.host; }
                } catch (HostConfig.Invalid ignored) { }
            }
            if (address == null && service.ipv4 != null && HostConfig.isIpv4Literal(service.ipv4)) { address = "http://" + service.ipv4 + "/"; title = service.ipv4; }
            if (address == null || unique.containsKey(address)) continue;
            String detail = service.ipv4 != null && !service.ipv4.equals(title) ? service.ipv4 : "";
            unique.put(address, new Choice(title, detail, address));
        }
        List<Choice> list = new ArrayList<>(unique.values());
        Collections.sort(list, (a, b) -> a.title.toLowerCase(Locale.ROOT).compareTo(b.title.toLowerCase(Locale.ROOT)));
        return list.size() > MAX_CHOICES ? list.subList(0, MAX_CHOICES) : list;
    }
}
