; ============================================================================
; channels.asm — Musical Channel System
; ============================================================================
; Routes output to different channels based on content type.
; Channels act like audio mixing channels — each handles a specific stream.
;
; Channels:
;   CH_SOPRANO (0) — Primary output (stdout display)
;   CH_ALTO    (1) — Secondary output
;   CH_TENOR   (2) — Debug/trace output
;   CH_BASS    (3) — Persistent log (worklog)
;   CH_HARP    (4) — Error stream
;   CH_TIMPANI (5) — Signal/event stream
;
; API:
;   channel_init        — Initialize channel system
;   channel_route       — Route data to appropriate channel(s)
;   channel_set_mask    — Set active channel bitmask
;   channel_is_active   — Check if channel is active
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"
%include "musical.inc"

extern musical_state
extern temp_buf
extern output_buf
extern output_len
extern worklog_buf
extern worklog_ctx_len

extern worklog_append_entry
extern worklog_append_raw
extern str_len
extern str_copy

global channel_init
global channel_route
global channel_set_mask
global channel_is_active
global channel_write_debug
global channel_write_error
global channel_flush_all

; ============================================================================
section .data
; ============================================================================

; Per-channel buffers (small, for intermediate storage)
channel_debug_buf:  times 4096 db 0
channel_error_buf:  times 4096 db 0
channel_event_buf:  times 4096 db 0

; Channel write pointers
channel_debug_ptr:  dq channel_debug_buf
channel_error_ptr:  dq channel_error_buf
channel_event_ptr:  dq channel_event_buf

; ============================================================================
section .rodata
; ============================================================================

; Channel names
channel_names:
    dq ch_name_soprano
    dq ch_name_alto
    dq ch_name_tenor
    dq ch_name_bass
    dq ch_name_harp
    dq ch_name_timpani

ch_name_soprano: db 'Soprano', 0
ch_name_alto:    db 'Alto', 0
ch_name_tenor:   db 'Tenor', 0
ch_name_bass:    db 'Bass', 0
ch_name_harp:    db 'Harp', 0
ch_name_timpani: db 'Timpani', 0

; ============================================================================
section .text
; ============================================================================

; ============================================================================
; channel_init — Initialize channel system
; ============================================================================
channel_init:
    push    rbp
    mov     rbp, rsp

    ; Set default active channels: soprano + bass
    lea     rax, [rel musical_state]
    mov     byte [rax + MS_ACTIVE_CHANNELS], CH_MASK_SOPRANO | CH_MASK_BASS

    ; Reset write pointers
    lea     rax, [rel channel_debug_buf]
    mov     [rel channel_debug_ptr], rax
    lea     rax, [rel channel_error_buf]
    mov     [rel channel_error_ptr], rax
    lea     rax, [rel channel_event_buf]
    mov     [rel channel_event_ptr], rax

    pop     rbp
    ret

; ============================================================================
; channel_route — Route data to appropriate channel(s)
; ============================================================================
; Input:  rdi = data pointer
;         rsi = data length
;         dl  = channel type (CH_SOPRANO, CH_BASS, etc.)
; ============================================================================
channel_route:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rdi            ; r12 = data pointer
    mov     r13, rsi            ; r13 = data length
    mov     r14, rdx            ; r14 = channel type

    ; Check if channel is active
    lea     rbx, [rel musical_state]
    movzx   eax, byte [rbx + MS_ACTIVE_CHANNELS]
    bt      eax, r14d
    jnc     .route_done         ; channel not active

    ; Route based on channel type
    cmp     r14d, CH_SOPRANO
    je      .route_soprano
    cmp     r14d, CH_BASS
    je      .route_bass
    cmp     r14d, CH_TENOR
    je      .route_tenor
    cmp     r14d, CH_HARP
    je      .route_harp
    cmp     r14d, CH_TIMPANI
    je      .route_timpani
    jmp     .route_done

.route_soprano:
    ; Primary output — already handled by TUI display
    ; Just pass through
    jmp     .route_done

.route_bass:
    ; Persistent log — append to worklog
    mov     rdi, r12
    mov     rsi, r13
    call    worklog_append_raw
    jmp     .route_done

.route_tenor:
    ; Debug output — append to debug buffer
    lea     rdi, [rel channel_debug_ptr]
    mov     rdi, [rdi]
    mov     rsi, r12
    mov     rdx, r13
    ; Clamp to buffer size
    lea     rax, [rel channel_debug_buf]
    add     rax, 4096
    sub     rax, rdi
    cmp     rdx, rax
    jle     .tenor_ok
    mov     rdx, rax
.tenor_ok:
    ; Simple copy
    push    rcx
    mov     rcx, rdx
.tenor_copy:
    test    rcx, rcx
    jz      .tenor_done
    movzx   eax, byte [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     rcx
    jmp     .tenor_copy
.tenor_done:
    pop     rcx
    mov     [rel channel_debug_ptr], rdi
    jmp     .route_done

.route_harp:
    ; Error stream — append to error buffer
    lea     rdi, [rel channel_error_ptr]
    mov     rdi, [rdi]
    mov     rsi, r12
    mov     rdx, r13
    lea     rax, [rel channel_error_buf]
    add     rax, 4096
    sub     rax, rdi
    cmp     rdx, rax
    jle     .harp_ok
    mov     rdx, rax
.harp_ok:
    push    rcx
    mov     rcx, rdx
.harp_copy:
    test    rcx, rcx
    jz      .harp_done
    movzx   eax, byte [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     rcx
    jmp     .harp_copy
.harp_done:
    pop     rcx
    mov     [rel channel_error_ptr], rdi
    jmp     .route_done

.route_timpani:
    ; Signal/event stream — append to event buffer
    lea     rdi, [rel channel_event_ptr]
    mov     rdi, [rdi]
    mov     rsi, r12
    mov     rdx, r13
    lea     rax, [rel channel_event_buf]
    add     rax, 4096
    sub     rax, rdi
    cmp     rdx, rax
    jle     .timpani_ok
    mov     rdx, rax
.timpani_ok:
    push    rcx
    mov     rcx, rdx
.timpani_copy:
    test    rcx, rcx
    jz      .timpani_done
    movzx   eax, byte [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     rcx
    jmp     .timpani_copy
.timpani_done:
    pop     rcx
    mov     [rel channel_event_ptr], rdi

.route_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; ============================================================================
; channel_set_mask — Set active channel bitmask
; ============================================================================
; Input:  al = new channel bitmask
; ============================================================================
channel_set_mask:
    lea     rcx, [rel musical_state]
    mov     [rcx + MS_ACTIVE_CHANNELS], al
    ret

; ============================================================================
; channel_is_active — Check if a channel is active
; ============================================================================
; Input:  rdi = channel index (0-5)
; Returns: rax = 1 if active, 0 otherwise
; ============================================================================
channel_is_active:
    lea     rcx, [rel musical_state]
    movzx   eax, byte [rcx + MS_ACTIVE_CHANNELS]
    bt      eax, edi
    setc    al
    movzx   eax, al
    ret

; ============================================================================
; channel_write_debug — Write to debug channel
; ============================================================================
; Input:  rdi = data pointer, rsi = data length
; ============================================================================
channel_write_debug:
    mov     rdx, CH_TENOR
    jmp     channel_route

; ============================================================================
; channel_write_error — Write to error channel
; ============================================================================
; Input:  rdi = data pointer, rsi = data length
; ============================================================================
channel_write_error:
    mov     rdx, CH_HARP
    jmp     channel_route

; ============================================================================
; channel_flush_all — Flush all buffered channel data
; ============================================================================
channel_flush_all:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12

    ; Flush error buffer (Harp) -> stderr
    lea     r12, [rel channel_error_buf]
    mov     rbx, [rel channel_error_ptr]
    sub     rbx, r12
    test    rbx, rbx
    jz      .fl_e_done
    mov     rax, SYS_WRITE
    mov     edi, STDERR
    lea     rsi, [rel channel_error_buf]
    mov     rdx, rbx
    syscall
    lea     rax, [rel channel_error_buf]
    mov     [rel channel_error_ptr], rax
.fl_e_done:

    ; Flush debug buffer (Tenor) -> stderr
    lea     r12, [rel channel_debug_buf]
    mov     rbx, [rel channel_debug_ptr]
    sub     rbx, r12
    test    rbx, rbx
    jz      .fl_d_done
    mov     rax, SYS_WRITE
    mov     edi, STDERR
    lea     rsi, [rel channel_debug_buf]
    mov     rdx, rbx
    syscall
    lea     rax, [rel channel_debug_buf]
    mov     [rel channel_error_ptr], rax
.fl_d_done:

    ; Flush event buffer (Timpani) -> worklog
    lea     r12, [rel channel_event_buf]
    mov     rbx, [rel channel_event_ptr]
    sub     rbx, r12
    test    rbx, rbx
    jz      .fl_v_done
    mov     byte [r12 + rbx], 0
    lea     rdi, [rel channel_event_buf]
    call    worklog_append_raw
    lea     rax, [rel channel_event_buf]
    mov     [rel channel_event_ptr], rax
.fl_v_done:

    pop     r12
    pop     rbx
    pop     rbp
    ret
