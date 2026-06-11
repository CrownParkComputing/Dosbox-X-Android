package com.dosboxx.app;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Minimal ISO9660 reader. Lists DOS programs (.exe/.bat/.com) inside a CD
 * image so {@link GameLauncherActivity} can auto-pick a launcher without the
 * user typing at the D: prompt, and can extract a whole image to a host
 * directory (used for "preinstalled" CDs that must run from a writable C:).
 *
 * Supports plain 2048-byte ISOs and raw .bin tracks (2352-byte Mode1/Mode2
 * and 2336-byte Mode2) referenced from a .cue. Plain 8.3 ISO9660 names only
 * (no Joliet) — that is what DOS-era CDs use.
 *
 * Windows executables (PE/NE) are excluded from the program list — they can't
 * run on this DOS build; {@link Scan#sawWindowsExe} lets the launcher tell the
 * user a CD is Windows-only (e.g. Road Rash 1996) instead of failing silently.
 */
final class IsoReader implements AutoCloseable {

    private static final int SECTOR_DATA = 2048;
    /** Cap on a single directory extent — guards against corrupt images. */
    private static final int MAX_DIR_BYTES = 4 * 1024 * 1024;

    /** Result of {@link #scan}: DOS-runnable programs + whether Windows exes exist. */
    static final class Scan {
        final List<String> programs = new ArrayList<>();   // "DIR\\RUN.EXE" style paths
        boolean sawWindowsExe = false;
    }

    private final RandomAccessFile raf;
    private int sectorSize;   // bytes per raw sector in the file
    private int dataOffset;   // offset of the 2048-byte payload within a sector
    private long rootLba, rootLen;

    /** List DOS programs on the image. Unreadable / non-9660 → empty result. */
    static Scan scan(File isoOrCue, int maxDepth) {
        Scan out = new Scan();
        File data = dataFileFor(isoOrCue);
        if (data == null) return out;
        IsoReader r = null;
        try {
            r = new IsoReader(data);
            r.walk(r.rootLba, r.rootLen, "", maxDepth, out, null);
        } catch (Exception e) {
            // caller drops to the D: prompt
        } finally {
            if (r != null) r.close();
        }
        return out;
    }

    /** Extract the entire image into destDir. Returns false on any error. */
    static boolean extractTo(File isoOrCue, File destDir) {
        File data = dataFileFor(isoOrCue);
        if (data == null) return false;
        IsoReader r = null;
        try {
            r = new IsoReader(data);
            r.walk(r.rootLba, r.rootLen, "", 8, null, destDir);
            return true;
        } catch (Exception e) {
            return false;
        } finally {
            if (r != null) r.close();
        }
    }

    private static File dataFileFor(File isoOrCue) {
        if (isoOrCue.getName().toLowerCase(Locale.US).endsWith(".cue")) {
            return binForCue(isoOrCue);
        }
        return isoOrCue;
    }

    /** Resolve the data file named by the cue sheet's first FILE line. */
    private static File binForCue(File cue) {
        try {
            BufferedReader br = new BufferedReader(new FileReader(cue));
            try {
                String line;
                while ((line = br.readLine()) != null) {
                    String t = line.trim();
                    if (!t.toUpperCase(Locale.US).startsWith("FILE")) continue;
                    int q1 = t.indexOf('"');
                    int q2 = t.lastIndexOf('"');
                    String name = (q1 >= 0 && q2 > q1)
                        ? t.substring(q1 + 1, q2)
                        : t.substring(4).trim().split("\\s+")[0];
                    File f = new File(name);
                    if (!f.isAbsolute()) f = new File(cue.getParentFile(), name);
                    return f.isFile() ? f : null;
                }
            } finally {
                br.close();
            }
        } catch (IOException ignored) { }
        return null;
    }

    private IsoReader(File image) throws IOException {
        raf = new RandomAccessFile(image, "r");
        // Find the Primary Volume Descriptor (logical sector 16) by trying the
        // common raw layouts: plain 2048, raw 2352 Mode1 (+16) / Mode2-XA (+24),
        // and headerless Mode2 2336 (+8).
        int[][] layouts = { {2048, 0}, {2352, 16}, {2352, 24}, {2336, 8} };
        byte[] pvd = new byte[SECTOR_DATA];
        for (int[] l : layouts) {
            sectorSize = l[0];
            dataOffset = l[1];
            try {
                readAt(16, 0, pvd, SECTOR_DATA);
            } catch (IOException e) {
                continue;
            }
            if ((pvd[0] & 0xff) == 1 && pvd[1] == 'C' && pvd[2] == 'D'
                    && pvd[3] == '0' && pvd[4] == '0' && pvd[5] == '1') {
                // Root directory record lives at offset 156 of the PVD.
                rootLba = u32le(pvd, 156 + 2);
                rootLen = u32le(pvd, 156 + 10);
                return;
            }
        }
        raf.close();
        throw new IOException("no ISO9660 volume descriptor");
    }

    /** Walk a directory extent: collect programs into scan and/or extract into destDir. */
    private void walk(long lba, long len, String prefix, int depth, Scan scan, File destDir)
            throws IOException {
        if (len <= 0 || len > MAX_DIR_BYTES) return;
        int sectors = (int) ((len + SECTOR_DATA - 1) / SECTOR_DATA);
        byte[] buf = new byte[SECTOR_DATA];
        for (int s = 0; s < sectors; s++) {
            readAt(lba + s, 0, buf, SECTOR_DATA);
            int pos = 0;
            while (pos < SECTOR_DATA) {
                int recLen = buf[pos] & 0xff;
                if (recLen == 0) break;             // rest of sector is padding
                if (pos + recLen > SECTOR_DATA) break;
                int nameLen = buf[pos + 32] & 0xff;
                boolean isDir = (buf[pos + 25] & 0x02) != 0;
                // Skip the self (0x00) and parent (0x01) entries.
                boolean special = nameLen == 1 && (buf[pos + 33] == 0 || buf[pos + 33] == 1);
                if (!special && nameLen > 0 && pos + 33 + nameLen <= SECTOR_DATA) {
                    String name = new String(buf, pos + 33, nameLen, "US-ASCII");
                    int semi = name.indexOf(';');   // strip the ";1" version suffix
                    if (semi >= 0) name = name.substring(0, semi);
                    if (name.endsWith(".")) name = name.substring(0, name.length() - 1);
                    long extLba = u32le(buf, pos + 2);
                    long extLen = u32le(buf, pos + 10);
                    if (isDir) {
                        if (depth > 0) {
                            File sub = destDir == null ? null : new File(destDir, name);
                            if (sub != null && !sub.exists() && !sub.mkdirs()) {
                                throw new IOException("mkdir failed: " + sub);
                            }
                            walk(extLba, extLen, prefix + name + "\\", depth - 1, scan, sub);
                        }
                    } else {
                        if (destDir != null) {
                            extractFile(extLba, extLen, new File(destDir, name));
                        }
                        if (scan != null) {
                            String lower = name.toLowerCase(Locale.US);
                            if (lower.endsWith(".bat") || lower.endsWith(".com")) {
                                scan.programs.add(prefix + name);
                            } else if (lower.endsWith(".exe")) {
                                if (isWindowsExe(extLba, extLen)) scan.sawWindowsExe = true;
                                else scan.programs.add(prefix + name);
                            }
                        }
                    }
                }
                pos += recLen;
            }
        }
    }

    /** True for PE (Win32) / NE (Win16) executables; plain MZ and LE/LX (DOS4GW) are DOS. */
    private boolean isWindowsExe(long lba, long size) {
        try {
            if (size < 0x40) return false;
            byte[] hdr = new byte[64];
            readAt(lba, 0, hdr, 64);
            if (hdr[0] != 'M' || hdr[1] != 'Z') return false;
            long e = u32le(hdr, 0x3c);
            if (e <= 0 || e + 2 > size) return false;
            byte[] sig = new byte[2];
            readAt(lba, e, sig, 2);
            return (sig[0] == 'P' && sig[1] == 'E') || (sig[0] == 'N' && sig[1] == 'E');
        } catch (IOException e) {
            return false;
        }
    }

    private void extractFile(long lba, long size, File out) throws IOException {
        byte[] buf = new byte[SECTOR_DATA];
        FileOutputStream fos = new FileOutputStream(out);
        try {
            long left = size;
            long sec = lba;
            while (left > 0) {
                int take = (int) Math.min(left, SECTOR_DATA);
                raf.seek(sec * (long) sectorSize + dataOffset);
                raf.readFully(buf, 0, take);
                fos.write(buf, 0, take);
                left -= take;
                sec++;
            }
        } finally {
            fos.close();
        }
    }

    /** Read n bytes starting at byte `off` within the extent beginning at `lba`. */
    private void readAt(long lba, long off, byte[] dst, int n) throws IOException {
        int got = 0;
        while (got < n) {
            long abs = off + got;
            long sec = lba + abs / SECTOR_DATA;
            int inSec = (int) (abs % SECTOR_DATA);
            raf.seek(sec * (long) sectorSize + dataOffset + inSec);
            int take = Math.min(n - got, SECTOR_DATA - inSec);
            raf.readFully(dst, got, take);
            got += take;
        }
    }

    private static long u32le(byte[] b, int off) {
        return (b[off] & 0xffL) | (b[off + 1] & 0xffL) << 8
             | (b[off + 2] & 0xffL) << 16 | (b[off + 3] & 0xffL) << 24;
    }

    @Override public void close() {
        try { raf.close(); } catch (IOException ignored) { }
    }
}
