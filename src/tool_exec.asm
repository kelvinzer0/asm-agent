; ============================================================================
; tool_exec.asm — Execute Tool (VisiBox ONLY — no fallback)
; ============================================================================
; Uses visibox_client for JSON protocol. VisiBox is REQUIRED.
;
; Args:    none (reads command_buf)
; Returns:  eax = exit code
;          output_buf = command output, output_len = length
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

extern vb_build_execute
extern vb_send_recv
extern vb_extract_string
extern vb_parse_int
extern vb_get_response_id
extern vb_get_cursor
extern vb_get_has_next
extern check_blocked

global tool_exec_handler

section .text

tool_exec_handler:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12

    ; --- Check blocked commands ---
    call    check_blocked
    test    eax, eax
    jnz     .blocked

    ; 1. Build JSON with options (output_limit, line_numbers)
    call    vb_build_execute

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

    ; VisiBox returned an error — put message in output_buf
    lea     rdi, [rel output_buf]
    lea     rsi, [rel vb_type_error]
    call    str_copy
    mov     [rel output_len], rax
    mov     eax, 1
    jmp     .done

.no_vb_error:
    ; 4. Extract output
    lea     rdi, [rel vb_key_output]
    call    vb_extract_string
    mov     [rel output_len], r14

    ; 4b. If output is empty, add hint so the model understands
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

    ; 6. Save pagination metadata
    call    vb_get_response_id
    call    vb_get_cursor
    call    vb_get_has_next

    jmp     .done

.visibox_failed:
    ; VisiBox pipe/fork failed — report as error
    lea     rdi, [rel output_buf]
    lea     rsi, [rel vb_type_error]
    call    str_copy
    mov     [rel output_len], rax
    mov     eax, 1
    jmp     .done

.blocked:
    lea     rdi, [rel output_buf]
    lea     rsi, [rel vb_type_error]
    call    str_copy
    mov     [rel output_len], rax
    mov     eax, 1

.done:
    pop     r12
    pop     rbx
    pop     rbp
    ret