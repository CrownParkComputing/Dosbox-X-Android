#!/usr/bin/env python3
"""Builds assets/demo/DEMO.COM -- the demo that shows the emulator working.

WRITTEN, NOT SOURCED. The demo has to be something the user opens out of their
own library, and every DOS program that could serve that purpose is somebody's.
This one is ours: 8086 machine code assembled here, and nothing else.

WHY A .COM AND NOT A .EXE. A .COM is a flat image loaded at 0100h with no
header and no relocations, so "assembling" it is emitting bytes -- no linker,
no toolchain to install, and nothing to go wrong silently. It is also the
oldest, most universally supported thing DOS can run, which matters when the
point is to demonstrate the emulator rather than the program.

WHY IT NEEDS NO BIOS. Unlike the C64 and Amiga front ends, this one ships no
ROM at all and does not need to: DOSBox-X provides its own DOS (the FreeDOS
utilities are built into the core as blobs), so a fresh install already boots
to a working C:\\> prompt. What was missing was something to RUN there -- which
is what a reviewer with no games of their own needs to see.

It calls INT 10h and INT 21h only: set a text mode, paint the screen through
the BIOS video buffer, print through DOS, wait for a key, exit. No undocumented
behaviour, nothing timing-dependent, and no assumption about which DOS is
underneath -- so it is the same demo on DOSBox-X's built-in DOS as on a real
MS-DOS boot disk.

    python3 tool/make_demo_com.py

Run from the flutter_app directory.
"""

from __future__ import annotations

import pathlib

ORG = 0x100          # where DOS loads a .COM image
VIDEO_SEG = 0xB800   # colour text-mode video memory
CELLS = 80 * 25
ATTR = 0x1F          # bright white on blue, for every cell

# What it says. Kept to plain ASCII: the demo runs before any code page has
# been chosen, and a box-drawing character that renders as a letter would look
# like a bug rather than a decoration.
MESSAGE = "\r\n".join([
    "  ****  RETRO-DOSBOX  ****",
    "",
    "  This is a real PC, emulated by DOSBox-X.",
    "",
    "  The app ships no games and no MS-DOS.",
    "  It does not need them: DOSBox-X provides",
    "  its own DOS, so this ran with nothing",
    "  supplied by you.",
    "",
    "  Put your own games in the Retro-DosBox",
    "  folder and they appear on the shelf.",
    "",
    "  Press any key to return to DOS.",
]) + "$"


def assemble() -> bytes:
    """Emit the program. The message offset is computed, never hardcoded."""
    code = bytearray()

    def emit(*b: int) -> None:
        code.extend(b)

    # mov ax,0003h / int 10h -- 80x25 colour text, and clears the screen.
    emit(0xB8, 0x03, 0x00)
    emit(0xCD, 0x10)

    # cld first: rep stosw walks forward only if the direction flag is clear.
    # DOS conventionally enters a program with it clear, but "conventionally"
    # is not "always", and the failure -- writing backwards out of the video
    # segment -- would be spectacular and hard to attribute.
    #
    # Paint every cell with our attribute. Done before any text is printed:
    # DOS's own output writes characters and leaves the attribute byte alone in
    # text mode, so the colour has to be there first for the text to land on.
    emit(0xFC)                                     # cld
    emit(0xB8, VIDEO_SEG & 0xFF, VIDEO_SEG >> 8)   # mov ax,0B800h
    emit(0x8E, 0xC0)                               # mov es,ax
    emit(0x31, 0xFF)                               # xor di,di
    emit(0xB9, CELLS & 0xFF, CELLS >> 8)           # mov cx,2000
    emit(0xB8, 0x20, ATTR)                         # mov ax,attr<<8 | ' '
    emit(0xF3, 0xAB)                               # rep stosw

    # Cursor to row 2, column 2, page 0.
    emit(0xB4, 0x02)                               # mov ah,02h
    emit(0xB7, 0x00)                               # mov bh,0
    emit(0xB6, 0x02)                               # mov dh,2   (row)
    emit(0xB2, 0x02)                               # mov dl,2   (col)
    emit(0xCD, 0x10)                               # int 10h

    # mov ah,09h / mov dx,msg / int 21h -- print the $-terminated string.
    emit(0xB4, 0x09)
    msg_operand = len(code) + 1                    # where the word goes
    emit(0xBA, 0x00, 0x00)                         # placeholder, patched below
    emit(0xCD, 0x21)

    # mov ah,00h / int 16h -- wait for a keypress, so the screen is readable
    # rather than flashing past on a fast host.
    emit(0xB4, 0x00)
    emit(0xCD, 0x16)

    # mov ah,4Ch / int 21h -- terminate with exit code 0.
    emit(0xB4, 0x4C)
    emit(0xCD, 0x21)

    msg_addr = ORG + len(code)
    code[msg_operand] = msg_addr & 0xFF
    code[msg_operand + 1] = msg_addr >> 8
    code.extend(MESSAGE.encode("ascii"))
    return bytes(code)


def main() -> None:
    out = pathlib.Path("assets/demo/DEMO.COM")
    out.parent.mkdir(parents=True, exist_ok=True)
    image = assemble()
    out.write_bytes(image)
    # A .COM cannot exceed 65280 bytes; this is nowhere near, but the check
    # costs nothing and names the limit for anyone extending the message.
    assert len(image) < 0xFF00, "a .COM image cannot exceed 65280 bytes"
    print(f"wrote {out} ({len(image)} bytes)")


if __name__ == "__main__":
    main()
