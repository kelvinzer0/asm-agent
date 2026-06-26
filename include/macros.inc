; ============================================================================
; macros.inc — ASM-AGENT NASM Macros
; ============================================================================

; --- ANSI Color Escape Sequences ---
%define ESC                 0x1B

section .rodata

; Terminal colors
ansi_reset      db ESC, '[0m', 0
ansi_bold       db ESC, '[1m', 0
ansi_dim        db ESC, '[2m', 0
ansi_italic     db ESC, '[3m', 0
ansi_underline  db ESC, '[4m', 0

; Foreground colors
ansi_red        db ESC, '[38;5;203m', 0
ansi_green      db ESC, '[38;5;114m', 0
ansi_yellow     db ESC, '[38;5;221m', 0
ansi_blue       db ESC, '[38;5;75m', 0
ansi_magenta    db ESC, '[38;5;176m', 0
ansi_cyan       db ESC, '[38;5;80m', 0
ansi_white      db ESC, '[38;5;255m', 0
ansi_gray       db ESC, '[38;5;245m', 0
ansi_orange     db ESC, '[38;5;208m', 0

; Background colors
ansi_bg_dark    db ESC, '[48;5;235m', 0
ansi_bg_darker  db ESC, '[48;5;233m', 0
ansi_bg_accent  db ESC, '[48;5;236m', 0

; Cursor / Screen control
ansi_clear      db ESC, '[2J', ESC, '[H', 0
ansi_hide_cur   db ESC, '[?25l', 0
ansi_show_cur   db ESC, '[?25h', 0
ansi_save_cur   db ESC, '[s', 0
ansi_rest_cur   db ESC, '[u', 0
ansi_erase_line db ESC, '[2K', 0

; --- Box Drawing Characters (UTF-8) ---
box_tl          db 0xE2, 0x95, 0xAD, 0  ; ╭
box_tr          db 0xE2, 0x95, 0xAE, 0  ; ╮
box_bl          db 0xE2, 0x95, 0xB0, 0  ; ╰
box_br          db 0xE2, 0x95, 0xAF, 0  ; ╯
box_h           db 0xE2, 0x94, 0x80, 0  ; ─
box_v           db 0xE2, 0x94, 0x82, 0  ; │
box_vr          db 0xE2, 0x94, 0x9C, 0  ; ├
box_vl          db 0xE2, 0x94, 0xA4, 0  ; ┤

; --- Status Icons (UTF-8) ---
icon_think      db 0xF0, 0x9F, 0xA4, 0x94, 0  ; 🤔
icon_exec       db 0xE2, 0x9A, 0xA1, 0         ; ⚡
icon_output     db 0xF0, 0x9F, 0x93, 0x9D, 0   ; 📝
icon_done       db 0xE2, 0x9C, 0x85, 0         ; ✅
icon_error      db 0xE2, 0x9D, 0x8C, 0         ; ❌
icon_loop       db 0xF0, 0x9F, 0x94, 0x84, 0   ; 🔄
icon_rocket     db 0xF0, 0x9F, 0x9A, 0x80, 0   ; 🚀
icon_shield     db 0xF0, 0x9F, 0x9B, 0xA1, 0   ; 🛡️
icon_brain      db 0xF0, 0x9F, 0xA7, 0xA0, 0   ; 🧠
icon_arrow      db 0xE2, 0x96, 0xB6, 0         ; ▶
icon_gear       db 0xE2, 0x9A, 0x99, 0         ; ⚙
icon_dot        db 0xE2, 0x97, 0x8F, 0         ; ●

newline         db 10, 0

section .text

; ============================================================================
; MACRO: SYSCALL1..6 — Wrappers for Linux syscalls
; ============================================================================
%macro SYSCALL1 2
    mov     rax, %1
    mov     rdi, %2
    syscall
%endmacro

%macro SYSCALL2 3
    mov     rax, %1
    mov     rdi, %2
    mov     rsi, %3
    syscall
%endmacro

%macro SYSCALL3 4
    mov     rax, %1
    mov     rdi, %2
    mov     rsi, %3
    mov     rdx, %4
    syscall
%endmacro

%macro SYSCALL4 5
    mov     rax, %1
    mov     rdi, %2
    mov     rsi, %3
    mov     rdx, %4
    mov     r10, %5
    syscall
%endmacro

%macro SYSCALL6 7
    mov     rax, %1
    mov     rdi, %2
    mov     rsi, %3
    mov     rdx, %4
    mov     r10, %5
    mov     r8, %6
    mov     r9, %7
    syscall
%endmacro

; ============================================================================
; MACRO: PRINT — Write null-terminated string to fd
; Usage: PRINT STDOUT, my_string_label
; Clobbers: rax, rdi, rsi, rdx, rcx
; ============================================================================
%macro PRINT 2
    push    rdi
    push    rsi
    push    rdx
    push    rcx
    mov     rdi, %2
    call    str_len
    mov     rdx, rax            ; length
    mov     rsi, %2             ; buffer
    mov     rdi, %1             ; fd
    mov     rax, SYS_WRITE
    syscall
    pop     rcx
    pop     rdx
    pop     rsi
    pop     rdi
%endmacro

; ============================================================================
; MACRO: PRINT_COLOR — Print colored text
; Usage: PRINT_COLOR STDOUT, ansi_green, my_text
; ============================================================================
%macro PRINT_COLOR 3
    PRINT %1, %2
    PRINT %1, %3
    PRINT %1, ansi_reset
%endmacro

; ============================================================================
; MACRO: PRINT_LEN — Write buffer with known length to fd
; Usage: PRINT_LEN STDOUT, buffer, length
; ============================================================================
%macro PRINT_LEN 3
    push    rax
    push    rdi
    push    rsi
    push    rdx
    mov     rdi, %1
    mov     rsi, %2
    mov     rdx, %3
    mov     rax, SYS_WRITE
    syscall
    pop     rdx
    pop     rsi
    pop     rdi
    pop     rax
%endmacro

; ============================================================================
; MACRO: EXIT — Exit process with code
; ============================================================================
%macro EXIT 1
    mov     rdi, %1
    mov     rax, SYS_EXIT
    syscall
%endmacro
