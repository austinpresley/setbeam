package com.setbeam.receiver.core;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * One session-chat message as this receiver shows it: read-only text with its author's label and
 * reactions. Feed frames attached to a message are not downloaded; the receiver says one was
 * shared. Session chat is session-only, so nothing here is ever written to storage.
 */
public final class ChatLine {
    public static final int MAX_MESSAGES = 100;
    public static final int MAX_TEXT = 1200;

    public final int id;
    public final String name;
    /** A validated pointer color id, such as "teal". */
    public final String color;
    /** Written by the Mac's operator (the DigiTech). */
    public final boolean operator;
    public final String text;
    /** Seconds since 1970, as the Mac reported it. */
    public final double sentAt;
    public final boolean hasFrame;
    public final boolean sampleFrame;
    public final boolean frameUnavailable;
    /** Id of the message this one answers, or 0. */
    public final int replyTo;
    /** "❤️ 2  👍 1" style summary, or empty. */
    public final String reactions;

    public ChatLine(int id, String name, String color, boolean operator, String text, double sentAt,
                    boolean hasFrame, boolean sampleFrame, int replyTo, String reactions) {
        this(id, name, color, operator, text, sentAt, hasFrame, sampleFrame, false, replyTo, reactions);
    }

    private ChatLine(int id, String name, String color, boolean operator, String text, double sentAt,
                     boolean hasFrame, boolean sampleFrame, boolean frameUnavailable, int replyTo, String reactions) {
        this.id = id; this.name = name; this.color = color; this.operator = operator; this.text = text;
        this.sentAt = sentAt; this.hasFrame = hasFrame; this.sampleFrame = sampleFrame; this.frameUnavailable = frameUnavailable; this.replyTo = replyTo;
        this.reactions = reactions;
    }

    /** Parses the gateway's chat array, dropping malformed entries, newest last, at most 100. */
    public static List<ChatLine> parse(JSONArray array) {
        List<ChatLine> lines = new ArrayList<>();
        int start = Math.max(0, array.length() - MAX_MESSAGES);
        for (int i = start; i < array.length(); i++) {
            JSONObject item = array.optJSONObject(i);
            if (item == null) continue;
            int id = item.optInt("id", 0);
            if (id <= 0) continue;
            String name = HostConfig.cleanLabel(item.optString("name", ""), HostConfig.MAX_NAME);
            String text = cleanText(item.optString("text", ""));
            boolean hasFrame = item.optBoolean("hasFrame", false);
            boolean sampleFrame = item.optBoolean("sampleFrame", false);
            boolean unavailable = !hasFrame && item.optBoolean("hadFrame", hasFrame);
            if (text.isEmpty() && !hasFrame && !unavailable) continue;
            lines.add(new ChatLine(id, name == null ? "Viewer" : name, Pointer.validColor(item.optString("color", null)),
                    item.optBoolean("operatorMessage", false), text, item.optDouble("sentAt", 0),
                    hasFrame, sampleFrame, unavailable, Math.max(0, item.optInt("replyTo", 0)),
                    reactions(item.optJSONArray("reactions"))));
        }
        Collections.sort(lines, (a, b) -> Integer.compare(a.id, b.id));
        return Collections.unmodifiableList(lines);
    }

    @Override public boolean equals(Object other) {
        if (!(other instanceof ChatLine)) return false;
        ChatLine line = (ChatLine) other;
        return id == line.id && name.equals(line.name) && color.equals(line.color) && operator == line.operator
                && text.equals(line.text) && Double.compare(sentAt, line.sentAt) == 0 && hasFrame == line.hasFrame
                && sampleFrame == line.sampleFrame && frameUnavailable == line.frameUnavailable
                && replyTo == line.replyTo && reactions.equals(line.reactions);
    }

    @Override public int hashCode() { return id; }

    /** Keeps line breaks; removes other control, format and direction-override characters; bounded. */
    static String cleanText(String value) {
        if (value == null) return "";
        StringBuilder clean = new StringBuilder();
        int count = 0;
        for (int i = 0; i < value.length() && count < MAX_TEXT;) {
            int cp = value.codePointAt(i);
            i += Character.charCount(cp);
            if (cp == '\t') cp = ' ';
            int type = Character.getType(cp);
            if (cp != '\n' && (type == Character.CONTROL || type == Character.FORMAT && cp != 0x200D && cp != 0xFE0F)) continue;
            clean.appendCodePoint(cp);
            count++;
        }
        return clean.toString().trim().replaceAll("\n{3,}", "\n\n");
    }

    static String reactions(JSONArray array) {
        if (array == null) return "";
        StringBuilder text = new StringBuilder();
        for (int i = 0; i < array.length() && i < 6; i++) {
            JSONObject item = array.optJSONObject(i);
            if (item == null) continue;
            String emoji = emoji(item.optString("reaction", ""));
            int count = item.optInt("count", 0);
            if (emoji == null || count <= 0) continue;
            if (text.length() > 0) text.append("  ");
            text.append(emoji).append(' ').append(Math.min(count, 999));
        }
        return text.toString();
    }

    static String emoji(String reaction) {
        switch (reaction) {
            case "heart": return "❤️";
            case "thumbsUp": return "👍";
            case "laugh": return "😂";
            case "surprised": return "😮";
            case "sad": return "😢";
            case "emphasis": return "‼️";
            default: return null;
        }
    }

    /** The text to show, with a placeholder for an attached frame. */
    public String display() {
        String frame = "";
        if (hasFrame) frame = sampleFrame ? "[Shared a SAMPLE MEDIA frame]" : "[Shared a frame]";
        else if (frameUnavailable) frame = sampleFrame ? "[SAMPLE MEDIA frame no longer available]" : "[Shared frame no longer available]";
        if (text.isEmpty()) return frame;
        return frame.isEmpty() ? text : text + "\n" + frame;
    }
}
