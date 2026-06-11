package com.dosboxx.app;

import org.apache.commons.compress.archivers.sevenz.SevenZArchiveEntry;
import org.apache.commons.compress.archivers.sevenz.SevenZFile;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;
import java.util.Locale;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Extracts game archives for the in-app importer. Supports .zip (java.util.zip)
 * and .7z (Apache Commons Compress + XZ for LZMA2) — the two formats the
 * pre-packaged DOS/CD game sets ship as.
 *
 * Two install shapes:
 *  - DOS game: every file extracted into a game folder, with a redundant single
 *    top-level wrapper directory flattened away.
 *  - CD-ROM:   only the disc-image files (.iso / .cue / .bin / .img) extracted
 *    flat into the CD library.
 */
final class ArchiveExtractor {

    /** Progress callback (entry names as they are written); may be null. */
    interface Progress { void onEntry(String name); }

    static boolean isArchive(String name) {
        String n = name.toLowerCase(Locale.US);
        return n.endsWith(".zip") || n.endsWith(".7z");
    }

    private static boolean isDiscImage(String name) {
        String n = name.toLowerCase(Locale.US);
        return n.endsWith(".iso") || n.endsWith(".cue") || n.endsWith(".bin") || n.endsWith(".img");
    }

    private static boolean isDosProgram(String name) {
        String n = name.toLowerCase(Locale.US);
        return n.endsWith(".exe") || n.endsWith(".bat") || n.endsWith(".com");
    }

    /** What an archive looks like, so the importer can suggest a destination. */
    static final class Kind {
        boolean hasDiscImage;
        boolean hasDosProgram;
    }

    /** Peek at the entry names without extracting. */
    static Kind classify(File archive) {
        Kind k = new Kind();
        try {
            for (String name : listNames(archive)) {
                if (isDiscImage(name)) k.hasDiscImage = true;
                else if (isDosProgram(name)) k.hasDosProgram = true;
            }
        } catch (IOException ignored) { }
        return k;
    }

    private static List<String> listNames(File archive) throws IOException {
        List<String> out = new ArrayList<>();
        if (archive.getName().toLowerCase(Locale.US).endsWith(".7z")) {
            SevenZFile z = new SevenZFile(archive);
            try {
                SevenZArchiveEntry e;
                while ((e = z.getNextEntry()) != null) {
                    if (!e.isDirectory()) out.add(e.getName());
                }
            } finally {
                z.close();
            }
        } else {
            ZipFile z = new ZipFile(archive);
            try {
                Enumeration<? extends ZipEntry> en = z.entries();
                while (en.hasMoreElements()) {
                    ZipEntry e = en.nextElement();
                    if (!e.isDirectory()) out.add(e.getName());
                }
            } finally {
                z.close();
            }
        }
        return out;
    }

    /**
     * Extract a DOS game into destDir (a fresh game folder). A single common
     * top-level directory in the archive is stripped so files land directly in
     * destDir. Returns false on any error.
     */
    static boolean extractGame(File archive, File destDir, Progress p) {
        String strip = commonTopDir(archive);
        return extract(archive, destDir, false, strip, p);
    }

    /** Extract only the disc-image files (flat, basename only) into destDir. */
    static boolean extractDiscImages(File archive, File destDir, Progress p) {
        return extract(archive, destDir, true, null, p);
    }

    /** Single common top-level folder shared by every entry, or null. */
    private static String commonTopDir(File archive) {
        try {
            String top = null;
            for (String name : listNames(archive)) {
                String n = name.replace('\\', '/');
                int slash = n.indexOf('/');
                if (slash < 0) return null;            // a file at the root → no common dir
                String first = n.substring(0, slash);
                if (top == null) top = first;
                else if (!top.equals(first)) return null;
            }
            return top;
        } catch (IOException e) {
            return null;
        }
    }

    private static boolean extract(File archive, File destDir, boolean discOnly,
                                   String stripTop, Progress p) {
        if (!destDir.exists()) destDir.mkdirs();
        try {
            if (archive.getName().toLowerCase(Locale.US).endsWith(".7z")) {
                SevenZFile z = new SevenZFile(archive);
                try {
                    SevenZArchiveEntry e;
                    while ((e = z.getNextEntry()) != null) {
                        if (e.isDirectory()) continue;
                        File out = target(e.getName(), destDir, discOnly, stripTop);
                        if (out == null) continue;
                        if (p != null) p.onEntry(out.getName());
                        writeEntry(z, out);
                    }
                } finally {
                    z.close();
                }
            } else {
                ZipFile z = new ZipFile(archive);
                try {
                    Enumeration<? extends ZipEntry> en = z.entries();
                    while (en.hasMoreElements()) {
                        ZipEntry e = en.nextElement();
                        if (e.isDirectory()) continue;
                        File out = target(e.getName(), destDir, discOnly, stripTop);
                        if (out == null) continue;
                        if (p != null) p.onEntry(out.getName());
                        InputStream in = z.getInputStream(e);
                        try { writeStream(in, out); } finally { in.close(); }
                    }
                } finally {
                    z.close();
                }
            }
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    /** Resolve the output file for an entry, or null to skip it. */
    private static File target(String name, File destDir, boolean discOnly, String stripTop) {
        String n = name.replace('\\', '/');
        if (n.contains("..")) return null;
        if (discOnly) {
            if (!isDiscImage(n)) return null;
            int slash = n.lastIndexOf('/');
            return new File(destDir, slash >= 0 ? n.substring(slash + 1) : n);   // flat
        }
        if (stripTop != null && (n.equals(stripTop) || n.startsWith(stripTop + "/"))) {
            n = n.substring(stripTop.length());
            while (n.startsWith("/")) n = n.substring(1);
        }
        if (n.isEmpty()) return null;
        File out = new File(destDir, n);
        File parent = out.getParentFile();
        if (parent != null && !parent.exists()) parent.mkdirs();
        return out;
    }

    private static void writeEntry(SevenZFile z, File out) throws IOException {
        OutputStream o = new FileOutputStream(out);
        try {
            byte[] buf = new byte[1 << 16];
            int n;
            while ((n = z.read(buf)) > 0) o.write(buf, 0, n);
        } finally {
            o.close();
        }
    }

    private static void writeStream(InputStream in, File out) throws IOException {
        OutputStream o = new FileOutputStream(out);
        try {
            byte[] buf = new byte[1 << 16];
            int n;
            while ((n = in.read(buf)) > 0) o.write(buf, 0, n);
        } finally {
            o.close();
        }
    }

    private ArchiveExtractor() { }
}
