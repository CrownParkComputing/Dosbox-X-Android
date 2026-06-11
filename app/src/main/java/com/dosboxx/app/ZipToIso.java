package com.dosboxx.app;

import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.Collections;
import java.util.Comparator;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Builds an ISO9660 CD image from a .zip archive so its contents can be
 * IMGMOUNTed as a real (IDE-attached) CD drive — the only kind of mount a
 * booted guest OS (Win95/98/ME) can see; host-folder MOUNTs are invisible to
 * a booted guest. Writes both namespaces every Win9x CD shipped with:
 *  - plain ISO9660 level 1 (8.3 uppercase names) for DOS, and
 *  - a Joliet supplementary descriptor (UCS-2, long names) for Windows.
 *
 * Counterpart of {@link IsoReader} (which reads images); kept similarly
 * minimal: no Rock Ridge, no boot catalog, no multi-extent (>4GB) files.
 */
final class ZipToIso {

    private static final int SECTOR = 2048;

    /** Tree node for one zip entry (or a directory implied by entry paths). */
    private static final class Node {
        final String name;          // original name (Joliet namespace)
        final boolean dir;
        final Node parent;
        final List<Node> children = new ArrayList<>();
        ZipEntry entry;             // files only
        long size;                  // files only
        String isoName;             // 8.3 uppercase (no ";1" version suffix)
        String jolName;             // possibly truncated to 64 chars
        long lba;                   // file data extent
        long isoLba, isoLen;        // directory extent, ISO namespace
        long jolLba, jolLen;        // directory extent, Joliet namespace
        int pathIndex;              // 1-based path table index (dirs)

        Node(String name, boolean dir, Node parent) {
            this.name = name; this.dir = dir; this.parent = parent;
        }
    }

    /** Convert zip → isoOut. Returns false (and deletes isoOut) on any error. */
    static boolean convert(File zip, File isoOut) {
        ZipFile zf = null;
        try {
            zf = new ZipFile(zip);
            Node root = buildTree(zf);
            assignNames(root);
            write(zf, root, isoOut, volumeIdFor(zip.getName()), zip.lastModified());
            return true;
        } catch (Exception e) {
            isoOut.delete();
            return false;
        } finally {
            if (zf != null) try { zf.close(); } catch (IOException ignored) { }
        }
    }

    // ---- tree construction ----

    private static Node buildTree(ZipFile zf) throws IOException {
        Node root = new Node("", true, null);
        Map<String, Node> dirs = new HashMap<>();
        dirs.put("", root);
        Enumeration<? extends ZipEntry> en = zf.entries();
        while (en.hasMoreElements()) {
            ZipEntry e = en.nextElement();
            String path = e.getName().replace('\\', '/');
            while (path.startsWith("/")) path = path.substring(1);
            if (path.isEmpty() || path.contains("..")) continue;
            boolean isDir = e.isDirectory();
            if (isDir && path.endsWith("/")) path = path.substring(0, path.length() - 1);
            String[] parts = path.split("/");
            Node at = root;
            StringBuilder key = new StringBuilder();
            for (int i = 0; i < parts.length; i++) {
                boolean last = (i == parts.length - 1);
                if (key.length() > 0) key.append('/');
                key.append(parts[i]);
                if (last && !isDir) {
                    Node f = new Node(parts[i], false, at);
                    f.entry = e;
                    f.size = e.getSize() >= 0 ? e.getSize() : countSize(zf, e);
                    if (f.size > 0xFFFFFFFFL) throw new IOException("file too large for ISO9660");
                    at.children.add(f);
                } else {
                    Node d = dirs.get(key.toString());
                    if (d == null) {
                        d = new Node(parts[i], true, at);
                        at.children.add(d);
                        dirs.put(key.toString(), d);
                    }
                    at = d;
                }
            }
        }
        sortTree(root);
        return root;
    }

    /** Streamed entries can report size -1; decompress once to measure. */
    private static long countSize(ZipFile zf, ZipEntry e) throws IOException {
        InputStream in = zf.getInputStream(e);
        try {
            long n = 0; byte[] buf = new byte[65536]; int r;
            while ((r = in.read(buf)) > 0) n += r;
            return n;
        } finally {
            in.close();
        }
    }

    private static void sortTree(Node dir) {
        Collections.sort(dir.children, new Comparator<Node>() {
            @Override public int compare(Node a, Node b) {
                return a.name.compareToIgnoreCase(b.name);
            }
        });
        for (Node c : dir.children) if (c.dir) sortTree(c);
    }

    /** Per-directory: deduped 8.3 names for ISO, ≤64-char names for Joliet. */
    private static void assignNames(Node dir) {
        Set<String> usedIso = new HashSet<>();
        Set<String> usedJol = new HashSet<>();
        for (Node c : dir.children) {
            c.isoName = iso83(c.name, c.dir, usedIso);
            String j = c.name.length() > 64 ? c.name.substring(0, 64) : c.name;
            int n = 1;
            while (!usedJol.add(j.toLowerCase(Locale.US))) j = j + "_" + n++;
            c.jolName = j;
            if (c.dir) assignNames(c);
        }
    }

    private static String iso83(String name, boolean dir, Set<String> used) {
        String base = name, ext = "";
        int dot = name.lastIndexOf('.');
        if (!dir && dot > 0) { base = name.substring(0, dot); ext = name.substring(dot + 1); }
        base = sanitizeIso(base);
        ext = sanitizeIso(ext);
        if (base.isEmpty()) base = "_";
        if (base.length() > 8) base = base.substring(0, 8);
        if (ext.length() > 3) ext = ext.substring(0, 3);
        String cand = dir || ext.isEmpty() ? base : base + "." + ext;
        int n = 1;
        while (!used.add(cand)) {
            String tail = "~" + n++;
            String b = base.substring(0, Math.min(base.length(), 8 - tail.length())) + tail;
            cand = dir || ext.isEmpty() ? b : b + "." + ext;
        }
        return cand;
    }

    private static String sanitizeIso(String s) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = Character.toUpperCase(s.charAt(i));
            sb.append((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' ? c : '_');
        }
        return sb.toString();
    }

    private static String volumeIdFor(String zipName) {
        int dot = zipName.lastIndexOf('.');
        String v = sanitizeIso(dot > 0 ? zipName.substring(0, dot) : zipName);
        if (v.isEmpty()) v = "CDROM";
        return v.length() > 32 ? v.substring(0, 32) : v;
    }

    // ---- layout + write ----

    private static void write(ZipFile zf, Node root, File isoOut, String volId, long stamp)
            throws IOException {
        // Directories in path-table (BFS) order; 1-based indices.
        List<Node> dirs = new ArrayList<>();
        dirs.add(root);
        for (int i = 0; i < dirs.size(); i++) {
            for (Node c : dirs.get(i).children) if (c.dir) dirs.add(c);
        }
        for (int i = 0; i < dirs.size(); i++) dirs.get(i).pathIndex = i + 1;

        for (Node d : dirs) {
            d.isoLen = extentSize(d, false);
            d.jolLen = extentSize(d, true);
        }
        byte[] isoPtL = buildPathTable(dirs, false, false), isoPtM;
        byte[] jolPtL = buildPathTable(dirs, true, false), jolPtM;

        // sectors 0-15 reserved, 16 PVD, 17 SVD (Joliet), 18 terminator
        long cur = 19;
        long isoPtLLba = cur; cur += sectors(isoPtL.length);
        long isoPtMLba = cur; cur += sectors(isoPtL.length);
        long jolPtLLba = cur; cur += sectors(jolPtL.length);
        long jolPtMLba = cur; cur += sectors(jolPtL.length);
        for (Node d : dirs) { d.isoLba = cur; cur += sectors(d.isoLen); }
        for (Node d : dirs) { d.jolLba = cur; cur += sectors(d.jolLen); }
        List<Node> files = new ArrayList<>();
        for (Node d : dirs) for (Node c : d.children) if (!c.dir) files.add(c);
        for (Node f : files) { f.lba = cur; cur += sectors(f.size); }
        long totalSectors = cur;

        // Path tables carry extent LBAs, so rebuild now that they're assigned.
        isoPtL = buildPathTable(dirs, false, false);
        isoPtM = buildPathTable(dirs, false, true);
        jolPtL = buildPathTable(dirs, true, false);
        jolPtM = buildPathTable(dirs, true, true);

        byte[] date = recordDate(stamp);
        OutputStream out = new BufferedOutputStream(new FileOutputStream(isoOut), 1 << 16);
        try {
            byte[] zero = new byte[SECTOR];
            for (int i = 0; i < 16; i++) out.write(zero);
            out.write(volumeDescriptor(false, root, volId, totalSectors,
                isoPtL.length, isoPtLLba, isoPtMLba, date, stamp));
            out.write(volumeDescriptor(true, root, volId, totalSectors,
                jolPtL.length, jolPtLLba, jolPtMLba, date, stamp));
            byte[] term = new byte[SECTOR];
            term[0] = (byte) 255;
            System.arraycopy(ascii("CD001"), 0, term, 1, 5);
            term[6] = 1;
            out.write(term);
            writePadded(out, isoPtL);
            writePadded(out, isoPtM);
            writePadded(out, jolPtL);
            writePadded(out, jolPtM);
            for (Node d : dirs) out.write(dirExtent(d, false, date));
            for (Node d : dirs) out.write(dirExtent(d, true, date));
            for (Node f : files) {
                long written = 0;
                if (f.size > 0) {
                    InputStream in = zf.getInputStream(f.entry);
                    try {
                        byte[] buf = new byte[65536]; int r;
                        while ((r = in.read(buf)) > 0) { out.write(buf, 0, r); written += r; }
                    } finally {
                        in.close();
                    }
                }
                if (written != f.size) throw new IOException("zip entry size mismatch: " + f.name);
                int pad = (int) (sectors(f.size) * SECTOR - f.size);
                if (pad > 0) out.write(zero, 0, pad);
            }
        } finally {
            out.close();
        }
    }

    private static long sectors(long bytes) { return (bytes + SECTOR - 1) / SECTOR; }

    private static void writePadded(OutputStream out, byte[] data) throws IOException {
        out.write(data);
        int pad = (int) (sectors(data.length) * SECTOR - data.length);
        if (pad > 0) out.write(new byte[pad]);
    }

    // ---- directory records ----

    private static byte[] nameBytes(Node c, boolean joliet) {
        String n = joliet ? c.jolName : c.isoName;
        if (!c.dir) n = n + ";1";
        return joliet ? ucs2(n) : ascii(n);
    }

    private static int recLen(int nameByteLen) {
        int l = 33 + nameByteLen;
        return (l & 1) == 1 ? l + 1 : l;   // pad to even
    }

    /** Records may not straddle a sector boundary; skip to the next sector. */
    private static int advance(int pos, int len) {
        if ((pos % SECTOR) + len > SECTOR) pos = ((pos / SECTOR) + 1) * SECTOR;
        return pos + len;
    }

    private static long extentSize(Node dir, boolean joliet) {
        int pos = advance(advance(0, 34), 34);   // "." and ".."
        for (Node c : dir.children) pos = advance(pos, recLen(nameBytes(c, joliet).length));
        return sectors(pos) * SECTOR;
    }

    private static byte[] dirExtent(Node dir, boolean joliet, byte[] date) {
        long selfLba = joliet ? dir.jolLba : dir.isoLba;
        long selfLen = joliet ? dir.jolLen : dir.isoLen;
        Node parent = dir.parent != null ? dir.parent : dir;
        long parLba = joliet ? parent.jolLba : parent.isoLba;
        long parLen = joliet ? parent.jolLen : parent.isoLen;
        byte[] buf = new byte[(int) selfLen];
        int pos = putRecord(buf, 0, new byte[]{0}, selfLba, selfLen, true, date);
        pos = putRecord(buf, pos, new byte[]{1}, parLba, parLen, true, date);
        for (Node c : dir.children) {
            long lba = c.dir ? (joliet ? c.jolLba : c.isoLba) : c.lba;
            long len = c.dir ? (joliet ? c.jolLen : c.isoLen) : c.size;
            pos = putRecord(buf, pos, nameBytes(c, joliet), lba, len, c.dir, date);
        }
        return buf;
    }

    private static int putRecord(byte[] buf, int pos, byte[] name, long lba, long len,
                                 boolean dir, byte[] date) {
        int rl = recLen(name.length);
        if ((pos % SECTOR) + rl > SECTOR) pos = ((pos / SECTOR) + 1) * SECTOR;
        buf[pos] = (byte) rl;                       // record length; ext-attr len 0
        both32(buf, pos + 2, lba);
        both32(buf, pos + 10, len);
        System.arraycopy(date, 0, buf, pos + 18, 7);
        buf[pos + 25] = (byte) (dir ? 0x02 : 0x00); // flags
        both16(buf, pos + 28, 1);                   // volume sequence number
        buf[pos + 32] = (byte) name.length;
        System.arraycopy(name, 0, buf, pos + 33, name.length);
        return pos + rl;
    }

    /** 7-byte directory-record timestamp (offset-from-1900 form). */
    private static byte[] recordDate(long millis) {
        Calendar c = Calendar.getInstance();
        c.setTimeInMillis(millis > 0 ? millis : System.currentTimeMillis());
        return new byte[] {
            (byte) (c.get(Calendar.YEAR) - 1900), (byte) (c.get(Calendar.MONTH) + 1),
            (byte) c.get(Calendar.DAY_OF_MONTH), (byte) c.get(Calendar.HOUR_OF_DAY),
            (byte) c.get(Calendar.MINUTE), (byte) c.get(Calendar.SECOND), 0,
        };
    }

    // ---- path tables ----

    private static byte[] buildPathTable(List<Node> dirs, boolean joliet, boolean bigEndian) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (Node d : dirs) {
            byte[] name = d.parent == null ? new byte[]{0}
                : (joliet ? ucs2(d.jolName) : ascii(d.isoName));
            long lba = joliet ? d.jolLba : d.isoLba;
            int parent = d.parent != null ? d.parent.pathIndex : 1;
            out.write(name.length);
            out.write(0);                            // ext-attr length
            byte[] b = new byte[6];
            if (bigEndian) { be32(b, 0, lba); be16(b, 4, parent); }
            else           { le32(b, 0, lba); le16(b, 4, parent); }
            out.write(b, 0, 6);
            out.write(name, 0, name.length);
            if ((name.length & 1) == 1) out.write(0);
        }
        return out.toByteArray();
    }

    // ---- volume descriptors ----

    private static byte[] volumeDescriptor(boolean joliet, Node root, String volId,
            long totalSectors, int ptSize, long ptLLba, long ptMLba, byte[] date, long stamp) {
        byte[] b = new byte[SECTOR];
        b[0] = (byte) (joliet ? 2 : 1);
        System.arraycopy(ascii("CD001"), 0, b, 1, 5);
        b[6] = 1;
        fillText(b, 8, 32, "", joliet);              // system id
        fillText(b, 40, 32, volId, joliet);          // volume id
        both32(b, 80, totalSectors);
        if (joliet) { b[88] = 0x25; b[89] = 0x2F; b[90] = 0x45; }   // "%/E" = UCS-2 level 3
        both16(b, 120, 1);                           // volume set size
        both16(b, 124, 1);                           // volume sequence number
        both16(b, 128, SECTOR);                      // logical block size
        both32(b, 132, ptSize);
        le32(b, 140, ptLLba);
        be32(b, 148, ptMLba);
        long rootLba = joliet ? root.jolLba : root.isoLba;
        long rootLen = joliet ? root.jolLen : root.isoLen;
        putRecord(b, 156, new byte[]{0}, rootLba, rootLen, true, date);
        fillText(b, 190, 128, "", joliet);           // volume set id
        fillText(b, 318, 128, "", joliet);           // publisher
        fillText(b, 446, 128, "", joliet);           // data preparer
        fillText(b, 574, 128, "DOSBOX-X ANDROID ZIP2ISO", joliet);  // application
        fillText(b, 702, 37, "", joliet);            // copyright file id
        fillText(b, 739, 37, "", joliet);            // abstract file id
        fillText(b, 776, 37, "", joliet);            // bibliographic file id
        volDate(b, 813, stamp);                      // creation
        volDate(b, 830, stamp);                      // modification
        System.arraycopy(ascii("0000000000000000"), 0, b, 847, 16);  // no expiration
        System.arraycopy(ascii("0000000000000000"), 0, b, 864, 16);  // no effective date
        b[881] = 1;                                  // file structure version
        return b;
    }

    /** 17-byte "YYYYMMDDHHMMSScc" + tz volume-descriptor timestamp. */
    private static void volDate(byte[] b, int off, long millis) {
        Calendar c = Calendar.getInstance();
        c.setTimeInMillis(millis > 0 ? millis : System.currentTimeMillis());
        String s = String.format(Locale.US, "%04d%02d%02d%02d%02d%02d00",
            c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH),
            c.get(Calendar.HOUR_OF_DAY), c.get(Calendar.MINUTE), c.get(Calendar.SECOND));
        System.arraycopy(ascii(s), 0, b, off, 16);
    }

    /** Space-padded text field — single-byte for ISO, UCS-2 for Joliet. */
    private static void fillText(byte[] b, int off, int len, String s, boolean joliet) {
        if (joliet) {
            for (int i = 0; i < len; i += 2) { b[off + i] = 0; b[off + i + 1] = ' '; }
            byte[] u = ucs2(s.length() > len / 2 ? s.substring(0, len / 2) : s);
            System.arraycopy(u, 0, b, off, u.length);
        } else {
            for (int i = 0; i < len; i++) b[off + i] = ' ';
            byte[] a = ascii(s.length() > len ? s.substring(0, len) : s);
            System.arraycopy(a, 0, b, off, a.length);
        }
    }

    // ---- byte helpers ----

    private static byte[] ascii(String s) {
        byte[] b = new byte[s.length()];
        for (int i = 0; i < s.length(); i++) b[i] = (byte) s.charAt(i);
        return b;
    }

    private static byte[] ucs2(String s) {
        byte[] b = new byte[s.length() * 2];
        for (int i = 0; i < s.length(); i++) {
            b[i * 2] = (byte) (s.charAt(i) >> 8);
            b[i * 2 + 1] = (byte) s.charAt(i);
        }
        return b;
    }

    private static void le16(byte[] b, int off, int v) {
        b[off] = (byte) v; b[off + 1] = (byte) (v >> 8);
    }

    private static void be16(byte[] b, int off, int v) {
        b[off] = (byte) (v >> 8); b[off + 1] = (byte) v;
    }

    private static void le32(byte[] b, int off, long v) {
        b[off] = (byte) v; b[off + 1] = (byte) (v >> 8);
        b[off + 2] = (byte) (v >> 16); b[off + 3] = (byte) (v >> 24);
    }

    private static void be32(byte[] b, int off, long v) {
        b[off] = (byte) (v >> 24); b[off + 1] = (byte) (v >> 16);
        b[off + 2] = (byte) (v >> 8); b[off + 3] = (byte) v;
    }

    private static void both16(byte[] b, int off, int v) {
        le16(b, off, v); be16(b, off + 2, v);
    }

    private static void both32(byte[] b, int off, long v) {
        le32(b, off, v); be32(b, off + 4, v);
    }

    private ZipToIso() { }
}
