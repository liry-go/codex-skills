package dev.local.figmapreview;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Rect;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.DataInputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

final class PreviewPack {
    private static final int MAX_BYTES = 24 * 1024 * 1024;
    private static final int MAX_MANIFEST = 64 * 1024;
    private static final int MAX_EDGE = 4096;
    private static final int MAX_PIXELS = 24 * 1024 * 1024;
    private static final int MAX_BUTTONS = 64;

    final Bitmap screen;
    final List<Button> buttons;

    private PreviewPack(Bitmap screen, List<Button> buttons) {
        this.screen = screen;
        this.buttons = buttons;
    }

    static PreviewPack read(File file) throws IOException, JSONException {
        require(file.length() > 0 && file.length() <= MAX_BYTES, "Invalid preview ZIP size");
        try (ZipFile zip = new ZipFile(file)) {
            Set<String> names = new HashSet<>();
            long total = 0;
            Enumeration<? extends ZipEntry> entries = zip.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                require(entry.getSize() >= 0 && entry.getSize() <= MAX_BYTES, "Invalid ZIP entry size");
                total += entry.getSize();
                require(!entry.isDirectory() && names.add(entry.getName())
                        && names.size() <= 2 + MAX_BUTTONS * 2 && total <= MAX_BYTES,
                        "Invalid preview ZIP entries");
            }
            ZipEntry manifest = zip.getEntry("preview.json");
            require(manifest != null && manifest.getSize() <= MAX_MANIFEST, "Missing or oversized manifest");
            JSONObject metadata;
            try (DataInputStream input = new DataInputStream(zip.getInputStream(manifest))) {
                byte[] bytes = new byte[(int) manifest.getSize()];
                input.readFully(bytes);
                require(input.read() == -1, "Invalid manifest size");
                metadata = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
            }
            integer(metadata.get("schema"), 1, 1, "schema");
            JSONArray definitions = metadata.getJSONArray("buttons");
            require(definitions.length() <= MAX_BUTTONS, "Too many buttons");

            Images images = new Images(zip);
            Bitmap screen = images.load("screen.png", 0, 0);
            List<Button> buttons = new ArrayList<>();
            for (int i = 0; i < definitions.length(); i++) {
                JSONObject definition = definitions.getJSONObject(i);
                String label = definition.getString("label");
                require(!label.trim().isEmpty() && label.trim().length() <= 200, "Invalid button label");
                JSONArray rect = definition.getJSONArray("rect");
                require(rect.length() == 4, "Button needs a four-value rectangle");
                int left = integer(rect.get(0), 0, screen.getWidth() - 1, "left");
                int top = integer(rect.get(1), 0, screen.getHeight() - 1, "top");
                int width = integer(rect.get(2), 1, screen.getWidth() - left, "width");
                int height = integer(rect.get(3), 1, screen.getHeight() - top, "height");
                Rect area = new Rect(left, top, left + width, top + height);
                for (Button other : buttons) {
                    require(!Rect.intersects(area, other.area), "Overlapping button rectangles");
                }
                int pressMs = integer(definition.has("press_ms") ? definition.get("press_ms") : 0, 0, 1000, "press_ms");
                int releaseMs = integer(definition.has("release_ms") ? definition.get("release_ms") : 0, 0, 1000, "release_ms");
                String mode = definition.getString("mode");
                if (mode.equals("patch")) {
                    Bitmap patch = images.tile(definition, "pressed", width, height);
                    buttons.add(new Button(area, patch, null, 0, pressMs, releaseMs));
                } else {
                    require(mode.equals("sink"), "Unknown press mode");
                    Bitmap underlay = images.tile(definition, "underlay", width, height);
                    Bitmap face = images.tile(definition, "face", width, height);
                    int depth = integer(definition.get("depth"), 1, height - 1, "depth");
                    buttons.add(new Button(area, underlay, face, depth, pressMs, releaseMs));
                }
            }
            names.remove("preview.json");
            require(names.equals(images.loaded.keySet()), "Unused preview ZIP entries");
            return new PreviewPack(screen, buttons);
        }
    }

    private static void require(boolean condition, String message) throws IOException {
        if (!condition) throw new IOException(message);
    }

    private static int integer(Object value, int min, int max, String name) throws IOException {
        require(value instanceof Integer && (int) value >= min && (int) value <= max,
                "Invalid " + name);
        return (int) value;
    }

    static final class Button {
        final Rect area;
        final Bitmap backing;
        final Bitmap face;
        final int depth;
        final int pressMs;
        final int releaseMs;

        Button(Rect area, Bitmap backing, Bitmap face, int depth, int pressMs, int releaseMs) {
            this.area = area;
            this.backing = backing;
            this.face = face;
            this.depth = depth;
            this.pressMs = pressMs;
            this.releaseMs = releaseMs;
        }
    }

    private static final class Images {
        final ZipFile zip;
        final Map<String, Bitmap> loaded = new HashMap<>();
        int pixelCount;

        Images(ZipFile zip) {
            this.zip = zip;
        }

        Bitmap tile(JSONObject definition, String key, int width, int height)
                throws JSONException, IOException {
            String name = definition.getString(key);
            require(name.matches("[A-Za-z0-9][A-Za-z0-9_.-]{0,91}\\.png") && !name.equals("screen.png"),
                    "Invalid tile filename");
            return load(name, width, height);
        }

        Bitmap load(String name, int width, int height) throws IOException {
            Bitmap bitmap = loaded.get(name);
            if (bitmap == null) {
                ZipEntry entry = zip.getEntry(name);
                require(entry != null, "Missing image " + name);
                BitmapFactory.Options options = new BitmapFactory.Options();
                options.inJustDecodeBounds = true;
                try (InputStream input = zip.getInputStream(entry)) {
                    BitmapFactory.decodeStream(input, null, options);
                }
                require("image/png".equals(options.outMimeType)
                                && options.outWidth > 0 && options.outWidth <= MAX_EDGE
                                && options.outHeight > 0 && options.outHeight <= MAX_EDGE,
                        "Invalid PNG " + name);
                pixelCount += options.outWidth * options.outHeight;
                require(pixelCount <= MAX_PIXELS, "Preview uses too much bitmap memory");
                options.inJustDecodeBounds = false;
                options.inPreferredConfig = Bitmap.Config.ARGB_8888;
                try (InputStream input = zip.getInputStream(entry)) {
                    bitmap = BitmapFactory.decodeStream(input, null, options);
                }
                require(bitmap != null, "Could not decode " + name);
                bitmap.setDensity(Bitmap.DENSITY_NONE);
                loaded.put(name, bitmap);
            }
            require(width == 0 || (bitmap.getWidth() == width && bitmap.getHeight() == height),
                    "Tile size does not match its button rectangle");
            return bitmap;
        }
    }
}
