// How big is the disk this image represents?
//
// Two callers need the answer and they need the same answer: the library
// scanner, deciding whether a loose image is a floppy or a bootable hard
// disk, and the conf builder, deciding whether a bootable image is big
// enough to hold Windows rather than DOS. Splitting the question out keeps
// them from disagreeing.
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

class DiskImage {
  DiskImage._();

  /// Image formats that describe a hard disk whatever their size.
  ///
  /// The distinction matters because the size test below cannot settle it on
  /// its own: an unfilled dynamic VHD is a few kilobytes on disk, and a .img
  /// of the same length really is a floppy.
  static const Set<String> hardDiskExtensions = {'.vhd', '.hdd', '.hdi'};

  /// Whether [path] names a hard-disk image rather than a floppy image.
  ///
  /// Extension first, then size. [minHardDiskBytes] is the threshold for the
  /// ambiguous formats (.img, .ima, .dsk), which were used for both.
  static bool isHardDisk(String path, {required int minHardDiskBytes}) {
    if (hardDiskExtensions.contains(p.extension(path).toLowerCase())) {
      return true;
    }
    return virtualSize(path) >= minHardDiskBytes;
  }

  /// The size of the disk the image represents, which is not always the size
  /// of the file.
  ///
  /// A dynamic VHD -- what every 86Box/VirtualPC-era pre-built Windows image
  /// ships as -- stores only the blocks that have been written, so a 20GB
  /// Windows 98 disk can be a 4KB file the moment before it is filled. Going
  /// by file length alone therefore reads exactly the images this matters
  /// for as tiny floppies.
  ///
  /// The VHD footer carries the real figure. Dynamic and differencing images
  /// keep a copy of that footer at offset 0 (fixed images have it only at the
  /// end, where the file length is already the right answer), so reading the
  /// first 512 bytes settles it. Returns the file length on anything that is
  /// not a VHD, and 0 when the file cannot be read at all.
  static int virtualSize(String path) {
    final file = File(path);
    int fileLength;
    try {
      fileLength = file.lengthSync();
    } on FileSystemException {
      return 0;
    }
    if (p.extension(path).toLowerCase() != '.vhd') return fileLength;

    RandomAccessFile? handle;
    try {
      handle = file.openSync();
      final header = handle.readSync(0x38);
      if (header.length < 0x38) return fileLength;
      // "conectix" -- the footer cookie. Absent at offset 0 on a fixed VHD,
      // whose file length already includes everything but the 512-byte
      // footer and is close enough for a size threshold.
      const cookie = <int>[0x63, 0x6F, 0x6E, 0x65, 0x63, 0x74, 0x69, 0x78];
      for (var i = 0; i < cookie.length; i++) {
        if (header[i] != cookie[i]) return fileLength;
      }
      // currentSize: 8 bytes big-endian at offset 0x30 of the footer.
      final size = ByteData.sublistView(
        Uint8List.fromList(header),
      ).getUint64(0x30, Endian.big);
      return size > 0 ? size : fileLength;
    } on FileSystemException {
      return fileLength;
    } finally {
      handle?.closeSync();
    }
  }
}
