; ============================================================================
; tool_fetch_page.asm — VisiBox fetch_page Tool
; ============================================================================
; Uses saved response_id + cursor from last execute to get next page.
;
; Args:    none (reads vb_saved_response_id, vb_saved_cursor)
; Returns:  eax = 0 success, 1 error
;          output_buf = next page of output
;          output_len = length
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

extern output_buf
extern output_len
extern use_visibox
extern visibox_response_raw
extern vb_saved_response_id
extern vb_saved_cursor

extern str_find
extern str_len
extern str_copy

extern vb_build_fetch_page
extern vb_send_recv
extern vb_extract_string
extern vb_get_response_id
extern vb_get_cursor
extern vb_get_has_next

global tool_fetch_page_handler

section .rodata
no_cursor_msg  db 'No pagination cursor available. Run a command first.', 0
page_end_msg   db 'No more pages available.', 0

section .text

tool_fetch_page_handler:
    push    rbp
    mov     rbp, rsp
    push    rbx

    cmp     byte [rel use_visibox], 1
    jne     .no_visibox

    ; Check if we have a cursor
    cmp     byte [rel vb_saved_cursor], 0
    je      .no_cursor

    ; 1. Build fetch_page JSON
    call    vb_build_fetch_page

    ; 2. Send/receive
    call    vb_send_recv
    test    eax, eax
    js      .fetch_err

    ; 3. Check for error
    lea     rdi, [rel visibox_response_raw]
    lea     rsi, [rel vb_key_err]
    call    str_find
    test    rax, rax
    jz      .no_fetch_error

    ; Error — maybe cursor expired
    lea     rdi, [rel output_buf]
    lea     rsi, [rel page_end_msg]
    call    str_copy
    mov     [rel output_len], rax
    mov     eax, 1
    jmp     .done

.no_fetch_error:
    ; 4. Extract output
    lea     rdi, [rel vb_key_output]
    call    vb_extract_string
    mov     [rel output_len], r14

    ; 5. Update metadata (new cursor for next page)
    call    vb_get_response_id
    call    vb_get_cursor
    call    vb_get_has_next

    xor     eax, eax
    jmp     .done

.no_cursor:
    lea     rdi, [rel output_buf]
    lea     rsi, [rel no_cursor_msg]
    call    str_copy
    mov     [rel output_len], rax
    mov     eax, 1
    jmp     .done

.no_visibox:
.fetch_err:
    mov     eax, 1

.done:
    pop     rbx
    pop     rbp
    ret