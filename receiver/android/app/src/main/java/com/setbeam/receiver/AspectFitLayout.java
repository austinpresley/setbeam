package com.setbeam.receiver;

import android.content.Context;
import android.util.AttributeSet;
import android.view.View;
import android.widget.FrameLayout;

/**
 * Sizes its child to the largest rectangle with the picture's aspect ratio that fits, centered,
 * so the whole frame is visible without cropping or stretching. WebRTC's SurfaceViewRenderer
 * crops to its view's shape, so the view itself must have the picture's shape.
 */
public final class AspectFitLayout extends FrameLayout {
    private int pictureWidth, pictureHeight;

    public AspectFitLayout(Context context) { super(context); }
    public AspectFitLayout(Context context, AttributeSet attrs) { super(context, attrs); }

    /** Sets the decoded picture size; zero keeps the child at full size. */
    public void setPicture(int width, int height) {
        if (width == pictureWidth && height == pictureHeight) return;
        pictureWidth = width; pictureHeight = height;
        requestLayout();
    }

    @Override protected void onMeasure(int widthSpec, int heightSpec) {
        int width = MeasureSpec.getSize(widthSpec), height = MeasureSpec.getSize(heightSpec);
        setMeasuredDimension(width, height);
        int childWidth = width, childHeight = height;
        if (pictureWidth > 0 && pictureHeight > 0 && width > 0 && height > 0) {
            if ((long) width * pictureHeight > (long) height * pictureWidth) {
                childWidth = (int) Math.max(1, Math.round((double) height * pictureWidth / pictureHeight));
            } else {
                childHeight = (int) Math.max(1, Math.round((double) width * pictureHeight / pictureWidth));
            }
        }
        for (int i = 0; i < getChildCount(); i++) {
            getChildAt(i).measure(MeasureSpec.makeMeasureSpec(childWidth, MeasureSpec.EXACTLY),
                    MeasureSpec.makeMeasureSpec(childHeight, MeasureSpec.EXACTLY));
        }
    }

    @Override protected void onLayout(boolean changed, int left, int top, int right, int bottom) {
        int width = right - left, height = bottom - top;
        for (int i = 0; i < getChildCount(); i++) {
            View child = getChildAt(i);
            int x = (width - child.getMeasuredWidth()) / 2, y = (height - child.getMeasuredHeight()) / 2;
            child.layout(x, y, x + child.getMeasuredWidth(), y + child.getMeasuredHeight());
        }
    }
}
