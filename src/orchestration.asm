; ============================================================================
; orchestration.asm — ASM-AGENT Orchestration (Simplified for Tool Calls)
; ============================================================================
; Tool calls architecture removes the need for HANDOFF/mode system.
; This module now provides only:
;   - orchestration_init: clear state
;   - orchestration_log_state: log current iteration state
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"
%include "musical.inc"
%include "orchestration.inc"

; --- External data ---
extern musical_state
extern temp_buf
extern timestamp_buf
extern iteration_count
extern task_buf
extern command_buf

; --- External functions ---
extern str_len
extern str_copy
extern str_concat
extern uint_to_str
extern get_timestamp
extern worklog_append_entry
extern worklog_append_raw

; --- Export ---
global orchestration_init
global orchestration_log_state
global current_mode
global checkpoint_data

; ============================================================================
section .data
; ============================================================================

current_mode:   db 0    ; Unused but kept for checkpoint compatibility

; Checkpoint data (64 bytes)
checkpoint_data: times CP_SIZE db 0

; ============================================================================
section .rodata
; ============================================================================

wl_orch_state:  db 'ORCHESTRATION', 0
orch_fmt:       db 'Iter: ', 0

; ============================================================================
section .text
; ============================================================================

; ============================================================================
; orchestration_init — Initialize orchestration system
; ============================================================================
orchestration_init:
    push    rbp
    mov     rbp, rsp

    xor     al, al
    lea     rdi, [rel checkpoint_data]
    mov     rcx, CP_SIZE
    rep     stosb

    pop     rbp
    ret

; ============================================================================
; orchestration_log_state — Log current iteration state to worklog
; ============================================================================
orchestration_log_state:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12

    lea     r12, [rel temp_buf]

    ; Build: "Iter: N\n"
    mov     rdi, r12
    lea     rsi, [rel orch_fmt]
    call    .copy_str

    ; Append iteration number
    mov     eax, [iteration_count]
    push    rbx
    mov     rbx, rdi
    sub     rsp, 16
    mov     rdi, rsp
    mov     esi, eax
    call    uint_to_str
    mov     rdi, rbx
    mov     rsi, rsp
    call    .copy_str
    add     rsp, 16
    pop     rbx

    ; Newline + null
    mov     byte [r12], 10
    inc     r12
    mov     byte [r12], 0

    ; Write to worklog
    lea     rdi, [rel wl_orch_state]
    lea     rsi, [rel temp_buf]
    call    worklog_append_raw

    pop     r12
    pop     rbx
    pop     rbp
    ret

; --- Helper: copy string to rdi, advance r12 ---
.copy_str:
.cs_loop:
    lodsb
    test    al, al
    jz      .cs_done
    mov     [rdi], al
    inc     rdi
    inc     r12
    jmp     .cs_loop
.cs_done:
    ret