package com.dosboxx.app;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * Creates an MBR-partitioned, FAT32-formatted hard disk image that a Win9x
 * guest mounts as a ready-to-use data drive (the "games disk" — D: when
 * attached as the second BIOS disk). The file is written sparse: only the
 * MBR, boot sectors and FATs are materialized, so creating even an 8GB image
 * is instant and the file grows as the guest fills it.
 *
 * Geometry matches the launcher's imgmount convention (512 bytes/sector,
 * 63 sectors/track, 255 heads); the partition starts at sector 63 (classic
 * DOS cylinder alignment, same as the WinBox windows98.img).
 */
final class Fat32Disk {

    private static final int SS = 512;            // bytes per sector
    private static final int SPT = 63;            // sectors per track
    private static final int HEADS = 255;
    private static final int PART_START = 63;     // first partition sector
    private static final int RESERVED = 32;       // FAT32 reserved sectors
    private static final int SEC_PER_CLUS = 8;    // 4KB clusters

    /** Create the image (~sizeBytes, rounded down to whole cylinders). */
    static void create(File img, long sizeBytes, String label) throws IOException {
        long cylBytes = (long) SS * SPT * HEADS;
        long cylinders = sizeBytes / cylBytes;
        if (cylinders < 9) throw new IOException("image too small for FAT32");
        long totalSectors = cylinders * SPT * HEADS;
        long partSectors = totalSectors - PART_START;

        // FAT sizing: clusters need 4 bytes each in the FAT; iterate to settle.
        long fatSectors = 1;
        for (int i = 0; i < 8; i++) {
            long dataSectors = partSectors - RESERVED - 2 * fatSectors;
            long clusters = dataSectors / SEC_PER_CLUS;
            fatSectors = ((clusters + 2) * 4 + SS - 1) / SS;
        }
        long dataStart = PART_START + RESERVED + 2 * fatSectors;
        long clusters = (PART_START + partSectors - dataStart) / SEC_PER_CLUS;
        if (clusters < 65525) throw new IOException("too few clusters for FAT32");

        RandomAccessFile f = new RandomAccessFile(img, "rw");
        try {
            f.setLength(0);
            f.setLength(totalSectors * SS);       // sparse body

            // ---- MBR ----
            byte[] mbr = new byte[SS];
            mbr[446] = (byte) 0x80;               // active
            chs(mbr, 447, PART_START);
            mbr[450] = 0x0C;                      // FAT32 (LBA)
            chs(mbr, 451, PART_START + partSectors - 1);
            le32(mbr, 454, PART_START);
            le32(mbr, 458, partSectors);
            mbr[510] = 0x55; mbr[511] = (byte) 0xAA;
            f.seek(0);
            f.write(mbr);

            // ---- FAT32 boot sector ----
            byte[] bs = new byte[SS];
            bs[0] = (byte) 0xEB; bs[1] = 0x58; bs[2] = (byte) 0x90;
            ascii(bs, 3, "MSDOS5.0");
            le16(bs, 11, SS);
            bs[13] = SEC_PER_CLUS;
            le16(bs, 14, RESERVED);
            bs[16] = 2;                           // FAT copies
            bs[21] = (byte) 0xF8;                 // media: fixed disk
            le16(bs, 24, SPT);
            le16(bs, 26, HEADS);
            le32(bs, 28, PART_START);             // hidden sectors
            le32(bs, 32, partSectors);
            le32(bs, 36, fatSectors);
            le32(bs, 44, 2);                      // root dir cluster
            le16(bs, 48, 1);                      // FSInfo sector
            le16(bs, 50, 6);                      // backup boot sector
            bs[64] = (byte) 0x80;                 // BIOS drive number
            bs[66] = 0x29;                        // extended boot signature
            le32(bs, 67, (int) (System.currentTimeMillis() / 1000)); // volume id
            ascii(bs, 71, padLabel(label));
            ascii(bs, 82, "FAT32   ");
            bs[510] = 0x55; bs[511] = (byte) 0xAA;

            // ---- FSInfo ----
            byte[] fsi = new byte[SS];
            ascii(fsi, 0, "RRaA");
            ascii(fsi, 484, "rrAa");
            le32(fsi, 488, clusters - 1);         // free clusters (root uses one)
            le32(fsi, 492, 3);                    // next free hint
            fsi[510] = 0x55; fsi[511] = (byte) 0xAA;

            writeSector(f, PART_START, bs);
            writeSector(f, PART_START + 1, fsi);
            writeSector(f, PART_START + 6, bs);   // backups
            writeSector(f, PART_START + 7, fsi);

            // ---- FATs: media descriptor, EOC for FAT[1] and the root cluster ----
            byte[] fat0 = new byte[SS];
            le32(fat0, 0, 0x0FFFFFF8L);
            le32(fat0, 4, 0xFFFFFFFFL);
            le32(fat0, 8, 0x0FFFFFFFL);           // root cluster chain end
            writeSector(f, PART_START + RESERVED, fat0);
            writeSector(f, PART_START + RESERVED + fatSectors, fat0);

            // ---- root dir: volume label entry (rest of the cluster is sparse zeros) ----
            byte[] root = new byte[SS];
            ascii(root, 0, padLabel(label));
            root[11] = 0x08;                      // ATTR_VOLUME_ID
            writeSector(f, dataStart, root);
        } finally {
            f.close();
        }
    }

    /** True if the name marks a data disk this class creates. */
    static boolean isGamesDisk(String fileName) {
        return fileName.toLowerCase().startsWith("gamesdisk") && fileName.toLowerCase().endsWith(".img");
    }

    static String shortSafeName(String wantedName, boolean dir) {
        String[] parts = shortParts(wantedName, dir);
        return format83(parts[0], parts[1]);
    }

    /** Copy a host directory into the FAT32 image root as a new top-level
     *  folder. Minimal writer for the games disks created above: 8.3 names,
     *  no LFN, no overwrite. Returns the created DOS folder name, or null. */
    static String copyDirectoryToRoot(File img, File srcDir, String wantedName) {
        try {
            return copyDirectoryToRootOrThrow(img, srcDir, wantedName);
        } catch (Exception e) {
            return null;
        }
    }

    static String copyDirectoryToRootOrThrow(File img, File srcDir, String wantedName) throws IOException {
        Writer w = null;
        try {
            w = new Writer(img);
            String dosName = w.uniqueShortName(w.rootCluster, wantedName, true);
            long dirCluster = w.allocCluster();
            w.clearCluster(dirCluster);
            w.initDir(dirCluster, w.rootCluster);
            w.addEntry(w.rootCluster, dosName, true, dirCluster, 0);
            w.copyDir(srcDir, dirCluster);
            return dosName.trim();
        } finally {
            if (w != null) try { w.close(); } catch (IOException ignored) { }
        }
    }

    static void writeRootFileOrThrow(File img, String fileName, String body) throws IOException {
        Writer w = null;
        try {
            w = new Writer(img);
            w.writeRootFile(fileName, body.getBytes(StandardCharsets.US_ASCII));
        } finally {
            if (w != null) try { w.close(); } catch (IOException ignored) { }
        }
    }

    private static void writeSector(RandomAccessFile f, long lba, byte[] data) throws IOException {
        f.seek(lba * SS);
        f.write(data);
    }

    private static String padLabel(String label) {
        StringBuilder sb = new StringBuilder();
        for (char c : label.toUpperCase().toCharArray()) {
            if (sb.length() == 11) break;
            sb.append((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ? c : '_');
        }
        while (sb.length() < 11) sb.append(' ');
        return sb.toString();
    }

    /** 3-byte CHS field for an LBA (clamped to the CHS ceiling like fdisk). */
    private static void chs(byte[] b, int off, long lba) {
        long c = lba / (HEADS * SPT);
        long h = (lba / SPT) % HEADS;
        long s = (lba % SPT) + 1;
        if (c > 1023) { c = 1023; h = HEADS - 1; s = SPT; }
        b[off] = (byte) h;
        b[off + 1] = (byte) (((c >> 2) & 0xC0) | s);
        b[off + 2] = (byte) c;
    }

    private static void ascii(byte[] b, int off, String s) {
        for (int i = 0; i < s.length(); i++) b[off + i] = (byte) s.charAt(i);
    }

    private static void le16(byte[] b, int off, int v) {
        b[off] = (byte) v; b[off + 1] = (byte) (v >> 8);
    }

    private static void le32(byte[] b, int off, long v) {
        b[off] = (byte) v; b[off + 1] = (byte) (v >> 8);
        b[off + 2] = (byte) (v >> 16); b[off + 3] = (byte) (v >> 24);
    }

    private static long u32(byte[] b, int o) {
        return (b[o] & 0xffL) | ((b[o + 1] & 0xffL) << 8)
             | ((b[o + 2] & 0xffL) << 16) | ((b[o + 3] & 0xffL) << 24);
    }

    private static int u16(byte[] b, int o) {
        return (b[o] & 0xff) | ((b[o + 1] & 0xff) << 8);
    }

    static final class Writer implements AutoCloseable {
        final RandomAccessFile raf;
        final long partStart;
        final int bytesPerSector;
        final int secPerClus;
        final int numFats;
        final long fatStart;
        final long fatSize;
        final long dataStart;
        final long rootCluster;
        final long clusterCount;
        final int clusterBytes;

        Writer(File img) throws IOException {
            raf = new RandomAccessFile(img, "rw");
            byte[] mbr = readRawSector(0, SS);
            long ps = -1, partSectors = -1;
            for (int i = 0; i < 4; i++) {
                int e = 446 + i * 16;
                int type = mbr[e + 4] & 0xff;
                if (type == 0x0B || type == 0x0C) {
                    ps = u32(mbr, e + 8);
                    partSectors = u32(mbr, e + 12);
                    break;
                }
            }
            if (ps < 0) throw new IOException("no FAT32 partition");
            partStart = ps;
            byte[] bpb = readRawSector(partStart, SS);
            bytesPerSector = u16(bpb, 11);
            secPerClus = bpb[13] & 0xff;
            int reserved = u16(bpb, 14);
            numFats = bpb[16] & 0xff;
            fatSize = u32(bpb, 36);
            rootCluster = u32(bpb, 44);
            fatStart = partStart + reserved;
            dataStart = partStart + reserved + (long) numFats * fatSize;
            clusterCount = (partStart + partSectors - dataStart) / secPerClus;
            clusterBytes = secPerClus * bytesPerSector;
            if (bytesPerSector != SS || secPerClus <= 0 || rootCluster < 2) {
                throw new IOException("unsupported FAT32 image");
            }
        }

        void copyDir(File src, long dstCluster) throws IOException {
            File[] kids = src.listFiles();
            if (kids == null) return;
            java.util.Arrays.sort(kids, (a, b) -> a.getName().compareToIgnoreCase(b.getName()));
            for (File f : kids) {
                if (f.getName().startsWith(".")) continue;
                if (f.isDirectory()) {
                    String name = uniqueShortName(dstCluster, f.getName(), true);
                    long c = allocCluster();
                    clearCluster(c);
                    initDir(c, dstCluster);
                    addEntry(dstCluster, name, true, c, 0);
                    copyDir(f, c);
                } else {
                    String name = uniqueShortName(dstCluster, f.getName(), false);
                    long size = f.length();
                    long first = size > 0 ? writeFileClusters(f) : 0;
                    addEntry(dstCluster, name, false, first, size);
                }
            }
        }

        long writeFileClusters(File src) throws IOException {
            long clusters = (src.length() + clusterBytes - 1) / clusterBytes;
            List<Long> chain = new ArrayList<>();
            for (long i = 0; i < clusters; i++) chain.add(allocCluster());
            for (int i = 0; i < chain.size(); i++) {
                setFat(chain.get(i), i + 1 < chain.size() ? chain.get(i + 1) : 0x0FFFFFFFL);
            }
            FileInputStream in = new FileInputStream(src);
            try {
                byte[] buf = new byte[clusterBytes];
                for (long c : chain) {
                    int pos = 0, n;
                    while (pos < buf.length && (n = in.read(buf, pos, buf.length - pos)) > 0) pos += n;
                    while (pos < buf.length) buf[pos++] = 0;
                    writeCluster(c, buf);
                }
            } finally {
                in.close();
            }
            return chain.get(0);
        }

        long writeFileClusters(IsoReader.FileSource src, long size) throws IOException {
            long clusters = (size + clusterBytes - 1) / clusterBytes;
            List<Long> chain = new ArrayList<>();
            for (long i = 0; i < clusters; i++) chain.add(allocCluster());
            for (int i = 0; i < chain.size(); i++) {
                setFat(chain.get(i), i + 1 < chain.size() ? chain.get(i + 1) : 0x0FFFFFFFL);
            }
            byte[] buf = new byte[clusterBytes];
            long posInFile = 0;
            for (long c : chain) {
                int pos = 0;
                while (pos < buf.length && posInFile < size) {
                    int take = (int) Math.min(buf.length - pos, size - posInFile);
                    src.read(posInFile, buf, pos, take);
                    pos += take;
                    posInFile += take;
                }
                while (pos < buf.length) buf[pos++] = 0;
                writeCluster(c, buf);
            }
            return chain.isEmpty() ? 0 : chain.get(0);
        }

        long writeBytesClusters(byte[] src) throws IOException {
            long clusters = (src.length + clusterBytes - 1L) / clusterBytes;
            List<Long> chain = new ArrayList<>();
            for (long i = 0; i < clusters; i++) chain.add(allocCluster());
            for (int i = 0; i < chain.size(); i++) {
                setFat(chain.get(i), i + 1 < chain.size() ? chain.get(i + 1) : 0x0FFFFFFFL);
            }
            int posInFile = 0;
            for (long c : chain) {
                byte[] buf = new byte[clusterBytes];
                int take = Math.min(buf.length, src.length - posInFile);
                if (take > 0) {
                    System.arraycopy(src, posInFile, buf, 0, take);
                    posInFile += take;
                }
                writeCluster(c, buf);
            }
            return chain.isEmpty() ? 0 : chain.get(0);
        }

        void writeRootFile(String wantedName, byte[] data) throws IOException {
            String[] parts = shortParts(wantedName, false);
            String name83 = format83(parts[0], parts[1]);
            deleteEntries(rootCluster, name83);
            long first = data.length > 0 ? writeBytesClusters(data) : 0;
            addEntry(rootCluster, name83, false, first, data.length);
        }

        void deleteEntries(long dirCluster, String name83) throws IOException {
            byte[] target = name83.getBytes(StandardCharsets.US_ASCII);
            for (long c : dirChain(dirCluster)) {
                byte[] d = readCluster(c);
                boolean changed = false;
                for (int off = 0; off + 32 <= d.length; off += 32) {
                    int first = d[off] & 0xff;
                    if (first == 0x00) break;
                    if (first == 0xE5 || (d[off + 11] & 0xff) == 0x0F) continue;
                    boolean match = true;
                    for (int i = 0; i < 11; i++) {
                        if (d[off + i] != target[i]) { match = false; break; }
                    }
                    if (match) {
                        d[off] = (byte) 0xE5;
                        changed = true;
                    }
                }
                if (changed) writeCluster(c, d);
            }
        }

        String uniqueShortName(long dirCluster, String wanted, boolean dir) throws IOException {
            Set<String> used = usedNames(dirCluster);
            String[] parts = shortParts(wanted, dir);
            String base = parts[0], ext = parts[1];
            String first = format83(base, ext);
            if (!used.contains(first)) return first;
            for (int i = 1; i < 10000; i++) {
                String tail = "~" + i;
                String b = base.substring(0, Math.min(base.length(), Math.max(1, 8 - tail.length()))) + tail;
                String cand = format83(b, ext);
                if (!used.contains(cand)) return cand;
            }
            throw new IOException("no unique FAT name");
        }

        Set<String> usedNames(long dirCluster) throws IOException {
            Set<String> out = new HashSet<>();
            for (long c : dirChain(dirCluster)) {
                byte[] d = readCluster(c);
                for (int off = 0; off + 32 <= d.length; off += 32) {
                    int first = d[off] & 0xff;
                    if (first == 0x00) break;
                    if (first == 0xE5 || (d[off + 11] & 0xff) == 0x0F) continue;
                    out.add(new String(d, off, 11, "US-ASCII"));
                }
            }
            return out;
        }

        void initDir(long cluster, long parent) throws IOException {
            byte[] d = new byte[clusterBytes];
            putEntry(d, 0, ".          ", true, cluster, 0);
            putEntry(d, 32, "..         ", true, parent, 0);
            writeCluster(cluster, d);
        }

        void addEntry(long dirCluster, String name83, boolean dir, long firstCluster, long size) throws IOException {
            long c = dirCluster;
            while (true) {
                byte[] d = readCluster(c);
                for (int off = 0; off + 32 <= d.length; off += 32) {
                    int first = d[off] & 0xff;
                    if (first == 0x00 || first == 0xE5) {
                        putEntry(d, off, name83, dir, firstCluster, size);
                        writeCluster(c, d);
                        return;
                    }
                }
                long next = fat(c);
                if (next >= 0x0FFFFFF8L) {
                    next = allocCluster();
                    setFat(c, next);
                    setFat(next, 0x0FFFFFFFL);
                    clearCluster(next);
                }
                c = next;
            }
        }

        void putEntry(byte[] d, int off, String name83, boolean dir, long firstCluster, long size) {
            for (int i = 0; i < 11; i++) d[off + i] = (byte) (i < name83.length() ? name83.charAt(i) : ' ');
            d[off + 11] = (byte) (dir ? 0x10 : 0x20);
            le16(d, off + 20, (int) ((firstCluster >> 16) & 0xffff));
            le16(d, off + 26, (int) (firstCluster & 0xffff));
            le32(d, off + 28, size);
        }

        long allocCluster() throws IOException {
            for (long c = 3; c < clusterCount + 2; c++) {
                if (fat(c) == 0) {
                    setFat(c, 0x0FFFFFFFL);
                    clearCluster(c);
                    return c;
                }
            }
            throw new IOException("disk full");
        }

        List<Long> dirChain(long start) throws IOException {
            List<Long> out = new ArrayList<>();
            long c = start;
            int guard = 0;
            while (c >= 2 && c < 0x0FFFFFF8L && guard++ < 1 << 22) {
                out.add(c);
                c = fat(c);
            }
            return out;
        }

        long fat(long cluster) throws IOException {
            raf.seek((fatStart * bytesPerSector) + cluster * 4);
            byte[] b = new byte[4];
            raf.readFully(b);
            return u32(b, 0) & 0x0FFFFFFFL;
        }

        void setFat(long cluster, long value) throws IOException {
            byte[] b = new byte[4];
            le32(b, 0, value);
            for (int i = 0; i < numFats; i++) {
                raf.seek(((fatStart + i * fatSize) * bytesPerSector) + cluster * 4);
                raf.write(b);
            }
        }

        byte[] readCluster(long cluster) throws IOException {
            return readSector(dataStart + (cluster - 2) * secPerClus, clusterBytes);
        }

        void writeCluster(long cluster, byte[] data) throws IOException {
            raf.seek((dataStart + (cluster - 2) * secPerClus) * bytesPerSector);
            raf.write(data);
        }

        void clearCluster(long cluster) throws IOException {
            writeCluster(cluster, new byte[clusterBytes]);
        }

        byte[] readSector(long lba, int len) throws IOException {
            byte[] b = new byte[len];
            raf.seek(lba * bytesPerSector);
            raf.readFully(b);
            return b;
        }

        byte[] readRawSector(long lba, int len) throws IOException {
            byte[] b = new byte[len];
            raf.seek(lba * SS);
            raf.readFully(b);
            return b;
        }

        @Override public void close() throws IOException { raf.close(); }
    }

    private static String[] shortParts(String name, boolean dir) {
        String n = name == null ? "" : name.trim();
        int dot = dir ? -1 : n.lastIndexOf('.');
        String base = dot > 0 ? n.substring(0, dot) : n;
        String ext = dot > 0 ? n.substring(dot + 1) : "";
        base = sanitizeFat(base);
        ext = sanitizeFat(ext);
        if (base.isEmpty()) base = "GAME";
        if (base.length() > 8) base = base.substring(0, 8);
        if (ext.length() > 3) ext = ext.substring(0, 3);
        return new String[]{base, ext};
    }

    private static String format83(String base, String ext) {
        StringBuilder sb = new StringBuilder(11);
        for (int i = 0; i < 8; i++) sb.append(i < base.length() ? base.charAt(i) : ' ');
        for (int i = 0; i < 3; i++) sb.append(i < ext.length() ? ext.charAt(i) : ' ');
        return sb.toString();
    }

    private static String sanitizeFat(String s) {
        StringBuilder sb = new StringBuilder();
        String up = s.toUpperCase(Locale.US);
        for (int i = 0; i < up.length(); i++) {
            char c = up.charAt(i);
            if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$' || c == '~') {
                sb.append(c);
            } else {
                sb.append('_');
            }
        }
        return sb.toString();
    }

    private Fat32Disk() { }
}
