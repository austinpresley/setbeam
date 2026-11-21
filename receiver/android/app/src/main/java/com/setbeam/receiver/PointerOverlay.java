package com.setbeam.receiver;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.os.SystemClock;
import android.util.AttributeSet;
import android.view.View;

import com.setbeam.receiver.core.Pointer;

import java.util.Collections;
import java.util.List;

/**
 * Other viewers' shared pointers, drawn over the picture. It sits inside the picture's own
 * aspect-fit frame, so 0..1 coordinates map to the shared picture, and below the cover, so no
 * pointer shows while the picture is covered. Presence only: it grants and sends nothing.
 */
public final class PointerOverlay extends View {
    private static final long FADE_MS = 500;
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint ring = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint text = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF pill = new RectF();
    private final float density;
    private List<Pointer> pointers = Collections.emptyList();

    public PointerOverlay(Context context) { this(context, null); }

    public PointerOverlay(Context context, AttributeSet attrs) {
        super(context, attrs);
        density = getResources().getDisplayMetrics().density;
        ring.setStyle(Paint.Style.STROKE);
        ring.setStrokeWidth(2.5f * density);
        ring.setColor(0xFFFFFFFF);
        text.setTextSize(16 * density);
        text.setTypeface(Typeface.DEFAULT_BOLD);
        setWillNotDraw(false);
        setFocusable(false);
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
    }

    /** Replaces the pointers shown. An empty list clears them at once. */
    public void setPointers(List<Pointer> value) {
        pointers = value == null ? Collections.emptyList() : value;
        invalidate();
    }

    @Override protected void onDraw(Canvas canvas) {
        if (pointers.isEmpty()) return;
        long now = SystemClock.elapsedRealtime();
        int width = getWidth(), height = getHeight();
        long nextChange = Long.MAX_VALUE;
        float radius = 11 * density, pad = 8 * density;
        for (Pointer pointer : pointers) {
            long left = pointer.expiresAt - now;
            if (left <= 0) continue;
            // Redraw every frame only while fading; otherwise wake when the next fade begins.
            nextChange = Math.min(nextChange, left > FADE_MS ? left - FADE_MS : 0);
            int alpha = (int) (255 * Math.min(1f, left / (float) FADE_MS));
            int rgb = Pointer.rgb(pointer.color);
            float x = (float) (pointer.x * width), y = (float) (pointer.y * height);
            fill.setColor((alpha << 24) | rgb);
            ring.setAlpha(alpha);
            canvas.drawCircle(x, y, radius, fill);
            canvas.drawCircle(x, y, radius, ring);
            // Name label to the lower right, kept inside the picture.
            float textWidth = text.measureText(pointer.label);
            float labelLeft = Math.min(x + radius + 4 * density, width - textWidth - 2 * pad);
            float labelTop = Math.min(y + radius, height - text.getTextSize() - pad * 1.5f);
            pill.set(Math.max(0, labelLeft), Math.max(0, labelTop), Math.max(0, labelLeft) + textWidth + 2 * pad,
                    Math.max(0, labelTop) + text.getTextSize() + pad);
            canvas.drawRoundRect(pill, pad, pad, fill);
            text.setColor(((Pointer.darkText(pointer.color) ? 0x101318 : 0xFFFFFF)) | (alpha << 24));
            canvas.drawText(pointer.label, pill.left + pad, pill.bottom - pad * 0.5f - text.descent(), text);
        }
        if (nextChange == 0) postInvalidateOnAnimation();
        else if (nextChange != Long.MAX_VALUE) postInvalidateDelayed(nextChange);
    }
}
