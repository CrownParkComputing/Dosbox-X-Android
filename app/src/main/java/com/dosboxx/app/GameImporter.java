package com.dosboxx.app;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ContentResolver;
import android.content.Intent;
import android.net.Uri;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Guided DOS / Windows 98 game import via the system file picker (SAF
 * ACTION_OPEN_DOCUMENT). The launcher has two entry points: "Add CD game"
 * and "Add rip game". After the user picks a file, this class asks which
 * platform the game targets and starts the matching install path.
 *
 * Routing:
 *
 *   - CD game + MS-DOS: copy media to cds/, mount it as D:, boot DOS setup.
 *   - CD game + Windows 98: copy media to cds/, boot Win98 with it mounted.
 *   - Rip game + MS-DOS: unzip/7z to games/<name>/ and launch from there.
 *   - Rip game + Windows 98: keep a .zip rip as setup media, convert it to
 *     an ISO on first boot, and boot Win98 with it mounted.
 *
 * The legacy import/ drop folder still works — the importer's
 * ArchiveExtractor.classify() heuristic decides kind there.
 */
final class GameImporter {

    /** What the picked archive is destined to become. */
    public static final int KIND_DOS_GAME      = 0;
    public static final int KIND_DOS_CD        = 1;
    public static final int KIND_DOS_CD_SETUP  = 2;
    public static final int KIND_WIN98_MEDIA   = 3;

    /** Request code used by GameLauncherActivity for ACTION_OPEN_DOCUMENT. */
    public static final int REQ_PICK = 4242;
    public static final int REQ_PICK_CD_GAME = 4243;
    public static final int REQ_PICK_RIP_GAME = 4244;

    private GameImporter() { }

    /** Launch the system file picker. The activity receives the result via
     *  onActivityResult(...) and forwards to {@link #onPickResult}. */
    public static void startSafPicker(Activity a) {
        startSafPicker(a, REQ_PICK);
    }

    public static void startSafPicker(Activity a, int requestCode) {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        // .zip / .7z / .iso / .cue / .bin / .img — the user picks any of
        // them and the import dialog figures out which kind it is from the
        // extension. ACTION_OPEN_DOCUMENT with no type works too, but the
        // MIME hints make the picker more useful (Drive shows archives and
        // images more prominently when it knows what we want).
        i.setType("*/*");
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.putExtra(Intent.EXTRA_MIME_TYPES, new String[]{
            "application/zip",
            "application/x-7z-compressed",
            "application/octet-stream",
            "application/x-cd-image",
            "application/x-iso9660-image",
            "*/*"
        });
        a.startActivityForResult(i, requestCode);
    }

    /** Activity should call this from onActivityResult when requestCode == REQ_PICK. */
    public static void onPickResult(final Activity a, final Intent data,
                                    final GameLauncherActivity host) {
        onPickResult(a, data, host, REQ_PICK);
    }

    public static void onPickResult(final Activity a, final Intent data,
                                    final GameLauncherActivity host,
                                    final int requestCode) {
        if (data == null || data.getData() == null) return;
        final Uri uri = data.getData();
        // Take a guess at kind from the filename first — we can re-prompt if
        // wrong. The picker hands us the display name; basename it.
        String name = queryDisplayName(a, uri);
        if (name == null) name = uri.getLastPathSegment();
        if (name == null) name = "game";
        final String base = stripExt(name);
        final String ext = extOf(name);

        if (requestCode == REQ_PICK_CD_GAME) {
            if (!isCdMediaName(name)) {
                Toast.makeText(a,
                    "CD games need .iso, .cue, .bin, .img, .zip, or .7z media.",
                    Toast.LENGTH_LONG).show();
                return;
            }
            promptPlatform(a, "Add CD game", base,
                () -> importSafUri(a, host, uri, base, ext, KIND_DOS_CD_SETUP),
                () -> importSafUri(a, host, uri, base, ext, KIND_WIN98_MEDIA));
            return;
        }

        if (requestCode == REQ_PICK_RIP_GAME) {
            promptPlatform(a, "Add rip game", base,
                () -> importSafUri(a, host, uri, base, ext, KIND_DOS_GAME),
                () -> {
                    if (!ext.equalsIgnoreCase("zip")) {
                        Toast.makeText(a,
                            "Windows 98 rip import needs a .zip so it can be mounted as a CD.",
                            Toast.LENGTH_LONG).show();
                        return;
                    }
                    importSafUri(a, host, uri, base, ext, KIND_WIN98_MEDIA);
                });
            return;
        }

        // Pick a kind by the file's extension. The user can correct it.
        final int guessedKind = kindForName(name);

        // Confirm + maybe let the user override the kind.
        final String[] options;
        final int[] kinds;
        if (guessedKind == KIND_DOS_CD) {
            options = new String[]{
                "Setup this CD in Windows 98",
                "Setup this CD in MS-DOS",
                "Add to CD library only",
                "Add as MS-DOS rip folder"
            };
            kinds   = new int[]{KIND_WIN98_MEDIA, KIND_DOS_CD_SETUP, KIND_DOS_CD, KIND_DOS_GAME};
        } else {
            options = new String[]{
                "Install as MS-DOS rip",
                "Use as Windows 98 setup media",
                "Add to CD library"
            };
            kinds   = new int[]{KIND_DOS_GAME, KIND_WIN98_MEDIA, KIND_DOS_CD};
        }
        new AlertDialog.Builder(a)
            .setTitle("Add " + base)
            .setItems(options, (d, w) -> importSafUri(a, host, uri, base, ext, kinds[w]))
            .setNegativeButton("Cancel", null)
            .show();
    }

    private static void promptPlatform(final Activity a, String title, String base,
                                       final Runnable dos, final Runnable win98) {
        new AlertDialog.Builder(a)
            .setTitle(title + ": " + base)
            .setItems(new String[]{"MS-DOS", "Windows 98"}, (d, w) -> {
                if (w == 0) dos.run();
                else        win98.run();
            })
            .setNegativeButton("Cancel", null)
            .show();
    }

    /** Copy a SAF Uri and route it to games/ or cds/ depending on kind. */
    private static void importSafUri(final Activity a, final GameLauncherActivity host,
                                     final Uri uri, final String base, final String ext,
                                     final int kind) {
        final String safe = safeName(base);
        final boolean archiveMedia = (kind == KIND_DOS_CD || kind == KIND_DOS_CD_SETUP
            || kind == KIND_WIN98_MEDIA)
            && (ext.equalsIgnoreCase("zip") || ext.equalsIgnoreCase("7z"));
        // Disc images go to the visible CD library. Archive-backed media is a
        // reusable source package, so keep it in the hidden archive collection;
        // the launcher extracts one temporary mountable image per run.
        final File destDir, destFile;
        if (archiveMedia) {
            destDir = host.getCdArchivesDir();
            destFile = new File(destDir, safe + "." + ext);
        } else if (kind == KIND_DOS_CD || kind == KIND_DOS_CD_SETUP || kind == KIND_WIN98_MEDIA) {
            destDir = host.getCdsDir();
            destFile = new File(destDir, safe + "." + ext);
        } else {
            destDir = host.getImportDir();
            destFile = new File(destDir, safe + "." + ext);
        }
        if (!destDir.isDirectory()) destDir.mkdirs();
        if (destFile.exists()) destFile.delete();

        final AlertDialog dlg = makeProgressDialog(a, "Copying " + base + "." + ext + "…");
        dlg.show();

        final File fDest = destFile;
        final File fDestDir = destDir;
        new Thread(() -> {
            boolean copied = false;
            try {
                ContentResolver cr = a.getContentResolver();
                try (InputStream in = cr.openInputStream(uri);
                     OutputStream out = new FileOutputStream(fDest)) {
                    if (in == null) throw new Exception("couldn't open picked file");
                    byte[] buf = new byte[1 << 16];
                    int n;
                    while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                    copied = true;
                }
            } catch (Exception e) {
                // leave copied=false; toast below
            }
            final boolean fCopied = copied;
            a.runOnUiThread(() -> {
                dlg.dismiss();
                if (!fCopied) {
                    fDest.delete();
                    Toast.makeText(a, "Couldn't copy " + base + ".", Toast.LENGTH_LONG).show();
                    return;
                }
                if (archiveMedia && kind == KIND_DOS_CD) {
                    Toast.makeText(a, base + " added to the CD collection.", Toast.LENGTH_LONG).show();
                    host.rescan();
                } else if (kind == KIND_DOS_CD) {
                    Toast.makeText(a, base + " added to the CD library.", Toast.LENGTH_LONG).show();
                    host.rescan();
                } else if (kind == KIND_DOS_CD_SETUP) {
                    host.rescan();
                    host.installCdToMsdos(fDest);
                } else if (kind == KIND_WIN98_MEDIA) {
                    host.rescan();
                    host.setupWin98FromMedia(fDest);
                } else {
                    // Archive → existing extract path (handles games/ extract
                    // and the setup-then-pick chain).
                    host.runImport(fDest, dlg);
                }
            });
        }).start();
    }

    // ---- helper: which kind does the user mean for this file? ----

    private static int kindForName(String name) {
        String n = name.toLowerCase(Locale.US);
        if (n.endsWith(".iso") || n.endsWith(".cue") || n.endsWith(".bin") || n.endsWith(".img"))
            return KIND_DOS_CD;
        return KIND_DOS_GAME;
    }

    private static boolean isCdMediaName(String name) {
        String n = name.toLowerCase(Locale.US);
        return n.endsWith(".iso") || n.endsWith(".cue") || n.endsWith(".bin")
            || n.endsWith(".img") || n.endsWith(".zip") || n.endsWith(".7z");
    }

    private static String extOf(String name) {
        int dot = name.lastIndexOf('.');
        return dot >= 0 ? name.substring(dot + 1) : "";
    }

    private static String stripExt(String name) {
        int dot = name.lastIndexOf('.');
        return dot > 0 ? name.substring(0, dot) : name;
    }

    private static String safeName(String s) {
        StringBuilder sb = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_')
                sb.append(c);
            else sb.append('_');
        }
        String out = sb.toString().trim();
        return out.isEmpty() ? "game" : out;
    }

    private static String queryDisplayName(Activity a, Uri uri) {
        try (android.database.Cursor c = a.getContentResolver().query(uri, null, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                int idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME);
                if (idx >= 0) return c.getString(idx);
            }
        } catch (Exception ignored) { }
        return null;
    }

    // ---- installer detection ----

    /** Find a setup-style exe in folder, or null. We mirror findSetup's
     *  rules but go a bit deeper (case-insensitive, depth 3, prefer .exe). */
    public static File findInstaller(File folder) {
        List<File> bats = new ArrayList<>();
        List<File> exes = new ArrayList<>();
        scanLaunchers(folder, 3, bats, exes);
        for (File f : exes) {
            String n = f.getName().toLowerCase(Locale.US);
            if (n.startsWith("setup") || n.startsWith("install") || n.startsWith("dosinst")) return f;
        }
        for (File f : bats) {
            String n = f.getName().toLowerCase(Locale.US);
            if (n.startsWith("setup") || n.startsWith("install") || n.startsWith("dosinst")) return f;
        }
        return null;
    }

    private static void scanLaunchers(File dir, int depth, List<File> bats, List<File> exes) {
        File[] kids = dir.listFiles();
        if (kids == null) return;
        for (File f : kids) {
            if (f.isDirectory()) { if (depth > 0) scanLaunchers(f, depth - 1, bats, exes); }
            else {
                String n = f.getName().toLowerCase(Locale.US);
                if (n.endsWith(".bat")) bats.add(f);
                else if (n.endsWith(".exe") || n.endsWith(".com")) exes.add(f);
            }
        }
    }

    // ---- progress dialog factory (matches the one in GameLauncherActivity) ----

    private static AlertDialog makeProgressDialog(Activity a, String title) {
        int pad = (int) (20 * a.getResources().getDisplayMetrics().density);
        LinearLayout box = new LinearLayout(a);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(pad, pad, pad, pad);
        TextView msg = new TextView(a);
        msg.setText(title);
        msg.setTextColor(0xFFE0E0E0);
        box.addView(msg);
        ProgressBar bar = new ProgressBar(a, null, android.R.attr.progressBarStyleHorizontal);
        bar.setIndeterminate(true);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        blp.topMargin = pad;
        box.addView(bar, blp);
        return new AlertDialog.Builder(a)
            .setView(box)
            .setCancelable(false)
            .create();
    }
}
