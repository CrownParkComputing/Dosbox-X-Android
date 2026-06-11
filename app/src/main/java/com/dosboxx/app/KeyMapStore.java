package com.dosboxx.app;

import android.content.Context;
import android.view.KeyEvent;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

/**
 * Per-game gamepad-to-keyboard keymap, persisted as JSON under
 * <externalFilesDir>/keymaps/<safeName>.json. A null/empty result from
 * {@link #load} means "no override" — the caller should fall back to
 * the hard-coded defaults in SDLActivity.
 */
public final class KeyMapStore {

    private static final String DIR_NAME = "keymaps";

    /** Canonical button names, in the order the editor displays them. */
    public static final String[] BUTTONS = {
        "A", "B", "X", "Y",
        "L1", "R1",
        "START", "SELECT",
        "DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT", "DPAD_CENTER"
    };

    private KeyMapStore() {}

    public static File dir(Context ctx) {
        File d = new File(ctx.getExternalFilesDir(null), DIR_NAME);
        if (!d.exists()) d.mkdirs();
        return d;
    }

    /** Returns a file-safe lowercase identifier derived from the folder name. */
    public static String safeName(String folderName) {
        String lower = folderName.toLowerCase(Locale.US);
        StringBuilder sb = new StringBuilder(lower.length());
        for (int i = 0; i < lower.length(); i++) {
            char c = lower.charAt(i);
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) sb.append(c);
            else sb.append('_');
        }
        String s = sb.toString();
        if (s.isEmpty()) s = "game";
        return s;
    }

    /** Pre-fix behavior: uppercase letters were lost to '_' (so "DOOM" → "____"
     *  and same-length all-caps names collided). Kept only to migrate old files. */
    private static String legacySafeName(String folderName) {
        StringBuilder sb = new StringBuilder(folderName.length());
        for (int i = 0; i < folderName.length(); i++) {
            char c = folderName.charAt(i);
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) sb.append(c);
            else sb.append('_');
        }
        String s = sb.toString();
        if (s.isEmpty()) s = "game";
        return s;
    }

    /** The fallback keymap — same values the launcher used before per-game maps. */
    public static Map<String, Integer> defaultMap() {
        Map<String, Integer> m = new LinkedHashMap<>();
        m.put("A",           KeyEvent.KEYCODE_CTRL_LEFT);
        m.put("B",           KeyEvent.KEYCODE_SPACE);
        m.put("X",           KeyEvent.KEYCODE_ENTER);
        m.put("Y",           KeyEvent.KEYCODE_TAB);
        m.put("L1",          KeyEvent.KEYCODE_SHIFT_LEFT);
        m.put("R1",          KeyEvent.KEYCODE_CTRL_LEFT);
        m.put("START",       KeyEvent.KEYCODE_ENTER);
        m.put("SELECT",      KeyEvent.KEYCODE_ESCAPE);
        m.put("DPAD_UP",     KeyEvent.KEYCODE_DPAD_UP);
        m.put("DPAD_DOWN",   KeyEvent.KEYCODE_DPAD_DOWN);
        m.put("DPAD_LEFT",   KeyEvent.KEYCODE_DPAD_LEFT);
        m.put("DPAD_RIGHT",  KeyEvent.KEYCODE_DPAD_RIGHT);
        m.put("DPAD_CENTER", KeyEvent.KEYCODE_ENTER);
        return m;
    }

    /** Returns a fresh mutable map seeded with defaults. */
    public static Map<String, Integer> newDefaultMap() {
        return new LinkedHashMap<>(defaultMap());
    }

    /**
     * Load a saved keymap. Returns null if no file exists or the file is
     * unreadable / malformed. Callers should fall back to {@link #defaultMap()}.
     */
    public static Map<String, Integer> load(Context ctx, String folderName) {
        File f = new File(dir(ctx), safeName(folderName) + ".json");
        if (!f.isFile()) {
            // One-time migration from the legacy (uppercase-lossy) file name.
            File legacy = new File(dir(ctx), legacySafeName(folderName) + ".json");
            if (legacy.isFile() && !legacy.getName().equals(f.getName())) legacy.renameTo(f);
        }
        if (!f.isFile()) return null;
        try {
            byte[] buf = new byte[(int) f.length()];
            java.io.FileInputStream in = new java.io.FileInputStream(f);
            try {
                int off = 0;
                while (off < buf.length) {
                    int n = in.read(buf, off, buf.length - off);
                    if (n < 0) break;
                    off += n;
                }
            } finally {
                in.close();
            }
            String json = new String(buf, 0, (int) f.length(), "UTF-8");
            return parse(json);
        } catch (Exception e) {
            return null;
        }
    }

    /** Atomic write: write to .tmp, then rename. Preserves the joystick flag. */
    public static boolean save(Context ctx, String folderName, Map<String, Integer> map) {
        return write(ctx, folderName, map, loadJoystickMode(ctx, folderName));
    }

    /**
     * Per-game "joystick mode": the gamepad is passed through to DOS as a real
     * joystick instead of being translated to keyboard keys. Stored alongside
     * the keymap in the same JSON file. ON by default (user preference) —
     * the long-press toggle opts a game out.
     */
    public static boolean loadJoystickMode(Context ctx, String folderName) {
        File f = new File(dir(ctx), safeName(folderName) + ".json");
        if (!f.isFile()) return true;
        try {
            JSONObject root = new JSONObject(readFile(f));
            return root.optBoolean("joystick", true);
        } catch (Exception e) {
            return true;
        }
    }

    public static boolean saveJoystickMode(Context ctx, String folderName, boolean on) {
        return write(ctx, folderName, load(ctx, folderName), on);
    }

    private static boolean write(Context ctx, String folderName, Map<String, Integer> map, boolean joystick) {
        File d = dir(ctx);
        File f = new File(d, safeName(folderName) + ".json");
        File tmp = new File(d, safeName(folderName) + ".json.tmp");
        try {
            Writer w = new OutputStreamWriter(new FileOutputStream(tmp, false), "UTF-8");
            try {
                w.write(toJson(folderName, map, joystick));
            } finally {
                w.close();
            }
            if (!tmp.renameTo(f)) {
                // rename can fail across some filesystems; fall back to copy.
                if (f.exists() && !f.delete()) return false;
                return tmp.renameTo(f);
            }
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /** Delete a saved keymap (used by "Reset to defaults"). */
    public static boolean clear(Context ctx, String folderName) {
        File f = new File(dir(ctx), safeName(folderName) + ".json");
        return !f.exists() || f.delete();
    }

    // ---- JSON (intentionally tiny, no external dependencies) ----

    public static String toJson(String folderName, Map<String, Integer> map) {
        return toJson(folderName, map, false);
    }

    public static String toJson(String folderName, Map<String, Integer> map, boolean joystick) {
        StringBuilder sb = new StringBuilder(256);
        sb.append("{\"game\":\"").append(escape(folderName)).append("\"");
        sb.append(",\"joystick\":").append(joystick);
        sb.append(",\"buttons\":{");
        boolean first = true;
        if (map != null) {
            for (String b : BUTTONS) {
                Integer v = map.get(b);
                if (v == null) continue;
                if (!first) sb.append(',');
                first = false;
                sb.append('"').append(b).append("\":").append(v.intValue());
            }
        }
        sb.append("}}");
        return sb.toString();
    }

    private static String readFile(File f) throws java.io.IOException {
        byte[] buf = new byte[(int) f.length()];
        java.io.FileInputStream in = new java.io.FileInputStream(f);
        try {
            int off = 0;
            while (off < buf.length) {
                int n = in.read(buf, off, buf.length - off);
                if (n < 0) break;
                off += n;
            }
        } finally {
            in.close();
        }
        return new String(buf, "UTF-8");
    }

    public static Map<String, Integer> parse(String json) {
        try {
            JSONObject root = new JSONObject(json);
            JSONObject buttons = root.optJSONObject("buttons");
            if (buttons == null) return null;
            Map<String, Integer> out = new LinkedHashMap<>();
            for (String b : BUTTONS) {
                int v = buttons.optInt(b, Integer.MIN_VALUE);
                if (v != Integer.MIN_VALUE) out.put(b, v);
            }
            return out.isEmpty() ? null : out;
        } catch (JSONException e) {
            return null;
        }
    }

    private static String escape(String s) {
        StringBuilder sb = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default:
                    if (c < 0x20) sb.append(String.format(Locale.US, "\\u%04x", (int) c));
                    else sb.append(c);
            }
        }
        return sb.toString();
    }

    /** Human-friendly label for an Android keycode — used in the editor UI. */
    public static String keycodeLabel(int kc) {
        if (kc == KeyEvent.KEYCODE_UNKNOWN) return "(none)";
        switch (kc) {
            case KeyEvent.KEYCODE_DPAD_UP:     return "DPAD UP";
            case KeyEvent.KEYCODE_DPAD_DOWN:   return "DPAD DOWN";
            case KeyEvent.KEYCODE_DPAD_LEFT:   return "DPAD LEFT";
            case KeyEvent.KEYCODE_DPAD_RIGHT:  return "DPAD RIGHT";
            case KeyEvent.KEYCODE_DPAD_CENTER: return "DPAD CENTER";
            case KeyEvent.KEYCODE_ENTER:       return "ENTER";
            case KeyEvent.KEYCODE_ESCAPE:      return "ESC";
            case KeyEvent.KEYCODE_SPACE:       return "SPACE";
            case KeyEvent.KEYCODE_TAB:         return "TAB";
            case KeyEvent.KEYCODE_SHIFT_LEFT:  return "SHIFT";
            case KeyEvent.KEYCODE_CTRL_LEFT:   return "CTRL";
            case KeyEvent.KEYCODE_ALT_LEFT:    return "ALT";
            case KeyEvent.KEYCODE_BACK:        return "BACK";
            default:
                String n = KeyEvent.keyCodeToString(kc);
                if (n != null && n.startsWith("KEYCODE_")) n = n.substring(8);
                return n != null ? n : ("keycode " + kc);
        }
    }
}
