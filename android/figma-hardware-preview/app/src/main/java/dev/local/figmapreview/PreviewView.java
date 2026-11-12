package dev.local.figmapreview;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.os.SystemClock;
import android.view.MotionEvent;
import android.view.View;

final class PreviewView extends View {
    private static final long MIN_TAP_FEEDBACK_MS = 35;
    private final Runnable finishTap = this::release;
    private final Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG | Paint.ANTI_ALIAS_FLAG);

    private PreviewPack pack;
    private PreviewPack.Button active;
    private int pointer = -1;
    private long pressStarted;
    private ValueAnimator animation;
    private float progress;
    private float scale = 1f;
    private float left;
    private float top;

    PreviewView(Context context) {
        super(context);
    }

    void show(PreviewPack next) {
        clearPress();
        pack = next;
        fit();
        invalidate();
    }

    void clearPress() {
        removeCallbacks(finishTap);
        stopAnimation();
        pointer = -1;
        active = null;
        progress = 0;
        invalidate();
    }

    @Override
    protected void onSizeChanged(int width, int height, int oldWidth, int oldHeight) {
        fit();
    }

    private void fit() {
        if (pack == null) return;
        scale = Math.min((float) getWidth() / pack.screen.getWidth(),
                         (float) getHeight() / pack.screen.getHeight());
        left = (getWidth() - pack.screen.getWidth() * scale) / 2;
        top = (getHeight() - pack.screen.getHeight() * scale) / 2;
    }

    @Override
    protected void onDraw(Canvas canvas) {
        canvas.drawColor(Color.BLACK);
        if (pack == null || scale <= 0) return;
        canvas.save();
        canvas.translate(left, top);
        canvas.scale(scale, scale);
        canvas.drawBitmap(pack.screen, 0, 0, paint);
        if (active != null && progress > 0) {
            Rect area = active.area;
            canvas.save();
            canvas.clipRect(area);
            if (active.face == null && progress < 1) {
                canvas.saveLayerAlpha(area.left, area.top, area.right, area.bottom,
                                      Math.round(255 * progress));
            }
            canvas.drawColor(Color.BLACK);
            canvas.drawBitmap(active.backing, area.left, area.top, paint);
            if (active.face != null) {
                canvas.drawBitmap(active.face, area.left, area.top + active.depth * progress, paint);
            } else if (progress < 1) {
                canvas.restore();
            }
            canvas.restore();
        }
        canvas.restore();
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        if (pack == null || scale <= 0) return false;
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                PreviewPack.Button button = hit(event.getX(), event.getY());
                if (button == null) return false;
                if (button != active) clearPress();
                removeCallbacks(finishTap);
                active = button;
                pressStarted = SystemClock.uptimeMillis();
                pointer = event.getPointerId(0);
                animateTo(1f, active.pressMs);
                return true;
            case MotionEvent.ACTION_MOVE:
                int index = event.findPointerIndex(pointer);
                if (pointer >= 0 && (index < 0 || hit(event.getX(index), event.getY(index)) != active)) {
                    release();
                }
                return true;
            case MotionEvent.ACTION_POINTER_UP:
                if (event.getPointerId(event.getActionIndex()) == pointer) release();
                return true;
            case MotionEvent.ACTION_UP:
                if (pointer >= 0) {
                    if (hit(event.getX(), event.getY()) == active) {
                        performClick();
                        pointer = -1;
                        // A very quick tap should still reach at least one rendered frame.
                        long remaining = MIN_TAP_FEEDBACK_MS - (SystemClock.uptimeMillis() - pressStarted);
                        if (remaining > 0) postDelayed(finishTap, remaining);
                        else release();
                    } else {
                        release();
                    }
                }
                return true;
            case MotionEvent.ACTION_CANCEL:
                if (pointer >= 0) release();
                return true;
            default:
                return true;
        }
    }

    @Override
    public boolean performClick() {
        super.performClick();
        return true;
    }

    private PreviewPack.Button hit(float x, float y) {
        float px = (x - left) / scale;
        float py = (y - top) / scale;
        for (PreviewPack.Button button : pack.buttons) {
            Rect rect = button.area;
            if (px >= rect.left && px < rect.right && py >= rect.top && py < rect.bottom) return button;
        }
        return null;
    }

    private void release() {
        pointer = -1;
        animateTo(0f, active.releaseMs);
    }

    private void stopAnimation() {
        if (animation != null) {
            animation.removeAllUpdateListeners();
            animation.cancel();
            animation = null;
        }
    }

    private void animateTo(float target, int duration) {
        stopAnimation();
        if (duration == 0 || progress == target) {
            progress = target;
            if (target == 0) active = null;
            invalidate();
            return;
        }
        animation = ValueAnimator.ofFloat(progress, target);
        animation.setDuration(duration);
        animation.addUpdateListener(value -> {
            progress = (float) value.getAnimatedValue();
            if (target == 0 && progress == 0) active = null;
            invalidate();
        });
        animation.start();
    }
}
