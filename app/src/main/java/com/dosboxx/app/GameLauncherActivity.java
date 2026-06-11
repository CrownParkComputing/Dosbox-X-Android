package com.dosboxx.app;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ListView;
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
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

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
    private File importDir;  // drop folder for .zip/.7z game archives
    private File confFile;
    private TextView pathLabel;
    private ListView list;
    private static final int TAB_GAMES = 0, TAB_IMPORT = 1;
    private Button[] tabBtns = new Button[2];
    private int tab = TAB_GAMES;
    private final List<Runnable> rowTap = new ArrayList<>();
    private final List<Runnable> rowHold = new ArrayList<>();
    private File mPendingBootDisc;   // the one CD to mount for the next Win98 boot (or null)

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

    /** Choose where the games / cds / import folders live. */
    private void storageWizard() {
        File base = AppConfig.baseDir(this);
        new AlertDialog.Builder(this)
            .setTitle("Storage location")
            .setMessage("Games, CDs and imports are stored under:\n" + base.getAbsolutePath()
                + "\n\nKeep them in the app folder, or choose any folder on your device "
                + "(easier to reach from a file manager).")
            .setPositiveButton("Choose a folder…", (d, w) -> chooseFolder())
            .setNeutralButton("Use app folder", (d, w) -> applyNewBase(AppConfig.defaultBase(this)))
            .setNegativeButton("Close", null)
            .show();
    }

    private void chooseFolder() {
        if (android.os.Build.VERSION.SDK_INT >= 30 && !android.os.Environment.isExternalStorageManager()) {
            new AlertDialog.Builder(this)
                .setTitle("Permission needed")
                .setMessage("To store games outside the app folder, DOSBox-X needs \"All files access\". "
                    + "Grant it on the next screen, then tap Storage… again.")
                .setPositiveButton("Open settings", (d, w) -> {
                    try {
                        startActivity(new android.content.Intent(
                            android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                            android.net.Uri.parse("package:" + getPackageName())));
                    } catch (Exception e) {
                        startActivity(new android.content.Intent(
                            android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION));
                    }
                })
                .setNegativeButton("Cancel", null)
                .show();
            return;
        }
        File start = android.os.Environment.getExternalStorageDirectory();   // /storage/emulated/0
        pickDirectory(start, dir -> applyNewBase(new File(dir, "DOSBox-X")));
    }

    /** Simple directory browser yielding a real filesystem path. */
    private void pickDirectory(final File dir, final java.util.function.Consumer<File> onPick) {
        File[] kids = dir.listFiles();
        final List<File> subs = new ArrayList<>();
        if (kids != null) {
            Arrays.sort(kids, NAME);
            for (File f : kids) if (f.isDirectory() && !f.getName().startsWith(".")) subs.add(f);
        }
        final File parent = dir.getParentFile();
        final List<String> items = new ArrayList<>();
        if (parent != null) items.add("⬆  ..");
        for (File s : subs) items.add("📁  " + s.getName());
        new AlertDialog.Builder(this)
            .setTitle(dir.getAbsolutePath())
            .setItems(items.toArray(new String[0]), (d, w) -> {
                if (parent != null && w == 0) pickDirectory(parent, onPick);
                else pickDirectory(subs.get(parent != null ? w - 1 : w), onPick);
            })
            .setPositiveButton("Use this folder", (d, w) -> onPick.accept(dir))
            .setNegativeButton("Cancel", null)
            .show();
    }

    private void applyNewBase(final File newBase) {
        final File oldBase = AppConfig.baseDir(this);
        if (newBase.getAbsolutePath().equals(oldBase.getAbsolutePath())) {
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

        // Games | Import tabs
        LinearLayout tabs = new LinearLayout(this);
        tabs.setOrientation(LinearLayout.HORIZONTAL);
        String[] tabLabels = {"GAMES", "IMPORT"};
        for (int i = 0; i < tabLabels.length; i++) {
            final int which = i;
            Button b = new Button(this);
            b.setAllCaps(false);
            b.setTextSize(13);
            b.setText(tabLabels[i]);
            b.setOnClickListener(v -> { tab = which; rescan(); });
            tabBtns[i] = b;
            tabs.addView(b, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        }
        root.addView(tabs);

        pathLabel = new TextView(this);
        pathLabel.setTextColor(0xFF80A0B0);
        pathLabel.setTextSize(11);
        pathLabel.setPadding(0, dp(2), 0, dp(8));
        root.addView(pathLabel);

        list = new ListView(this);
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
            AppConfig.markSetupDone(this);
            storageWizard();
        }
    }

    private void rescan() {
        rowTap.clear();
        rowHold.clear();
        List<String> labels = new ArrayList<>();
        for (int i = 0; i < tabBtns.length; i++) {
            tabBtns[i].setBackgroundColor(tab == i ? 0xFF3D6B8E : 0xFF2A3138);
            tabBtns[i].setTextColor(0xFFFFFFFF);
        }
        if (tab == TAB_IMPORT) buildImportRows(labels);
        else                   buildGamesList(labels);
        ArrayAdapter<String> ad = new ArrayAdapter<String>(this,
                android.R.layout.simple_list_item_1, labels) {
            @Override public View getView(int pos, View cv, ViewGroup parent) {
                View v = super.getView(pos, cv, parent);
                ((TextView) v).setTextColor(0xFFE0E0E0);
                ((TextView) v).setTextSize(17);
                return v;
            }
        };
        list.setAdapter(ad);
        list.setOnItemClickListener((parent, view, position, id) -> {
            if (position < rowTap.size() && rowTap.get(position) != null) rowTap.get(position).run();
        });
        list.setOnItemLongClickListener((parent, view, position, id) -> {
            if (position < rowHold.size() && rowHold.get(position) != null) {
                rowHold.get(position).run();
                return true;
            }
            return false;
        });
    }

    /** MS-DOS tab: game folders (without an OS boot image) + disk images.
     *  CD-library discs are listed too — a disc is directly playable as a
     *  DOS CD game here AND insertable into Windows from the other tab. */
    /** Unified games list: every game once, tagged [DOS]/[WIN98] and [CD]/[rip].
     *  Tap to play; long-press to change type / CD / delete. */
    private void buildGamesList(List<String> labels) {
        pathLabel.setText("Tap to play · long-press to set DOS/Windows 98, CD/rip, or delete.\n"
            + "[CD] = needs its disc inserted (slower Win98 disk) · [rip] = runs without the CD.");
        final File boot = findBootFolder();

        // Windows 98 desktop (boot the OS with no CD — full disk speed).
        if (boot != null) {
            labels.add("▶  Windows 98 desktop");
            rowTap.add(() -> bootWin98(boot, null));
            rowHold.add(() -> onLongPick(boot));
        }

        // All game folders (minus the Win98 OS) and disc images, each once.
        List<File> entries = new ArrayList<>();
        File[] kids = gamesDir.listFiles();
        if (kids != null) {
            Arrays.sort(kids, NAME);
            for (File f : kids) {
                if (f.getName().startsWith(".")) continue;       // .c = per-ISO C: drives
                if (f.isDirectory()) {
                    if (findBootImage(f) != null) continue;       // the Win98 OS (desktop above)
                    entries.add(f);
                } else {
                    String n = f.getName().toLowerCase();
                    if (n.endsWith(".img") || n.endsWith(".iso") || n.endsWith(".cue")) entries.add(f);
                }
            }
        }
        File[] discs = cdsDir.listFiles();
        if (discs != null) {
            Arrays.sort(discs, NAME);
            for (File f : discs) {
                if (f.isDirectory()) continue;
                String n = f.getName().toLowerCase();
                if (n.endsWith(".iso") || n.endsWith(".cue")) entries.add(f);
            }
        }
        Collections.sort(entries, new Comparator<File>() {
            @Override public int compare(File a, File b) {
                return gameName(a).compareToIgnoreCase(gameName(b));
            }
        });
        for (File e : entries) addGameRow(labels, e, boot);

        // Games installed on the Windows D: drive that aren't copied out yet.
        List<File> disks = new ArrayList<>();
        collectGamesDisks(gamesDir, 2, disks);
        for (File disk : disks) {
            final File gd = disk;
            for (String dn : Fat32Reader.listTopDirs(disk)) {
                if (new File(gamesDir, dn).exists()) continue;
                final String name = dn;
                labels.add("💾 " + name + "   [WIN98] [on D:]");
                rowTap.add(() -> bootWin98(boot, null));        // it's on D:, boot Windows
                rowHold.add(() -> copyFromGamesDisk(gd, name, false));   // or copy to DOS
            }
        }
        if (labels.isEmpty()) {
            labels.add("(no games yet — add some on the Import tab)");
            rowTap.add(null);
            rowHold.add(null);
        }
    }

    /** Game display name (folder name, or disc basename). */
    private static String gameName(File f) {
        return f.isDirectory() ? f.getName() : discName(f);
    }

    /** Add one game row with its [DOS]/[WIN98] + [CD]/[rip] tags. */
    private void addGameRow(List<String> labels, final File entry, final File boot) {
        final String name = gameName(entry);
        final boolean isDisc = !entry.isDirectory()
            && (entry.getName().toLowerCase().endsWith(".iso") || entry.getName().toLowerCase().endsWith(".cue"));
        // auto defaults: discs -> DOS if they hold DOS programs else WIN98; folders/.img -> DOS
        String autoPlat = (isDisc && !isDosDisc(entry)) ? GameMeta.WIN98 : GameMeta.DOS;
        final String plat = GameMeta.platform(this, name, autoPlat);
        final boolean needsCd = GameMeta.needsCd(this, name, plat.equals(GameMeta.WIN98));
        String tag = "   [" + (plat.equals(GameMeta.WIN98) ? "WIN98" : "DOS") + "] ["
            + (needsCd ? "CD" : "rip") + "]";
        labels.add((entry.isDirectory() ? "📁 " : "💿 ") + name + tag);
        rowTap.add(() -> {
            if (plat.equals(GameMeta.WIN98)) {
                bootWin98(boot, needsCd && isDisc ? entry : null);
            } else {
                onPick(entry);
            }
        });
        rowHold.add(() -> onLongPick(entry));
    }

    /** The folder holding the bootable Windows image, or null. */
    private File findBootFolder() {
        File[] kids = gamesDir.listFiles();
        if (kids != null) {
            Arrays.sort(kids, NAME);
            for (File f : kids) {
                if (f.isDirectory() && !f.getName().startsWith(".") && findBootImage(f) != null) return f;
            }
        }
        return null;
    }

    /** Boot Windows 98 with exactly `disc` in the drive (or none, for full disk
     *  speed). The disc stays in the CD library; it's mounted by absolute path. */
    private void bootWin98(File boot, File disc) {
        if (boot == null) {
            Toast.makeText(this, "No Windows 98 image found in the games folder.", Toast.LENGTH_LONG).show();
            return;
        }
        mPendingBootDisc = disc;
        onPick(boot);
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
                deleteContents(folder); folder.delete();
                File cDir = new File(gamesDir, ".c/" + KeyMapStore.safeName(folder.getName()));
                if (cDir.isDirectory()) { deleteContents(cDir); cDir.delete(); }
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

    /** Import tab: lists .zip/.7z archives dropped in import/. Tapping one
     *  installs it — as a DOS game (-> games/<name>/) or a CD-ROM image
     *  (-> the CD library), auto-detected from the archive contents. */
    private void buildImportRows(List<String> labels) {
        pathLabel.setText("Drop game archives (.zip / .7z) in:\n" + importDir.getAbsolutePath()
            + "\nTap one to install it as a DOS game or a CD.");
        File[] kids = importDir.listFiles();
        List<File> archives = new ArrayList<>();
        if (kids != null) {
            Arrays.sort(kids, NAME);
            for (File f : kids) if (!f.isDirectory() && ArchiveExtractor.isArchive(f.getName())) archives.add(f);
        }
        if (archives.isEmpty()) {
            labels.add("(no .zip/.7z archives in the import folder)");
            rowTap.add(null);
            rowHold.add(null);
            return;
        }
        for (File a : archives) {
            final File archive = a;
            long mb = a.length() / (1024 * 1024);
            labels.add("📦 " + a.getName() + "  (" + mb + " MB)");
            rowTap.add(() -> importDialog(archive));
            rowHold.add(() -> confirmDeleteArchive(archive));
        }
    }

    /** Ask how to install an archive (DOS game vs CD), defaulting to the
     *  auto-detected kind, then extract on a background thread. */
    private void importDialog(final File archive) {
        new Thread(() -> {
            final ArchiveExtractor.Kind kind = ArchiveExtractor.classify(archive);
            runOnUiThread(() -> {
                // Order the choices so the detected kind is the first/default.
                final boolean cdFirst = kind.hasDiscImage || !kind.hasDosProgram;
                final String cd = "CD-ROM image → CD library";
                final String dos = "DOS game → games folder";
                final String[] items = cdFirst ? new String[]{cd, dos} : new String[]{dos, cd};
                new AlertDialog.Builder(this)
                    .setTitle("Install " + archive.getName())
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
                String name = archive.getName().replaceFirst("(?i)\\.(zip|7z)$", "");
                File gameDir = new File(gamesDir, name);
                ok = ArchiveExtractor.extractGame(archive, gameDir, progress);
                dest = "MS-DOS games";
            }
            final int fWinVer = winVer;
            runOnUiThread(() -> {
                dlg.dismiss();
                if (ok) {
                    Toast.makeText(this, archive.getName() + " installed to " + dest + ".", Toast.LENGTH_LONG).show();
                    tab = TAB_GAMES;
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

    /** First OS-sized .img in the folder, or null. */
    private File findBootImage(File folder) {
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
     * sees it, then `boot c:`.
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
        File floppy = findImgBySize(folder, 2, 1, FLOPPY_MAX);
        if (floppy != null) {
            lines.add("imgmount 0 \"" + floppy.getAbsolutePath() + "\" -t floppy -fs none");
        }
        long cylinders = bootImg.length() / (512L * 63 * 255);
        lines.add("imgmount 2 \"" + bootImg.getAbsolutePath()
            + "\" -size 512,63,255," + cylinders + " -t hdd -fs none");
        // Data disks ("Create games disk..."): BIOS drives 3+ — the guest
        // letters them D: etc right after the system C:. They take the IDE
        // primary-slave slot, which is why the CDs sit on the secondary.
        List<File> disks = new ArrayList<>();
        collectGamesDisks(folder, 2, disks);
        int driveNo = 3;
        for (File gd : disks) {
            long cyl = gd.length() / (512L * 63 * 255);
            lines.add("imgmount " + driveNo + " \"" + gd.getAbsolutePath()
                + "\" -size 512,63,255," + cyl + " -t hdd -fs none");
            driveNo++;
        }
        // Exactly one CD this boot (or none) — mounted by absolute path from
        // the library, IDE secondary master. The guest reads it via the
        // injected real-mode chain (CD1.SYS scans channels; MSCDEX pins E:).
        // No CD = the disk stays in fast 32-bit mode; a CD forces compat mode.
        File disc = mPendingBootDisc;
        mPendingBootDisc = null;
        if (disc != null && disc.isFile()) {
            lines.add("imgmount d \"" + disc.getAbsolutePath() + "\" -t iso -ide 2m");
        }
        lines.add("boot c:");

        Map<String, Integer> map = KeyMapStore.load(this, folder.getName());
        org.libsdl.app.SDLActivity.setKeyMap(map);
        boolean joy = KeyMapStore.loadJoystickMode(this, folder.getName());
        org.libsdl.app.SDLActivity.setJoystickMode(joy);
        // Windows draws its own cursor — touch acts as a trackpad instead.
        org.libsdl.app.SDLActivity.setTrackpadMouse(true);
        writeAndLaunch(buildBootConf(lines, joy), folder.getName());
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
        sb.append("[dosbox]\nmachine=svga_s3\nmemsize=512\nvmemsize=4\n\n");
        sb.append("[cpu]\ncore=dynamic\ncputype=pentium\ncycles=max\n\n");
        sb.append("[mixer]\nnosound=false\nrate=44100\nblocksize=1024\nprebuffer=25\n\n");
        sb.append("[sblaster]\nsbtype=sb16\nsbbase=220\nirq=7\ndma=1\nhdma=5\noplmode=auto\n\n");
        sb.append("[dos]\nxms=false\nems=false\numb=false\n\n");
        // int13fakeio/int13fakev86io only help once the guest reaches 32-bit
        // protected-mode disk access. While the real-mode CD driver (cd1.sys)
        // forces MS-DOS Compatibility Mode, those flags just add v86 I/O-trap
        // overhead to every real-mode INT 13h call — i.e. they make the disk
        // slower. So leave them off until the guest's IDE controller is bound
        // to a protected-mode driver (and cd1.sys removed).
        sb.append("[ide, primary]\nenable=true\n\n[ide, secondary]\nenable=true\n\n");
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
        lines.add("imgmount d \"" + iso.getAbsolutePath() + "\" -t iso");
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
        org.libsdl.app.SDLActivity.setTrackpadMouse(false);   // DOS games take taps directly
        writeAndLaunch(buildConf(lines, joy, cyclesFor(gameName, programName),
            mixerFor(programName)), gameName);
    }

    /**
     * CPU cycles per game/program. Speed-sensitive DOS setup utilities crash
     * at cycles=max (Screamer's SETUP.EXE is the canonical case), and some
     * games need a fixed CPU speed for sane game speed and timing.
     */
    private static String cyclesFor(String gameName, String programName) {
        String p = programName == null ? "" : programName.toLowerCase();
        if (p.startsWith("setup") || p.startsWith("install") || p.startsWith("dosinst")) {
            return "fixed 20000";
        }
        // 3dfx build: the emulated Voodoo renders inline on the emulation
        // thread, so lower CPU cycles leave host headroom for the rasterizer
        // (150000 + Voodoo = audio underruns / jitter on the device).
        if (p.startsWith("s2_3dfx")) return "fixed 100000";
        if (gameName.toLowerCase().contains("screamer")) return "fixed 150000";
        return "max";
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
        final boolean joy = KeyMapStore.loadJoystickMode(this, gameName);
        final String joyItem = "Joystick mode: " + (joy ? "ON" : "OFF");
        final boolean isFolder = entry.isDirectory();
        final File folder = entry;
        final String lower = gameName.toLowerCase();
        final boolean isCdImage = !isFolder && (lower.endsWith(".iso") || lower.endsWith(".cue"));
        // Folders with a setup/install utility get a dedicated entry — it runs
        // at low fixed cycles (these tools crash at cycles=max) and is how
        // games like Screamer switch their own controls to joystick.
        final File setup = isFolder ? findSetup(folder) : null;
        final boolean bootable = isFolder && findBootImage(folder) != null;
        List<String> menu = new ArrayList<>();
        if ((isFolder && !bootable) || isCdImage) menu.add("Pick program...");
        if (isCdImage) menu.add("Install to C: (copy the CD)...");
        if (isCdImage && isDosDisc(entry)) menu.add("Copy to MS-DOS games...");
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
            if (disks.isEmpty()) menu.add("Create games disk (D:)...");
            else menu.add("Copy game from D: to MS-DOS...");
        }
        // Per-game type (DOS / Windows 98) + CD (rip / needs CD) assignment.
        final String metaName = gameName(entry);
        final String autoPlat = (isCdImage && !isDosDisc(entry)) ? GameMeta.WIN98 : GameMeta.DOS;
        final String plat = GameMeta.platform(this, metaName, autoPlat);
        final boolean needsCd = GameMeta.needsCd(this, metaName, plat.equals(GameMeta.WIN98));
        if (!bootable) {
            menu.add(plat.equals(GameMeta.WIN98) ? "Set type → MS-DOS" : "Set type → Windows 98");
            menu.add(needsCd ? "CD: needs disc (tap = mark as rip)" : "CD: rip / no disc (tap = needs CD)");
        }
        // Gamepad→key mapping is meaningless for a booted Windows guest
        // (it gets the trackpad mouse + the real gameport joystick instead).
        if (!bootable) menu.add("Edit controls...");
        menu.add(joyItem);
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
                else if (it.startsWith("Copy to MS-DOS games")) copyIsoToDosGames(entry);
                else if (it.startsWith("Run setup"))    launchGame(folder, setup);
                else if (it.startsWith("Insert CD"))    insertCdDialog(folder);
                else if (it.startsWith("Eject CD"))     ejectCdDialog(folder);
                else if (it.startsWith("Create games disk")) createGamesDiskDialog(folder);
                else if (it.startsWith("Copy game from D:")) copyFromGamesDiskDialog(folder);
                else if (it.startsWith("Set type")) {
                    String np = plat.equals(GameMeta.WIN98) ? GameMeta.DOS : GameMeta.WIN98;
                    GameMeta.setPlatform(this, metaName, np);
                    GameMeta.setNeedsCd(this, metaName, np.equals(GameMeta.WIN98));
                    rescan();
                }
                else if (it.startsWith("CD:")) { GameMeta.setNeedsCd(this, metaName, !needsCd); rescan(); }
                else if (it.startsWith("Edit controls")) openKeymapEditor(gameName);
                else if (it.startsWith("Delete game"))   confirmDeleteGame(folder);
                else if (it.startsWith("Delete disc"))   confirmDeleteDisc(entry);
                else                                     toggleJoystickMode(gameName, !joy);
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
                    Toast.makeText(this, name + " added to MS-DOS games — you can delete the disc now.",
                        Toast.LENGTH_LONG).show();
                    tab = TAB_GAMES;
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
     *  images (or .zip archives, which get pressed onto an ISO) and put one
     *  into the game's changer folder. */
    private void insertCdDialog(File folder) {
        List<File> cds = new ArrayList<>();
        for (File dir : new File[]{cdsDir, gamesDir}) {
            File[] kids = dir.listFiles();
            if (kids == null) continue;
            Arrays.sort(kids, NAME);
            for (File f : kids) {
                if (f.isDirectory() || f.equals(folder)) continue;
                String n = f.getName().toLowerCase();
                if (n.endsWith(".iso") || n.endsWith(".cue") || n.endsWith(".zip")) cds.add(f);
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
                if (pick.getName().toLowerCase().endsWith(".zip")) {
                    insertZipAsCd(pick, folder);
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

    /** Put a .zip into the changer. If the zip CONTAINS a disc image
     *  (.iso, or .cue + its data file, or a raw .img rip), that image is
     *  extracted as-is; otherwise the zip's files are pressed onto a new
     *  ISO (the only drive form a booted Win9x guest can mount). */
    private void insertZipAsCd(final File zip, final File folder) {
        final AlertDialog dlg = new AlertDialog.Builder(this)
            .setTitle(zip.getName())
            .setMessage("Importing the CD from the ZIP…")
            .setCancelable(false)
            .show();
        new Thread(() -> {
            final String inserted = importZipCd(zip, folder);
            runOnUiThread(() -> {
                dlg.dismiss();
                if (inserted != null) {
                    markFirstCd(folder, inserted);
                    Toast.makeText(this,
                        inserted + " is in the drive — launch the game to use it.",
                        Toast.LENGTH_LONG).show();
                    rescan();
                } else {
                    Toast.makeText(this, "Couldn't import a CD from " + zip.getName() + ".",
                        Toast.LENGTH_LONG).show();
                }
            });
        }).start();
    }

    /** Worker for {@link #insertZipAsCd}: returns the inserted disc's name, or null. */
    private String importZipCd(File zip, File folder) {
        try {
            ZipFile zf = new ZipFile(zip);
            try {
                ZipEntry cue = null, iso = null, img = null;
                for (Enumeration<? extends ZipEntry> en = zf.entries(); en.hasMoreElements(); ) {
                    ZipEntry e = en.nextElement();
                    if (e.isDirectory()) continue;
                    String n = e.getName().toLowerCase(Locale.US);
                    if (n.endsWith(".cue") && cue == null) cue = e;
                    else if (n.endsWith(".iso") && iso == null) iso = e;
                    else if ((n.endsWith(".img") || n.endsWith(".bin")) && img == null) img = e;
                }
                if (cue != null) {
                    File cueOut = extractZipEntry(zf, cue, folder);
                    String dataName = cueDataName(cueOut);
                    ZipEntry data = dataName != null ? findZipEntryByName(zf, dataName) : null;
                    if (data == null) { cueOut.delete(); return null; }   // cue without its data file
                    extractZipEntry(zf, data, folder);
                    return cueOut.getName();
                }
                if (iso != null) {
                    return extractZipEntry(zf, iso, folder).getName();
                }
                if (img != null) {
                    // orphan raw rip — write a cue for it (sector size sniffed)
                    File imgOut = extractZipEntry(zf, img, folder);
                    File cueOut = writeCueFor(imgOut);
                    return cueOut != null ? cueOut.getName() : null;
                }
            } finally {
                zf.close();
            }
        } catch (Exception e) {
            return null;
        }
        // no disc image inside — press the zip's files onto a new ISO
        String n = zip.getName();
        File out = new File(folder, n.substring(0, n.length() - 4) + ".iso");
        return ZipToIso.convert(zip, out) ? out.getName() : null;
    }

    /** Extract one zip entry into destDir (basename only), overwriting. */
    private static File extractZipEntry(ZipFile zf, ZipEntry e, File destDir) throws IOException {
        String name = e.getName();
        int slash = name.lastIndexOf('/');
        File out = new File(destDir, slash >= 0 ? name.substring(slash + 1) : name);
        InputStream in = zf.getInputStream(e);
        try {
            FileOutputStream fo = new FileOutputStream(out);
            try {
                byte[] buf = new byte[65536];
                int r;
                while ((r = in.read(buf)) > 0) fo.write(buf, 0, r);
            } finally {
                fo.close();
            }
        } finally {
            in.close();
        }
        return out;
    }

    /** Find a zip entry whose base name matches (case-insensitive). */
    private static ZipEntry findZipEntryByName(ZipFile zf, String baseName) {
        for (Enumeration<? extends ZipEntry> en = zf.entries(); en.hasMoreElements(); ) {
            ZipEntry e = en.nextElement();
            if (e.isDirectory()) continue;
            String n = e.getName();
            int slash = n.lastIndexOf('/');
            if (n.substring(slash + 1).equalsIgnoreCase(baseName)) return e;
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
                if (n.endsWith(".iso") || n.endsWith(".cue")) out.add(f);
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
                            tab = TAB_GAMES;
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
            } else if (Fat32Disk.isGamesDisk(f.getName())) {
                out.add(f);
            }
        }
    }

    /** "Create games disk (D:)..." — a formatted FAT32 image the guest OS
     *  mounts as D: for installing games (the CD lives at E:). */
    private void createGamesDiskDialog(final File folder) {
        final String[] sizes = {"2 GB", "4 GB", "8 GB"};
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

    private void toggleJoystickMode(String gameName, boolean on) {
        KeyMapStore.saveJoystickMode(this, gameName, on);
        Toast.makeText(this, on
            ? "Joystick mode ON — the gamepad reaches the game as a real DOS joystick; the ⌨ button shows a full keyboard."
            : "Joystick mode OFF — gamepad buttons are mapped to keyboard keys again.",
            Toast.LENGTH_LONG).show();
    }

    /** Resolve the launcher for a game folder per the auto-pick rules. */
    private File autoPickLauncher(File folder) {
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

    private void openKeymapEditor(String gameName) {
        Intent i = new Intent(this, KeyMapEditorActivity.class);
        i.putExtra(KeyMapEditorActivity.EXTRA_GAME_NAME, gameName);
        startActivity(i);
    }

    /** Write the conf for (folder, launcher) and start SDLActivity with the saved keymap. */
    private void launchGame(File folder, File launcher) {
        List<File> cds = new ArrayList<>();
        collectCds(folder, 3, cds);
        setKeymapAndLaunch(folder.getName(), mountLines(folder, launcher, cds),
            launcher != null ? launcher.getName() : null);
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
        // the CD⇄ button (Ctrl+F4) cycles through, like the boot-image flow
        if (!cds.isEmpty()) {
            StringBuilder im = new StringBuilder("imgmount d");
            for (File cd : cds) im.append(" \"").append(cd.getAbsolutePath()).append("\"");
            im.append(" -t iso");
            lines.add(im.toString());
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
        }
        return lines;
    }

    private String buildConf(List<String> autoexec, boolean joystick, String cycles, String mixer) {
        StringBuilder sb = new StringBuilder();
        /* Android: stay windowed (the GPU fill-path runs only in the windowed
         * branch and scales to the full native display). Hide the DOSBox menu
         * bar so games render edge-to-edge with no toolbar clipping. */
        sb.append("[sdl]\noutput=surface\nshowmenu=false\nshowdetails=false\n\n");
        sb.append("[render]\naspect=bilinear\n\n");
        // svga_s3 allows high-res SVGA modes (best resolution per game).
        // memsize stays below 64MB: DOS/4GW 1.97 (ICR2 and friends) breaks
        // when it sees 64MB+ of RAM ("Unable to find IndyCar.exe in ''").
        sb.append("[dosbox]\nmachine=svga_s3\nmemsize=32\n\n");
        sb.append("[cpu]\ncore=dynamic\ncputype=pentium\ncycles=").append(cycles).append("\n\n");
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
