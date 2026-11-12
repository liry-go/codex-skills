package dev.local.figmapreview;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.widget.FrameLayout;
import android.widget.TextView;

import org.json.JSONException;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class PreviewActivity extends Activity {
    private static final String TAG = "FigmaHardwarePreview";
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private PreviewView preview;
    private TextView placeholder;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        FrameLayout layout = new FrameLayout(this);
        preview = new PreviewView(this);
        layout.addView(preview, new FrameLayout.LayoutParams(-1, -1));

        placeholder = new TextView(this);
        placeholder.setText(R.string.empty_preview);
        placeholder.setTextColor(Color.WHITE);
        placeholder.setGravity(Gravity.CENTER);
        layout.addView(placeholder, new FrameLayout.LayoutParams(-1, -1));
        setContentView(layout);
        hideSystemBars();

        File saved = new File(getFilesDir(), "preview.zip");
        if (saved.isFile()) worker.execute(() -> restore(saved));
        accept(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        accept(intent);
    }

    @Override
    public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (focused) hideSystemBars();
        else if (preview != null) preview.clearPress();
    }

    @Override
    protected void onPause() {
        preview.clearPress();
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        worker.shutdown();
        super.onDestroy();
    }

    @SuppressWarnings("deprecation")
    private void hideSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            getWindow().setDecorFitsSystemWindows(false);
            WindowInsetsController controller = getWindow().getInsetsController();
            if (controller != null) {
                controller.hide(WindowInsets.Type.systemBars());
                controller.setSystemBarsBehavior(
                        WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        } else {
            getWindow().getDecorView().setSystemUiVisibility(
                    View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    | View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        }
    }

    private void accept(Intent intent) {
        String id = intent.getStringExtra("preview_id");
        if (id != null && id.matches("[a-f0-9]{32}")) {
            worker.execute(() -> importPreview(id));
        }
    }

    private void restore(File file) {
        try {
            PreviewPack pack = PreviewPack.read(file);
            runOnUiThread(() -> display(pack));
        } catch (IOException | JSONException error) {
            Log.w(TAG, "Could not restore saved preview", error);
        }
    }

    private void importPreview(String id) {
        File incoming = new File(getFilesDir(), "incoming-" + id + ".zip");
        File saved = new File(getFilesDir(), "preview.zip");
        try {
            PreviewPack pack = PreviewPack.read(incoming);
            if (!incoming.renameTo(saved)) throw new IOException("Could not save the preview");
            runOnUiThread(() -> {
                display(pack);
                acknowledge(id, "ok");
            });
        } catch (IOException | JSONException error) {
            Log.w(TAG, "Could not load preview", error);
            acknowledge(id, "Viewer rejected the preview: " + error.getMessage());
        }
    }

    private void display(PreviewPack pack) {
        preview.show(pack);
        placeholder.setVisibility(View.GONE);
    }

    private void acknowledge(String id, String response) {
        File status = new File(getFilesDir(), "status-" + id);
        File temporary = new File(getFilesDir(), "status-" + id + ".tmp");
        try {
            Files.write(temporary.toPath(), response.getBytes(StandardCharsets.UTF_8));
            if (!temporary.renameTo(status)) throw new IOException("Could not send preview status");
        } catch (IOException error) {
            Log.w(TAG, "Could not send preview status", error);
        }
    }
}
