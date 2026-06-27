; ============================================================================
; tool_search.asm — VisiBox search_jump Tool
; ============================================================================
; Searches for a keyword in the last command's output, jumps to the page
; containing that keyword.
;
; Args:    none (reads command_buf = keyword, vb_saved_response_id)
; Returns:  eax = 0 success, 1 error
;          output_buf = the page containing the keyword (with context)
;          output_len = length
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

extern command_buf
extern output_buf
extern output_len
extern visibox_response_raw
extern vb_saved_response_id

extern str_find
extern str_len
extern str_copy

extern vb_build_search
extern vb_send_recv
extern vb_extract_string
extern vb_get_response_id
extern vb_get_cursor
extern vb_get_has_next

global tool_search_handler

section .rodata
no_resp_msg db 'No command response to search. Run a command first.', 0
no_keyword_msg db 'Empty keyword for search.', 0

section .text

tool_search_handler:
    push    rbp
    mov     rbp, rsp

    ; Check we have a response_id
    cmp     byte [rel vb_saved_response_id], 0
    je      .no_response

    ; Check keyword not empty
    cmp     byte [rel command_buf], 0
    je      .no_keyword

    ; 1. Build search JSON (command_buf = keyword)
    call    vb_build_search

    ; 2. Send/receive
    call    vb_send_recv
    test    eax, eax
    js      .err

    ; 3. Check for error
    lea     rdi, [rel visibox_response_raw]
    lea     rsi, [rel vb_key_err]
    call    str_find
    test    rax, rax
    jnz     .err

    ; 4. Extract output (the page with the keyword + context)
    lea     rdi, [rel vb_key_output]
    call    vb_extract_string
    mov     [rel output_len], r14

    ; 5. Update metadata
    call    vb_get_response_id
    call    vb_get_cursor
    call    vb_get_has_next

    xor     eax, eax
    jmp     .done

.no_response:
    lea     rdi, [rel output_buf]
    lea     rsi, [rel no_resp_msg]
    call    str_copy
    mov     [rel output_len], rax
    mov     eax, 1
    jmp     .done

.no_keyword:
    lea     rdi, [rel output_buf]
    lea     rsi, [rel no_keyword_msg]
    call    str_copy
    mov     [rel output_len], rax
    mov     eax, 1
    jmp     .done

.err:
    mov     eax, 1

.done:
    pop     rbp
    ret