package com.setbeam.receiver.core;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Another participant's shared pointer, relative to the shared picture (0..1 on each axis). It is
 * presence only: it grants no control, and this receiver never sends one of its own.
 */
public final class Pointer {
    public static final int MAX_POINTERS = 16;
    public static final long MAX_TTL_MS = 10_000;
    static final String[] COLORS = {"blue", "green", "orange", "pink", "purple", "yellow", "red", "teal", "cyan", "lime", "indigo", "brown"};

    public final int number;
    public final String label;
    public final String color;
    public final double x;
    public final double y;
    /** Monotonic time after which this pointer fades, on the receiver's clock. */
    public final long expiresAt;

    public Pointer(int number, String label, String color, double x, double y, long expiresAt) {
        this.number = number; this.label = label; this.color = color; this.x = x; this.y = y; this.expiresAt = expiresAt;
    }

    /** A known pointer color id, or "blue". */
    public static String validColor(String value) {
        if (value != null) for (String color : COLORS) if (color.equals(value)) return color;
        return "blue";
    }

    /** sRGB as 0xRRGGBB, matching the Mac's palette. */
    public static int rgb(String color) {
        switch (validColor(color)) {
            case "green": return 0x177838;
            case "orange": return 0xFA941A;
            case "pink": return 0xCC2980;
            case "purple": return 0x7540CC;
            case "yellow": return 0xFAD11F;
            case "red": return 0xC42B2B;
            case "teal": return 0x0A7380;
            case "cyan": return 0x3DC7E6;
            case "lime": return 0xA6D93B;
            case "indigo": return 0x4238C9;
            case "brown": return 0x8A5426;
            case "blue": default: return 0x1A5ED9;
        }
    }

    /** Whether the name label needs dark text for contrast, as on the Mac. */
    public static boolean darkText(String color) {
        String c = validColor(color);
        return c.equals("orange") || c.equals("yellow") || c.equals("cyan") || c.equals("lime");
    }

    /**
     * Parses a {@code pointers} message's items. Coordinates must be finite and are clamped to the
     * picture; each pointer expires after its reported ttl, at most 10 s.
     */
    public static List<Pointer> parse(JSONArray items, long now) {
        List<Pointer> pointers = new ArrayList<>();
        if (items == null) return pointers;
        for (int i = 0; i < items.length() && pointers.size() < MAX_POINTERS; i++) {
            JSONObject item = items.optJSONObject(i);
            if (item == null) continue;
            Object rawX = item.opt("x"), rawY = item.opt("y");
            if (!(rawX instanceof Number) || !(rawY instanceof Number)) continue;
            double x = ((Number) rawX).doubleValue(), y = ((Number) rawY).doubleValue();
            if (!Double.isFinite(x) || !Double.isFinite(y)) continue;
            long ttl = Math.max(0, Math.min(MAX_TTL_MS, item.optLong("ttl", 0)));
            if (ttl == 0) continue;
            String label = HostConfig.cleanLabel(item.optString("label", ""), HostConfig.MAX_NAME);
            pointers.add(new Pointer(item.optInt("n", 0), label == null ? "Viewer" : label, validColor(item.optString("color", null)),
                    clamp(x), clamp(y), now + ttl));
        }
        return Collections.unmodifiableList(pointers);
    }

    private static double clamp(double value) { return Math.max(0, Math.min(1, value)); }
}
