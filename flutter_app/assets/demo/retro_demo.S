/*
 * Retro-DosBox Homebrew Demo
 *
 * A tiny original 16-bit DOS .COM program used to prove that the emulator
 * works without downloading or supplying commercial software. Build with
 * tools/build-homebrew-demo.sh from the repository root.
 *
 * SPDX-License-Identifier: MIT
 */

.code16
.intel_syntax noprefix
.global _start

.section .text
_start:
    /* A known 80x25 text screen makes the result deterministic. */
    mov ax, 0x0003
    int 0x10

    mov dx, offset banner
    mov ah, 0x09
    int 0x21

    xor bx, bx

animate:
    /* Draw a changing spinner in bright amber at row 15, column 38. */
    mov ah, 0x02
    xor bh, bh
    mov dx, 0x0f26
    int 0x10

    mov si, offset spinner
    mov ax, bx
    and ax, 3
    add si, ax
    mov al, byte ptr [si]
    mov ah, 0x09
    mov bl, 0x0e
    mov cx, 1
    int 0x10

    /* Exit on any key. */
    mov ah, 0x01
    int 0x16
    jnz exit_demo

    /* A short host-independent delay keeps the spinner readable. */
    mov cx, 0x0800
delay_outer:
    mov dx, 0x0040
delay_inner:
    dec dx
    jnz delay_inner
    loop delay_outer

    inc bx
    jmp animate

exit_demo:
    xor ah, ah
    int 0x16
    mov ax, 0x0003
    int 0x10
    mov ax, 0x4c00
    int 0x21

banner:
    .ascii "\r\n"
    .ascii "                 RETRO-DOSBOX HOMEBREW DEMO\r\n"
    .ascii "                 ==========================\r\n\r\n"
    .ascii "     This is an original DOS program included with Retro-DosBox.\r\n"
    .ascii "     It is not a commercial game, ROM, BIOS, DOS or Windows image.\r\n\r\n"
    .ascii "     DOSBox-X is running this program inside FreeDOS 1.4.\r\n"
    .ascii "     No account, network connection or external files are needed.\r\n\r\n"
    .ascii "     Source code and the MIT licence are included with the app.\r\n\r\n"
    .ascii "                    EMULATION IS RUNNING\r\n\r\n"
    .ascii "                 Press any key to return.$"

spinner:
    .ascii "|/-\\"
