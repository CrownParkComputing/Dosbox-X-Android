package com.dosboxx.app;

import android.content.Context;

import org.json.JSONObject;

import java.io.File;
import java.io.FileWriter;
import java.io.RandomAccessFile;

/**
 * Per-game metadata for the unified Games list: which platform a game is
 * assigned to (DOS or Windows 98) and whether it needs its CD inserted to run
 * (copy protection / CD audio) vs being a no-CD "rip". Stored as one small
 * JSON file per game name, alongside the keymaps.
 *
 * Each getter takes a default (the auto-detected value) and returns the user's
 * stored override if there is one, so games work sensibly before any tagging.
 */
final class GameMeta {

    static final String DOS = "dos";
    static final String WIN98 = "win98";

    static String platform(Context c, String name, String dflt) {
        JSONObject o = read(c, name);
        return o != null ? o.optString("platform", dflt) : dflt;
    }

    static boolean needsCd(Context c, String name, boolean dflt) {
        JSONObject o = read(c, name);
        return o != null ? o.optBoolean("needsCd", dflt) : dflt;
    }

    static void setPlatform(Context c, String name, String p) { put(c, name, "platform", p); }
    static void setNeedsCd(Context c, String name, boolean b) { put(c, name, "needsCd", b); }

    /** Drop a game's metadata (e.g. when it's deleted). */
    static void clear(Context c, String name) {
        File f = file(c, name);
        if (f.isFile()) f.delete();
    }

    // ---- storage ----

    private static void put(Context c, String name, String key, Object val) {
        JSONObject o = read(c, name);
        if (o == null) o = new JSONObject();
        try {
            o.put(key, val);
            FileWriter w = new FileWriter(file(c, name), false);
            w.write(o.toString());
            w.close();
        } catch (Exception ignored) { }
    }

    private static JSONObject read(Context c, String name) {
        File f = file(c, name);
        if (!f.isFile()) return null;
        try {
            byte[] b = new byte[(int) f.length()];
            RandomAccessFile raf = new RandomAccessFile(f, "r");
            try { raf.readFully(b); } finally { raf.close(); }
            return new JSONObject(new String(b, "UTF-8"));
        } catch (Exception e) {
            return null;
        }
    }

    private static File dir(Context c) {
        File d = new File(c.getExternalFilesDir(null), "gamemeta");
        if (!d.exists()) d.mkdirs();
        return d;
    }

    private static File file(Context c, String name) {
        return new File(dir(c), KeyMapStore.safeName(name) + ".json");
    }

    private GameMeta() { }
}
