; ============================================================================
; tool_session.asm — VisiBox Session Tool (Persistent Shell)
; ============================================================================
; Uses VisiBox daemon mode to run commands in a persistent shell where
; cd, export, alias, and other state-changing operations are kept across
; invocations. VisiBox is REQUIRED — no fallback.
;
; Args:    none (reads command_buf = command to run in persistent shell)
; Returns:  eax = exit code (0 success, 1 error)
;          output_buf = command output, output_len = length
;
; The session handler is structurally similar to tool_exec but sends
; {"type":"session",...} instead of {"type":"execute",...} to VisiBox.
; The daemon maintains shell state between calls.
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

extern command_buf
extern output_buf
extern output_len
extern visibox_response_raw
extern saved_envp
extern wait_status
extern pipe_fds

extern str_find
extern str_len
extern str_copy

extern vb_build_session
extern vb_send_recv
extern vb_extract_string
extern vb_parse_int
extern vb_get_response_id
extern vb_get_cursor
extern vb_get_has_next
extern check_blocked

global tool_session_handler

section .rodata
session_err_msg db 'SESSION: VisiBox error.', 0

section .text

tool_session_handler:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12

    ; --- Check blocked commands (same safety filter as EXEC) ---
    call    check_blocked
    test    eax, eax
    jnz     .blocked

    ; 1. Build session JSON with options
    call    vb_build_session

    ; 2. Send/receive via visibox
    call    vb_send_recv
    test    eax, eax
    js      .visibox_failed

    ; 3. Check for error response
    lea     rdi, [rel visibox_response_raw]
    lea     rsi, [rel vb_key_err]
    call    str_find
    test    rax, rax
    jz      .no_vb_error

    ; VisiBox returned an error
    lea     rdi, [rel output_buf]
    lea     rsi, [rel session_err_msg]
    call    str_copy
    mov     [rel output_len], rax
    mov     eax, 1
    jmp     .done

.no_vb_error:
    ; 4. Extract output
    lea     rdi, [rel vb_key_output]
    call    vb_extract_string
    mov     [rel output_len], r14

    ; 4b. If output is empty, add hint
    test    r14, r14
    jnz     .has_output
    lea     rdi, [rel output_buf]
    lea     rsi, [rel vb_empty_output]
    call    str_copy
    mov     [rel output_len], rax
.has_output:

    ; 5. Extract exit_code
    lea     rdi, [rel vb_key_exit_code]
    call    vb_parse_int

    ; 6. Save pagination metadata (session responses can be large too)
    call    vb_get_response_id
    call    vb_get_cursor
    call    vb_get_has_next

    jmp     .done

.visibox_failed:
    ; VisiBox send/recv failed — report error
    lea     rdi, [rel output_buf]
    lea     rsi, [rel session_err_msg]
    call    str_copy
    mov     [rel output_len], rax
    mov     eax, 1
    jmp     .done

.blocked:
    lea     rdi, [rel output_buf]
    lea     rsi, [rel session_err_msg]
    call    str_copy
    mov     [rel output_len], rax
    mov     eax, 1

.done:
    pop     r12
    pop     rbx
    pop     rbp
    ret