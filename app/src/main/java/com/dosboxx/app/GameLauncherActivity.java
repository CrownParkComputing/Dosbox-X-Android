package com.dosboxx.app;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Simple on-device game launcher for DOSBox-X.
 *
 * Lists games under <externalFilesDir>/games/ (each game = a subfolder, or a
 * disk image .img/.iso/.cue). Picking one writes <externalFilesDir>/dosbox-x.conf
 * with an [autoexec] that mounts + launches it, then starts the emulator
 * (SDLActivity), which loads that conf on startup.
 */
public class GameLauncherActivity extends Activity {

    private File gamesDir;
    private File cdsDir;     // CD library: discs not currently in any changer
    private File importDir;  // drop folder for .zip game archives
    private File confFile;
    private LinearLayout importActions;
    private Button addGameBtn;
    private ListView list;
    private final List<Runnable> rowTap = new ArrayList<>();
    private final List<Runnable> rowHold = new ArrayList<>();
    // Parallel to rowTap/rowHold: when true, the row renders a ⋮ button on
    // the right that opens the same menu as the long-press. Set to true for
    // game/CD rows (where the long-press menu has useful actions) and false
    // for tab-spacer / informational rows.
    private final List<Boolean> rowHasMenu = new ArrayList<>();
    // Set by the ⋮ button's onClick so onItemClick (which also fires for
    // taps that land on the button) knows to skip the row tap. -1 = no
    // suppression; any other value = the position whose tap should be
    // suppressed for this single click.
    private int mSuppressNextRowTap = -1;
    private File mPendingBootDisc;   // the one CD to mount for the next Win98 boot (or null)
    private File mPendingSetupFolder;   // the folder to chain the launch-picker into after the emulator returns
    private boolean mPendingSetupFromCd;   // true when the setup chain started from a CD install (defaults to "needs CD")

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if ((requestCode == GameImporter.REQ_PICK
                || requestCode == GameImporter.REQ_PICK_CD_GAME
                || requestCode == GameImporter.REQ_PICK_RIP_GAME)
                && resultCode == Activity.RESULT_OK) {
            GameImporter.onPickResult(this, data, this, requestCode);
        }
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        initDirs();
        // The conf is always read by the emulator from the app's own dir.
        confFile = new File(getExternalFilesDir(null), "dosbox-x.conf");

        // A game/Windows session is still running (app was minimized, not
        // exited) → resume it instead of showing the launcher; skip the splash.
        boolean emuAlive = emulatorRunning();

        // Brief branded splash on cold start, then the launcher. (On Android
        // 12+ the system also shows the icon splash first; this keeps the full
        // logo visible a moment longer and covers older versions.)
        if (savedInstanceState == null && !emuAlive) {
            android.widget.ImageView splash = new android.widget.ImageView(this);
            splash.setBackgroundColor(0xFF000000);
            splash.setImageResource(R.drawable.splash_logo);
            splash.setScaleType(android.widget.ImageView.ScaleType.FIT_CENTER);
            setContentView(splash);
            new android.os.Handler(android.os.Looper.getMainLooper())
                .postDelayed(this::buildUi, 1100);
        } else {
            buildUi();
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        // If a game/Windows session is still alive, bring it back to the front
        // (resumes the guest where it left off) rather than sitting on the list.
        if (emulatorRunning()) {
            Intent i = new Intent(this, org.libsdl.app.SDLActivity.class);
            i.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            startActivity(i);
            return;
        }
        // Emulator just exited after we ran an installer — open the launch
        // picker so the user can pick the installed game.
        if (mPendingSetupFolder != null) {
            final File folder = mPendingSetupFolder;
            final boolean fromCd = mPendingSetupFromCd;
            mPendingSetupFolder = null;
            mPendingSetupFromCd = false;
            if (hasInstallContent(folder)) {
                Toast.makeText(this, "Setup finished — pick the game.", Toast.LENGTH_SHORT).show();
                showLaunchPickerForFolder(folder, fromCd, true);
            } else {
                deleteEmptyInstallDir(folder);
                Toast.makeText(this,
                    "No files were written to the MS-DOS install folder, so no game was added.",
                    Toast.LENGTH_LONG).show();
                rescan();
            }
        }
    }

    /** True if an emulator session is running in the :emu process (marker file
     *  present AND the process actually alive — a stale marker is cleaned up). */
    private boolean emulatorRunning() {
        File marker = new File(getExternalFilesDir(null), ".emu_running");
        if (!marker.isFile()) return false;
        try {
            android.app.ActivityManager am =
                (android.app.ActivityManager) getSystemService(ACTIVITY_SERVICE);
            List<android.app.ActivityManager.RunningAppProcessInfo> procs = am.getRunningAppProcesses();
            if (procs != null) {
                for (android.app.ActivityManager.RunningAppProcessInfo p : procs) {
                    if (p.processName != null && p.processName.endsWith(":emu")) return true;
                }
            }
        } catch (Exception ignored) { }
        marker.delete();   // process gone — stale marker
        return false;
    }

    // ---- storage setup wizard ----

    private void firstRunStorageWizard() {
        File base = AppConfig.baseDir(this);
        new AlertDialog.Builder(this)
            .setTitle("Set up storage")
            .setMessage("DOSBox-X needs folders for games, CD archives, extracted CDs, and imports.\n\n"
                + "Current folder:\n" + base.getAbsolutePath())
            .setPositiveButton("Use this folder", (d, w) -> acceptCurrentStorage())
            .setNeutralButton("Choose folder", (d, w) -> chooseFolder())
            .setNegativeButton("Use app folder", (d, w) -> applyNewBase(AppConfig.defaultBase(this)))
            .setCancelable(false)
            .show();
    }

    private void acceptCurrentStorage() {
        initDirs();
        AppConfig.markSetupDone(this);
        rescan();
        Toast.makeText(this, "Storage ready: " + AppConfig.baseDir(this).getAbsolutePath(),
            Toast.LENGTH_LONG).show();
    }

    /** Storage location and on-device library maintenance. */
    private void storageWizard() {
        File base = AppConfig.baseDir(this);
        final int pad = dp(18);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(pad, pad, pad, pad);
        TextView path = new TextView(this);
        path.setText("Current folder:\n" + base.getAbsolutePath());
        path.setTextColor(Color.BLACK);
        path.setTextSize(13);
        path.setPadding(0, 0, 0, dp(10));
        box.addView(path);

        final AlertDialog[] dialog = new AlertDialog[1];
        addStorageButton(box, "Set storage folder...", dialog, () -> chooseFolder());
        addStorageButton(box, "Use app folder", dialog, () -> applyNewBase(AppConfig.defaultBase(this)));
        addStorageButton(box, "CD ZIP sources", dialog,
            () -> manageStorageFolder("CD ZIP sources", getCdArchivesDir(), true));
        addStorageButton(box, "Kept extracted CDs", dialog,
            () -> manageStorageFolder("Kept extracted CDs", getKeptExtractedCdsDir(), true));
        addStorageButton(box, "Temporary extracted CD", dialog,
            () -> manageStorageFolder("Temporary extracted CD", getPreparedCdsDir(), true));
        addStorageButton(box, "Visible CD images", dialog,
            () -> manageStorageFolder("Visible CD images", cdsDir, true, true));
        addStorageButton(box, "Installed games", dialog,
            () -> manageStorageFolder("Installed games", gamesDir, false));
        addStorageButton(box, "Download Windows 98 image...", dialog,
            () -> promptDownloadWin98Image());
        addStorageButton(box, "Import folder", dialog,
            () -> manageStorageFolder("Import folder", importDir, true));
        addStorageButton(box, "Clear all DOS games", dialog, () -> confirmClearAllDos());

        dialog[0] = new AlertDialog.Builder(this)
            .setTitle("Storage")
            .setView(box)
            .setNegativeButton("Close", null)
            .create();
        dialog[0].show();
    }

    private void addStorageButton(LinearLayout box, String label, final AlertDialog[] dialog,
                                  final Runnable action) {
        Button b = new Button(this);
        b.setAllCaps(false);
        b.setText(label);
        b.setOnClickListener(v -> {
            if (dialog[0] != null) dialog[0].dismiss();
            action.run();
        });
        box.addView(b, new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
    }

    private void manageStorageFolder(final String title, final File dir, final boolean allowDeleteAll) {
        manageStorageFolder(title, dir, allowDeleteAll, false);
    }

    private void manageStorageFolder(final String title, final File dir,
                                     final boolean allowDeleteAll,
                                     final boolean hideDotEntries) {
        if (!dir.exists()) dir.mkdirs();
        File[] kids = dir.listFiles();
        final List<File> entries = new ArrayList<>();
        if (kids != null) {
            Arrays.sort(kids, NAME);
            for (File f : kids) {
                if (hideDotEntries && f.getName().startsWith(".")) continue;
                entries.add(f);
            }
        }
        final List<String> rows = new ArrayList<>();
        rows.add("Path: " + dir.getAbsolutePath());
        rows.add("Tap an item to delete it");
        if (entries.isEmpty()) rows.add("(empty)");
        for (File f : entries) {
            rows.add((f.isDirectory() ? "DIR  " : "FILE ") + f.getName() + "  " + humanSize(f));
        }
        ArrayAdapter<String> adapter = new ArrayAdapter<String>(this,
            android.R.layout.simple_list_item_1, rows) {
            @Override public View getView(int position, View convertView, ViewGroup parent) {
                TextView tv = (TextView) super.getView(position, convertView, parent);
                tv.setTextSize(position < 2 ? 11 : 12);
                tv.setSingleLine(false);
                tv.setPadding(dp(12), dp(6), dp(12), dp(6));
                return tv;
            }
        };
        AlertDialog.Builder b = new AlertDialog.Builder(this)
            .setTitle(title)
            .setAdapter(adapter, (d, w) -> {
                if (w < 2 || entries.isEmpty()) {
                    manageStorageFolder(title, dir, allowDeleteAll, hideDotEntries);
                    return;
                }
                confirmDeleteStorageEntry(title, dir, entries.get(w - 2), allowDeleteAll, hideDotEntries);
            })
            .setPositiveButton("Refresh", (d, w) -> manageStorageFolder(title, dir, allowDeleteAll, hideDotEntries))
            .setNegativeButton("Back", (d, w) -> storageWizard());
        if (allowDeleteAll && !entries.isEmpty()) {
            b.setNeutralButton("Delete all...", (d, w) ->
                confirmDeleteStorageFolderContents(title, dir, entries, hideDotEntries));
        }
        b.show();
    }

    private void confirmDeleteStorageEntry(final String title, final File parent,
                                           final File entry, final boolean allowDeleteAll,
                                           final boolean hideDotEntries) {
        new AlertDialog.Builder(this)
            .setTitle(entry.getName())
            .setMessage("Delete this " + (entry.isDirectory() ? "folder" : "file") + "?\n\n"
                + entry.getAbsolutePath())
            .setPositiveButton("Delete", (d, w) -> {
                if (entry.isDirectory()) deleteTree(entry);
                else entry.delete();
                Toast.makeText(this, entry.getName() + " deleted.", Toast.LENGTH_SHORT).show();
                rescan();
                manageStorageFolder(title, parent, allowDeleteAll, hideDotEntries);
            })
            .setNegativeButton("Cancel", (d, w) -> manageStorageFolder(title, parent, allowDeleteAll, hideDotEntries))
            .show();
    }

    private void confirmDeleteStorageFolderContents(final String title, final File dir,
                                                    final List<File> entries,
                                                    final boolean hideDotEntries) {
        new AlertDialog.Builder(this)
            .setTitle("Delete all " + title + "?")
            .setMessage("This deletes everything under:\n" + dir.getAbsolutePath())
            .setPositiveButton("Delete all", (d, w) -> {
                for (File entry : entries) {
                    if (entry.isDirectory()) deleteTree(entry);
                    else entry.delete();
                }
                Toast.makeText(this, title + " cleared.", Toast.LENGTH_SHORT).show();
                rescan();
                manageStorageFolder(title, dir, true, hideDotEntries);
            })
            .setNegativeButton("Cancel", (d, w) -> manageStorageFolder(title, dir, true, hideDotEntries))
            .show();
    }

    private static String humanSize(File f) {
        long bytes = storageSize(f);
        if (bytes >= (1L << 30)) return String.format(Locale.US, "%.1f GB", bytes / (double) (1L << 30));
        if (bytes >= (1L << 20)) return String.format(Locale.US, "%.1f MB", bytes / (double) (1L << 20));
        if (bytes >= (1L << 10)) return String.format(Locale.US, "%.1f KB", bytes / (double) (1L << 10));
        return bytes + " B";
    }

    private static long storageSize(File f) {
        if (f == null || !f.exists()) return 0;
        if (f.isFile()) return f.length();
        long total = 0;
        File[] kids = f.listFiles();
        if (kids != null) for (File k : kids) total += storageSize(k);
        return total;
    }

    private void confirmClearAllDos() {
        new AlertDialog.Builder(this)
            .setTitle("Clear all DOS games?")
            .setMessage("This deletes:\n"
                + "• every game folder under games/ (not the Win98 OS bundle)\n"
                + "• every disc in the CD library\n"
                + "• every entry in the import folder\n"
                + "• every per-game keymap and metadata file.\n\n"
                + "This can't be undone.")
            .setPositiveButton("Clear", (d, w) -> clearAllDos())
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void clearAllDos() {
        // The Windows 98 OS bundle lives in games/ as a folder with a big
        // .img inside — find it first so we don't delete it.
        File bootBundle = findBootFolder();
        File[] kids = gamesDir.listFiles();
        int deleted = 0;
        if (kids != null) for (File f : kids) {
            if (f.equals(bootBundle)) continue;
            if (f.getName().startsWith(".")) {
                // .c/ holds per-ISO C: drives; only the boot bundle's is owned
                // by us, and we never touch it. Wipe the rest.
                if (f.isDirectory()) { deleteContents(f); f.delete(); }
                continue;
            }
            if (f.isDirectory()) { deleteContents(f); f.delete(); }
            else                  { f.delete(); }
            deleted++;
        }
        // CD library, import folder — both leaf dirs, full wipe.
        if (cdsDir.isDirectory()) { deleteContents(cdsDir); }
        if (importDir.isDirectory()) { deleteContents(importDir); }
        // Per-game keymaps + gamemeta live in the app dir (always).
        File keymaps = new File(getExternalFilesDir(null), "keymaps");
        File gamemeta = new File(getExternalFilesDir(null), "gamemeta");
        if (keymaps.isDirectory())  deleteContents(keymaps);
        if (gamemeta.isDirectory()) deleteContents(gamemeta);

        Toast.makeText(this, "DOS library cleared (" + deleted + " games removed).", Toast.LENGTH_LONG).show();
        rescan();
    }

    private void promptDownloadWin98Image() {
        String url = configuredWin98ImageUrl();
        if (TextUtils.isEmpty(url)) {
            promptSetWin98DownloadUrl("");
            return;
        }
        confirmWin98Download(url);
    }

    private String configuredWin98ImageUrl() {
        String saved = AppConfig.win98ImageUrl(this);
        if (!TextUtils.isEmpty(saved)) return saved.trim();
        return getString(R.string.win98_image_url).trim();
    }

    private void promptSetWin98DownloadUrl(String current) {
        final EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setHint("https://example.com/windows98.zip");
        input.setText(current);
        input.setSelectAllOnFocus(true);
        int pad = dp(20);
        input.setPadding(pad, pad / 2, pad, pad / 2);
        new AlertDialog.Builder(this)
            .setTitle("Windows 98 image URL")
            .setMessage("Paste an HTTPS URL for a .zip or raw .img that you are allowed to use.")
            .setView(input)
            .setPositiveButton("Save", (d, w) -> {
                String url = input.getText().toString().trim();
                if (!isSupportedWin98DownloadUrl(url)) {
                    Toast.makeText(this, "Use an HTTPS .zip or .img URL.", Toast.LENGTH_LONG).show();
                    return;
                }
                AppConfig.setWin98ImageUrl(this, url);
                confirmWin98Download(url);
            })
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void confirmWin98Download(final String url) {
        File existing = findBootFolder();
        String msg = "Download and install the Windows 98 image into:\n"
            + new File(AppConfig.baseDir(this), "WinBox98").getAbsolutePath()
            + "\n\nSource:\n" + url;
        if (existing != null) {
            msg += "\n\nExisting image folder will be replaced:\n" + existing.getAbsolutePath();
        }
        new AlertDialog.Builder(this)
            .setTitle("Download Windows 98 image?")
            .setMessage(msg)
            .setPositiveButton("Download", (d, w) -> downloadAndInstallWin98Image(url))
            .setNeutralButton("Change URL", (d, w) -> promptSetWin98DownloadUrl(url))
            .setNegativeButton("Cancel", null)
            .show();
    }

    private static boolean isSupportedWin98DownloadUrl(String url) {
        if (url == null) return false;
        String u = url.trim().toLowerCase(Locale.US);
        String path = downloadUrlPath(u);
        return u.startsWith("https://")
            && (path.endsWith(".zip") || path.endsWith(".img"));
    }

    private static String downloadUrlPath(String url) {
        try {
            return new URL(url).getPath().toLowerCase(Locale.US);
        } catch (Exception e) {
            return url == null ? "" : url.toLowerCase(Locale.US);
        }
    }

    private void downloadAndInstallWin98Image(final String url) {
        final int pad = dp(20);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(pad, pad, pad, pad);
        final TextView msg = new TextView(this);
        msg.setText("Starting download...");
        msg.setTextColor(0xFFE0E0E0);
        box.addView(msg);
        final ProgressBar bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        bar.setIndeterminate(true);
        bar.setMax(1000);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        blp.topMargin = dp(12);
        box.addView(bar, blp);
        final AlertDialog dlg = new AlertDialog.Builder(this)
            .setTitle("Windows 98 image")
            .setView(box)
            .setCancelable(false)
            .show();

        new Thread(() -> {
            String error = null;
            File staging = null;
            File finalBootDir = new File(AppConfig.baseDir(this), "WinBox98");
            try {
                if (!isSupportedWin98DownloadUrl(url)) {
                    throw new IOException("Use an HTTPS .zip or .img URL.");
                }
                staging = uniqueDir(new File(importDir, ".win98-download"));
                if (!staging.mkdirs()) throw new IOException("Couldn't create download folder.");
                String lower = downloadUrlPath(url);
                String ext = lower.endsWith(".zip") ? ".zip" : ".img";
                File payload = new File(staging, "download" + ext);
                downloadFile(url, payload, (done, total) -> updateWin98DownloadProgress(
                    msg, bar, "Downloading", done, total));

                File extracted = new File(staging, "WinBox98");
                if (!extracted.mkdirs()) throw new IOException("Couldn't create install folder.");
                if (ext.equals(".img")) {
                    File out = new File(extracted, "windows98.img");
                    if (!payload.renameTo(out) && !(copyFile(payload, out) && payload.delete())) {
                        throw new IOException("Couldn't stage downloaded image.");
                    }
                } else {
                    boolean ok = ArchiveExtractor.extractDiscImages(payload, extracted,
                        (done, total) -> updateWin98DownloadProgress(msg, bar, "Extracting", done, total));
                    if (!ok) throw new IOException("Couldn't extract downloaded archive.");
                }
                if (findBootImage(extracted) == null) {
                    throw new IOException("Downloaded file did not contain a bootable Windows 98 .img.");
                }
                if (finalBootDir.exists() && !deleteTree(finalBootDir)) {
                    throw new IOException("Couldn't replace existing WinBox98 folder.");
                }
                if (!moveTree(extracted, finalBootDir)) {
                    throw new IOException("Couldn't install WinBox98 folder.");
                }
            } catch (IOException e) {
                error = e.getMessage();
            } finally {
                if (staging != null && staging.exists()) deleteTree(staging);
            }
            final String fError = error;
            runOnUiThread(() -> {
                dlg.dismiss();
                if (fError == null) {
                    Toast.makeText(this, "Windows 98 image installed.", Toast.LENGTH_LONG).show();
                    rescan();
                } else {
                    Toast.makeText(this, "Download failed: " + fError, Toast.LENGTH_LONG).show();
                }
            });
        }).start();
    }

    private void updateWin98DownloadProgress(final TextView msg, final ProgressBar bar,
                                             final String label, final long done,
                                             final long total) {
        runOnUiThread(() -> {
            if (total > 0) {
                int permille = (int) Math.min(1000, done * 1000 / total);
                bar.setIndeterminate(false);
                bar.setProgress(permille);
                msg.setText(String.format(Locale.US, "%s %d%%   (%d / %d MB)",
                    label, permille / 10, done >> 20, total >> 20));
            } else {
                msg.setText(label + " " + (done >> 20) + " MB...");
            }
        });
    }

    private static void downloadFile(String url, File out, ArchiveExtractor.Progress progress)
            throws IOException {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setConnectTimeout(30000);
        conn.setReadTimeout(30000);
        conn.setInstanceFollowRedirects(true);
        int code = conn.getResponseCode();
        if (code < 200 || code >= 300) throw new IOException("HTTP " + code);
        long total = conn.getContentLengthLong();
        long done = 0;
        long lastReport = -1;
        try (InputStream in = conn.getInputStream();
             OutputStream os = new FileOutputStream(out)) {
            byte[] buf = new byte[1 << 16];
            int n;
            while ((n = in.read(buf)) > 0) {
                os.write(buf, 0, n);
                done += n;
                if (progress != null && (done - lastReport >= (2L << 20) || lastReport < 0)) {
                    lastReport = done;
                    progress.onProgress(done, total);
                }
            }
        } finally {
            conn.disconnect();
        }
        if (progress != null) progress.onProgress(done, total);
    }

    private void chooseFolder() {
        final List<File> roots = new ArrayList<>();
        File[] dirs = getExternalFilesDirs(null);
        if (dirs != null) {
            for (File d : dirs) {
                if (d == null) continue;
                if (!d.exists()) d.mkdirs();
                if (!d.isDirectory()) continue;
                boolean seen = false;
                for (File r : roots) {
                    if (sameFile(r, d)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) roots.add(d);
            }
        }
        if (roots.isEmpty()) roots.add(AppConfig.defaultBase(this));

        final List<String> labels = new ArrayList<>();
        for (int i = 0; i < roots.size(); i++) {
            File d = roots.get(i);
            labels.add(storageLabel(d, i) + "\n" + d.getAbsolutePath());
        }
        new AlertDialog.Builder(this)
            .setTitle("Storage location")
            .setItems(labels.toArray(new String[0]), (d, w) -> applyNewBase(roots.get(w)))
            .setNegativeButton("Cancel", null)
            .show();
    }

    private String storageLabel(File dir, int index) {
        String path = dir.getAbsolutePath();
        if (path.startsWith("/storage/emulated/")) return "Device storage";
        return index == 0 ? "App storage" : "Removable storage";
    }

    private void applyNewBase(final File newBase) {
        final File oldBase = AppConfig.baseDir(this);
        if (newBase.getAbsolutePath().equals(oldBase.getAbsolutePath())) {
            AppConfig.markSetupDone(this);
            initDirs();
            rescan();
            Toast.makeText(this, "Already storing games there.", Toast.LENGTH_SHORT).show();
            return;
        }
        newBase.mkdirs();
        if (hasLibrary(oldBase)) {
            new AlertDialog.Builder(this)
                .setTitle("Move existing games?")
                .setMessage("Move your current games, CDs and imports to\n" + newBase.getAbsolutePath() + " ?")
                .setPositiveButton("Move", (d, w) -> migrateThenSet(oldBase, newBase))
                .setNeutralButton("Switch (leave old files)", (d, w) -> setBase(newBase, "Storage set."))
                .setNegativeButton("Cancel", null)
                .show();
        } else {
            setBase(newBase, "Games will be stored in " + newBase.getAbsolutePath());
        }
    }

    private void setBase(File newBase, String msg) {
        if (newBase.getAbsolutePath().equals(AppConfig.defaultBase(this).getAbsolutePath())) AppConfig.useDefault(this);
        else AppConfig.setBaseDir(this, newBase);
        AppConfig.markSetupDone(this);
        initDirs();
        rescan();
        Toast.makeText(this, msg, Toast.LENGTH_LONG).show();
    }

    private boolean hasLibrary(File base) {
        for (String s : new String[]{"games", "cds", "import"}) {
            File[] k = new File(base, s).listFiles();
            if (k != null && k.length > 0) return true;
        }
        return false;
    }

    private void migrateThenSet(final File oldBase, final File newBase) {
        final AlertDialog dlg = new AlertDialog.Builder(this)
            .setMessage("Moving games to the new folder…").setCancelable(false).show();
        new Thread(() -> {
            boolean ok = true;
            for (String s : new String[]{"games", "cds", "import"}) {
                ok &= moveTree(new File(oldBase, s), new File(newBase, s));
            }
            final boolean fOk = ok;
            runOnUiThread(() -> {
                dlg.dismiss();
                setBase(newBase, fOk ? "Games moved." : "Moved (some files couldn't be moved).");
            });
        }).start();
    }

    /** Move a directory tree (fast rename when possible, else copy+delete). */
    private boolean moveTree(File src, File dst) {
        if (!src.exists()) return true;
        if (!dst.exists() && src.renameTo(dst)) return true;
        if (!dst.exists() && !dst.mkdirs()) return false;
        File[] kids = src.listFiles();
        if (kids != null) for (File f : kids) {
            File out = new File(dst, f.getName());
            boolean moved = f.renameTo(out)
                || (f.isDirectory() ? (copyDir(f, out) && deleteTree(f)) : (copyFile(f, out) && f.delete()));
            if (!moved) return false;
        }
        src.delete();
        return true;
    }

    private static boolean deleteTree(File d) {
        File[] k = d.listFiles();
        if (k != null) for (File f : k) { if (f.isDirectory()) deleteTree(f); else f.delete(); }
        return d.delete();
    }

    /** Point games/cds/import at the configured base folder (app dir by default). */
    private void initDirs() {
        File base = AppConfig.baseDir(this);
        gamesDir = new File(base, "games");
        if (!gamesDir.exists()) gamesDir.mkdirs();
        cdsDir = new File(base, "cds");
        if (!cdsDir.exists()) cdsDir.mkdirs();
        importDir = new File(base, "import");
        if (!importDir.exists()) importDir.mkdirs();
        getPreparedCdsDir();
    }

    /** Importer entry point — current import folder (the SAF flow drops into it). */
    public File getImportDir() { return importDir; }

    /** Importer entry point — current CD library folder (the SAF flow drops CDs into it). */
    public File getCdsDir() { return cdsDir; }

    /** Hidden work area for archive-backed CD media selected through import. */
    public File getPreparedCdsDir() {
        File d = new File(cdsDir, ".prepared-cds");
        if (!d.exists()) d.mkdirs();
        return d;
    }

    /** Hidden collection of reusable ZIP CD source packages. */
    public File getCdArchivesDir() {
        File d = new File(cdsDir, ".archives");
        if (!d.exists()) d.mkdirs();
        return d;
    }

    /** Optional persistent extracted copies, kept separate from visible cds/. */
    public File getKeptExtractedCdsDir() {
        File d = new File(cdsDir, ".extracted-cds");
        if (!d.exists()) d.mkdirs();
        return d;
    }

    private File newPreparedCdRunDir() {
        clearPreparedCdRuns();
        File d = new File(getPreparedCdsDir(), "run_" + System.currentTimeMillis());
        if (!d.exists()) d.mkdirs();
        return d;
    }

    private void clearPreparedCdRuns() {
        File root = getPreparedCdsDir();
        File[] kids = root.listFiles();
        if (kids == null) return;
        for (File f : kids) {
            if (f.isDirectory() && f.getName().startsWith("run_")) {
                deleteTree(f);
            }
        }
    }

    private void prepareArchiveCd(final File archive, final java.util.function.Consumer<File> onReady) {
        prepareArchiveCd(archive, false, onReady);
    }

    private void prepareArchiveCd(final File archive, final boolean keepExtracted,
                                  final java.util.function.Consumer<File> onReady) {
        final int pad = dp(20);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(pad, pad, pad, pad);
        final TextView msg = new TextView(this);
        msg.setText("Starting extraction...");
        msg.setTextColor(0xFFE0E0E0);
        box.addView(msg);
        final ProgressBar bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        bar.setIndeterminate(true);
        bar.setMax(1000);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        blp.topMargin = dp(12);
        box.addView(bar, blp);
        final AlertDialog dlg = new AlertDialog.Builder(this)
            .setTitle(archive.getName())
            .setView(box)
            .setCancelable(false)
            .show();
        final ArchiveExtractor.Progress progress = (done, total) -> runOnUiThread(() -> {
            if (total > 0) {
                int permille = (int) Math.min(1000, done * 1000 / total);
                bar.setIndeterminate(false);
                bar.setProgress(permille);
                msg.setText(String.format(Locale.US, "%d%%   (%d / %d MB)",
                    permille / 10, done >> 20, total >> 20));
            } else {
                msg.setText((done >> 20) + " MB extracted...");
            }
        });
        new Thread(() -> {
            final File preparedDir = keepExtracted
                ? uniqueDir(new File(getKeptExtractedCdsDir(),
                    archive.getName().replaceFirst("(?i)\\.zip$", "")))
                : newPreparedCdRunDir();
            final String mountedName = importArchiveCd(archive, preparedDir, progress);
            runOnUiThread(() -> {
                dlg.dismiss();
                if (mountedName != null) {
                    if (keepExtracted) {
                        Toast.makeText(this, "Kept extracted CD in " + preparedDir.getName() + ".",
                            Toast.LENGTH_SHORT).show();
                    }
                    onReady.accept(new File(preparedDir, mountedName));
                } else {
                    if (keepExtracted) deleteTree(preparedDir);
                    Toast.makeText(this, "Couldn't prepare CD media from " + archive.getName() + ".",
                        Toast.LENGTH_LONG).show();
                }
            });
        }).start();
    }

    private void keepExtractedArchiveCd(final File archive) {
        final File outDir = uniqueDir(new File(getKeptExtractedCdsDir(),
            archive.getName().replaceFirst("(?i)\\.zip$", "")));
        final int pad = dp(20);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(pad, pad, pad, pad);
        final TextView msg = new TextView(this);
        msg.setText("Starting extraction...");
        msg.setTextColor(0xFFE0E0E0);
        box.addView(msg);
        final ProgressBar bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        bar.setIndeterminate(true);
        bar.setMax(1000);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        blp.topMargin = dp(12);
        box.addView(bar, blp);
        final AlertDialog dlg = new AlertDialog.Builder(this)
            .setTitle("Keep extracted copy")
            .setView(box)
            .setCancelable(false)
            .show();
        final ArchiveExtractor.Progress progress = (done, total) -> runOnUiThread(() -> {
            if (total > 0) {
                int permille = (int) Math.min(1000, done * 1000 / total);
                bar.setIndeterminate(false);
                bar.setProgress(permille);
                msg.setText(String.format(Locale.US, "%d%%   (%d / %d MB)",
                    permille / 10, done >> 20, total >> 20));
            } else {
                msg.setText((done >> 20) + " MB extracted...");
            }
        });
        new Thread(() -> {
            final String mountedName = importArchiveCd(archive, outDir, progress);
            runOnUiThread(() -> {
                dlg.dismiss();
                if (mountedName != null) {
                    Toast.makeText(this, "Kept extracted CD in " + outDir.getName() + ".",
                        Toast.LENGTH_LONG).show();
                    rescan();
                } else {
                    deleteTree(outDir);
                    Toast.makeText(this, "Couldn't extract " + archive.getName() + ".",
                        Toast.LENGTH_LONG).show();
                }
            });
        }).start();
    }

    private static File uniqueDir(File base) {
        if (!base.exists()) return base;
        File parent = base.getParentFile();
        String name = base.getName();
        for (int i = 2; i < 100; i++) {
            File c = new File(parent, name + " " + i);
            if (!c.exists()) return c;
        }
        return new File(parent, name + " " + System.currentTimeMillis());
    }

    public void addArchiveCdToLibrary(final File archive) {
        final AlertDialog dlg = new AlertDialog.Builder(this)
            .setTitle(archive.getName())
            .setMessage("Preparing CD media...")
            .setCancelable(false)
            .show();
        new Thread(() -> {
            final String mountedName = importArchiveCd(archive, cdsDir);
            runOnUiThread(() -> {
                dlg.dismiss();
                if (mountedName != null) {
                    Toast.makeText(this, discName(new File(cdsDir, mountedName))
                        + " added to the CD library.", Toast.LENGTH_LONG).show();
                    rescan();
                } else {
                    Toast.makeText(this, "Couldn't prepare CD media from " + archive.getName() + ".",
                        Toast.LENGTH_LONG).show();
                }
            });
        }).start();
    }

    /** Called by GameImporter after the SAF-picked archive is on disk. CD
     *  picks don't go through here — the importer copies them straight to
     *  cds/ and can immediately start the selected setup flow. */
    public void runImport(final File archive, final AlertDialog progressDialog) {
        extractArchiveAndContinue(archive, /*asCd*/ false, progressDialog, this::promptSetupForFolder);
    }

    /** Like the old extractArchive(), but takes an already-shown progress dialog
     *  and a callback to invoke when the folder is ready. */
    private void extractArchiveAndContinue(final File archive, final boolean asCd,
                                           final AlertDialog dlg,
                                           final java.util.function.Consumer<File> onReady) {
        // The dialog was built by GameImporter.makeProgressDialog — its
        // initial title ("Copying …") stays. We don't keep a ref to the inner
        // TextView; the spinner is enough feedback during extract.
        final ArchiveExtractor.Progress progress = (done, total) -> { /* spinner only */ };

        new Thread(() -> {
            final boolean ok;
            final File readyFolder;   // the DOS-game folder, or the per-game C: drive for CD
            int winVer = 0;
            if (asCd) {
                java.util.Set<String> before = listNamesIn(cdsDir);
                ok = ArchiveExtractor.extractDiscImages(archive, cdsDir, progress);
                File disc = ok ? newDisc(cdsDir, before) : null;
                if (disc != null) {
                    winVer = IsoReader.scan(disc, 4).maxWinSubsystem;
                    // Seed the per-game C: drive with the CD contents.
                    String safe = KeyMapStore.safeName(disc.getName());
                    File cDir = new File(gamesDir, ".c/" + safe);
                    if (!cDir.exists()) cDir.mkdirs();
                    IsoReader.extractTo(disc, cDir);
                    readyFolder = cDir;
                } else {
                    readyFolder = null;
                }
            } else {
                String name = archive.getName().replaceFirst("(?i)\\.zip$", "");
                File gameDir = new File(gamesDir, name);
                if (gameDir.exists()) deleteContents(gameDir);
                ok = ArchiveExtractor.extractGame(archive, gameDir, progress);
                readyFolder = ok ? normalizeImportedRipFolder(gameDir) : gameDir;
                archive.delete();
            }
            final File fReady = readyFolder;
            final int fWinVer = winVer;
            runOnUiThread(() -> {
                dlg.dismiss();
                if (!ok || fReady == null) {
                    Toast.makeText(this, "Couldn't extract " + archive.getName() + ".", Toast.LENGTH_LONG).show();
                    if (fReady != null) { deleteContents(fReady); fReady.delete(); }
                    return;
                }
                rescan();
                if (fWinVer >= 5) {
                    new AlertDialog.Builder(this)
                        .setTitle("May not run in Windows 98")
                        .setMessage("This CD's program needs Windows 2000/XP (build " + fWinVer
                            + ".x) and probably won't run in the Windows 98 guest.")
                        .setPositiveButton("OK", null)
                        .show();
                }
                // Chain into setup detection.
                onReady.accept(fReady);
            });
        }).start();
    }

    /** Look for a setup exe in the imported folder, ask the user whether to run
     *  it, and (if yes) boot the emulator with a conf that runs that exe.
     *  After the emulator returns, open the launch picker. */
    private void promptSetupForFolder(final File folder) {
        promptSetupForFolder(folder, false);
    }

    private void promptSetupForFolder(final File folder, final boolean fromCd) {
        File setup = GameImporter.findInstaller(folder);
        if (setup == null) {
            // No installer detected — go straight to the launch picker so the
            // user can choose which exe to use.
            showLaunchPickerForFolder(folder, fromCd, true);
            return;
        }
        new AlertDialog.Builder(this)
            .setTitle(folder.getName())
            .setMessage("Found " + setup.getName() + ". Run it now?\n\n"
                + "Tip: when setup finishes, exit the emulator and you'll be asked to pick the game.")
            .setPositiveButton("Run setup", (d, w) -> {
                writeSidecarFile(folder, GameLauncherActivity.SIDE_LAUNCHER, relpath(folder, setup));
                runInstaller(folder, setup, fromCd);
            })
            .setNeutralButton("Skip setup", (d, w) -> showLaunchPickerForFolder(folder, fromCd, true))
            .setNegativeButton("Cancel", null)
            .show();
    }

    /** Boot DOSBox with the importer's folder mounted as C: and `installer` run
     *  from it. After SDLActivity returns, onResume() detects the pending
     *  setup folder and pops the launch picker. */
    private void runInstaller(final File folder, final File installer) {
        runInstaller(folder, installer, false);
    }

    private void runInstaller(final File folder, final File installer, final boolean fromCd) {
        mPendingSetupFolder = folder;
        mPendingSetupFromCd = fromCd;
        List<String> lines = new ArrayList<>();
        lines.add("mount c \"" + folder.getAbsolutePath() + "\"");
        lines.add("c:");
        String rel = relpath(folder, installer);
        int slash = rel.replace('\\', '/').lastIndexOf('/');
        if (slash >= 0) lines.add("cd \"" + rel.substring(0, slash).replace('/', '\\') + "\"");
        lines.add(installer.getName());
        setKeymapAndLaunch(folder.getName(), lines, installer.getName());
    }

    /** Show the "Pick launch exe" dialog and write the choice to .launch. */
    private void showLaunchPickerForFolder(final File folder) {
        showLaunchPickerForFolder(folder, false);
    }

    private void showLaunchPickerForFolder(final File folder, final boolean fromCd) {
        showLaunchPickerForFolder(folder, fromCd, false);
    }

    private void showLaunchPickerForFolder(final File folder, final boolean fromCd,
                                           final boolean launchAfterPick) {
        // For CD installs, the folder is games/.c/<name>/ — but the game row
        // in the unified list is keyed by the *disc* name, not the C: path.
        // We discover the disc basename by reverse-lookup.
        String displayName = folder.getName();
        if (folder.getParentFile() != null
                && folder.getParentFile().getName().equals(".c")) {
            // The cDir maps to a disc; the disc name is whatever the matching
            // .cue/.iso's safe-name produced. We don't store that mapping
            // explicitly — the row uses the disc basename, but for storing the
            // sidecar the folder name itself is fine (it's the only folder
            // that uses that name).
            displayName = folder.getName();
        }
        final List<File> launchers = findLaunchers(folder, 3);
        if (launchers.isEmpty()) {
            Toast.makeText(this, "No .exe or .bat found — opening " + folder.getName() + " at C:\\.",
                Toast.LENGTH_LONG).show();
            launchGame(folder, null);
            return;
        }
        // Exclude the installer we already ran, so the user doesn't re-pick it.
        File installer = GameImporter.findInstaller(folder);
        String[] names = new String[launchers.size()];
        for (int i = 0; i < launchers.size(); i++) {
            File f = launchers.get(i);
            names[i] = relpath(folder, f) + (f.equals(installer) ? "  (installer)" : "");
        }
        final String fDisplay = displayName;
        final boolean fFromCd = fromCd;
        final boolean fLaunchAfterPick = launchAfterPick;
        new AlertDialog.Builder(this)
            .setTitle("Pick the game for " + fDisplay)
            .setItems(names, (d, w) -> {
                File pick = launchers.get(w);
                writeSidecarFile(folder, GameLauncherActivity.SIDE_LAUNCH, relpath(folder, pick));
                rescan();
                promptNeedsCdForGame(folder, fFromCd, fLaunchAfterPick);
            })
            .setNegativeButton("Skip for now", (d, w) -> rescan())
            .show();
    }

    /** Ask the user whether the installed game still needs its CD in the
     *  drive (CD audio / copy protection) or runs as a no-CD rip. Stored
     *  in GameMeta so the GAMES row tags it correctly. CD installs default
     *  to needs-CD; plain DOS imports default to rip. */
    private void promptNeedsCdForGame(final File folder) {
        promptNeedsCdForGame(folder, false);
    }

    private void promptNeedsCdForGame(final File folder, final boolean fromCd) {
        promptNeedsCdForGame(folder, fromCd, false);
    }

    private void promptNeedsCdForGame(final File folder, final boolean fromCd,
                                      final boolean launchAfterSave) {
        // CD installs default the dialog to "Needs the CD" (most CD games
        // use CD audio or copy protection), plain DOS imports default to
        // "No CD (rip)". The buttons swap order so the most likely answer
        // is the positive (right-most, easy-to-tap) one.
        final String yesLabel = fromCd ? "Needs the CD" : "No CD (rip)";
        final String noLabel  = fromCd ? "No CD (rip)"  : "Needs the CD";
        final boolean yesMeans = fromCd;   // yesLabel saves `fromCd`
        final boolean noMeans  = !fromCd;  // noLabel saves the opposite
        new AlertDialog.Builder(this)
            .setTitle(folder.getName())
            .setMessage("Does this game need the CD in the drive to play?\n\n"
                + "• \"" + yesLabel + "\" — uses CD audio or copy protection\n"
                + "• \"" + noLabel  + "\" — runs without the disc\n\n"
                + "(You can change this later: long-press the game on the GAMES tab.)")
            .setPositiveButton(yesLabel, (d, w) -> saveNeedsCd(folder, yesMeans, launchAfterSave))
            .setNegativeButton(noLabel,  (d, w) -> saveNeedsCd(folder, noMeans, launchAfterSave))
            .setNeutralButton("Skip",   (d, w) -> rescan())
            .show();
    }

    private void saveNeedsCd(final File folder, final boolean needs) {
        saveNeedsCd(folder, needs, false);
    }

    private void saveNeedsCd(final File folder, final boolean needs, final boolean launchAfterSave) {
        GameMeta.setNeedsCd(this, folder.getName(), needs);
        Toast.makeText(this, folder.getName() + (needs
            ? " needs its CD in the drive to play."
            : " runs without the disc."), Toast.LENGTH_LONG).show();
        rescan();
        if (launchAfterSave) launchGame(folder, autoPickLauncher(folder));
    }

    /** Write a single-line sidecar file in `folder`. */
    private static void writeSidecarFile(File folder, String name, String relPath) {
        try {
            FileWriter w = new FileWriter(new File(folder, name), false);
            w.write(relPath);
            w.close();
        } catch (Exception ignored) { }
    }

    private void showAddCdGameDialog() {
        final List<File> sources = new ArrayList<>();
        final List<String> labels = new ArrayList<>();
        for (File f : keptExtractedDiscs()) {
            sources.add(f);
            labels.add(discName(f) + "  [extracted]");
        }
        for (File f : cdArchiveSources()) {
            sources.add(f);
            labels.add(f.getName() + "  [zip]");
        }
        if (sources.isEmpty()) {
            GameImporter.startSafPicker(this, GameImporter.REQ_PICK_CD_GAME);
            return;
        }
        String[] names = labels.toArray(new String[0]);
        new AlertDialog.Builder(this)
            .setTitle("Add CD game")
            .setItems(names, (d, w) -> promptCdSourcePlatform(sources.get(w)))
            .setPositiveButton("Import file...", (d, w) ->
                GameImporter.startSafPicker(this, GameImporter.REQ_PICK_CD_GAME))
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void promptCdSourcePlatform(final File media) {
        final String base = discName(media);
        final boolean archive = isArchiveCdFile(media);
        AlertDialog.Builder b = new AlertDialog.Builder(this).setTitle(base);
        final CheckBox keep = new CheckBox(this);
        if (archive) {
            keep.setText("Keep extracted copy");
            keep.setTextColor(0xFFE0E0E0);
            keep.setPadding(dp(20), dp(8), dp(20), dp(8));
            b.setView(keep);
        }
        b.setPositiveButton("Windows 98", (d, w) -> {
            if (archive && keep.isChecked()) {
                prepareArchiveCd(media, true, prepared -> setupWin98FromMedia(prepared));
            } else {
                setupWin98FromMedia(media);
            }
        });
        b.setNeutralButton("MS-DOS", (d, w) -> {
            if (archive && keep.isChecked()) {
                prepareArchiveCd(media, true, prepared -> installCdToMsdos(prepared, prepared.getName()));
            } else {
                installCdToMsdos(media);
            }
        });
        b.setNegativeButton("Cancel", null);
        b.show();
    }

    private void confirmDeleteCdSource(final File media) {
        final File target = isArchiveCdFile(media) ? media : keptExtractRoot(media);
        if (target == null) {
            Toast.makeText(this, "Couldn't find the extracted folder to delete.", Toast.LENGTH_LONG).show();
            return;
        }
        new AlertDialog.Builder(this)
            .setTitle(target.getName())
            .setMessage("Delete this " + (target.isDirectory() ? "extracted CD copy" : "ZIP source") + "?")
            .setPositiveButton("Delete", (d, w) -> {
                if (target.isDirectory()) deleteTree(target);
                else target.delete();
                Toast.makeText(this, target.getName() + " deleted.", Toast.LENGTH_SHORT).show();
                rescan();
            })
            .setNegativeButton("Cancel", null)
            .show();
    }

    private File keptExtractRoot(File media) {
        File root = getKeptExtractedCdsDir().getAbsoluteFile();
        File cur = media.isDirectory() ? media.getAbsoluteFile() : media.getParentFile();
        while (cur != null) {
            File parent = cur.getParentFile();
            if (parent != null && parent.getAbsoluteFile().equals(root)) return cur;
            cur = parent;
        }
        return null;
    }

    private void buildUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(0xFF101418);
        int pad = dp(12);
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText("DOSBox-X — Games");
        title.setTextColor(0xFFFFFFFF);
        title.setTextSize(22);
        root.addView(title);

        // Two direct setup entry points. Each one asks MS-DOS vs Windows 98
        // after the file is picked and then boots/mounts the right target.
        importActions = new LinearLayout(this);
        importActions.setOrientation(LinearLayout.HORIZONTAL);
        addGameBtn = new Button(this);
        addGameBtn.setAllCaps(false);
        addGameBtn.setText("+ Add CD game");
        addGameBtn.setOnClickListener(v -> showAddCdGameDialog());
        importActions.addView(addGameBtn, new LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        Button addRipBtn = new Button(this);
        addRipBtn.setAllCaps(false);
        addRipBtn.setText("+ Add rip game");
        addRipBtn.setOnClickListener(v -> GameImporter.startSafPicker(this, GameImporter.REQ_PICK_RIP_GAME));
        importActions.addView(addRipBtn, new LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        root.addView(importActions);

        // Column headers above the list (just labels — not clickable).
        TextView header = new TextView(this);
        header.setText("NAME                     TYPE    CD/RIP   STATUS");
        header.setTextColor(0xFF80A0B0);
        header.setTextSize(11);
        header.setTypeface(android.graphics.Typeface.MONOSPACE);
        header.setPadding(0, dp(12), 0, dp(4));
        root.addView(header);

        list = new ListView(this);
        list.setBackgroundColor(0xFF101418);
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f);
        root.addView(list, llp);

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        Button storage = new Button(this);
        storage.setText("Storage…");
        storage.setOnClickListener(v -> storageWizard());
        buttons.addView(storage, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        Button refresh = new Button(this);
        refresh.setText("Refresh");
        refresh.setOnClickListener(v -> rescan());
        buttons.addView(refresh, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        root.addView(buttons);

        setContentView(root);
        rescan();

        // First run: offer to choose where games live (instead of the app dir).
        if (!AppConfig.setupDone(this)) {
            firstRunStorageWizard();
        }
    }

    public void rescan() {
        rowTap.clear();
        rowHold.clear();
        rowHasMenu.clear();
        List<String> labels = new ArrayList<>();
        buildGamesList(labels);
        final float d = getResources().getDisplayMetrics().density;
        ArrayAdapter<String> ad = new ArrayAdapter<String>(this,
                android.R.layout.simple_list_item_1, labels) {
            @Override public View getView(int pos, View cv, ViewGroup parent) {
                // Use a monospace text view so the columns line up across rows.
                TextView tv = new TextView(GameLauncherActivity.this);
                tv.setText(labels.get(pos));
                tv.setTextColor(0xFFE0E0E0);
                tv.setTextSize(14);
                tv.setTypeface(android.graphics.Typeface.MONOSPACE);
                tv.setPadding((int)(8*d), (int)(10*d), (int)(4*d), (int)(10*d));
                tv.setFocusable(false);
                tv.setClickable(false);
                boolean wantMenu = pos < rowHasMenu.size() && rowHasMenu.get(pos);
                android.util.Log.d("DosBoxX", "getView pos=" + pos + " wantMenu=" + wantMenu +
                    " label=" + labels.get(pos).substring(0, Math.min(20, labels.get(pos).length())));
                if (!wantMenu) {
                    return tv;
                }
                // Wrap the text in a horizontal layout with a ⋮ button on
                // the right that opens a per-row popup menu. The button is
                // the only way to access row actions — there is no
                // long-press in this UI.
                LinearLayout row = new LinearLayout(GameLauncherActivity.this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                row.setGravity(android.view.Gravity.CENTER_VERTICAL);
                row.setBackgroundColor(0x00000000);
                LinearLayout.LayoutParams textLp = new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
                row.addView(tv, textLp);
                android.widget.Button menu = new android.widget.Button(GameLauncherActivity.this);
                menu.setText("⋮");
                menu.setTextColor(0xFFE0E0E0);
                menu.setTextSize(18);
                menu.setAllCaps(false);
                menu.setBackgroundColor(0x00000000);
                menu.setPadding((int)(12*d), (int)(4*d), (int)(12*d), (int)(4*d));
                menu.setMinWidth(0);
                menu.setMinimumWidth(0);
                // Without this, a focusable button blocks the listview's
                // onItemClick for the row it sits in.
                menu.setFocusable(false);
                menu.setClickable(true);
                final int posFinal = pos;
                menu.setOnClickListener(w -> {
                    if (posFinal < rowHold.size() && rowHold.get(posFinal) != null) {
                        mSuppressNextRowTap = posFinal;
                        rowHold.get(posFinal).run();
                    }
                });
                LinearLayout.LayoutParams menuLp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                row.addView(menu, menuLp);
                return row;
            }
        };
        list.setAdapter(ad);
        list.setOnItemClickListener((parent, view, position, id) -> {
            // The ⋮ button's click sets mSuppressNextRowTap to its position
            // so a row tap that immediately follows the button click
            // doesn't also launch the game.
            if (position == mSuppressNextRowTap) {
                mSuppressNextRowTap = -1;
                return;
            }
            if (position < rowTap.size() && rowTap.get(position) != null) rowTap.get(position).run();
        });
        // No long-press listener — rows are launched by tap, and all
        // per-row actions are reachable through the ⋮ button.
    }

    /** MS-DOS tab: game folders (without an OS boot image) + disk images.
     *  CD-library discs are listed too — a disc is directly playable as a
     *  DOS CD game here AND insertable into Windows from the other tab. */
    /** Unified games list: every game once, with column-aligned type / CD /
     *  rip / status flags. Tap to play; ⋮ button on the right for actions. */
    private void buildGamesList(List<String> labels) {
        final File boot = findBootFolder();

        // Windows 98 desktop (boot the OS with no CD — full disk speed).
        if (boot != null) {
            File validD = firstGamesDisk(boot);
            File badD = firstInvalidGamesDisk(boot);
            labels.add(formatRow("▶  Windows 98 desktop", "—", "—",
                validD != null ? "D: ready" : (badD != null ? "D: repair" : "")));
            rowTap.add(() -> bootWin98Desktop(boot));
            rowHold.add(() -> onLongPick(boot));
            rowHasMenu.add(true);
        }

        // Installed game folders (minus the Win98 OS) and local disk images,
        // each once. CD library media is listed separately as mount-only
        // media; it is not an installed game until a DOS folder or Win98 D:
        // install exists.
        List<File> entries = new ArrayList<>();
        File[] kids = gamesDir.listFiles();
        if (kids != null) {
            Arrays.sort(kids, NAME);
            for (File f : kids) {
                if (f.getName().startsWith(".")) continue;       // .c = per-ISO C: drives
                if (f.isDirectory()) {
                    if (findBootImage(f) != null) continue;       // the Win98 OS (desktop above)
                    if (!hasInstallContent(f)) continue;
                    entries.add(f);
                } else {
                    String n = f.getName().toLowerCase();
                    if (n.endsWith(".img") || n.endsWith(".iso") || n.endsWith(".cue")) entries.add(f);
                }
            }
        }
        Collections.sort(entries, new Comparator<File>() {
            @Override public int compare(File a, File b) {
                return gameName(a).compareToIgnoreCase(gameName(b));
            }
        });
        for (File e : entries) addGameRow(labels, e, boot);

        // CD library: mount-only media. These rows can start an install/mount
        // session, but they deliberately do not appear as installed games.
        List<File> media = new ArrayList<>();
        File[] discs = cdsDir.listFiles();
        if (discs != null) {
            Arrays.sort(discs, NAME);
            java.util.Set<String> preparedDiscKeys = preparedDiscKeys(discs);
            for (File f : discs) {
                if (f.isDirectory()) continue;
                if (isArchiveCdFile(f) && preparedDiscKeys.contains(cdMediaKey(f))) continue;
                if (isCdMediaListFile(f)) media.add(f);
            }
        }
        Collections.sort(media, new Comparator<File>() {
            @Override public int compare(File a, File b) {
                return gameName(a).compareToIgnoreCase(gameName(b));
            }
        });
        for (File disc : media) addCdMediaRow(labels, disc, boot);

        // Games installed on the Windows D: drive that aren't copied out yet.
        List<File> disks = new ArrayList<>();
        collectGamesDisks(gamesDir, 2, disks);
        for (File disk : disks) {
            final File gd = disk;
            for (String dn : Fat32Reader.listTopDirs(disk)) {
                if (new File(gamesDir, dn).exists()) continue;
                final String name = dn;
                final boolean needsCd = GameMeta.needsCd(this, name, false);
                labels.add(formatRow("💾 " + name, "WIN98", needsCd ? "CD" : "rip", "on D:"));
                rowTap.add(() -> playWin98Game(name, boot, needsCd));
                rowHold.add(() -> onWin98DiskGameMenu(gd, name, boot));
                rowHasMenu.add(true);
            }
        }
        if (labels.isEmpty()) {
            labels.add("(no games yet — tap + Add CD game or + Add rip game)");
            rowTap.add(null);
            rowHold.add(null);
            rowHasMenu.add(false);
        }
    }

    /** Game display name (folder name, or disc basename). */
    private static String gameName(File f) {
        return f.isDirectory() ? f.getName() : discName(f);
    }

    /** User-visible files written by an installer/import. Empty setup C:
     *  folders and launcher sidecars do not make a game installed. */
    private static boolean hasInstallContent(File dir) {
        if (dir == null || !dir.isDirectory()) return false;
        File[] kids = dir.listFiles();
        if (kids == null) return false;
        for (File f : kids) {
            String n = f.getName();
            if (n.equals(SIDE_LAUNCHER) || n.equals(SIDE_LAUNCH) || n.equals(".cd1")) continue;
            if (n.startsWith(".")) continue;
            if (f.isDirectory()) {
                if (hasInstallContent(f)) return true;
            } else {
                return true;
            }
        }
        return false;
    }

    private static void deleteEmptyInstallDir(File dir) {
        if (dir == null || !dir.isDirectory() || hasInstallContent(dir)) return;
        deleteTree(dir);
    }

    /** A disc in cds/ is not installed; tapping it only starts a mount/setup
     *  session for DOS or Windows. */
    private void addCdMediaRow(List<String> labels, final File disc, final File boot) {
        final String name = discName(disc);
        labels.add(formatRow("💿 " + name, "MEDIA", "CD", "mount"));
        rowTap.add(() -> mountCdMediaDialog(disc, boot));
        rowHold.add(() -> onCdMediaMenu(disc, boot));
        rowHasMenu.add(true);
    }

    private void mountCdMediaDialog(final File disc, final File boot) {
        final String[] items = new String[]{"Mount/setup in MS-DOS", "Mount in Windows 98"};
        new AlertDialog.Builder(this)
            .setTitle(discName(disc))
            .setItems(items, (d, w) -> {
                if (w == 0) installCdToMsdos(disc);
                else        setupWin98FromMedia(disc);
            })
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void onCdMediaMenu(final File disc, final File boot) {
        List<String> menu = new ArrayList<>();
        menu.add("Mount/setup in MS-DOS");
        menu.add("Mount in Windows 98");
        menu.add("Copy CD contents to MS-DOS drive...");
        if (boot != null) menu.add("Copy CD contents to Windows drive...");
        menu.add("Delete CD media...");
        final String[] items = menu.toArray(new String[0]);
        new AlertDialog.Builder(this)
            .setTitle(disc.getName())
            .setItems(items, (d, w) -> {
                String it = items[w];
                if (it.startsWith("Mount/setup in MS-DOS")) installCdToMsdos(disc);
                else if (it.startsWith("Mount in Windows")) setupWin98FromMedia(disc);
                else if (it.startsWith("Copy CD contents to MS-DOS")) copyCdMediaToDosDrive(disc);
                else if (it.startsWith("Copy CD contents to Windows")) copyCdMediaToWindowsDrive(disc, boot);
                else if (it.startsWith("Delete")) confirmDeleteDisc(disc);
            })
            .show();
    }

    /** Add one game row formatted as a column-aligned string. */
    private void addGameRow(List<String> labels, final File entry, final File boot) {
        final String name = gameName(entry);
        final boolean isLibraryDisc = entry.getParentFile() != null && entry.getParentFile().equals(cdsDir);
        final boolean isDisc = !entry.isDirectory()
            && (isLibraryDisc ? isCdImageFile(entry) : isIsoCueOrBin(entry));
        // auto defaults: discs -> DOS if they hold DOS programs else WIN98; folders/.img -> DOS
        String autoPlat = (isDisc && !isDosDisc(entry)) ? GameMeta.WIN98 : GameMeta.DOS;
        final String plat = GameMeta.platform(this, name, autoPlat);
        final boolean needsCd = GameMeta.needsCd(this, name, defaultNeedsCd(entry, plat));
        // Soft tag for the import flow: [ready] once a launch exe is recorded,
        // [setup] if a setup exe is recorded but the user hasn't picked the
        // game yet, otherwise nothing (the standard DOS/Win98 + CD/rip row).
        String soft = "";
        if (entry.isDirectory() && !name.startsWith(".")) {
            if (hasStoredLaunch(entry))      soft = "ready";
            else if (hasStoredSetupOnly(entry)) soft = "setup";
        }
        String prefix = entry.isDirectory() ? "📁 " : "💿 ";
        labels.add(formatRow(prefix + name,
            plat.equals(GameMeta.WIN98) ? "WIN98" : "DOS",
            needsCd ? "CD" : "rip",
            soft));
        rowTap.add(() -> {
            if (plat.equals(GameMeta.WIN98)) {
                if (needsCd) {
                    if (isDisc) bootWin98(boot, entry);
                    else        promptPickWin98CdFromLibrary(name, boot);
                } else {
                    bootWin98(boot, null);
                }
            } else {
                onPick(entry);
            }
        });
        rowHold.add(() -> onLongPick(entry));
        rowHasMenu.add(true);
    }

    private boolean defaultNeedsCd(File entry, String platform) {
        if (GameMeta.WIN98.equals(platform)) return true;
        return entry != null && entry.isDirectory() && findCdInLibrary(gameName(entry)) != null;
    }

    /** Column widths for the GAMES list. The header at the top of the
     *  screen ("NAME  TYPE  CD/RIP  STATUS") matches these widths. */
    private static final int COL_NAME = 38;
    private static final int COL_TYPE = 6;
    private static final int COL_CD   = 7;
    private static final int COL_STAT = 6;

    /** Pad each field to its column width so rows line up under the
     *  monospace header. Names longer than the column are truncated
     *  with an ellipsis so they don't push the other columns. */
    private static String formatRow(String name, String type, String cd, String status) {
        StringBuilder sb = new StringBuilder();
        sb.append(padOrTrim(name, COL_NAME));
        sb.append("  ");
        sb.append(padOrTrim(type, COL_TYPE));
        sb.append("  ");
        sb.append(padOrTrim(cd, COL_CD));
        sb.append("  ");
        sb.append(padOrTrim(status, COL_STAT));
        return sb.toString();
    }

    private static String padOrTrim(String s, int w) {
        if (s == null) s = "";
        // Replace newlines/tabs in case the name has any; newlines would
        // break the row layout entirely.
        s = s.replace('\n', ' ').replace('\t', ' ');
        if (s.length() > w) {
            if (w <= 1) return s.substring(0, w);
            return s.substring(0, w - 1) + "…";
        }
        StringBuilder sb = new StringBuilder(s);
        for (int i = s.length(); i < w; i++) sb.append(' ');
        return sb.toString();
    }

    /** The folder holding the bootable Windows image, or null. */
    private File findBootFolder() {
        File f = findBootFolderIn(gamesDir);
        if (f != null) return f;
        File base = AppConfig.baseDir(this);
        if (base != null && !sameFile(base, gamesDir)) {
            f = findBootFolderIn(base);
            if (f != null) return f;
        }
        return null;
    }

    private File findBootFolderIn(File dir) {
        if (dir == null || !dir.isDirectory()) return null;
        File[] kids = dir.listFiles();
        if (kids == null) return null;
        Arrays.sort(kids, NAME);
        for (File f : kids) {
            if (!f.isDirectory() || f.getName().startsWith(".")) continue;
            String n = f.getName().toLowerCase(Locale.US);
            if (n.equals("games") || n.equals("cds") || n.equals("cd")
                    || n.equals("import") || n.equals("keymaps") || n.equals("gamemeta")) {
                continue;
            }
            if (findBootImage(f) != null) return f;
        }
        return null;
    }

    private static boolean sameFile(File a, File b) {
        if (a == null || b == null) return false;
        try {
            return a.getCanonicalFile().equals(b.getCanonicalFile());
        } catch (IOException e) {
            return a.getAbsolutePath().equals(b.getAbsolutePath());
        }
    }

    /** Boot Windows 98 from the desktop row, using any CD inserted for the
     *  next boot. */
    private void bootWin98Desktop(final File boot) {
        if (boot == null) {
            Toast.makeText(this, "No Windows 98 image found in the games folder.", Toast.LENGTH_LONG).show();
            return;
        }
        if (firstGamesDisk(boot) == null) {
            File bad = firstInvalidGamesDisk(boot);
            if (bad != null) {
                promptRepairGamesDisk(boot, bad, "Windows 98 D: needs repair",
                    "The existing " + bad.getName() + " is " + gamesDiskProblem(bad)
                    + ", so it will not be mounted as D:. Replace it with a 4 GB writable games disk?",
                    () -> bootWin98(boot, null),
                    () -> bootWin98(boot, null));
                return;
            }
        }
        bootWin98(boot, null);
    }

    /** Boot Windows 98 with `disc` in the drive. A null disc keeps any CD that
     *  was inserted for the next boot, otherwise the boot starts with no CD. */
    private void bootWin98(File boot, File disc) {
        if (boot == null) {
            Toast.makeText(this, "No Windows 98 image found in the games folder.", Toast.LENGTH_LONG).show();
            return;
        }
        if (disc != null) {
            String n = disc.getName().toLowerCase(Locale.US);
            if (isArchiveCdFile(disc)) {
                final File archiveDisc = disc;
                prepareArchiveCd(archiveDisc, prepared -> bootWin98(boot, prepared));
                return;
            }
            if (n.endsWith(".bin")) disc = ensureCueForBin(disc);
        }
        if (disc != null) mPendingBootDisc = disc;
        onPick(boot);
    }

    private void playWin98Game(String name, File boot, boolean needsCd) {
        if (needsCd) {
            File stored = storedCdForGame(name);
            if (stored != null) {
                bootWin98(boot, stored);
                return;
            }
            promptPickWin98CdFromLibrary(name, boot);
        } else {
            bootWin98(boot, null);
        }
    }

    private void promptPickWin98CdFromLibrary(final String gameName, final File boot) {
        if (boot == null) {
            Toast.makeText(this, "No Windows 98 image found in the games folder.", Toast.LENGTH_LONG).show();
            return;
        }
        pickCdFromLibrary(gameName + " needs its CD", gameName, disc -> {
                GameMeta.setCdMedia(GameLauncherActivity.this, gameName, disc.getName());
                bootWin98(boot, disc);
            },
            () -> {
                GameMeta.setNeedsCd(GameLauncherActivity.this, gameName, false);
                rescan();
                bootWin98(boot, null);
            });
    }

    /** Start a Windows 98 install session from a CD image or ZIP rip. A ZIP is
     *  converted to an ISO because booted Windows cannot see Android folders.
     *  The media is mounted for this boot only, so it is effectively ejected
     *  when the emulator exits. */
    public void setupWin98FromMedia(final File media) {
        final File boot = findBootFolder();
        if (boot == null) {
            Toast.makeText(this, "No Windows 98 image found in the games folder.", Toast.LENGTH_LONG).show();
            return;
        }
        Toast.makeText(this,
            "Booting Windows 98 with " + media.getName() + ". The CD should be D:\\.",
            Toast.LENGTH_LONG).show();
        bootWin98(boot, media);
    }

    private void createGamesDiskThenBoot(final File boot, final File media) {
        createGamesDiskThenRun(boot, () -> setupWin98FromMedia(media));
    }

    private File firstGamesDisk(File folder) {
        List<File> disks = new ArrayList<>();
        collectGamesDisks(folder, 2, disks);
        return disks.isEmpty() ? null : disks.get(0);
    }

    private File firstInvalidGamesDisk(File folder) {
        List<File> disks = new ArrayList<>();
        collectInvalidGamesDisks(folder, 2, disks);
        return disks.isEmpty() ? null : disks.get(0);
    }

    private void promptRepairGamesDisk(final File boot, final File badDisk,
                                       String title, String message,
                                       final Runnable afterRepair,
                                       final Runnable withoutRepair) {
        AlertDialog.Builder b = new AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(message)
            .setPositiveButton("Replace D:", (d, w) -> createGamesDiskThenRun(boot, afterRepair));
        if (withoutRepair != null) {
            b.setNegativeButton("Boot without D:", (d, w) -> withoutRepair.run());
            b.setNeutralButton("Cancel", null);
        } else {
            b.setNegativeButton("Cancel", null);
        }
        b.show();
    }

    private static String gamesDiskProblem(File f) {
        long len = f.length();
        if (len <= WIN98_GAMES_DISK_MIN) return "too small to be a Windows games disk";
        if (len > WIN98_GAMES_DISK_MAX) return "too large for the Windows 98 IDE geometry";
        return "not recognised as a usable Windows games disk";
    }

    private void onWin98DiskGameMenu(final File disk, final String name, final File boot) {
        final boolean needsCd = GameMeta.needsCd(this, name, false);
        final String[] items = new String[]{
            "Play",
            needsCd ? "CD: needs disc (tap = mark as rip)" : "CD: rip / no disc (tap = needs CD)",
            "Choose CD...",
            "Copy to MS-DOS games..."
        };
        new AlertDialog.Builder(this)
            .setTitle(name)
            .setItems(items, (d, w) -> {
                if (w == 0) playWin98Game(name, boot, needsCd);
                else if (w == 1) {
                    GameMeta.setPlatform(this, name, GameMeta.WIN98);
                    GameMeta.setNeedsCd(this, name, !needsCd);
                    rescan();
                } else if (w == 2) {
                    pickCdFromLibrary(name + " CD", name, disc -> {
                        GameMeta.setPlatform(GameLauncherActivity.this, name, GameMeta.WIN98);
                        GameMeta.setNeedsCd(GameLauncherActivity.this, name, true);
                        GameMeta.setCdMedia(GameLauncherActivity.this, name, disc.getName());
                        Toast.makeText(GameLauncherActivity.this,
                            name + " will use " + disc.getName() + ".",
                            Toast.LENGTH_LONG).show();
                        rescan();
                    });
                } else {
                    copyFromGamesDisk(disk, name, false);
                }
            })
            .show();
    }

    private void pickCdFromLibrary(String title, String bestMatchName,
                                   java.util.function.Consumer<File> onPick) {
        pickCdFromLibrary(title, bestMatchName, onPick, null);
    }

    private void pickCdFromLibrary(String title, String bestMatchName,
                                   java.util.function.Consumer<File> onPick,
                                   final Runnable markAsRip) {
        final List<File> discs = libraryDiscs();
        if (discs.isEmpty()) {
            AlertDialog.Builder b = new AlertDialog.Builder(this)
                .setTitle(title)
                .setMessage("No disc images are in the CD library. Use + Add CD game first.");
            if (markAsRip != null) b.setPositiveButton("Mark as rip", (d, w) -> markAsRip.run());
            b.setNegativeButton("Cancel", null).show();
            return;
        }
        File best = bestMatchName != null ? findCdInLibrary(bestMatchName) : null;
        final List<File> ordered = new ArrayList<>();
        if (best != null) ordered.add(best);
        for (File f : discs) if (f != best) ordered.add(f);
        String[] names = new String[ordered.size()];
        for (int i = 0; i < ordered.size(); i++) {
            names[i] = discName(ordered.get(i)) + (i == 0 && best != null ? "  (auto)" : "");
        }
        AlertDialog.Builder b = new AlertDialog.Builder(this)
            .setTitle(title)
            .setItems(names, (d, w) -> onPick.accept(ordered.get(w)));
        if (markAsRip != null) b.setNeutralButton("Mark as rip", (d, w) -> markAsRip.run());
        b.setNegativeButton("Cancel", null).show();
    }

    private List<File> libraryDiscs() {
        List<File> discs = new ArrayList<>();
        if (cdsDir == null || !cdsDir.isDirectory()) return discs;
        File[] kids = cdsDir.listFiles();
        if (kids != null) {
            Arrays.sort(kids, NAME);
            java.util.Set<String> preparedDiscKeys = preparedDiscKeys(kids);
            for (File f : kids) {
                if (isArchiveCdFile(f) && preparedDiscKeys.contains(cdMediaKey(f))) continue;
                if (isCdMediaListFile(f)) discs.add(f);
            }
        }
        discs.addAll(cdArchiveSources());
        discs.addAll(keptExtractedDiscs());
        return discs;
    }

    private List<File> cdArchiveSources() {
        List<File> archives = new ArrayList<>();
        File dir = getCdArchivesDir();
        File[] kids = dir.listFiles();
        if (kids != null) {
            Arrays.sort(kids, NAME);
            for (File f : kids) {
                if (!f.isDirectory() && isArchiveCdFile(f)) archives.add(f);
            }
        }
        return archives;
    }

    private List<File> keptExtractedDiscs() {
        List<File> discs = new ArrayList<>();
        collectKeptExtractedDiscs(getKeptExtractedCdsDir(), 2, discs);
        Collections.sort(discs, NAME);
        return discs;
    }

    private void collectKeptExtractedDiscs(File dir, int depth, List<File> out) {
        File[] kids = dir.listFiles();
        if (kids == null) return;
        Arrays.sort(kids, NAME);
        java.util.Set<String> discKeys = preparedDiscKeys(kids);
        for (File f : kids) {
            if (f.isDirectory()) {
                if (depth > 0) collectKeptExtractedDiscs(f, depth - 1, out);
            } else {
                if (isArchiveCdFile(f) && discKeys.contains(cdMediaKey(f))) continue;
                if (isCdMediaListFile(f)) out.add(f);
            }
        }
    }

    private File findCdByStoredName(String mediaName) {
        if (mediaName == null || mediaName.length() == 0) return null;
        for (File f : libraryDiscs()) {
            if (f.getName().equals(mediaName)) return f;
        }
        return null;
    }

    private File storedCdForGame(String gameName) {
        return findCdByStoredName(GameMeta.cdMedia(this, gameName));
    }

    /** Copy a game folder out of a Windows data disk into MS-DOS games; if
     *  {@code play} also launch it once copied. */
    private void copyFromGamesDisk(final File disk, final String name, final boolean play) {
        final File dest = new File(gamesDir, name);
        if (dest.exists()) { onPick(dest); return; }
        final AlertDialog dlg = new AlertDialog.Builder(this)
            .setTitle(name).setMessage("Copying from Windows D: to MS-DOS games…")
            .setCancelable(false).show();
        new Thread(() -> {
            final boolean ok = Fat32Reader.extractTopDir(disk, name, dest);
            runOnUiThread(() -> {
                dlg.dismiss();
                if (ok) {
                    Toast.makeText(this, name + " copied to MS-DOS games.", Toast.LENGTH_SHORT).show();
                    rescan();
                    if (play) onPick(dest);
                } else {
                    deleteContents(dest); dest.delete();
                    Toast.makeText(this, "Couldn't copy " + name + ".", Toast.LENGTH_LONG).show();
                }
            });
        }).start();
    }

    /** Delete a game folder (and its per-game keymap + persistent C: drive). */
    private void confirmDeleteGame(final File folder) {
        new AlertDialog.Builder(this)
            .setTitle(folder.getName())
            .setMessage("Delete this game and its saves from the device? This can't be undone.")
            .setPositiveButton("Delete", (d, w) -> {
                // Sidecar files live at the root of the game folder and are
                // wiped explicitly so a re-import under the same name doesn't
                // resurrect a stale launcher or installer reference.
                new File(folder, SIDE_LAUNCHER).delete();
                new File(folder, SIDE_LAUNCH).delete();
                deleteContents(folder); folder.delete();
                File cDir = new File(gamesDir, ".c/" + KeyMapStore.safeName(folder.getName()));
                if (cDir.isDirectory()) {
                    new File(cDir, SIDE_LAUNCHER).delete();
                    new File(cDir, SIDE_LAUNCH).delete();
                    deleteContents(cDir); cDir.delete();
                }
                GameMeta.clear(this, folder.getName());
                Toast.makeText(this, folder.getName() + " deleted.", Toast.LENGTH_SHORT).show();
                rescan();
            })
            .setNegativeButton("Cancel", null)
            .show();
    }

    /** Delete a disc from the library: the .cue plus every data file it
     *  references (multi-track sets), or the .iso/.zip on its own. */
    private void confirmDeleteDisc(final File disc) {
        new AlertDialog.Builder(this)
            .setTitle(discName(disc))
            .setMessage("Delete this disc from the device? This can't be undone.")
            .setPositiveButton("Delete", (d, w) -> {
                if (disc.getName().toLowerCase().endsWith(".cue")) {
                    for (String dn : cueDataNames(disc)) {
                        File data = new File(disc.getParentFile(), dn);
                        if (data.isFile()) data.delete();
                    }
                }
                disc.delete();
                GameMeta.clear(this, discName(disc));
                Toast.makeText(this, discName(disc) + " deleted.", Toast.LENGTH_SHORT).show();
                rescan();
            })
            .setNegativeButton("Cancel", null)
            .show();
    }

    /** Cache: does this disc carry DOS-runnable programs? (Windows-only CDs
     *  like Road Rash '97 / NFS High Stakes only make sense in Win98.) */
    private final Map<String, Boolean> discDosCache = new HashMap<>();

    private boolean isDosDisc(File f) {
        String key = f.getAbsolutePath() + ":" + f.length();
        Boolean v = discDosCache.get(key);
        if (v == null) {
            IsoReader.Scan s = IsoReader.scan(f, 3);
            v = !s.programs.isEmpty();
            discDosCache.put(key, v);
        }
        return v;
    }

    /** Display name for a disc file (basename without extension). */
    private static String discName(File f) {
        String n = f.getName();
        int dot = n.lastIndexOf('.');
        return dot > 0 ? n.substring(0, dot) : n;
    }

    private static boolean isCdImageFile(File f) {
        if (f == null || f.isDirectory()) return false;
        String n = f.getName().toLowerCase(Locale.US);
        return n.endsWith(".iso") || n.endsWith(".cue") || n.endsWith(".bin") || n.endsWith(".img");
    }

    private static boolean isCdMediaListFile(File f) {
        if (f == null || f.isDirectory()) return false;
        if (isArchiveCdFile(f)) return false;
        String n = f.getName().toLowerCase(Locale.US);
        if (n.endsWith(".iso") || n.endsWith(".cue")) return true;
        if (n.endsWith(".bin") || n.endsWith(".img")) return !hasSiblingCue(f);
        return false;
    }

    private static java.util.Set<String> preparedDiscKeys(File[] files) {
        java.util.Set<String> out = new java.util.HashSet<>();
        if (files == null) return out;
        for (File f : files) {
            if (f != null && !f.isDirectory() && isCdMediaListFile(f) && !isArchiveCdFile(f)) {
                out.add(cdMediaKey(f));
            }
        }
        return out;
    }

    private static String cdMediaKey(File f) {
        String n = discName(f).toLowerCase(Locale.US);
        StringBuilder sb = new StringBuilder(n.length());
        for (int i = 0; i < n.length(); i++) {
            char c = n.charAt(i);
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) sb.append(c);
        }
        return sb.toString();
    }

    private static boolean isArchiveCdFile(File f) {
        if (f == null || f.isDirectory()) return false;
        String n = f.getName().toLowerCase(Locale.US);
        return n.endsWith(".zip");
    }

    private static boolean isIsoCueOrBin(File f) {
        if (f == null || f.isDirectory()) return false;
        String n = f.getName().toLowerCase(Locale.US);
        return n.endsWith(".iso") || n.endsWith(".cue") || n.endsWith(".bin");
    }

    /** Import tab: lists .zip archives dropped in import/. Tapping one
     *  installs it — as a DOS game (-> games/<name>/) or a CD-ROM image
     *  (-> the CD library), auto-detected from the archive contents. */
    private void buildImportRows(List<String> labels) {
        // Orphaned — the IMPORT tab was removed. Kept as a no-op safety
        // net; rescan() no longer calls this.
        File[] kids = importDir.listFiles();
        List<File> archives = new ArrayList<>();
        if (kids != null) {
            Arrays.sort(kids, NAME);
            for (File f : kids) if (!f.isDirectory() && ArchiveExtractor.isArchive(f.getName())) archives.add(f);
        }
        if (archives.isEmpty()) {
            labels.add("(no .zip archives in the import folder)");
            rowTap.add(null);
            rowHold.add(null);
            rowHasMenu.add(false);
            return;
        }
        for (File a : archives) {
            final File archive = a;
            long mb = a.length() / (1024 * 1024);
            labels.add("📦 " + a.getName() + "  (" + mb + " MB)");
            rowTap.add(() -> importDialog(archive));
            rowHold.add(() -> confirmDeleteArchive(archive));
            rowHasMenu.add(true);
        }
    }

    /** CD tab: every disc in cds/. Tap = install into MS-DOS games; long-press
     *  = insert into Win98 boot, copy into MS-DOS games, or delete. */
    private void buildCdList(List<String> labels) {
        // Orphaned — the CDS tab was removed. The unified games list now
        // shows CD rows itself, so rescan() no longer calls this.
        List<File> discs = new ArrayList<>();
        File[] kids = cdsDir.listFiles();
        if (kids != null) {
            Arrays.sort(kids, NAME);
            for (File f : kids) {
                if (f.isDirectory()) continue;
                String n = f.getName().toLowerCase(Locale.US);
                if (isCdMediaListFile(f))
                    discs.add(f);
            }
        }
        if (discs.isEmpty()) {
            labels.add("(no CDs yet — tap Add game / CD…)");
            rowTap.add(null);
            rowHold.add(null);
            rowHasMenu.add(false);
            return;
        }
        for (File d : discs) {
            final File disc = d;
            labels.add("💿 " + discName(disc) + "   [CD]");
            rowTap.add(() -> installCdToMsdos(disc));
            rowHold.add(() -> onCdLongPick(disc));
            rowHasMenu.add(true);
        }
    }

    /** Long-press menu for a CD: install to MS-DOS games / insert into Win98 /
     *  delete. Only the actions that make sense are shown. */
    private void onCdLongPick(final File disc) {
        final boolean win98Present = findBootFolder() != null;
        final List<String> menu = new ArrayList<>();
        menu.add("Install to MS-DOS games…");
        if (win98Present) menu.add("Insert into Windows 98 boot");
        menu.add("Delete disc…");
        final String[] items = menu.toArray(new String[0]);
        new AlertDialog.Builder(this)
            .setTitle(discName(disc))
            .setItems(items, (d, w) -> {
                String it = items[w];
                if (it.startsWith("Install to MS-DOS")) installCdToMsdos(disc);
                else if (it.startsWith("Insert into Windows 98")) insertCdForWin98(disc);
                else if (it.startsWith("Delete disc")) confirmDeleteDisc(disc);
            })
            .show();
    }

    /** Remember this disc as the CD to mount on the next Win98 boot. */
    private void insertCdForWin98(final File disc) {
        mPendingBootDisc = disc;
        Toast.makeText(this, discName(disc) + " will be in the Win98 drive on the next boot.",
            Toast.LENGTH_LONG).show();
    }

    /**
     * Install a CD into MS-DOS games. Creates games/&lt;discname&gt;/ (or asks
     * the user to overwrite), boots DOS with mount c &lt;gamesdir&gt;/&lt;name&gt;
     * + imgmount d &lt;disc&gt; and drops at the C: prompt. The user types
     * `d:`, navigates the CD, runs the installer; files land in
     * games/&lt;name&gt;. After the emulator returns, the setup-then-pick
     * chain runs and the new game appears on the GAMES tab.
     */
    public void installCdToMsdos(final File disc) {
        installCdToMsdos(disc, null);
    }

    private void installCdToMsdos(final File disc, final String sourceMediaName) {
        if (isArchiveCdFile(disc)) {
            final File archiveDisc = disc;
            prepareArchiveCd(archiveDisc, prepared -> installCdToMsdos(prepared, archiveDisc.getName()));
            return;
        }
        if (disc.getName().toLowerCase(Locale.US).endsWith(".bin")) {
            File cue = ensureCueForBin(disc);
            if (!cue.equals(disc)) {
                installCdToMsdos(cue, sourceMediaName != null ? sourceMediaName : disc.getName());
                return;
            }
        }
        final String name = discName(disc);
        final File dest = cleanInstallDirForCd(name);
        GameMeta.setCdMedia(this, dest.getName(), sourceMediaName != null ? sourceMediaName : disc.getName());
        if (dest.exists()) {
            new AlertDialog.Builder(this)
                .setTitle(dest.getName())
                .setMessage("Use this existing folder as the C: install drive?\n\n"
                    + dest.getAbsolutePath())
                .setPositiveButton("Use", (d, w) -> {
                    deleteContents(dest);
                    promptMsdosSetupProgram(disc, name, dest);
                })
                .setNegativeButton("Cancel", null)
                .show();
            return;
        }
        promptMsdosSetupProgram(disc, name, dest);
    }

    /** Pick a writable C: install folder for a CD setup. If games/<disc> is
     *  already present, it is often an old accidental CD extraction; do not
     *  mount that as C:. Use a clean sibling instead. */
    private File cleanInstallDirForCd(String name) {
        File preferred = new File(gamesDir, name);
        if (!preferred.exists()) return preferred;
        if (isEmptyDir(preferred)) return preferred;
        for (int i = 1; i < 100; i++) {
            File candidate = new File(gamesDir, i == 1 ? name + "_install" : name + "_install" + i);
            if (!candidate.exists() || isEmptyDir(candidate)) {
                Toast.makeText(this,
                    "Existing " + name + " folder found; using clean C: folder " + candidate.getName() + ".",
                    Toast.LENGTH_LONG).show();
                return candidate;
            }
        }
        return new File(gamesDir, name + "_install");
    }

    private static boolean isEmptyDir(File dir) {
        if (!dir.isDirectory()) return false;
        File[] kids = dir.listFiles();
        return kids == null || kids.length == 0;
    }

    private void promptMsdosSetupProgram(final File disc, final String name, final File dest) {
        final IsoReader.Scan scan = IsoReader.scan(disc, 4);
        if (scan.allPrograms.isEmpty()) {
            new AlertDialog.Builder(this)
                .setTitle(name)
                .setMessage("No executable program was found on this CD. Open the mounted CD at D:\\ anyway?")
                .setPositiveButton("Open D:", (d, w) -> doInstallCdToMsdos(disc, name, dest, null))
                .setNegativeButton("Cancel", null)
                .show();
            return;
        }
        final List<String> programs = setupProgramsFirst(scan.allPrograms);
        final String[] items = programs.toArray(new String[0]);
        new AlertDialog.Builder(this)
            .setTitle("Run setup from " + name)
            .setItems(items, (d, w) -> doInstallCdToMsdos(disc, name, dest, programs.get(w)))
            .setNegativeButton("Cancel", null)
            .show();
    }

    private static List<String> setupProgramsFirst(List<String> programs) {
        List<String> installers = new ArrayList<>();
        List<String> others = new ArrayList<>();
        for (String p : programs) {
            String b = isoBaseName(p);
            if (isSetupProgram(b)) installers.add(p);
            else others.add(p);
        }
        Collections.sort(installers, String.CASE_INSENSITIVE_ORDER);
        Collections.sort(others, String.CASE_INSENSITIVE_ORDER);
        installers.addAll(others);
        return installers;
    }

    private void doInstallCdToMsdos(final File disc, final String name, final File dest,
                                    final String setupProgram) {
        if (!dest.exists() && !dest.mkdirs()) {
            Toast.makeText(this, "Couldn't create " + dest.getAbsolutePath() + ".", Toast.LENGTH_LONG).show();
            return;
        }
        // Build the conf: C: = the install dir, D: = the disc as CD. If the
        // scanner found a setup program, run it directly from D: so the user
        // doesn't have to type paths on the DOS prompt.
        List<String> lines = new ArrayList<>();
        lines.add("mount c \"" + dest.getAbsolutePath() + "\"");
        lines.add(imgmountCdLine(disc));
        // DOS/4GW games (e.g. SWIV 3D) need DOS4GW.EXE on PATH.
        lines.add("set path=%path%;c:\\;d:\\");
        if (setupProgram != null) {
            lines.add("d:");
            addCdAndRun(lines, setupProgram);
        } else {
            lines.add("d:");
            lines.add("cls");
            lines.add("dir /w");
            lines.add("echo.");
            lines.add("echo C: is your empty install drive.");
            lines.add("echo No setup program was auto-detected on this D: CD.");
        }
        mPendingSetupFolder = dest;
        mPendingSetupFromCd = true;
        setKeymapAndLaunch(name, lines, setupProgram != null ? isoBaseName(setupProgram) : "setup");
    }

    /** Ask how to install an archive (DOS game vs CD), defaulting to the
     *  auto-detected kind, then extract on a background thread. */
    private void importDialog(final File archive) {
        new Thread(() -> {
            final ArchiveExtractor.Kind kind = ArchiveExtractor.classify(archive);
            runOnUiThread(() -> {
                // Order the choices so the detected kind is the first/default.
                final boolean cdFirst = kind.hasDiscImage || !kind.hasDosProgram;
                final String cd  = "Add to CD library (then use its row or + Add CD game)";
                final String dos = "Extract as a DOS game (no CD needed)";
                final String[] items = cdFirst ? new String[]{cd, dos} : new String[]{dos, cd};
                new AlertDialog.Builder(this)
                    .setTitle("Add " + archive.getName())
                    .setItems(items, (d, w) -> {
                        boolean asCd = items[w].equals(cd);
                        extractArchive(archive, asCd);
                    })
                    .show();
            });
        }).start();
    }

    private void extractArchive(final File archive, final boolean asCd) {
        // Progress dialog with a percentage + MB readout and a determinate bar.
        final int pad = dp(20);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(pad, pad, pad, pad);
        final TextView msg = new TextView(this);
        msg.setText(asCd ? "Extracting the CD image…" : "Installing the DOS game…");
        msg.setTextColor(0xFFE0E0E0);
        box.addView(msg);
        final android.widget.ProgressBar bar = new android.widget.ProgressBar(
            this, null, android.R.attr.progressBarStyleHorizontal);
        bar.setIndeterminate(true);
        bar.setMax(1000);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        blp.topMargin = dp(12);
        box.addView(bar, blp);
        final AlertDialog dlg = new AlertDialog.Builder(this)
            .setTitle(archive.getName())
            .setView(box)
            .setCancelable(false)
            .create();
        dlg.show();

        final ArchiveExtractor.Progress progress = (done, total) -> runOnUiThread(() -> {
            if (total > 0) {
                int permille = (int) (done * 1000 / total);
                bar.setIndeterminate(false);
                bar.setProgress(permille);
                msg.setText(String.format(java.util.Locale.US, "%d%%   (%d / %d MB)",
                    permille / 10, done >> 20, total >> 20));
            } else {
                msg.setText((done >> 20) + " MB extracted…");
            }
        });

        new Thread(() -> {
            final boolean ok;
            final String dest;
            int winVer = 0;
            if (asCd) {
                java.util.Set<String> before = listNamesIn(cdsDir);
                ok = ArchiveExtractor.extractDiscImages(archive, cdsDir, progress);
                if (ok) {
                    File disc = newDisc(cdsDir, before);
                    if (disc != null) winVer = IsoReader.scan(disc, 4).maxWinSubsystem;
                }
                dest = "CD library";
            } else {
                String name = archive.getName().replaceFirst("(?i)\\.zip$", "");
                File gameDir = new File(gamesDir, name);
                ok = ArchiveExtractor.extractGame(archive, gameDir, progress);
                dest = "MS-DOS games";
            }
            final int fWinVer = winVer;
            runOnUiThread(() -> {
                dlg.dismiss();
                if (ok) {
                    Toast.makeText(this, archive.getName() + " added to " + dest + ".", Toast.LENGTH_LONG).show();
                    rescan();
                    if (fWinVer >= 5) {
                        new AlertDialog.Builder(this)
                            .setTitle("May not run in Windows 98")
                            .setMessage("This CD's program needs Windows 2000/XP (build " + fWinVer
                                + ".x) and probably won't run in the Windows 98 guest.")
                            .setPositiveButton("OK", null)
                            .show();
                    }
                } else {
                    Toast.makeText(this, "Couldn't extract " + archive.getName() + ".", Toast.LENGTH_LONG).show();
                }
            });
        }).start();
    }

    private static java.util.Set<String> listNamesIn(File dir) {
        java.util.Set<String> s = new java.util.HashSet<>();
        File[] k = dir.listFiles();
        if (k != null) for (File f : k) s.add(f.getName());
        return s;
    }

    /** A newly-appeared .cue/.iso in dir (the disc just extracted), or null. */
    private static File newDisc(File dir, java.util.Set<String> before) {
        File[] k = dir.listFiles();
        if (k != null) for (File f : k) {
            String n = f.getName().toLowerCase();
            if ((n.endsWith(".cue") || n.endsWith(".iso")) && !before.contains(f.getName())) return f;
        }
        return null;
    }

    private void confirmDeleteArchive(final File archive) {
        new AlertDialog.Builder(this)
            .setTitle(archive.getName())
            .setMessage("Delete this archive from the import folder?")
            .setPositiveButton("Delete", (d, w) -> { archive.delete(); rescan(); })
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void onPick(File entry) {
        if (entry.isDirectory()) {
            // A big disk image = an installed OS (e.g. the Win98 bundle):
            // boot it instead of running a DOS exe.
            File bootImg = findBootImage(entry);
            if (bootImg != null) {
                launchBootImage(entry, bootImg);
                return;
            }
            File launcher = autoPickLauncher(entry);
            // Ambiguous folder (several runnable programs, no known/single
            // launcher — typical of a game copied in from Windows or a CD):
            // prompt for which exe to run instead of guessing.
            if (launcher != null && shouldPromptForExe(entry)) {
                showLauncherPicker(entry);
            } else {
                launchGame(entry, launcher);
            }
        } else {
            String n = entry.getName().toLowerCase();
            if (n.endsWith(".img")) {
                List<String> lines = new ArrayList<>();
                lines.add("imgmount c \"" + entry.getAbsolutePath() + "\" -t hdd -fs fat");
                lines.add("c:");
                String[] pref = preferredExes(entry.getName());
                if (pref != null) {
                    // Preinstalled HDD image of a known title (e.g. lotus.img):
                    // auto-run the game exe if it is where we expect it.
                    lines.add("if exist " + pref[0] + " " + pref[0]);
                } else {
                    Toast.makeText(this, "Mounted as C:. Use the on-screen keyboard to run the game.", Toast.LENGTH_LONG).show();
                }
                setKeymapAndLaunch(entry.getName(), lines);
            } else { // .iso / .cue
                launchIso(entry);
            }
        }
    }

    // ---- bootable OS images (e.g. the WinBox 98 SE bundle) ----

    private static final long BOOT_IMG_MIN = 256L * 1024 * 1024;   // ≥256MB = OS disk
    private static final long FLOPPY_MAX   = 3L * 1024 * 1024;     // ≤~2.88MB = floppy
    private static final long WIN98_GAMES_DISK_MIN = 64L * 1024 * 1024;
    private static final long WIN98_GAMES_DISK_MAX = 5L * 1024 * 1024 * 1024;

    /** First OS-sized .img in the folder, or null. */
    private File findBootImage(File folder) {
        File named = findNamed(folder, "windows98.img", 2);
        if (named != null && named.length() >= BOOT_IMG_MIN) return named;
        named = findNamed(folder, "win98.img", 2);
        if (named != null && named.length() >= BOOT_IMG_MIN) return named;
        return findImgBySize(folder, 2, BOOT_IMG_MIN, Long.MAX_VALUE);
    }

    private File findImgBySize(File dir, int depth, long min, long max) {
        File[] kids = dir.listFiles();
        if (kids == null) return null;
        for (File f : kids) {
            if (f.isDirectory()) {
                if (depth > 0) {
                    File r = findImgBySize(f, depth - 1, min, max);
                    if (r != null) return r;
                }
            } else if (f.getName().toLowerCase().endsWith(".img")
                       && !Fat32Disk.isGamesDisk(f.getName())   // data disks are never boot/floppy images
                       && !hasSiblingCue(f)                     // neither are cue-referenced CD images
                       && f.length() >= min && f.length() <= max) {
                return f;
            }
        }
        return null;
    }

    /**
     * Boot an installed-OS hard disk image (Win98 etc), mirroring the WinBox
     * bundle's autoexec: optional boot floppy on A:, the HDD as BIOS drive 2
     * with explicit LBA-style geometry, any CD image IDE-attached so Windows
     * sees it, then `boot -l c`.
     */
    private void launchBootImage(final File folder, final File bootImg) {
        // .zip "CDs" dropped in the folder become real ISOs first — a booted
        // guest can only read IDE-attached image mounts, never host folders
        // or archives, so the zip's contents are pressed onto an ISO9660+
        // Joliet image Windows 9x can browse with long filenames.
        final List<File> all = new ArrayList<>();
        collectZips(folder, 3, all);
        final List<File> zips = new ArrayList<>();
        for (File z : all) if (!isoFor(z).isFile()) zips.add(z);
        if (zips.isEmpty()) {
            doLaunchBootImage(folder, bootImg);
            return;
        }
        final AlertDialog dlg = new AlertDialog.Builder(this)
            .setTitle(folder.getName())
            .setMessage("Building CD images from ZIPs…")
            .setCancelable(false)
            .show();
        new Thread(() -> {
            final List<String> failed = new ArrayList<>();
            for (File z : zips) {
                if (!ZipToIso.convert(z, isoFor(z))) failed.add(z.getName());
            }
            runOnUiThread(() -> {
                dlg.dismiss();
                if (!failed.isEmpty()) {
                    Toast.makeText(this, "Couldn't convert: " + TextUtils.join(", ", failed),
                        Toast.LENGTH_LONG).show();
                }
                doLaunchBootImage(folder, bootImg);
            });
        }).start();
    }

    /** The ISO a .zip converts to (sits next to the zip; skipped if present). */
    private static File isoFor(File zip) {
        String n = zip.getName();
        return new File(zip.getParentFile(), n.substring(0, n.length() - 4) + ".iso");
    }

    private void doLaunchBootImage(File folder, File bootImg) {
        List<String> lines = new ArrayList<>();
        File floppy = findBootFloppy(folder);
        if (floppy != null) {
            lines.add("imgmount 0 \"" + floppy.getAbsolutePath() + "\" -t floppy -fs none");
        }
        // Exactly one CD this boot (or none) — mounted by absolute path from
        // the library, IDE secondary master. The Win98 guest assigns the
        // visible drive letter itself; DOSBox-X only needs a CD-style mount
        // letter here so the ATAPI device is attached before boot.
        File disc = mPendingBootDisc;
        mPendingBootDisc = null;
        long cylinders = bootImg.length() / (512L * 63 * 255);
        lines.add("imgmount 2 \"" + bootImg.getAbsolutePath()
            + "\" -size 512,63,255," + cylinders + " -t hdd -fs none -ide 1m");
        if (disc == null) {
            // Desktop boots can still expose the optional Windows games disk.
            // CD setup boots deliberately skip it so Win98 letters the CD-ROM
            // as D:, which many older installers assume.
            List<File> disks = new ArrayList<>();
            collectGamesDisks(folder, 2, disks);
            int driveNo = 3;
            for (File gd : disks) {
                long cyl = gd.length() / (512L * 63 * 255);
                String ide = driveNo == 3 ? " -ide 1s" : "";
                lines.add("imgmount " + driveNo + " \"" + gd.getAbsolutePath()
                    + "\" -size 512,63,255," + cyl + " -t hdd -fs none" + ide);
                driveNo++;
            }
        }
        if (disc != null && disc.isFile()) {
            File mountable = isRawCdTrack(disc) ? ensureCueForBin(disc) : disc;
            lines.add("imgmount d \"" + mountable.getAbsolutePath() + "\" -t iso -ide 2m");
        }
        lines.add("boot c:");

        Map<String, Integer> map = KeyMapStore.load(this, folder.getName());
        org.libsdl.app.SDLActivity.setKeyMap(map);
        boolean joy = KeyMapStore.loadJoystickMode(this, folder.getName());
        org.libsdl.app.SDLActivity.setJoystickMode(joy);
        org.libsdl.app.SDLActivity.setStickMouseMode(false);
        // Windows draws its own cursor — touch acts as a trackpad instead.
        org.libsdl.app.SDLActivity.setTrackpadMouse(true);
        writeAndLaunch(buildBootConf(lines, joy), folder.getName());
    }

    private File findBootFloppy(File folder) {
        File[] kids = folder.listFiles();
        if (kids == null) return null;
        Arrays.sort(kids, NAME);
        for (File f : kids) {
            if (f.isDirectory()) continue;
            String n = f.getName().toLowerCase(Locale.US);
            if (!n.endsWith(".img") || f.length() > FLOPPY_MAX) continue;
            if (n.contains("floppy") || n.contains("bootdisk") || n.contains("boot_disk")
                    || n.contains("boot-") || n.equals("boot.img") || n.equals("win98c.img")) {
                return f;
            }
        }
        return null;
    }

    /** Conf for booting Win9x from a disk image — settings from the WinBox
     *  bundle: lots of RAM, XMS/EMS/UMB off (Windows manages memory itself),
     *  SB16 (what the guest's drivers are installed for), IDE controllers on. */
    private String buildBootConf(List<String> autoexec, boolean joystick) {
        StringBuilder sb = new StringBuilder();
        // mouse_emulation=locked: the guest only ever sees relative motion,
        // which is what the trackpad-style touch input sends.
        sb.append("[sdl]\noutput=surface\nshowmenu=false\nshowdetails=false\n");
        sb.append("autolock=true\nmouse_emulation=locked\n\n");
        sb.append("[render]\naspect=bilinear\n\n");
        sb.append("[dosbox]\nmachine=svga_s3\nmemsize=512\nvmemsize=4\n");
        sb.append("enable pci bus=true\n");
        sb.append("locking disk image mount=false\n\n");
        sb.append("[cpu]\ncore=dynamic\ncputype=pentium\ncycles=max 105%\nisapnpbios=true\n\n");
        sb.append("[mixer]\nnosound=false\nrate=44100\nblocksize=1024\nprebuffer=25\n\n");
        sb.append("[sblaster]\nsbtype=sb16\nsbbase=220\nirq=7\ndma=1\nhdma=5\noplmode=auto\n\n");
        sb.append("[dos]\nxms=false\nems=false\numb=false\n\n");
        sb.append("[ide, primary]\nenable=true\n\n");
        sb.append("[ide, secondary]\nenable=true\ncd-rom insertion delay=4000\n\n");
        sb.append("[ide, tertiary]\nenable=true\n\n[ide, quaternary]\nenable=true\n\n");
        // Emulated Voodoo1 PCI card for Glide games inside the guest — the
        // guest needs the 3dfx reference drivers installed (staged at
        // C:\DRIVERS\VOODOO1 in the WinBox image).
        sb.append("[voodoo]\nvoodoo_card=software\n\n");
        // Windows guests need timed=true: VJOYD detects the joystick by timing
        // the gameport's analog discharge — untimed mode reads as "not
        // connected" in Game Controllers. 4axis exposes all 4 buttons for the
        // "2-axis, 4-button" profile. (DOS games keep 2axis/untimed.)
        if (joystick) sb.append("[joystick]\njoysticktype=4axis\ntimed=true\njoy1deadzone1=0.35\njoy1deadzone2=0.35\n\n");
        else          sb.append("[joystick]\njoysticktype=none\n\n");
        sb.append("[autoexec]\n@echo off\n");
        for (String l : autoexec) sb.append(l).append("\n");
        return sb.toString();
    }

    /**
     * Launch a CD image. Each ISO gets a persistent writable C: drive at
     * games/.c/<safeName> so installs and saves survive across runs; the image
     * itself is the read-only D: CD. Once a game lives on its C: we run it from
     * there; before that we auto-pick a program on the CD itself — for known
     * "preinstalled" CDs (e.g. an IndyCar ISO pressed from an installed folder)
     * we copy the CD onto C: once so config/saves can be written, otherwise we
     * fall back to the CD's installer (which lands on the persistent C:, so the
     * next tap just plays).
     */
    private void launchIso(File iso) {
        File cDir = new File(gamesDir, ".c/" + KeyMapStore.safeName(iso.getName()));
        if (!cDir.exists()) cDir.mkdirs();

        // Already on this game's C:? Run that.
        File installed = autoPickLauncher(cDir);
        if (installed != null) {
            setKeymapAndLaunch(iso.getName(), isoRunLines(iso, cDir, installed, null),
                installed.getName());
            return;
        }

        IsoReader.Scan scan = IsoReader.scan(iso, 3);

        // Known title with its game exe right on the CD → preinstalled CD;
        // copy it to the writable C: once and run from there.
        String[] pref = preferredExes(iso.getName());
        if (pref != null) {
            for (String name : pref) {
                if (containsBase(scan.programs, name)) {
                    copyCdToCThenLaunch(iso, cDir);
                    return;
                }
            }
        }

        String pick = pickIsoProgram(iso.getName(), scan.programs);
        if (pick == null) {
            pick = findInstaller(scan.programs);
            if (pick != null) {
                Toast.makeText(this,
                    "Running the installer — install to C:\\, then tap the game again to play.",
                    Toast.LENGTH_LONG).show();
            }
        }
        if (pick == null) {
            if (scan.sawWindowsExe) {
                // e.g. Road Rash (1996): the PC version is Windows 95 only.
                Toast.makeText(this,
                    "This CD only has Windows programs — it needs Windows 95 and can't run on this DOS build.",
                    Toast.LENGTH_LONG).show();
                return;
            }
            Toast.makeText(this, "No program found on the CD — dropped at the D: prompt.",
                Toast.LENGTH_LONG).show();
        }
        setKeymapAndLaunch(iso.getName(), isoRunLines(iso, cDir, null, pick),
            pick != null ? isoBaseName(pick) : null);
    }

    /** Mount C: (persistent dir) + D: (CD) and run either the installed exe or a CD path. */
    private List<String> isoRunLines(File iso, File cDir, File installed, String cdPick) {
        List<String> lines = new ArrayList<>();
        lines.add("mount c \"" + cDir.getAbsolutePath() + "\"");
        lines.add(imgmountCdLine(iso));
        // DOS/4GW games (e.g. SWIV 3D) keep DOS4GW.EXE at the drive root and
        // find it via PATH when the game exe lives in a subdirectory.
        lines.add("set path=%path%;c:\\");
        if (installed != null) {
            lines.add("c:");
            addCdAndRun(lines, relpath(cDir, installed));
        } else {
            lines.add("d:");
            if (cdPick != null) addCdAndRun(lines, cdPick);
        }
        return lines;
    }

    /** One-time copy of a preinstalled CD onto its writable C: drive, then launch. */
    private void copyCdToCThenLaunch(final File iso, final File cDir) {
        final AlertDialog dlg = new AlertDialog.Builder(this)
            .setTitle(iso.getName())
            .setMessage("First run — copying the CD to its C: drive…")
            .setCancelable(false)
            .show();
        new Thread(() -> {
            final boolean ok = IsoReader.extractTo(iso, cDir);
            runOnUiThread(() -> {
                dlg.dismiss();
                if (!ok) {
                    deleteContents(cDir);   // keep "not installed" state for the next tap
                    Toast.makeText(this, "Copy failed — running from the CD instead (saves won't work).",
                        Toast.LENGTH_LONG).show();
                    IsoReader.Scan scan = IsoReader.scan(iso, 3);
                    String pick = pickIsoProgram(iso.getName(), scan.programs);
                    setKeymapAndLaunch(iso.getName(), isoRunLines(iso, cDir, null, pick),
                        pick != null ? isoBaseName(pick) : null);
                    return;
                }
                File installed = autoPickLauncher(cDir);
                setKeymapAndLaunch(iso.getName(), isoRunLines(iso, cDir, installed, null),
                    installed != null ? installed.getName() : null);
            });
        }).start();
    }

    /** Load the per-game keymap + joystick mode, write the conf, start the emulator. */
    private void setKeymapAndLaunch(String gameName, List<String> lines) {
        setKeymapAndLaunch(gameName, lines, null);
    }

    private void setKeymapAndLaunch(String gameName, List<String> lines, String programName) {
        Map<String, Integer> map = KeyMapStore.load(this, gameName);
        org.libsdl.app.SDLActivity.setKeyMap(map);
        boolean joy = KeyMapStore.loadJoystickMode(this, gameName);
        org.libsdl.app.SDLActivity.setJoystickMode(joy);
        org.libsdl.app.SDLActivity.setStickMouseMode(KeyMapStore.loadStickMouseMode(this, gameName));
        org.libsdl.app.SDLActivity.setTrackpadMouse(false);   // DOS games take taps directly
        if (isScreamerSetup(gameName, programName)) {
            Toast.makeText(this,
                "Screamer setup is speed-sensitive; using the slower compatibility profile.",
                Toast.LENGTH_LONG).show();
        }
        writeAndLaunch(buildConf(lines, joy, machineFor(gameName, programName),
            cpuCoreFor(gameName, programName),
            cyclesFor(gameName, programName),
            mixerFor(programName)), gameName);
    }

    /**
     * CPU cycles per game/program. Speed-sensitive DOS setup utilities crash
     * at cycles=max (Screamer's SETUP.EXE is the canonical case), and some
     * games need a fixed CPU speed for sane game speed and timing.
     */
    private static String cyclesFor(String gameName, String programName) {
        String p = programName == null ? "" : programName.toLowerCase();
        if (isScreamerSetup(gameName, programName)) return "fixed 12000";
        if (isSetupProgram(programName)) {
            return "fixed 20000";
        }
        // 3dfx build: the emulated Voodoo renders inline on the emulation
        // thread, so lower CPU cycles leave host headroom for the rasterizer
        // (150000 + Voodoo = audio underruns / jitter on the device).
        if (p.startsWith("s2_3dfx")) return "fixed 100000";
        if (gameName.toLowerCase().contains("screamer")) return "fixed 150000";
        return "max";
    }

    private static String cpuCoreFor(String gameName, String programName) {
        return "dynamic";
    }

    private static String machineFor(String gameName, String programName) {
        return isScreamerSetup(gameName, programName) ? "vesa_nolfb" : "svga_s3";
    }

    private static boolean isScreamerSetup(String gameName, String programName) {
        return gameName != null
            && gameName.toLowerCase(Locale.US).contains("screamer")
            && isSetupProgram(programName);
    }

    private static boolean isSetupProgram(String programName) {
        String p = programName == null ? "" : programName.toLowerCase(Locale.US);
        return p.startsWith("setup") || p.startsWith("install") || p.startsWith("dosinst")
            || p.startsWith("setsound") || p.startsWith("setsnd")
            || p.startsWith("set") || p.startsWith("config");
    }

    /** Mixer settings per program: Glide/Voodoo games get bigger audio
     *  buffers so triangle-heavy frames don't starve the sound output. */
    private static String mixerFor(String programName) {
        String p = programName == null ? "" : programName.toLowerCase();
        if (p.startsWith("s2_3dfx")) {
            return "[mixer]\nnosound=false\nrate=44100\nblocksize=2048\nprebuffer=80\n\n";
        }
        return "[mixer]\nnosound=false\nrate=44100\nblocksize=1024\nprebuffer=25\n\n";
    }

    /** Append `cd \SUB` (if rel has a directory part) and the run line for rel. */
    private void addCdAndRun(List<String> lines, String rel) {
        rel = rel.replace('/', '\\');
        int slash = rel.lastIndexOf('\\');
        if (slash >= 0) lines.add("cd \\" + rel.substring(0, slash));
        lines.add(rel.substring(slash + 1));
    }

    /**
     * Known titles: launcher names to prefer (first match wins), by game
     * folder/image name (cf. the Screamer rule). Null → no preference.
     */
    private static String[] preferredExes(String gameName) {
        String g = gameName.toLowerCase();
        // ICR2 ships SVGA_RUN.BAT ("indycar.exe -h" = SVGA 640x480); on
        // IndyCar 1 there is no such bat and -h is just the help flag.
        if (g.contains("indy"))  return new String[] {"svga_run.bat", "indycar.exe"};
        if (g.contains("lotus")) return new String[] {"lotus.exe"};
        // SWIV 3D: the CD also carries Win95 builds and an "out soon" promo
        // FMV whose .bat would otherwise win the generic auto-pick.
        if (g.contains("swiv"))  return new String[] {"swiv_dos.exe"};
        // Bubble Bobble/Rainbow Islands: BUBBLE.BAT calls "start -1"; in
        // DOSBox-X that can hit the shell START command instead of START.EXE.
        // MENU.EXE is the clean DOS launcher for choosing either game.
        if (g.contains("bubble") && g.contains("rainbow")) return new String[] {"menu.exe", "bb.exe", "rainbow.exe"};
        // Hard Drivin' I/II (the II check must come first — both contain "drivin")
        if (g.contains("drivin")) {
            return g.contains("ii") || g.contains("2")
                ? new String[] {"hd2.exe"}
                : new String[] {"hard.exe"};
        }
        // Test Drive 2: pick the best display build (EGA > CGA/Tandy)
        if (g.contains("duel"))  return new String[] {"duel.exe", "td2.exe", "td2ega.exe", "td2cga.exe"};
        return null;
    }

    /** Auto-pick among programs found inside a CD image (paths like "DIR\\RUN.EXE"). */
    private String pickIsoProgram(String gameName, List<String> programs) {
        String[] preferred = preferredExes(gameName);
        if (preferred != null) {
            for (String name : preferred) {
                for (String p : programs) if (isoBaseName(p).equals(name)) return p;
            }
        }
        List<String> bats = new ArrayList<>();
        List<String> exes = new ArrayList<>();
        for (String p : programs) {
            String b = isoBaseName(p);
            if (isFilteredName(b)) continue;
            if (b.endsWith(".bat")) bats.add(p); else exes.add(p);
        }
        Collections.sort(bats, String.CASE_INSENSITIVE_ORDER);
        Collections.sort(exes, String.CASE_INSENSITIVE_ORDER);
        if (!bats.isEmpty()) return bats.get(0);
        if (!exes.isEmpty()) return exes.get(0);
        return null;
    }

    /** First installer-looking program on the CD, or null. */
    private String findInstaller(List<String> programs) {
        for (String p : programs) {
            String b = isoBaseName(p);
            if (b.startsWith("install") || b.startsWith("setup")) return p;
        }
        return null;
    }

    private static String isoBaseName(String path) {
        int slash = path.lastIndexOf('\\');
        return path.substring(slash + 1).toLowerCase();
    }

    private static boolean containsBase(List<String> programs, String baseName) {
        for (String p : programs) if (isoBaseName(p).equals(baseName)) return true;
        return false;
    }

    private static void deleteContents(File dir) {
        File[] kids = dir.listFiles();
        if (kids == null) return;
        for (File f : kids) {
            if (f.isDirectory()) deleteContents(f);
            f.delete();
        }
    }

    /** If an imported rip extracted as wrapper/GameName/..., promote GameName
     *  so it is the game folder mounted as C:, not the outer archive name. */
    private File normalizeImportedRipFolder(File wrapper) {
        if (wrapper == null || !wrapper.isDirectory()) return wrapper;
        if (hasRunnableAtRoot(wrapper)) return wrapper;
        File inner = singleRunnableChildDir(wrapper);
        if (inner == null) return wrapper;

        File target = uniqueGameDir(inner.getName());
        if (inner.renameTo(target) || copyDir(inner, target)) {
            deleteContents(wrapper);
            wrapper.delete();
            return target;
        }
        return inner;
    }

    private File singleRunnableChildDir(File wrapper) {
        File[] kids = wrapper.listFiles();
        if (kids == null) return null;
        File found = null;
        for (File f : kids) {
            String n = f.getName();
            if (n.startsWith(".") || n.equalsIgnoreCase("__MACOSX")) continue;
            if (!f.isDirectory()) continue;
            if (findLaunchers(f, 3).isEmpty()) continue;
            if (found != null) return null;
            found = f;
        }
        return found;
    }

    private File uniqueGameDir(String name) {
        File f = new File(gamesDir, name);
        if (!f.exists()) return f;
        for (int i = 2; i < 100; i++) {
            File c = new File(gamesDir, name + " " + i);
            if (!c.exists()) return c;
        }
        return new File(gamesDir, name + " import");
    }

    private static boolean hasRunnableAtRoot(File dir) {
        File[] kids = dir.listFiles();
        if (kids == null) return false;
        for (File f : kids) {
            if (!f.isFile()) continue;
            String n = f.getName().toLowerCase(Locale.US);
            if (n.endsWith(".exe") || n.endsWith(".bat") || n.endsWith(".com")) return true;
        }
        return false;
    }

    /** Names that are never the game: emulator binaries, installers, 3dfx patches. */
    private static boolean isFilteredName(String n) {
        return n.startsWith("dosbox") || n.startsWith("setup") || n.startsWith("install")
            || n.contains("3dfx") || n.contains("voodoo") || n.contains("glide");
    }

    /** Long-press menu — standardised across entry types: everything that can
     *  pick a program gets "Pick program..." (game folders AND CD images, via
     *  an ISO scan), every folder gets the CD changer (Insert/Eject), and all
     *  entries get "Edit controls..." + the joystick-mode toggle. */
    private void onLongPick(final File entry) {
        final String gameName = entry.getName();
        final boolean stickMouse = KeyMapStore.loadStickMouseMode(this, gameName);
        final String stickMouseItem = "Stick as mouse: " + (stickMouse ? "ON" : "OFF");
        final boolean isFolder = entry.isDirectory();
        final File folder = entry;
        final String lower = gameName.toLowerCase();
        final boolean isLibraryDisc = entry.getParentFile() != null && entry.getParentFile().equals(cdsDir);
        final boolean isCdImage = !isFolder
            && (isLibraryDisc ? isCdImageFile(entry) : isIsoCueOrBin(entry));
        // Folders with a setup/install utility get a dedicated entry — it runs
        // at low fixed cycles (these tools crash at cycles=max) and is how
        // games like Screamer switch their own controls to joystick. We honour
        // the user-picked .launcher sidecar first (so re-running the same
        // installer uses the right exe), then fall back to detection.
        final File setup = isFolder ? pickSetupExe(folder) : null;
        final boolean bootable = isFolder && findBootImage(folder) != null;
        List<String> menu = new ArrayList<>();
        if ((isFolder && !bootable) || isCdImage) menu.add("Pick program...");
        if (isCdImage) menu.add("Install to C: (copy the CD)...");
        if (isCdImage) menu.add("Copy CD contents to MS-DOS drive...");
        if (isCdImage && findBootFolder() != null) menu.add("Copy CD contents to Windows drive...");
        if (setup != null && !bootable) menu.add("Run setup... (" + relpath(folder, setup) + ")");
        if (isFolder) {
            // CD changer for any folder game (booted OS or plain DOS): all
            // discs inside are mounted as one Ctrl+F4 / CD⇄ swap set.
            menu.add("Insert CD...");
            List<File> inDrive = new ArrayList<>();
            collectCds(folder, 3, inDrive);
            if (!inDrive.isEmpty()) menu.add("Eject CD...");
        }
        if (bootable) {
            List<File> disks = new ArrayList<>();
            collectGamesDisks(folder, 2, disks);
            File badDisk = disks.isEmpty() ? firstInvalidGamesDisk(folder) : null;
            if (disks.isEmpty()) menu.add(badDisk != null ? "Repair games disk (D:)..." : "Create games disk (D:)...");
            else menu.add("Copy game from D: to MS-DOS...");
        }
        // Per-game type (DOS / Windows 98) + CD (rip / needs CD) assignment.
        final String metaName = gameName(entry);
        final String autoPlat = (isCdImage && !isDosDisc(entry)) ? GameMeta.WIN98 : GameMeta.DOS;
        final String plat = GameMeta.platform(this, metaName, autoPlat);
        final boolean needsCd = GameMeta.needsCd(this, metaName, defaultNeedsCd(entry, plat));
        if (!bootable) {
            menu.add(plat.equals(GameMeta.WIN98) ? "Set type → MS-DOS" : "Set type → Windows 98");
            menu.add(needsCd ? "CD: needs disc (tap = mark as rip)" : "CD: rip / no disc (tap = needs CD)");
            if (isFolder && needsCd) menu.add("Choose CD...");
        }
        // Button/key mapping is for DOS games; booted Windows gets the guest
        // joystick/mouse path instead.
        if (!bootable) {
            menu.add("Configure controls...");
            menu.add(stickMouseItem);
        }
        if (!bootable) menu.add(isFolder ? "Delete game..." : "Delete disc...");
        final String[] items = menu.toArray(new String[0]);
        new AlertDialog.Builder(this)
            .setTitle(gameName)
            .setItems(items, (d, w) -> {
                String it = items[w];
                if (it.startsWith("Pick program")) {
                    if (isFolder) showLauncherPicker(folder);
                    else          showIsoProgramPicker(entry);
                }
                else if (it.startsWith("Install to C:")) {
                    File cDir = new File(gamesDir, ".c/" + KeyMapStore.safeName(gameName));
                    if (!cDir.exists()) cDir.mkdirs();
                    copyCdToCThenLaunch(entry, cDir);
                }
                else if (it.startsWith("Copy CD contents to MS-DOS")) copyCdMediaToDosDrive(entry);
                else if (it.startsWith("Copy CD contents to Windows")) copyCdMediaToWindowsDrive(entry, findBootFolder());
                else if (it.startsWith("Run setup"))    launchGame(folder, setup);
                else if (it.startsWith("Insert CD"))    insertCdDialog(folder);
                else if (it.startsWith("Eject CD"))     ejectCdDialog(folder);
                else if (it.startsWith("Create games disk")) createGamesDiskDialog(folder);
                else if (it.startsWith("Repair games disk")) {
                    File bad = firstInvalidGamesDisk(folder);
                    promptRepairGamesDisk(folder, bad, "Repair Windows games disk?",
                        bad == null
                            ? "Create a 4 GB writable D: games disk?"
                            : "The existing " + bad.getName() + " is " + gamesDiskProblem(bad)
                                + ". Replace it with a 4 GB writable D: disk?",
                        () -> rescan(), null);
                }
                else if (it.startsWith("Copy game from D:")) copyFromGamesDiskDialog(folder);
                else if (it.startsWith("Set type")) {
                    String np = plat.equals(GameMeta.WIN98) ? GameMeta.DOS : GameMeta.WIN98;
                    GameMeta.setPlatform(this, metaName, np);
                    GameMeta.setNeedsCd(this, metaName, np.equals(GameMeta.WIN98));
                    rescan();
                }
                else if (it.startsWith("CD:")) { GameMeta.setNeedsCd(this, metaName, !needsCd); rescan(); }
                else if (it.startsWith("Choose CD")) {
                    pickCdFromLibrary(metaName + " CD", metaName, disc -> {
                        GameMeta.setCdMedia(GameLauncherActivity.this, metaName, disc.getName());
                        GameMeta.setNeedsCd(GameLauncherActivity.this, metaName, true);
                        Toast.makeText(GameLauncherActivity.this,
                            metaName + " will use " + disc.getName() + ".",
                            Toast.LENGTH_LONG).show();
                        rescan();
                    });
                }
                else if (it.startsWith("Configure controls")) showControlMapper(gameName);
                else if (it.startsWith("Stick as mouse")) {
                    KeyMapStore.saveStickMouseMode(this, gameName, !stickMouse);
                    Toast.makeText(this, !stickMouse
                        ? "Left stick now moves the DOS mouse."
                        : "Left stick now sends keyboard directions again.",
                        Toast.LENGTH_LONG).show();
                }
                else if (it.startsWith("Delete game"))   confirmDeleteGame(folder);
                else if (it.startsWith("Delete disc"))   confirmDeleteDisc(entry);
            })
            .show();
    }

    /** "Pick program..." for a CD image: everything already installed on its
     *  persistent C: drive plus every DOS program found on the CD itself. */
    private void showIsoProgramPicker(final File iso) {
        final File cDir = new File(gamesDir, ".c/" + KeyMapStore.safeName(iso.getName()));
        final List<File> onC = cDir.isDirectory() ? findLaunchers(cDir, 3) : new ArrayList<File>();
        final IsoReader.Scan scan = IsoReader.scan(iso, 3);
        List<String> names = new ArrayList<>();
        for (File f : onC) names.add("C:\\" + relpath(cDir, f).replace('/', '\\'));
        for (String p : scan.programs) names.add("D:\\" + p);
        if (names.isEmpty()) {
            Toast.makeText(this, "No DOS program found on this CD.", Toast.LENGTH_LONG).show();
            return;
        }
        final String[] items = names.toArray(new String[0]);
        new AlertDialog.Builder(this)
            .setTitle("Run which program?")
            .setItems(items, (d, w) -> {
                if (!cDir.exists()) cDir.mkdirs();
                if (w < onC.size()) {
                    File f = onC.get(w);
                    setKeymapAndLaunch(iso.getName(), isoRunLines(iso, cDir, f, null), f.getName());
                } else {
                    String pick = scan.programs.get(w - onC.size());
                    setKeymapAndLaunch(iso.getName(), isoRunLines(iso, cDir, null, pick),
                        isoBaseName(pick));
                }
            })
            .show();
    }

    private void copyCdMediaToDosDrive(final File media) {
        prepareCdMedia(media, prepared -> copyIsoToDosGames(prepared));
    }

    private void copyCdMediaToWindowsDrive(final File media, final File boot) {
        final File bootFolder = boot != null ? boot : findBootFolder();
        if (bootFolder == null) {
            Toast.makeText(this, "No Windows 98 image found in the games folder.", Toast.LENGTH_LONG).show();
            return;
        }
        File disk = firstGamesDisk(bootFolder);
        if (disk == null) {
            File bad = firstInvalidGamesDisk(bootFolder);
            if (bad != null) {
                promptRepairGamesDisk(bootFolder, bad, "Repair Windows games disk?",
                    "The existing " + bad.getName() + " is " + gamesDiskProblem(bad)
                    + ". Replace it with a 4 GB writable D: disk, then copy this CD into it?",
                    () -> copyCdMediaToWindowsDrive(media, bootFolder),
                    null);
                return;
            }
            new AlertDialog.Builder(this)
                .setTitle("Create Windows games disk?")
                .setMessage("Windows drive copy needs a writable D: games disk. Create a 4 GB disk, then copy this CD into it?")
                .setPositiveButton("Create and copy", (d, w) -> createGamesDiskThenCopyCd(bootFolder, media))
                .setNegativeButton("Cancel", null)
                .show();
            return;
        }
        prepareCdMedia(media, prepared -> copyIsoToWindowsDisk(prepared, disk));
    }

    private void createGamesDiskThenCopyCd(final File boot, final File media) {
        createGamesDiskThenRun(boot, () -> copyCdMediaToWindowsDrive(media, boot));
    }

    private void createGamesDiskThenRun(final File boot, final Runnable afterCreate) {
        final File img = new File(boot, "gamesdisk.img");
        final AlertDialog dlg = new AlertDialog.Builder(this)
            .setTitle(boot.getName())
            .setMessage("Creating a 4 GB games disk...")
            .setCancelable(false)
            .show();
        new Thread(() -> {
            boolean ok;
            try {
                Fat32Disk.create(img, 4L * 1024 * 1024 * 1024, "GAMES");
                ok = true;
            } catch (Exception e) {
                img.delete();
                ok = false;
            }
            final boolean fOk = ok;
            runOnUiThread(() -> {
                dlg.dismiss();
                if (fOk) {
                    rescan();
                    if (afterCreate != null) afterCreate.run();
                }
                else Toast.makeText(this, "Couldn't create the Windows games disk.", Toast.LENGTH_LONG).show();
            });
        }).start();
    }

    private void prepareCdMedia(final File media, final java.util.function.Consumer<File> onReady) {
        if (!isArchiveCdFile(media)) {
            File ready = isRawCdTrack(media) ? ensureCueForBin(media) : media;
            onReady.accept(ready);
            return;
        }
        prepareArchiveCd(media, onReady);
    }

    private void copyIsoToWindowsDisk(final File iso, final File disk) {
        copyIsoToWindowsDisk(iso, disk, null);
    }

    private void copyIsoToWindowsDisk(final File iso, final File disk, final Runnable afterSuccess) {
        final String name = discName(iso);
        final AlertDialog dlg = new AlertDialog.Builder(this)
            .setTitle(name)
            .setMessage("Copying the CD to the Windows D: drive...")
            .setCancelable(false)
            .show();
        new Thread(() -> {
            boolean ok = false;
            String copiedName = null;
            String error = null;
            try {
                copiedName = IsoReader.copyToFat32OrThrow(iso, disk, name);
                ok = copiedName != null;
            } catch (Exception e) {
                error = e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName();
                android.util.Log.e("DosBoxXLauncher", "CD copy failed: " + name, e);
            }
            final boolean fOk = ok;
            final String fCopiedName = copiedName;
            final String fError = error;
            runOnUiThread(() -> {
                dlg.dismiss();
                if (fOk) {
                    Toast.makeText(this, name + " copied to Windows D:\\" + fCopiedName + ".",
                        Toast.LENGTH_LONG).show();
                    rescan();
                    if (afterSuccess != null) afterSuccess.run();
                } else {
                    Toast.makeText(this, "Couldn't copy " + name + ": " + fError,
                        Toast.LENGTH_LONG).show();
                }
            });
        }).start();
    }

    /** Copy a DOS-game CD into a visible games/<name>/ folder so it becomes a
     *  normal MS-DOS menu entry. If the game was already installed onto its
     *  per-ISO C: drive (ran an installer), copy that install; otherwise copy
     *  the CD contents straight out. Afterwards the ISO can be deleted. */
    private void copyIsoToDosGames(final File iso) {
        final String name = discName(iso);
        final File dest = new File(gamesDir, name);
        if (dest.exists()) {
            Toast.makeText(this, "A game folder named \"" + name + "\" already exists.", Toast.LENGTH_LONG).show();
            return;
        }
        final File cDir = new File(gamesDir, ".c/" + KeyMapStore.safeName(iso.getName()));
        final boolean fromInstall = cDir.isDirectory() && autoPickLauncher(cDir) != null;
        final AlertDialog dlg = new AlertDialog.Builder(this)
            .setTitle(name)
            .setMessage(fromInstall ? "Copying the installed game to MS-DOS games…"
                                    : "Copying the CD to MS-DOS games…")
            .setCancelable(false)
            .show();
        new Thread(() -> {
            final boolean ok = fromInstall ? copyDir(cDir, dest) : IsoReader.extractTo(iso, dest);
            runOnUiThread(() -> {
                dlg.dismiss();
                if (ok) {
                    GameMeta.setPlatform(this, name, GameMeta.DOS);
                    GameMeta.setNeedsCd(this, name, true);
                    Toast.makeText(this, name + " added to MS-DOS games. The matching CD will still mount when it plays.",
                        Toast.LENGTH_LONG).show();
                    rescan();
                } else {
                    deleteContents(dest); dest.delete();
                    Toast.makeText(this, "Couldn't copy " + name + ".", Toast.LENGTH_LONG).show();
                }
            });
        }).start();
    }

    /** Recursive directory copy. */
    private static boolean copyDir(File src, File dst) {
        if (!dst.exists() && !dst.mkdirs()) return false;
        File[] kids = src.listFiles();
        if (kids == null) return true;
        for (File f : kids) {
            File out = new File(dst, f.getName());
            if (f.isDirectory()) { if (!copyDir(f, out)) return false; }
            else if (!copyFile(f, out)) return false;
        }
        return true;
    }

    private static boolean copyFile(File src, File dst) {
        try {
            FileInputStream in = new FileInputStream(src);
            try {
                FileOutputStream o = new FileOutputStream(dst);
                try {
                    byte[] buf = new byte[65536];
                    int n;
                    while ((n = in.read(buf)) > 0) o.write(buf, 0, n);
                } finally { o.close(); }
            } finally { in.close(); }
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    /** Move a CD image between two folders — for cue sheets, EVERY data file
     *  the cue references (multi-track .bin/.img sets) moves along with it. */
    private boolean moveCd(File cd, File destDir) {
        File dest = new File(destDir, cd.getName());
        if (!cd.renameTo(dest)) return false;
        if (cd.getName().toLowerCase().endsWith(".cue")) {
            for (String dataName : cueDataNames(dest)) {
                File data = new File(cd.getParentFile(), dataName);
                if (data.isFile()) data.renameTo(new File(destDir, dataName));
            }
        }
        return true;
    }

    /** All file names referenced by the cue sheet's FILE lines (multi-track). */
    private static List<String> cueDataNames(File cue) {
        List<String> names = new ArrayList<>();
        try {
            BufferedReader br = new BufferedReader(new FileReader(cue));
            try {
                String line;
                while ((line = br.readLine()) != null) {
                    String t = line.trim();
                    if (!t.toUpperCase(Locale.US).startsWith("FILE")) continue;
                    int q1 = t.indexOf('"'), q2 = t.lastIndexOf('"');
                    names.add((q1 >= 0 && q2 > q1)
                        ? t.substring(q1 + 1, q2)
                        : t.substring(4).trim().split("\\s+")[0]);
                }
            } finally {
                br.close();
            }
        } catch (IOException ignored) { }
        return names;
    }

    /** First data file a cue references, or null (used by the zip importer). */
    private static String cueDataName(File cue) {
        List<String> n = cueDataNames(cue);
        return n.isEmpty() ? null : n.get(0);
    }

    /** cue+img/bin pairs are CD images — never boot/data HDD candidates. */
    private static boolean hasSiblingCue(File img) {
        String n = img.getName();
        int dot = n.lastIndexOf('.');
        String base = dot >= 0 ? n.substring(0, dot) : n;
        return new File(img.getParentFile(), base + ".cue").isFile()
            || new File(img.getParentFile(), base + ".CUE").isFile();
    }

    /** Browse the CD library (and any loose discs in the games dir) for CD
     *  images (or archives, which are unpacked into mountable media) and put one
     *  into the game's changer folder. */
    private void insertCdDialog(File folder) {
        List<File> cds = new ArrayList<>();
        for (File dir : new File[]{cdsDir, gamesDir}) {
            File[] kids = dir.listFiles();
            if (kids == null) continue;
            Arrays.sort(kids, NAME);
            java.util.Set<String> preparedDiscKeys = dir.equals(cdsDir) ? preparedDiscKeys(kids) : new java.util.HashSet<String>();
            for (File f : kids) {
                if (f.isDirectory() || f.equals(folder)) continue;
                if (dir.equals(cdsDir) && isArchiveCdFile(f) && preparedDiscKeys.contains(cdMediaKey(f))) continue;
                String n = f.getName().toLowerCase(Locale.US);
                if (isCdMediaListFile(f)) cds.add(f);
            }
        }
        if (cds.isEmpty()) {
            Toast.makeText(this, "No .iso/.cue/.zip images found. Put discs in:\n"
                + cdsDir.getAbsolutePath(), Toast.LENGTH_LONG).show();
            return;
        }
        String[] names = new String[cds.size()];
        for (int i = 0; i < cds.size(); i++) names[i] = cds.get(i).getName();
        new AlertDialog.Builder(this)
            .setTitle("Insert which CD?")
            .setItems(names, (d, w) -> {
                File pick = cds.get(w);
                if (isArchiveCdFile(pick)) {
                    insertArchiveAsCd(pick, folder);
                } else if (moveCd(pick, folder)) {
                    markFirstCd(folder, names[w]);
                    Toast.makeText(this,
                        names[w] + " is in the drive — launch the game to use it.",
                        Toast.LENGTH_LONG).show();
                    rescan();
                } else {
                    Toast.makeText(this, "Couldn't move " + names[w] + ".", Toast.LENGTH_LONG).show();
                }
            })
            .show();
    }

    /** Put an archive into the changer. If the archive CONTAINS a disc image
     *  (.iso, or .cue + its data file, or a raw .img rip), that image is
     *  extracted as-is; otherwise a ZIP's files are pressed onto a new
     *  ISO (the only drive form a booted Win9x guest can mount). */
    private void insertArchiveAsCd(final File archive, final File folder) {
        final AlertDialog dlg = new AlertDialog.Builder(this)
            .setTitle(archive.getName())
            .setMessage("Preparing CD media...")
            .setCancelable(false)
            .show();
        new Thread(() -> {
            final String inserted = importArchiveCd(archive, folder);
            runOnUiThread(() -> {
                dlg.dismiss();
                if (inserted != null) {
                    markFirstCd(folder, inserted);
                    Toast.makeText(this,
                        inserted + " is in the drive — launch the game to use it.",
                        Toast.LENGTH_LONG).show();
                    rescan();
                } else {
                    Toast.makeText(this, "Couldn't import a CD from " + archive.getName() + ".",
                        Toast.LENGTH_LONG).show();
                }
            });
        }).start();
    }

    /** Worker for archive-backed CD media: returns the inserted disc's name, or null. */
    private String importArchiveCd(File archive, File folder) {
        return importArchiveCd(archive, folder, null);
    }

    /** Worker for archive-backed CD media: returns the inserted disc's name, or null. */
    private String importArchiveCd(File archive, File folder, ArchiveExtractor.Progress progress) {
        String n = archive.getName().toLowerCase(Locale.US);
        if (n.endsWith(".zip")) {
            String disc = importPackedDiscImages(archive, folder, progress);
            return disc != null ? disc : importZipFolderAsIso(archive, folder);
        }
        return null;
    }

    /** Extract disc image files from archives that contain actual
     *  media (.iso/.cue/.bin/.img), then return the mountable image name. */
    private String importPackedDiscImages(File archive, File folder) {
        return importPackedDiscImages(archive, folder, null);
    }

    private String importPackedDiscImages(File archive, File folder, ArchiveExtractor.Progress progress) {
        java.util.Set<String> before = listNamesIn(folder);
        boolean ok = ArchiveExtractor.extractDiscImages(archive, folder, progress);
        if (!ok) return null;
        File disc = newDiscMedia(folder, before);
        return disc != null ? disc.getName() : null;
    }

    private String importZipFolderAsIso(File zip, File folder) {
        String n = zip.getName();
        File out = new File(folder, n.substring(0, n.length() - 4) + ".iso");
        return ZipToIso.convert(zip, out) ? out.getName() : null;
    }

    /** A newly-appeared mountable CD image in dir, or null. */
    private File newDiscMedia(File dir, java.util.Set<String> before) {
        File[] k = dir.listFiles();
        if (k == null) return null;
        Arrays.sort(k, NAME);
        for (File f : k) {
            String n = f.getName().toLowerCase(Locale.US);
            if (n.endsWith(".cue") && !before.contains(f.getName())) return f;
        }
        for (File f : k) {
            String n = f.getName().toLowerCase(Locale.US);
            if (n.endsWith(".iso") && !before.contains(f.getName())) return f;
        }
        for (File f : k) {
            String n = f.getName().toLowerCase(Locale.US);
            if ((n.endsWith(".bin") || n.endsWith(".img")) && !before.contains(f.getName())) {
                File cue = writeCueFor(f);
                return cue != null ? cue : f;
            }
        }
        return null;
    }

    /** Cue sheet for an orphan raw CD rip: 2352-byte sectors start with the
     *  standard 12-byte sync pattern, plain ISO data rips are 2048. */
    private File writeCueFor(File img) {
        String mode = "MODE1/2048";
        try {
            FileInputStream in = new FileInputStream(img);
            try {
                byte[] h = new byte[12];
                if (in.read(h) == 12
                    && h[0] == 0 && (h[1] & 0xFF) == 0xFF && (h[10] & 0xFF) == 0xFF && h[11] == 0) {
                    mode = "MODE1/2352";
                }
            } finally {
                in.close();
            }
        } catch (IOException e) {
            return null;
        }
        String n = img.getName();
        File cue = new File(img.getParentFile(), n.substring(0, n.lastIndexOf('.')) + ".cue");
        try {
            FileWriter w = new FileWriter(cue, false);
            w.write("FILE \"" + n + "\" BINARY\r\n  TRACK 01 " + mode + "\r\n    INDEX 01 00:00:00\r\n");
            w.close();
            return cue;
        } catch (IOException e) {
            return null;
        }
    }

    /** Move a CD image out of the changer into the CD library. */
    private void ejectCdDialog(File folder) {
        List<File> cds = new ArrayList<>();
        collectCds(folder, 3, cds);
        String[] names = new String[cds.size()];
        for (int i = 0; i < cds.size(); i++) names[i] = cds.get(i).getName();
        new AlertDialog.Builder(this)
            .setTitle("Eject which CD?")
            .setItems(names, (d, w) -> {
                if (moveCd(cds.get(w), cdsDir)) {
                    Toast.makeText(this, names[w] + " moved to the CD library.", Toast.LENGTH_LONG).show();
                    rescan();
                } else {
                    Toast.makeText(this, "Couldn't move " + names[w] + ".", Toast.LENGTH_LONG).show();
                }
            })
            .show();
    }

    /** All CD images under dir (sorted by name), except that the most
     *  recently inserted disc (.cd1 marker) is moved to the front — the
     *  first disc of the swap set is the one in the drive at boot. */
    private void collectCds(File dir, int depth, List<File> out) {
        collectCdsInner(dir, depth, out);
        File marker = new File(dir, ".cd1");
        if (!marker.isFile()) return;
        try {
            BufferedReader br = new BufferedReader(new FileReader(marker));
            String first;
            try { first = br.readLine(); } finally { br.close(); }
            if (first != null) {
                for (int i = 1; i < out.size(); i++) {
                    if (out.get(i).getName().equals(first.trim())) {
                        out.add(0, out.remove(i));
                        break;
                    }
                }
            }
        } catch (IOException ignored) { }
    }

    private void collectCdsInner(File dir, int depth, List<File> out) {
        File[] kids = dir.listFiles();
        if (kids == null) return;
        Arrays.sort(kids, NAME);
        for (File f : kids) {
            if (f.isDirectory()) {
                if (depth > 0) collectCdsInner(f, depth - 1, out);
            } else {
                String n = f.getName().toLowerCase();
                // Plain .iso / .cue are the common cases; .bin is also
                // accepted and auto-wrapped with a generated .cue at mount
                // time (see ensureCueForBin).
                if (n.endsWith(".iso") || n.endsWith(".cue")
                        || ((n.endsWith(".bin") || n.endsWith(".img")) && !hasSiblingCue(f))) {
                    out.add(f);
                }
            }
        }
    }

    /** Remember which disc was inserted last — it boots in the drive. */
    private static void markFirstCd(File folder, String name) {
        try {
            FileWriter w = new FileWriter(new File(folder, ".cd1"), false);
            w.write(name);
            w.close();
        } catch (IOException ignored) { }
    }

    /** List the game folders installed on the Windows data disk (D:) and copy
     *  a chosen one out to a host games/<name>/ folder (an MS-DOS menu entry). */
    private void copyFromGamesDiskDialog(File folder) {
        List<File> disks = new ArrayList<>();
        collectGamesDisks(folder, 2, disks);
        if (disks.isEmpty()) {
            Toast.makeText(this, "No games disk (D:) in this folder.", Toast.LENGTH_LONG).show();
            return;
        }
        final File disk = disks.get(0);
        final List<String> dirs = Fat32Reader.listTopDirs(disk);
        if (dirs.isEmpty()) {
            Toast.makeText(this, "No game folders found on D: — install a game in Windows first.",
                Toast.LENGTH_LONG).show();
            return;
        }
        final String[] names = dirs.toArray(new String[0]);
        new AlertDialog.Builder(this)
            .setTitle("Copy which game from D:?")
            .setItems(names, (d, w) -> {
                final String name = names[w];
                final File dest = new File(gamesDir, name);
                if (dest.exists()) {
                    Toast.makeText(this, "\"" + name + "\" is already in MS-DOS games.", Toast.LENGTH_LONG).show();
                    return;
                }
                final AlertDialog dlg = new AlertDialog.Builder(this)
                    .setTitle(name).setMessage("Copying from D: to MS-DOS games…")
                    .setCancelable(false).show();
                new Thread(() -> {
                    final boolean ok = Fat32Reader.extractTopDir(disk, name, dest);
                    runOnUiThread(() -> {
                        dlg.dismiss();
                        if (ok) {
                            Toast.makeText(this, name + " copied to MS-DOS games.", Toast.LENGTH_LONG).show();
                            rescan();
                        } else {
                            deleteContents(dest); dest.delete();
                            Toast.makeText(this, "Couldn't copy " + name + ".", Toast.LENGTH_LONG).show();
                        }
                    });
                }).start();
            })
            .show();
    }

    /** Data-disk images (gamesdisk*.img) under dir, sorted by name. */
    private void collectGamesDisks(File dir, int depth, List<File> out) {
        File[] kids = dir.listFiles();
        if (kids == null) return;
        Arrays.sort(kids, NAME);
        for (File f : kids) {
            if (f.isDirectory()) {
                if (depth > 0) collectGamesDisks(f, depth - 1, out);
            } else if (isUsableGamesDisk(f)) {
                out.add(f);
            }
        }
    }

    private void collectInvalidGamesDisks(File dir, int depth, List<File> out) {
        File[] kids = dir.listFiles();
        if (kids == null) return;
        Arrays.sort(kids, NAME);
        for (File f : kids) {
            if (f.isDirectory()) {
                if (depth > 0) collectInvalidGamesDisks(f, depth - 1, out);
            } else if (Fat32Disk.isGamesDisk(f.getName()) && !isUsableGamesDisk(f)) {
                out.add(f);
            }
        }
    }

    private static boolean isUsableGamesDisk(File f) {
        return Fat32Disk.isGamesDisk(f.getName())
            && f.length() > WIN98_GAMES_DISK_MIN
            && f.length() <= WIN98_GAMES_DISK_MAX;
    }

    /** "Create games disk (D:)..." — a formatted FAT32 image the guest OS
     *  mounts as D: for installing games (the CD lives at E:). */
    private void createGamesDiskDialog(final File folder) {
        final String[] sizes = {"2 GB", "4 GB"};
        new AlertDialog.Builder(this)
            .setTitle("Games disk size")
            .setItems(sizes, (d, w) -> {
                final long bytes = (2L << w) * 1024 * 1024 * 1024;
                final File img = new File(folder, "gamesdisk.img");
                final AlertDialog dlg = new AlertDialog.Builder(this)
                    .setTitle(folder.getName())
                    .setMessage("Creating a " + sizes[w] + " games disk…")
                    .setCancelable(false)
                    .show();
                new Thread(() -> {
                    boolean ok;
                    try {
                        Fat32Disk.create(img, bytes, "GAMES");
                        ok = true;
                    } catch (Exception e) {
                        img.delete();
                        ok = false;
                    }
                    final boolean fOk = ok;
                    runOnUiThread(() -> {
                        dlg.dismiss();
                        Toast.makeText(this, fOk
                            ? "Games disk ready — Windows sees it as D: on next boot (the CD is E:). Install games to D:\\."
                            : "Couldn't create the games disk.",
                            Toast.LENGTH_LONG).show();
                    });
                }).start();
            })
            .show();
    }

    /** All .zip archives under dir — candidates for zip→ISO CD conversion. */
    private void collectZips(File dir, int depth, List<File> out) {
        File[] kids = dir.listFiles();
        if (kids == null) return;
        Arrays.sort(kids, NAME);
        for (File f : kids) {
            if (f.isDirectory()) {
                if (depth > 0) collectZips(f, depth - 1, out);
            } else if (f.getName().toLowerCase().endsWith(".zip")) {
                out.add(f);
            }
        }
    }

    /** First setup/install utility in the folder, or null. */
    private File findSetup(File folder) {
        for (File f : findLaunchers(folder, 3)) {
            String n = f.getName().toLowerCase();
            if (n.startsWith("setup") || n.startsWith("install") || n.startsWith("dosinst")) return f;
        }
        return null;
    }

    // ---- per-game sidecar files ----
    // Two tiny text files that record the user's setup-then-pick choices, so
    // the same game reopens straight to the right launcher / installer.
    public static final String SIDE_LAUNCHER = ".launcher";   // the SETUP.EXE the user picked
    public static final String SIDE_LAUNCH   = ".launch";     // the GAME.EXE the user picked

    /** The user-picked setup exe for this folder, or null if unset. */
    private File readSidecarLauncher(File folder) {
        return readSidecarFile(folder, SIDE_LAUNCHER);
    }

    /** The user-picked launch exe for this folder, or null if unset. */
    private File readSidecarLaunch(File folder) {
        return readSidecarFile(folder, SIDE_LAUNCH);
    }

    private File readSidecarFile(File folder, String name) {
        File f = new File(folder, name);
        if (!f.isFile()) return null;
        try {
            java.io.BufferedReader br = new java.io.BufferedReader(new FileReader(f));
            try {
                String line = br.readLine();
                if (line == null) return null;
                line = line.trim();
                if (line.isEmpty()) return null;
                File rel = new File(folder, line);
                return rel.isFile() ? rel : null;
            } finally { br.close(); }
        } catch (Exception e) { return null; }
    }

    /** Pick the setup exe: user-stored .launcher first, then auto-detect. */
    private File pickSetupExe(File folder) {
        File stored = readSidecarLauncher(folder);
        if (stored != null) return stored;
        return findSetup(folder);
    }

    /** True if the folder has a recorded launch exe (game is fully wired). */
    private boolean hasStoredLaunch(File folder) {
        return readSidecarLaunch(folder) != null;
    }

    /** True if the folder has a recorded setup exe (but no launch yet). */
    private boolean hasStoredSetupOnly(File folder) {
        return readSidecarLauncher(folder) != null && readSidecarLaunch(folder) == null;
    }

    private void toggleJoystickMode(String gameName, boolean on) {
        KeyMapStore.saveJoystickMode(this, gameName, on);
        Toast.makeText(this, on
            ? "Joystick mode ON — the gamepad reaches the game as a real DOS joystick; the ⌨ button shows a full keyboard."
            : "Joystick mode OFF — gamepad buttons are mapped to keyboard keys again.",
            Toast.LENGTH_LONG).show();
    }

    private void showControlMapper(final String gameName) {
        final Map<String, Integer> map = keyMapForEdit(gameName);
        String[] rows = new String[KeyMapStore.BUTTONS.length];
        for (int i = 0; i < KeyMapStore.BUTTONS.length; i++) {
            String b = KeyMapStore.BUTTONS[i];
            Integer v = map.get(b);
            rows[i] = b + "  →  " + KeyMapStore.keycodeLabel(v != null ? v : KeyEvent.KEYCODE_UNKNOWN);
        }
        new AlertDialog.Builder(this)
            .setTitle("Controls: " + gameName)
            .setItems(rows, (d, w) -> showTargetPicker(gameName, KeyMapStore.BUTTONS[w], map))
            .setNeutralButton("Reset", (d, w) -> {
                KeyMapStore.clear(this, gameName);
                Toast.makeText(this, "Controls reset to defaults.", Toast.LENGTH_SHORT).show();
            })
            .setNegativeButton("Close", null)
            .show();
    }

    private Map<String, Integer> keyMapForEdit(String gameName) {
        Map<String, Integer> saved = KeyMapStore.load(this, gameName);
        return saved != null ? new HashMap<>(saved) : KeyMapStore.newDefaultMap();
    }

    private void showTargetPicker(final String gameName, final String button,
                                  final Map<String, Integer> map) {
        final int[] codes = controlTargetCodes();
        String[] labels = new String[codes.length];
        for (int i = 0; i < codes.length; i++) labels[i] = KeyMapStore.keycodeLabel(codes[i]);
        new AlertDialog.Builder(this)
            .setTitle(button + " sends...")
            .setItems(labels, (d, w) -> {
                map.put(button, codes[w]);
                KeyMapStore.save(this, gameName, map);
                Toast.makeText(this, button + " → " + KeyMapStore.keycodeLabel(codes[w]),
                    Toast.LENGTH_SHORT).show();
                showControlMapper(gameName);
            })
            .setNegativeButton("Back", (d, w) -> showControlMapper(gameName))
            .show();
    }

    private static int[] controlTargetCodes() {
        return new int[] {
            KeyEvent.KEYCODE_UNKNOWN,
            KeyEvent.KEYCODE_DPAD_UP,
            KeyEvent.KEYCODE_DPAD_DOWN,
            KeyEvent.KEYCODE_DPAD_LEFT,
            KeyEvent.KEYCODE_DPAD_RIGHT,
            KeyEvent.KEYCODE_ENTER,
            KeyEvent.KEYCODE_ESCAPE,
            KeyEvent.KEYCODE_SPACE,
            KeyEvent.KEYCODE_CTRL_LEFT,
            KeyEvent.KEYCODE_ALT_LEFT,
            KeyEvent.KEYCODE_SHIFT_LEFT,
            KeyEvent.KEYCODE_TAB,
            KeyMapStore.TARGET_MOUSE_LEFT,
            KeyMapStore.TARGET_MOUSE_RIGHT,
            KeyEvent.KEYCODE_A,
            KeyEvent.KEYCODE_B,
            KeyEvent.KEYCODE_C,
            KeyEvent.KEYCODE_D,
            KeyEvent.KEYCODE_E,
            KeyEvent.KEYCODE_F,
            KeyEvent.KEYCODE_G,
            KeyEvent.KEYCODE_H,
            KeyEvent.KEYCODE_I,
            KeyEvent.KEYCODE_J,
            KeyEvent.KEYCODE_K,
            KeyEvent.KEYCODE_L,
            KeyEvent.KEYCODE_M,
            KeyEvent.KEYCODE_N,
            KeyEvent.KEYCODE_O,
            KeyEvent.KEYCODE_P,
            KeyEvent.KEYCODE_Q,
            KeyEvent.KEYCODE_R,
            KeyEvent.KEYCODE_S,
            KeyEvent.KEYCODE_T,
            KeyEvent.KEYCODE_U,
            KeyEvent.KEYCODE_V,
            KeyEvent.KEYCODE_W,
            KeyEvent.KEYCODE_X,
            KeyEvent.KEYCODE_Y,
            KeyEvent.KEYCODE_Z,
            KeyEvent.KEYCODE_0,
            KeyEvent.KEYCODE_1,
            KeyEvent.KEYCODE_2,
            KeyEvent.KEYCODE_3,
            KeyEvent.KEYCODE_4,
            KeyEvent.KEYCODE_5,
            KeyEvent.KEYCODE_6,
            KeyEvent.KEYCODE_7,
            KeyEvent.KEYCODE_8,
            KeyEvent.KEYCODE_9,
            KeyEvent.KEYCODE_F1,
            KeyEvent.KEYCODE_F2,
            KeyEvent.KEYCODE_F3,
            KeyEvent.KEYCODE_F4,
            KeyEvent.KEYCODE_F5,
            KeyEvent.KEYCODE_F6,
            KeyEvent.KEYCODE_F7,
            KeyEvent.KEYCODE_F8,
            KeyEvent.KEYCODE_F9,
            KeyEvent.KEYCODE_F10,
            KeyEvent.KEYCODE_F11,
            KeyEvent.KEYCODE_F12
        };
    }

    /** Resolve the launcher for a game folder per the auto-pick rules. */
    private File autoPickLauncher(File folder) {
        // User picked this launcher at import time — honour it.
        File stored = readSidecarLaunch(folder);
        if (stored != null && stored.isFile()) {
            String g = folder.getName().toLowerCase(Locale.US);
            if (!(g.contains("bubble") && g.contains("rainbow")
                    && stored.getName().equalsIgnoreCase("bubble.bat"))) {
                return stored;
            }
        }

        // Screamer 2: software Voodoo (3dfx) is enabled in the conf, so the
        // 3dfx build is the best pick (verified rendering on this core);
        // START65H.EXE is the SVGA fallback if it's missing or too slow —
        // long-press → "Pick program..." switches builds.
        if (folder.getName().toLowerCase().contains("screamer")) {
            File s23dfx = findNamed(folder, "s2_3dfx.exe", 3);
            if (s23dfx != null) return s23dfx;
            File start65h = findNamed(folder, "start65h.exe", 3);
            if (start65h != null) return start65h;
            File anyExe = findFirst(folder, new String[]{".exe"}, 3);
            if (anyExe != null) {
                Toast.makeText(this,
                    "Screamer build missing — expected S2_3DFX.EXE/START65H.EXE. Launching " + anyExe.getName() + ".",
                    Toast.LENGTH_LONG).show();
                return anyExe;
            }
        }

        // Whiplash / Fatal Racing ships both a 3dfx build (whip3dfx.exe) and
        // the original (fatal.exe). 3dfx is broken on this build, so prefer
        // fatal.exe. Also: never pick `dosbox-x.exe` or `setup.exe` — those
        // are the emulator binary and the installer respectively.
        if (folder.getName().toLowerCase().contains("whiplash")) {
            File fatal = findNamed(folder, "fatal.exe", 4);
            if (fatal != null) return fatal;
        }

        // Known titles — prefer the real game launcher (the folder may also
        // hold track packs, editors, readme tools).
        String[] preferred = preferredExes(folder.getName());
        if (preferred != null) {
            for (String name : preferred) {
                File f = findNamed(folder, name, 3);
                if (f != null) return f;
            }
        }

        List<File> launchers = findLaunchers(folder, 3);
        // Filter out emulator binaries, installers, and 3dfx patches.
        List<File> filtered = new ArrayList<>();
        for (File f : launchers) {
            if (isFilteredName(f.getName().toLowerCase())) continue;
            filtered.add(f);
        }
        if (filtered.isEmpty()) filtered = launchers;  // fallback: take anything we have
        if (filtered.isEmpty()) return null;            // drop to C: prompt
        if (filtered.size() == 1) return filtered.get(0);
        return filtered.get(0);                          // .bat wins, then alphabetical first
    }

    /** True when tapping a folder should prompt for the exe rather than auto-
     *  run: more than one runnable program and no known-title / single pick. */
    private boolean shouldPromptForExe(File folder) {
        String g = folder.getName().toLowerCase();
        if (preferredExes(folder.getName()) != null) return false;   // known title
        if (g.contains("screamer") || g.contains("whiplash")) return false;
        List<File> launchers = findLaunchers(folder, 3);
        List<File> filtered = new ArrayList<>();
        for (File f : launchers) if (!isFilteredName(f.getName().toLowerCase())) filtered.add(f);
        if (filtered.isEmpty()) filtered = launchers;
        return filtered.size() > 1;
    }

    /** Always show the launcher picker (long-press "Pick program..."). */
    private void showLauncherPicker(File folder) {
        List<File> launchers = findLaunchers(folder, 3);
        if (launchers.isEmpty()) {
            Toast.makeText(this, "No .exe or .bat found in this folder.", Toast.LENGTH_LONG).show();
            return;
        }
        final List<File> ls = launchers;
        String[] names = new String[ls.size()];
        for (int i = 0; i < ls.size(); i++) names[i] = relpath(folder, ls.get(i));
        new AlertDialog.Builder(this)
            .setTitle("Run which program?")
            .setItems(names, (dialog, which) -> launchGame(folder, ls.get(which)))
            .show();
    }

    /** Write the conf for (folder, launcher) and start SDLActivity with the saved keymap.
     *  If the folder has no disc and the game is flagged as needing one, try
     *  to find a matching disc in the CD library and mount it automatically.
     *  If no match is found there either, prompt the user to pick a disc
     *  from the library so the game can actually launch with a D: drive. */
    private void launchGame(File folder, File launcher) {
        List<File> cds = new ArrayList<>();
        collectCds(folder, 3, cds);
        if (cds.isEmpty()) {
            String gameName = folder.getName();
            boolean needsCd = GameMeta.needsCd(this, gameName, findCdInLibrary(gameName) != null);
            if (needsCd) {
                File stored = storedCdForGame(gameName);
                if (stored != null) {
                    launchDosGameWithLibraryCd(folder, launcher, gameName, stored, false);
                    return;
                }
                // Always prompt the user to pick a disc from the CD
                // library, so they see what's being mounted and can swap
                // if the auto-match would pick the wrong disc. We pre-fill
                // the dialog with the best match (if any) as the first
                // entry, marked as such.
                promptPickCdFromLibrary(folder, launcher, gameName);
                return;
            }
        }
        setKeymapAndLaunch(folder.getName(), mountLines(folder, launcher, cds),
            launcher != null ? launcher.getName() : null);
    }

    /** Show every disc in cds/ as a list dialog. Tapping one launches the
     *  game with that disc mounted as D:. Used when a game with needsCd=true
     *  has no disc in its folder. The best name-match (if any) is shown
     *  first; the rest of the library follows. A "Mark as rip" option
     *  flips the game's flag to no-CD and launches it without D:. */
    private void promptPickCdFromLibrary(final File folder, final File launcher,
                                          final String gameName) {
        if (cdsDir == null || !cdsDir.isDirectory()) {
            Toast.makeText(this,
                gameName + " needs its CD. Add one with + Add CD game first.",
                Toast.LENGTH_LONG).show();
            return;
        }
        final List<File> discs = libraryDiscs();
        if (discs.isEmpty()) {
            new android.app.AlertDialog.Builder(this)
                .setTitle(gameName + " needs its CD")
                .setMessage("No disc was found in this game folder, and your CD "
                    + "library is empty. Add a disc with + Add CD game, or mark "
                    + "this game as a no-CD rip.")
                .setPositiveButton("Mark as rip", (d, w) -> {
                    GameMeta.setNeedsCd(GameLauncherActivity.this, gameName, false);
                    rescan();
                    launchGame(folder, launcher);
                })
                .setNegativeButton("Cancel", null)
                .show();
            return;
        }
        // Pre-sort: best name-match first, then everything else. The match
        // is shown with " (auto)" appended so the user knows it would have
        // been the default if we'd silently mounted.
        File bestMatch = findCdInLibrary(gameName);
        final List<File> ordered = new ArrayList<>();
        if (bestMatch != null) ordered.add(bestMatch);
        for (File f : discs) if (f != bestMatch) ordered.add(f);
        final String[] names = new String[ordered.size()];
        for (int i = 0; i < ordered.size(); i++) {
            String base = discName(ordered.get(i));
            names[i] = (i == 0 && bestMatch != null) ? base + "  (auto)" : base;
        }
        new android.app.AlertDialog.Builder(this)
            .setTitle(gameName + " needs its CD — pick one")
            .setItems(names, (d, w) -> {
                launchDosGameWithLibraryCd(folder, launcher, gameName, ordered.get(w), true);
            })
            .setNeutralButton("Mark as rip", (d, w) -> {
                GameMeta.setNeedsCd(GameLauncherActivity.this, gameName, false);
                rescan();
                launchGame(folder, launcher);
            })
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void launchDosGameWithLibraryCd(final File folder, final File launcher,
                                             final String gameName, final File pick) {
        launchDosGameWithLibraryCd(folder, launcher, gameName, pick, true);
    }

    private void launchDosGameWithLibraryCd(final File folder, final File launcher,
                                             final String gameName, final File pick,
                                             final boolean remember) {
        if (remember && pick != null) GameMeta.setCdMedia(this, gameName, pick.getName());
        if (isArchiveCdFile(pick)) {
            final File archiveDisc = pick;
            prepareArchiveCd(archiveDisc,
                prepared -> launchDosGameWithLibraryCd(folder, launcher, gameName, prepared, false));
            return;
        }
        File mountable = ensureCueForBin(pick);
        List<File> cds = new ArrayList<>();
        cds.add(mountable);
        setKeymapAndLaunch(folder.getName(),
            mountLines(folder, launcher, cds),
            launcher != null ? launcher.getName() : null);
    }

    /** For a raw .bin track DOSBox can't mount with -t iso (it needs a .cue
     *  describing the track mode and pre-gap). If the picked file is a
     *  .bin with no sibling .cue, write a minimal Mode1/2352 single-track
     *  .cue next to it and return that. Otherwise return the input
     *  unchanged. The .cue is idempotent: we don't overwrite an existing
     *  one. This handles the common rips (Bubble Bobble, etc.) where
     *  the user only has the .bin. */
    private File ensureCueForBin(File pick) {
        if (pick == null) return null;
        String n = pick.getName().toLowerCase(java.util.Locale.US);
        if (!isRawCdTrack(pick)) return pick;
        File cue = new File(pick.getParentFile(),
            pick.getName().substring(0, pick.getName().lastIndexOf('.')) + ".cue");
        if (cue.isFile()) return cue;
        try {
            String binName = pick.getName();
            // Assume Mode1/2352 — the common case for DOS CD-ROM rips.
            // If the user has a Mode2 disc (rare for DOS games) they can
            // hand-edit the .cue or supply their own.
            String body = "FILE \"" + binName + "\" BINARY\n"
                + "  TRACK 01 MODE1/2352\n"
                + "    INDEX 01 00:00:00\n";
            java.io.FileWriter w = new java.io.FileWriter(cue, false);
            try { w.write(body); } finally { w.close(); }
            Toast.makeText(this,
                "Wrote " + cue.getName() + " so DOSBox can mount " + binName + ".",
                Toast.LENGTH_SHORT).show();
            return cue;
        } catch (Exception e) {
            return pick;
        }
    }

    private String imgmountCdLine(File disc) {
        File mountable = isRawCdTrack(disc) ? ensureCueForBin(disc) : disc;
        return "imgmount d \"" + mountable.getAbsolutePath() + "\" -t iso";
    }

    private static boolean isRawCdTrack(File f) {
        if (f == null || f.isDirectory()) return false;
        String n = f.getName().toLowerCase(java.util.Locale.US);
        return n.endsWith(".bin") || n.endsWith(".img");
    }

    /** Find a disc in cds/ whose name matches a game folder. Match order:
     *  exact (case-insensitive), then disc name starts with the game name,
     *  then disc name contains the game name. Returns the best match or null.
     *  Used by {@link #launchGame} so a game flagged as needing its CD
     *  auto-mounts the disc from the library without the user copying it. */
    private File findCdInLibrary(String gameName) {
        String target = gameName.toLowerCase(java.util.Locale.US).trim();
        if (target.isEmpty()) return null;
        File exact = null, prefix = null, contains = null;
        for (File f : libraryDiscs()) {
            String dn = discName(f).toLowerCase(java.util.Locale.US);
            if (dn.equals(target))                                    { exact = f; break; }
            if (prefix == null  && dn.startsWith(target))             prefix = f;
            if (contains == null && dn.contains(target))              contains = f;
        }
        return exact != null ? exact : (prefix != null ? prefix : contains);
    }

    /** Build the mount + run lines for a game folder and a chosen launcher (may be null). */
    private List<String> mountLines(File folder, File launcher, List<File> cds) {
        List<String> lines = new ArrayList<>();
        // ICR2 asks DOS/4GW for its own path (DOS4G_GET_APPPATH) and dies with
        // "Unable to find IndyCar.exe in ''" when it sits at the C: root —
        // mount the parent and run it from a subdirectory instead.
        boolean subdirMount = folder.getName().toLowerCase().contains("indy");
        File root = subdirMount ? folder.getParentFile() : folder;
        lines.add("mount c \"" + root.getAbsolutePath() + "\"");
        // auto-mount CD images found in the folder; several form one swap set
        // the CD⇄ button (Ctrl+F4) cycles through, like the boot-image flow.
        // .iso files mount as -t iso; .bin files are raw 2352-byte tracks
        // and need a sibling .cue (which we generate on the fly). We split
        // the list by type so the right -t flag goes with the right set.
        if (!cds.isEmpty()) {
            List<File> isos = new ArrayList<>();
            List<File> cdrs = new ArrayList<>();
            for (File cd : cds) {
                String n = cd.getName().toLowerCase(java.util.Locale.US);
                if (n.endsWith(".cue") || isRawCdTrack(cd)) cdrs.add(isRawCdTrack(cd) ? ensureCueForBin(cd) : cd);
                else                    isos.add(cd);
            }
            if (!isos.isEmpty()) {
                StringBuilder im = new StringBuilder("imgmount d");
                for (File cd : isos) im.append(" \"").append(cd.getAbsolutePath()).append("\"");
                im.append(" -t iso");
                lines.add(im.toString());
            }
            if (!cdrs.isEmpty()) {
                StringBuilder im = new StringBuilder("imgmount d");
                for (File cd : cdrs) im.append(" \"").append(cd.getAbsolutePath()).append("\"");
                im.append(" -t iso");
                lines.add(im.toString());
            }
        }
        lines.add("c:");
        if (launcher != null) {
            String rel = relpath(root, launcher);
            int slash = rel.replace('\\', '/').lastIndexOf('/');
            if (slash >= 0) {
                lines.add("cd \"" + rel.substring(0, slash).replace('/', '\\') + "\"");
            }
            lines.add(launcher.getName());
        } else if (subdirMount) {
            lines.add("cd \"" + folder.getName() + "\"");
            lines.add("cls");
            lines.add("dir /w");
            lines.add("echo.");
            lines.add("echo Type the EXE or BAT name to run the game.");
        } else {
            lines.add("cls");
            lines.add("dir /w");
            lines.add("echo.");
            lines.add("echo Type the EXE or BAT name to run the game.");
        }
        return lines;
    }

    private String buildConf(List<String> autoexec, boolean joystick, String machine,
                             String cpuCore, String cycles, String mixer) {
        StringBuilder sb = new StringBuilder();
        /* Android: stay windowed (the GPU fill-path runs only in the windowed
         * branch and scales to the full native display). Hide the DOSBox menu
         * bar so games render edge-to-edge with no toolbar clipping. */
        sb.append("[sdl]\noutput=surface\nshowmenu=false\nshowdetails=false\n\n");
        sb.append("[render]\naspect=bilinear\n\n");
        // svga_s3 allows high-res SVGA modes (best resolution per game), but
        // some old setup/config programs need a title-specific machine type.
        // memsize stays below 64MB: DOS/4GW 1.97 (ICR2 and friends) breaks
        // when it sees 64MB+ of RAM ("Unable to find IndyCar.exe in ''").
        sb.append("[dosbox]\nmachine=").append(machine).append("\nmemsize=32\n\n");
        sb.append("[cpu]\ncore=").append(cpuCore)
            .append("\ncputype=pentium\ncycles=").append(cycles).append("\n\n");
        sb.append(mixer);
        // sbpro2 (8-bit DMA) plays digital SFX reliably in DOSBox where sb16's
        // 16-bit DMA often goes silent for DOS games.
        sb.append("[sblaster]\nsbtype=sbpro2\nsbbase=220\nirq=7\ndma=1\noplmode=auto\n\n");
        // 3dfx Voodoo via the CPU rasterizer — the GL backend needs desktop
        // OpenGL, which Android lacks; software is what the core supports here
        // (verified: Screamer 2's S2_3DFX.EXE renders correctly with this).
        sb.append("[voodoo]\nvoodoo_card=software\n\n");
        if (joystick) {
            // Joystick mode: the gamepad flows through SDL to the DOS gameport.
            // 2axis = the classic 2-axis/2-button stick DOS-era setups expect;
            // timed=false gives stable axis readings (easier calibration).
            sb.append("[joystick]\njoysticktype=2axis\ntimed=false\njoy1deadzone1=0.35\njoy1deadzone2=0.35\n\n");
        } else {
            // gamepad is mapped to keys in SDLActivity; no DOS joystick / no calibration prompt
            sb.append("[joystick]\njoysticktype=none\n\n");
        }
        sb.append("[autoexec]\n@echo off\n");
        for (String l : autoexec) sb.append(l).append("\n");
        return sb.toString();
    }

    private void writeAndLaunch(String conf, String gameName) {
        try {
            FileWriter w = new FileWriter(confFile, false);
            w.write(conf);
            w.close();
        } catch (Exception e) {
            Toast.makeText(this, "Failed to write config: " + e.getMessage(), Toast.LENGTH_LONG).show();
            return;
        }
        Intent i = new Intent(this, org.libsdl.app.SDLActivity.class);
        // The emulator runs in its own :emu process, so our static setters
        // don't reach it — it reloads the per-game keymap/joystick mode from
        // KeyMapStore using this name (trackpad + CD count come from the conf).
        i.putExtra(org.libsdl.app.SDLActivity.EXTRA_GAME_NAME, gameName);
        startActivity(i);
    }

    // ---- file helpers ----
    private List<File> findLaunchers(File dir, int depth) {
        List<File> bats = new ArrayList<>();
        List<File> exes = new ArrayList<>();
        scan(dir, depth, bats, exes);
        Collections.sort(bats, NAME);
        Collections.sort(exes, NAME);
        List<File> out = new ArrayList<>();
        out.addAll(bats);  // batch files first (usually the intended launcher)
        out.addAll(exes);
        return out;
    }

    private void scan(File dir, int depth, List<File> bats, List<File> exes) {
        File[] kids = dir.listFiles();
        if (kids == null) return;
        for (File f : kids) {
            if (f.isDirectory()) { if (depth > 0) scan(f, depth - 1, bats, exes); }
            else {
                String n = f.getName().toLowerCase();
                if (n.endsWith(".bat")) bats.add(f);
                else if (n.endsWith(".exe") || n.endsWith(".com")) exes.add(f);
            }
        }
    }

    private File findFirst(File dir, String[] exts, int depth) {
        File[] kids = dir.listFiles();
        if (kids == null) return null;
        for (File f : kids) {
            if (f.isDirectory()) { if (depth > 0) { File r = findFirst(f, exts, depth - 1); if (r != null) return r; } }
            else { String n = f.getName().toLowerCase(); for (String e : exts) if (n.endsWith(e)) return f; }
        }
        return null;
    }

    /** Walk dir (BFS, depth-limited) and return the first file whose lowercased
     *  name exactly matches `name`. Used by the Screamer 2 rule to find
     *  START65H.EXE specifically. */
    private File findNamed(File dir, String name, int depth) {
        String target = name.toLowerCase();
        File[] kids = dir.listFiles();
        if (kids == null) return null;
        for (File f : kids) {
            if (f.isDirectory()) { if (depth > 0) { File r = findNamed(f, target, depth - 1); if (r != null) return r; } }
            else if (f.getName().toLowerCase().equals(target)) return f;
        }
        return null;
    }

    private static final Comparator<File> NAME = new Comparator<File>() {
        @Override public int compare(File a, File b) { return a.getName().compareToIgnoreCase(b.getName()); }
    };

    private String relpath(File base, File f) {
        String b = base.getAbsolutePath();
        String p = f.getAbsolutePath();
        if (p.startsWith(b)) { p = p.substring(b.length()); if (p.startsWith("/")) p = p.substring(1); }
        return p;
    }

    private int dp(int v) { return (int) (v * getResources().getDisplayMetrics().density); }
}
