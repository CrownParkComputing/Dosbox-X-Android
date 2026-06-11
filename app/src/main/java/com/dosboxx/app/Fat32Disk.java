package com.dosboxx.app;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;

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

    private Fat32Disk() { }
}
