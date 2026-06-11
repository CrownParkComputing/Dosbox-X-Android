package com.dosboxx.app;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.util.ArrayList;
import java.util.List;

/**
 * Minimal read side for the MBR + FAT32 images {@link Fat32Disk} creates (the
 * Win9x "games disk", D:). Lets the launcher list the games a user installed
 * inside Windows and copy a folder out onto the host as an MS-DOS game.
 *
 * Handles VFAT long filenames; enough of FAT32 for directory walking and file
 * extraction. Not a general FAT driver (no writing, no FAT12/16).
 */
final class Fat32Reader implements AutoCloseable {

    private final RandomAccessFile raf;
    private final long partStart;     // first sector of the FAT32 partition
    private final int bytesPerSector;
    private final int secPerClus;
    private final long fatStart;       // first FAT sector (absolute)
    private final long dataStart;      // first data sector (absolute)
    private final long rootCluster;

    private Fat32Reader(File img) throws IOException {
        raf = new RandomAccessFile(img, "r");
        byte[] mbr = readSector(0, 512);
        long ps = -1;
        for (int i = 0; i < 4; i++) {                 // 4 partition entries at 446
            int e = 446 + i * 16;
            int type = mbr[e + 4] & 0xff;
            if (type == 0x0B || type == 0x0C) { ps = u32(mbr, e + 8); break; }
        }
        if (ps < 0) ps = 63;                          // fall back to the cylinder-aligned default
        partStart = ps;
        byte[] bpb = readSector(partStart, 512);
        bytesPerSector = u16(bpb, 11);
        secPerClus = bpb[13] & 0xff;
        int reserved = u16(bpb, 14);
        int numFats = bpb[16] & 0xff;
        long fatSize = u32(bpb, 36);
        rootCluster = u32(bpb, 44);
        if (bytesPerSector <= 0 || secPerClus <= 0) throw new IOException("bad FAT32 BPB");
        fatStart = partStart + reserved;
        dataStart = partStart + reserved + (long) numFats * fatSize;
    }

    /** One file or directory in a FAT directory. */
    static final class Entry {
        final String name;
        final boolean dir;
        final long firstCluster;
        final long size;
        Entry(String name, boolean dir, long firstCluster, long size) {
            this.name = name; this.dir = dir; this.firstCluster = firstCluster; this.size = size;
        }
    }

    /** Top-level directory names in the image (the games installed on D:). */
    static List<String> listTopDirs(File img) {
        List<String> out = new ArrayList<>();
        try {
            Fat32Reader r = new Fat32Reader(img);
            try {
                for (Entry e : r.readDir(r.rootCluster)) if (e.dir) out.add(e.name);
            } finally {
                r.close();
            }
        } catch (IOException ignored) { }
        return out;
    }

    /** Copy the named top-level directory out of the image into destDir. */
    static boolean extractTopDir(File img, String dirName, File destDir) {
        try {
            Fat32Reader r = new Fat32Reader(img);
            try {
                for (Entry e : r.readDir(r.rootCluster)) {
                    if (e.dir && e.name.equalsIgnoreCase(dirName)) {
                        if (!destDir.exists() && !destDir.mkdirs()) return false;
                        r.copyDir(e.firstCluster, destDir);
                        return true;
                    }
                }
            } finally {
                r.close();
            }
        } catch (IOException e) {
            return false;
        }
        return false;
    }

    private void copyDir(long cluster, File destDir) throws IOException {
        for (Entry e : readDir(cluster)) {
            if (e.name.equals(".") || e.name.equals("..")) continue;
            File out = new File(destDir, e.name);
            if (e.dir) {
                if (out.mkdirs() || out.isDirectory()) copyDir(e.firstCluster, out);
            } else {
                writeFile(e.firstCluster, e.size, out);
            }
        }
    }

    // ---- directory parsing (with VFAT long names) ----

    private List<Entry> readDir(long startCluster) throws IOException {
        List<Entry> out = new ArrayList<>();
        byte[] data = readClusterChain(startCluster, 0);   // whole directory
        StringBuilder lfn = new StringBuilder();
        for (int off = 0; off + 32 <= data.length; off += 32) {
            int first = data[off] & 0xff;
            if (first == 0x00) break;                    // no more entries
            if (first == 0xE5) { lfn.setLength(0); continue; }   // deleted
            int attr = data[off + 11] & 0xff;
            if (attr == 0x0F) {                          // LFN fragment
                lfn.insert(0, lfnChars(data, off));
                continue;
            }
            if ((attr & 0x08) != 0) { lfn.setLength(0); continue; }   // volume label
            String name = lfn.length() > 0 ? trimLfn(lfn.toString()) : shortName(data, off);
            lfn.setLength(0);
            long clus = ((long) u16(data, off + 20) << 16) | u16(data, off + 26);
            long size = u32(data, off + 28);
            out.add(new Entry(name, (attr & 0x10) != 0, clus, size));
        }
        return out;
    }

    private static String lfnChars(byte[] d, int off) {
        StringBuilder s = new StringBuilder();
        int[] idx = {1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30};
        for (int i : idx) {
            int c = (d[off + i] & 0xff) | ((d[off + i + 1] & 0xff) << 8);
            if (c == 0x0000 || c == 0xFFFF) break;
            s.append((char) c);
        }
        return s.toString();
    }

    private static String trimLfn(String s) {
        int end = s.length();
        while (end > 0 && (s.charAt(end - 1) == '￿' || s.charAt(end - 1) == 0)) end--;
        return s.substring(0, end);
    }

    /** 8.3 short name → "NAME.EXT". */
    private static String shortName(byte[] d, int off) {
        StringBuilder base = new StringBuilder();
        for (int i = 0; i < 8; i++) { char c = (char) (d[off + i] & 0xff); if (c != ' ') base.append(c); }
        StringBuilder ext = new StringBuilder();
        for (int i = 8; i < 11; i++) { char c = (char) (d[off + i] & 0xff); if (c != ' ') ext.append(c); }
        return ext.length() > 0 ? base + "." + ext : base.toString();
    }

    // ---- cluster I/O ----

    /** Read a cluster chain. If maxBytes>0 stop once that many bytes are read. */
    private byte[] readClusterChain(long cluster, long maxBytes) throws IOException {
        int clusBytes = secPerClus * bytesPerSector;
        java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
        int guard = 0;
        while (cluster >= 2 && cluster < 0x0FFFFFF8L && guard++ < 1 << 22) {
            long sec = dataStart + (cluster - 2) * secPerClus;
            byte[] c = readSector(sec, clusBytes);
            bos.write(c, 0, c.length);
            if (maxBytes > 0 && bos.size() >= maxBytes) break;
            cluster = nextCluster(cluster);
        }
        return bos.toByteArray();
    }

    private void writeFile(long cluster, long size, File out) throws IOException {
        int clusBytes = secPerClus * bytesPerSector;
        OutputStream o = new FileOutputStream(out);
        try {
            long left = size;
            int guard = 0;
            while (cluster >= 2 && cluster < 0x0FFFFFF8L && left > 0 && guard++ < 1 << 22) {
                long sec = dataStart + (cluster - 2) * secPerClus;
                byte[] c = readSector(sec, clusBytes);
                int take = (int) Math.min(left, c.length);
                o.write(c, 0, take);
                left -= take;
                cluster = nextCluster(cluster);
            }
        } finally {
            o.close();
        }
    }

    private long nextCluster(long cluster) throws IOException {
        long fatByte = fatStart * (long) bytesPerSector + cluster * 4;
        raf.seek(fatByte);
        byte[] b = new byte[4];
        raf.readFully(b);
        return (u32(b, 0)) & 0x0FFFFFFFL;
    }

    private byte[] readSector(long sector, int len) throws IOException {
        byte[] b = new byte[len];
        raf.seek(sector * (long) (bytesPerSector == 0 ? 512 : bytesPerSector));
        raf.readFully(b);
        return b;
    }

    private static int u16(byte[] b, int o) { return (b[o] & 0xff) | ((b[o + 1] & 0xff) << 8); }
    private static long u32(byte[] b, int o) {
        return (b[o] & 0xffL) | ((b[o + 1] & 0xffL) << 8)
             | ((b[o + 2] & 0xffL) << 16) | ((b[o + 3] & 0xffL) << 24);
    }

    @Override public void close() throws IOException { raf.close(); }
}
