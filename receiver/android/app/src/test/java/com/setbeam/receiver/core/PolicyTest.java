package com.setbeam.receiver.core;

import static org.junit.Assert.*;

import java.net.InetAddress;
import java.util.Map;

import org.junit.Test;

public class PolicyTest {
    static final String CODE = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    static MiniHttp.Route root(String hostHeader) throws Exception {
        return new MiniHttp.Route("http", InetAddress.getByName("192.168.1.20"), 80, hostHeader, "setbeam.local");
    }

    @Test public void hostConfigAcceptsShortAddressForms() throws Exception {
        HostConfig bare = HostConfig.parse("setbeam.local", "Stage TV");
        assertEquals("http://setbeam.local/", bare.baseUrl());
        assertEquals("setbeam.local", bare.hostHeader());
        assertEquals(80, bare.port);
        HostConfig upper = HostConfig.parse(" HTTP://SetBeam.Local./ ", "  Stage \n  TV ");
        assertEquals("http://setbeam.local/", upper.baseUrl());
        assertEquals("Stage TV", upper.name);
        HostConfig ip = HostConfig.parse("http://192.168.1.20/", "TV");
        assertTrue(ip.isIpLiteral());
        HostConfig custom = HostConfig.parse("http://127.0.0.1:8080", "Test");
        assertEquals("127.0.0.1:8080", custom.hostHeader());
        assertEquals("https://mac.example/", HostConfig.parse("https://mac.example", "TV").baseUrl());
    }

    @Test public void hostConfigRefusesViewingLinksAndCredentials() {
        String[] refused = {"http://setbeam.local/s/" + CODE + "/", "http://setbeam.local/?code=1", "http://u:p@setbeam.local/",
                "ftp://setbeam.local/", "http://setbeam.local/#x", "", "http://bad_host/", "http://setbeam.local:0/"};
        for (String value : refused) {
            try { HostConfig.parse(value, "TV"); fail("accepted " + value); } catch (HostConfig.Invalid expected) { }
        }
        try { HostConfig.parse("setbeam.local", " \u0000​ "); fail("accepted empty name"); } catch (HostConfig.Invalid expected) { }
    }

    @Test public void namesAreBoundedLabels() {
        assertEquals(40, HostConfig.cleanName("x".repeat(80)).length());
        assertEquals("ab", HostConfig.cleanName("a\u0007b"));
        assertNull(HostConfig.cleanName("\t\n"));
    }

    @Test public void redirectMustStayOnTheSameHostAndBeAnAskPath() throws Exception {
        AskPath path = AskPath.fromRedirect(root("setbeam.local"), 302, "http://setbeam.local:52001/s/" + CODE + "/");
        assertEquals("/s/" + CODE + "/", path.path);
        assertEquals(52001, path.route.port);
        assertEquals("192.168.1.20", path.route.address.getHostAddress());
        assertEquals("/s/" + CODE + "/join", path.endpoint("join"));
        assertFalse("the key never contains the code", path.key.contains(CODE));
        assertEquals(64, path.key.length());
        assertFalse(path.label().contains(CODE.substring(0, 8)));

        AskPath numeric = AskPath.fromRedirect(root("192.168.1.20"), 302, "http://192.168.1.20:52001/s/" + CODE + "/");
        assertTrue(numeric.sameShare(path));

        String[][] bad = {
                {"301", "http://setbeam.local:52001/s/" + CODE + "/"},
                {"302", "http://other.local:52001/s/" + CODE + "/"},
                {"302", "https://setbeam.local:52001/s/" + CODE + "/"},
                {"302", "http://setbeam.local/s/" + CODE + "/"},
                {"302", "http://setbeam.local:52001/s/" + CODE.toUpperCase() + "/"},
                {"302", "http://setbeam.local:52001/s/" + CODE + "/join"},
                {"302", "http://setbeam.local:52001/s/" + CODE.substring(2) + "/"},
                {"302", "http://setbeam.local:52001/s/" + CODE + "/?x=1"},
                {"302", "http://user@setbeam.local:52001/s/" + CODE + "/"},
                {"302", "/s/" + CODE + "/"},
                {"302", null},
        };
        for (String[] item : bad) {
            try { AskPath.fromRedirect(root("setbeam.local"), Integer.parseInt(item[0]), item[1]); fail("accepted " + item[1]); }
            catch (AskPath.Rejected expected) { }
        }
    }

    @Test public void differentSharesHaveDifferentKeys() throws Exception {
        String other = "f".repeat(64);
        AskPath a = AskPath.fromRedirect(root("setbeam.local"), 302, "http://setbeam.local:1/s/" + CODE + "/");
        AskPath b = AskPath.fromRedirect(root("setbeam.local"), 302, "http://setbeam.local:1/s/" + other + "/");
        assertNotEquals(a.key, b.key);
        assertFalse(a.sameShare(b));
    }

    @Test public void whepMustBeTheSameMacNumerically() throws Exception {
        AskPath path = AskPath.fromRedirect(root("setbeam.local"), 302, "http://setbeam.local:52001/s/" + CODE + "/");
        WhepTarget target = WhepTarget.validate("http://192.168.1.20:8889/live/whep", path.route);
        assertEquals(8889, target.route.port);
        assertEquals("192.168.1.20", target.route.address.getHostAddress());
        assertEquals("/live/whep/abc-123", target.sessionPath("/live/whep/abc-123"));
        assertEquals("/live/whep/abc", target.sessionPath("http://192.168.1.20:8889/live/whep/abc"));
        assertNull(target.sessionPath("http://192.168.1.99:8889/live/whep/abc"));
        assertNull(target.sessionPath("/other/whep/abc"));
        assertNull(target.sessionPath("/live/whep/../../x"));
        String[] refused = {"http://192.168.1.21:8889/live/whep", "http://setbeam.local:8889/live/whep", "http://192.168.1.20/live/whep",
                "http://192.168.1.20:8889/local/whep", "http://u:p@192.168.1.20:8889/live/whep", "http://192.168.1.20:8889/live/whep?x",
                "file:///live/whep", null};
        for (String value : refused) {
            try { WhepTarget.validate(value, path.route); fail("accepted " + value); } catch (AskPath.Rejected expected) { }
        }
    }

    @Test public void whepNeverDowngradesFromHttps() throws Exception {
        MiniHttp.Route https = new MiniHttp.Route("https", InetAddress.getByName("192.168.1.20"), 443, "mac.example", "mac.example");
        AskPath path = AskPath.fromRedirect(https, 302, "https://mac.example:52001/s/" + CODE + "/");
        try { WhepTarget.validate("http://192.168.1.20:8889/live/whep", path.route); fail("downgrade accepted"); }
        catch (AskPath.Rejected expected) { assertTrue(expected.getMessage().contains("scheme")); }
        assertEquals("https", WhepTarget.validate("https://192.168.1.20:8889/live/whep", path.route).route.scheme);
        AskPath plain = AskPath.fromRedirect(root("setbeam.local"), 302, "http://setbeam.local:52001/s/" + CODE + "/");
        try { WhepTarget.validate("https://192.168.1.20:8889/live/whep", plain.route); fail("scheme change accepted"); }
        catch (AskPath.Rejected expected) { }
    }

    @Test public void configuredAddressComesBeforeBonjourAndOnlyItCorroboratesAnIdHint() throws Exception {
        HostConfig config = HostConfig.parse("setbeam.local", "TV");
        InetAddress real = InetAddress.getByName("192.168.1.20");
        String realId = "a".repeat(32), spoofId = "b".repeat(32);
        HostMatcher.Service spoof = service("192.168.1.66", "setbeam.local", spoofId);
        HostMatcher.Service genuine = service("192.168.1.20", "setbeam.local", realId);

        java.util.List<HttpGateway.Candidate> resolvedPlan = HostMatcher.plan(config, null, java.util.List.of(real), java.util.List.of(spoof, genuine));
        assertEquals("the configured name's own address is tried first", real, resolvedPlan.get(0).address);
        assertEquals("configured address", resolvedPlan.get(0).via);
        assertEquals("setbeam.local", resolvedPlan.get(0).hostHeader);
        assertEquals("only the advertisement at the resolved address becomes the hint", realId, resolvedPlan.get(0).macId);
        assertEquals("the duplicate address is not tried twice", 2, resolvedPlan.size());

        java.util.List<HttpGateway.Candidate> unresolved = HostMatcher.plan(config, null, java.util.List.of(), java.util.List.of(spoof));
        assertEquals("Bonjour is still a fallback when the name does not resolve", 1, unresolved.size());
        assertEquals("192.168.1.66", unresolved.get(0).hostHeader);
        assertNull("an uncorroborated advertisement never becomes the hint", unresolved.get(0).macId);

        java.util.List<HttpGateway.Candidate> hinted = HostMatcher.plan(config, realId, java.util.List.of(), java.util.List.of(spoof, genuine));
        assertEquals(1, hinted.size());
        assertEquals("192.168.1.20", hinted.get(0).hostHeader);
        assertEquals(realId, hinted.get(0).macId);

        HostConfig literal = HostConfig.parse("192.168.1.20", "TV");
        java.util.List<HttpGateway.Candidate> direct = HostMatcher.plan(literal, null, java.util.List.of(), java.util.List.of(spoof));
        assertEquals(1, direct.size());
        assertEquals("configured address", direct.get(0).via);
    }

    @Test public void pinnedMacCanMoveAndConflictingDirectAdvertisementDoesNotReplaceIt() throws Exception {
        HostConfig host = HostConfig.parse("setbeam.local", "TV");
        String paired = "a".repeat(32), replacement = "b".repeat(32);
        InetAddress old = InetAddress.getByName("192.168.1.20");
        java.util.List<HttpGateway.Candidate> plan = HostMatcher.plan(host, paired, java.util.List.of(old), java.util.List.of(
                service("192.168.1.20", "setbeam.local", replacement),
                service("192.168.1.21", "renamed.local", paired)));
        assertEquals(1, plan.size());
        assertEquals("192.168.1.21", plan.get(0).address.getHostAddress());
        assertEquals(paired, plan.get(0).macId);
    }

    static HostMatcher.Service service(String ip, String host, String id) {
        java.util.HashMap<String, String> txt = new java.util.HashMap<>(Map.of("v", "1", "path", "/"));
        if (host != null) txt.put("host", host);
        if (id != null) txt.put("id", id);
        return new HostMatcher.Service("setbeam", ip, 80, txt);
    }

    @Test public void discoveryMatchesOnlyThePairedMac() throws Exception {
        HostConfig config = HostConfig.parse("setbeam.local", "TV");
        String id = "a".repeat(32), other = "b".repeat(32);
        assertEquals(HostMatcher.Verdict.MATCH, HostMatcher.match(config, null, service("192.168.1.20", "setbeam.local", id)));
        assertEquals(HostMatcher.Verdict.MATCH, HostMatcher.match(config, null, service("192.168.1.20", "SETBEAM.local.", id)));
        assertEquals(HostMatcher.Verdict.OTHER_MAC, HostMatcher.match(config, null, service("192.168.1.21", "setbeam-2.local", other)));
        // Once pinned, the id decides, whatever the label; a copied name with another id is refused.
        assertEquals(HostMatcher.Verdict.MATCH, HostMatcher.match(config, id, service("192.168.1.30", "setbeam-2.local", id)));
        assertEquals(HostMatcher.Verdict.OTHER_MAC, HostMatcher.match(config, id, service("192.168.1.20", "setbeam.local", other)));
        assertEquals(HostMatcher.Verdict.OTHER_MAC, HostMatcher.match(config, id, service("192.168.1.20", "setbeam.local", null)));
        HostConfig ip = HostConfig.parse("192.168.1.20", "TV");
        assertEquals(HostMatcher.Verdict.MATCH, HostMatcher.match(ip, null, service("192.168.1.20", "x.local", id)));
        assertEquals(HostMatcher.Verdict.OTHER_MAC, HostMatcher.match(ip, null, service("192.168.1.21", "x.local", id)));
        HostMatcher.Service v2 = new HostMatcher.Service("s", "192.168.1.20", 80, Map.of("v", "2", "path", "/", "host", "setbeam.local"));
        assertEquals(HostMatcher.Verdict.NOT_SETBEAM, HostMatcher.match(config, null, v2));
        HostMatcher.Service noAddress = service(null, "setbeam.local", id);
        assertEquals(HostMatcher.Verdict.NOT_SETBEAM, HostMatcher.match(config, null, noAddress));
        HostMatcher.Service otherPort = new HostMatcher.Service("s", "192.168.1.20", 8080, Map.of("v", "1", "path", "/", "host", "setbeam.local"));
        assertEquals(HostMatcher.Verdict.NOT_SETBEAM, HostMatcher.match(config, null, otherPort));
    }
}
