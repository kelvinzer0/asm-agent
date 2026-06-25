; ============================================================================
; parser.asm — ASM-AGENT API Response Parser
; ============================================================================
; Parses the JSON response from the Chat Completions API to extract the
; assistant's "content" string, unescape it, and classify the action type.
;
; Input:
;   response_buf  = raw JSON response from API
;   response_len  = number of bytes in response_buf
;
; Output (in command_buf):
;   The text AFTER the "PREFIX:" tag (with leading spaces stripped).
;   e.g., for "EXEC: ls -la" -> command_buf = "ls -la"
;
; Return value (rax):
;   ACTION_EXEC  (0)  — command_buf has shell command to execute
;   ACTION_THINK (1)  — command_buf has reasoning text
;   ACTION_DONE  (2)  — command_buf has completion summary
;   ACTION_ERROR (-1) — parse failure or API error
;
; Register convention:
;   r12 = write pointer into command_buf during extraction
;   r13 = read pointer during content scanning
;   r14 = end boundary (response_buf + response_len)
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

; ---------------------------------------------------------------------------
; External data
; ---------------------------------------------------------------------------
extern response_buf             ; resb RESPONSE_BUF_SZ (262144)
extern response_len             ; resq 1
extern command_buf              ; resb COMMAND_BUF_SZ  (8192)

; ---------------------------------------------------------------------------
; External functions (defined in string.asm)
; ---------------------------------------------------------------------------
extern str_find                 ; rdi=haystack, rsi=needle -> rax=ptr or 0
extern str_starts_with          ; rdi=str, rsi=prefix -> rax=1/0
extern str_len                  ; rdi=str -> rax=length
extern str_copy                 ; rdi=dst, rsi=src -> rax=bytes copied
extern handoff_prefix           ; "HANDOFF:" string from orchestration.inc

; ---------------------------------------------------------------------------
; Export
; ---------------------------------------------------------------------------
global parse_response

; ============================================================================
; Read-only data for search needles and action prefixes
; ============================================================================
section .rodata

; JSON field keys to search for
needle_content: db '"content"', 0
needle_error:   db '"error"', 0
needle_done_suffix: db 'data:', 0

; XML tool_call tags
needle_tool_open:  db '<tool_call>', 0
needle_tool_close: db '</tool_call>', 0

; Action prefixes (fallback for non-XML responses)
prefix_exec:    db 'EXEC:', 0
prefix_think:   db 'THINK:', 0
prefix_done:    db 'DONE:', 0
prefix_next_page: db 'NEXT_PAGE:', 0

; ============================================================================
section .text
; ============================================================================

; ============================================================================
; parse_response — Parse API JSON, extract content, classify action
; ============================================================================
; Returns:
;   rax = ACTION_EXEC | ACTION_THINK | ACTION_DONE | ACTION_ERROR
;   command_buf is filled with the payload text (after prefix stripping)
; ============================================================================
parse_response:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbx

    ; -------------------------------------------------------------------
    ; Step 0: Strip "data: [DONE]" suffix if present
    ; -------------------------------------------------------------------
    lea     rdi, [rel response_buf]
    lea     rsi, [rel needle_done_suffix]
    call    str_find
    test    rax, rax
    jz      .no_strip_done
    ; Found "data:" — truncate response_buf here
    mov     byte [rax], 0
    ; Update response_len
    sub     rax, rdi
    mov     [rel response_len], rax
.no_strip_done:

    ; -------------------------------------------------------------------
    ; Step 1: Find "content" key in response_buf
    ; -------------------------------------------------------------------
    lea     rdi, [rel response_buf]
    lea     rsi, [rel needle_content]
    call    str_find            ; rax = pointer to '"content"' or 0

    test    rax, rax
    jz      .check_error        ; "content" not found — check for API error

    ; -------------------------------------------------------------------
    ; Step 2: Advance past the '"content"' string (9 bytes)
    ; -------------------------------------------------------------------
    add     rax, 9              ; skip past: "content"  (9 chars including quotes)
    mov     r13, rax            ; r13 = current read position

    ; Compute end boundary
    lea     rax, [rel response_buf]
    add     rax, [rel response_len]
    mov     r14, rax            ; r14 = one-past-end of response

    ; -------------------------------------------------------------------
    ; Step 3: Skip whitespace and the ':' delimiter
    ; -------------------------------------------------------------------
.skip_colon_ws:
    cmp     r13, r14
    jge     .return_error       ; ran off end of buffer
    movzx   eax, byte [r13]
    cmp     al, ' '
    je      .advance_skip1
    cmp     al, 9               ; tab
    je      .advance_skip1
    cmp     al, ':'
    je      .advance_skip1
    cmp     al, 10              ; newline
    je      .advance_skip1
    cmp     al, 13              ; carriage return
    je      .advance_skip1
    jmp     .check_value_type   ; found a non-whitespace, non-colon char

.advance_skip1:
    inc     r13
    jmp     .skip_colon_ws

    ; -------------------------------------------------------------------
    ; Step 4: Determine value type
    ; -------------------------------------------------------------------
.check_value_type:
    movzx   eax, byte [r13]

    cmp     al, '"'             ; opening quote of string value
    je      .extract_string

    cmp     al, 'n'             ; likely "null"
    je      .return_error

    ; Anything else (number, array, object) is unexpected
    jmp     .return_error

    ; -------------------------------------------------------------------
    ; Step 5: Extract and unescape the JSON string value
    ; -------------------------------------------------------------------
.extract_string:
    inc     r13                 ; skip past the opening '"'

    lea     r12, [rel command_buf]  ; r12 = write pointer into command_buf
    lea     r15, [rel command_buf]
    add     r15, COMMAND_BUF_SZ
    sub     r15, 2              ; r15 = safe write limit (leave room for null)

.extract_loop:
    cmp     r13, r14            ; past end of response?
    jge     .extract_done       ; truncated string — take what we have

    cmp     r12, r15            ; command_buf about to overflow?
    jge     .extract_done       ; truncate gracefully

    movzx   eax, byte [r13]
    inc     r13                 ; advance read pointer

    ; --- Check for backslash escape ---
    cmp     al, '\'
    je      .handle_escape

    ; --- Check for closing quote ---
    cmp     al, '"'
    je      .extract_done

    ; --- Ordinary character: copy as-is ---
    mov     [r12], al
    inc     r12
    jmp     .extract_loop

    ; --- Handle JSON escape sequences ---
.handle_escape:
    cmp     r13, r14            ; need at least one more byte
    jge     .extract_done

    movzx   eax, byte [r13]    ; read the char after backslash
    inc     r13

    cmp     al, '"'
    je      .esc_quote
    cmp     al, '\'
    je      .esc_backslash
    cmp     al, 'n'
    je      .esc_newline
    cmp     al, 't'
    je      .esc_tab
    cmp     al, 'r'
    je      .esc_cr
    cmp     al, '/'
    je      .esc_slash
    cmp     al, 'b'
    je      .esc_backspace
    cmp     al, 'f'
    je      .esc_formfeed

    ; Unknown escape: write the character as-is (best effort)
    mov     [r12], al
    inc     r12
    jmp     .extract_loop

.esc_quote:
    mov     byte [r12], '"'
    inc     r12
    jmp     .extract_loop

.esc_backslash:
    mov     byte [r12], '\'
    inc     r12
    jmp     .extract_loop

.esc_newline:
    mov     byte [r12], 10      ; ASCII LF
    inc     r12
    jmp     .extract_loop

.esc_tab:
    mov     byte [r12], 9       ; ASCII TAB
    inc     r12
    jmp     .extract_loop

.esc_cr:
    mov     byte [r12], 13      ; ASCII CR
    inc     r12
    jmp     .extract_loop

.esc_slash:
    mov     byte [r12], '/'
    inc     r12
    jmp     .extract_loop

.esc_backspace:
    mov     byte [r12], 8       ; ASCII BS
    inc     r12
    jmp     .extract_loop

.esc_formfeed:
    mov     byte [r12], 12      ; ASCII FF
    inc     r12
    jmp     .extract_loop

.extract_done:
    ; Null-terminate command_buf
    mov     byte [r12], 0

    ; -------------------------------------------------------------------
    ; Step 6: Classify the extracted content
    ; -------------------------------------------------------------------

    ; --- Check <tool_call> first (strict mode) ---
    lea     rdi, [rel command_buf]
    lea     rsi, [rel needle_tool_open]
    call    str_find
    test    rax, rax
    jz      .no_toolcall

    ; Found <tool_call> — extract command from inside
    mov     r13, rax            ; r13 = pointer to 
    add     r13, 11             ; skip past <tool_call> (11 bytes)

    ; Skip whitespace/newline after opening tag
.tool_skip_ws:
    cmp     r13, r14
    jge     .no_toolcall
    movzx   eax, byte [r13]
    cmp     al, ' '
    je      .tool_ws_ok
    cmp     al, 10
    je      .tool_ws_ok
    cmp     al, 13
    je      .tool_ws_ok
    cmp     al, 9
    je      .tool_ws_ok
    jmp     .tool_copy_cmd
.tool_ws_ok:
    inc     r13
    jmp     .tool_skip_ws

.tool_copy_cmd:
    ; Copy until </tool_call> or newline
    lea     r12, [rel command_buf]
.tool_copy_loop:
    cmp     r13, r14
    jge     .tool_done
    movzx   eax, byte [r13]

    ; Check for </tool_call>
    cmp     al, '<'
    jne     .tool_store
    ; Peek ahead for </
    lea     rcx, [r13 + 1]
    cmp     rcx, r14
    jge     .tool_store
    cmp     byte [rcx], '/'
    jne     .tool_store
    ; Check for </tool
    lea     rcx, [r13 + 2]
    cmp     rcx, r14
    jge     .tool_store
    cmp     byte [rcx], 't'
    jne     .tool_store
    jmp     .tool_done

.tool_store:
    cmp     al, 10
    je      .tool_done
    cmp     al, 13
    je      .tool_done
    ; Buffer overflow check
    lea     rcx, [rel command_buf]
    add     rcx, COMMAND_BUF_SZ - 2
    cmp     r12, rcx
    jge     .tool_done
    mov     [r12], al
    inc     r12
    inc     r13
    jmp     .tool_copy_loop

.tool_done:
    mov     byte [r12], 0       ; null-terminate
    mov     eax, ACTION_EXEC    ; tool_call = EXEC
    jmp     .epilogue

.no_toolcall:
    ; --- No XML tags: use prefix detection (model natural behavior) ---

    ; --- Check EXEC: (search anywhere in response) ---
    lea     rdi, [rel command_buf]
    lea     rsi, [rel prefix_exec]
    call    str_find
    test    rax, rax
    jnz     .found_exec

    ; --- Check THINK: (search anywhere) ---
    lea     rdi, [rel command_buf]
    lea     rsi, [rel prefix_think]
    call    str_find
    test    rax, rax
    jnz     .found_think

    ; --- Check DONE: (search anywhere) ---
    lea     rdi, [rel command_buf]
    lea     rsi, [rel prefix_done]
    call    str_find
    test    rax, rax
    jnz     .found_done

    ; --- Check HANDOFF: (search anywhere) ---
    lea     rdi, [rel command_buf]
    lea     rsi, [rel handoff_prefix]
    call    str_find
    test    rax, rax
    jnz     .found_handoff

    ; --- Check NEXT_PAGE: (search anywhere) ---
    lea     rdi, [rel command_buf]
    lea     rsi, [rel prefix_next_page]
    call    str_find
    test    rax, rax
    jnz     .found_next_page

    ; --- No recognized prefix: default to THINK ---

.fallback_think:
    mov     eax, ACTION_THINK
    jmp     .epilogue

    ; ---------------------------------------------------------------
    ; Found prefix somewhere in response — extract from that point
    ; ---------------------------------------------------------------
.found_exec:
    ; rax points to "EXEC:" in command_buf
    ; Extract from "EXEC:" to end of line
    mov     r13, rax            ; r13 = pointer to "EXEC:"
    lea     rdi, [rel prefix_exec]
    call    str_len
    mov     rbx, rax            ; rbx = prefix length (5)
    add     r13, rbx            ; r13 = past "EXEC:"
    mov     r15d, ACTION_EXEC
    jmp     .extract_from_ptr

.found_think:
    mov     r13, rax
    lea     rdi, [rel prefix_think]
    call    str_len
    mov     rbx, rax
    add     r13, rbx
    mov     r15d, ACTION_THINK
    jmp     .extract_from_ptr

.found_done:
    mov     r13, rax
    lea     rdi, [rel prefix_done]
    call    str_len
    mov     rbx, rax
    add     r13, rbx
    mov     r15d, ACTION_DONE
    jmp     .extract_from_ptr

.found_handoff:
    ; Handoff is handled by orchestration_check_handoff
    ; For now, treat as THINK
    mov     eax, ACTION_THINK
    jmp     .epilogue

.found_next_page:
    ; NEXT_PAGE doesn't need extracted content — just return the action
    mov     eax, ACTION_NEXT_PAGE
    jmp     .epilogue

    ; ---------------------------------------------------------------
    ; Extract from pointer: copy until newline or null
    ; For EXEC: stop at first space that starts explanatory text
    ; ---------------------------------------------------------------
.extract_from_ptr:
    ; Skip whitespace after prefix
.find_cmd_skip_ws:
    movzx   eax, byte [r13]
    cmp     al, ' '
    je      .find_cmd_ws_ok
    cmp     al, 9               ; tab
    je      .find_cmd_ws_ok
    cmp     al, 10              ; newline
    je      .find_cmd_ws_ok
    cmp     al, 13              ; CR
    je      .find_cmd_ws_ok
    jmp     .find_cmd_copy
.find_cmd_ws_ok:
    inc     r13
    jmp     .find_cmd_skip_ws

.find_cmd_copy:
    ; Copy from r13 to command_buf until newline or null
    lea     r12, [rel command_buf]

.find_cmd_loop:
    movzx   eax, byte [r13]
    test    al, al
    jz      .find_cmd_done
    cmp     al, 10              ; newline = end
    je      .find_cmd_done
    cmp     al, 13              ; CR = end
    je      .find_cmd_done
    ; Check buffer overflow
    lea     rcx, [rel command_buf]
    add     rcx, COMMAND_BUF_SZ - 2
    cmp     r12, rcx
    jge     .find_cmd_done
    mov     [r12], al
    inc     r12
    inc     r13
    jmp     .find_cmd_loop

.find_cmd_done:
    mov     byte [r12], 0       ; null terminate

    ; --- Post-process: strip common explanation patterns for EXEC ---
    cmp     r15d, ACTION_EXEC
    jne     .find_cmd_return

    ; Find common explanation markers: " to ", " for ", " and "
    lea     rdi, [rel command_buf]
    call    str_len
    test    rax, rax
    jz      .find_cmd_return

    ; Scan for " to " pattern
    lea     rdi, [rel command_buf]
    mov     ecx, eax            ; ecx = string length
.scan_explain:
    test    ecx, ecx
    jz      .find_cmd_return
    cmp     byte [rdi], ' '
    jne     .scan_next
    cmp     byte [rdi + 1], 't'
    jne     .scan_next
    cmp     byte [rdi + 2], 'o'
    jne     .scan_next
    cmp     byte [rdi + 3], ' '
    jne     .scan_next
    ; Found " to " — check if followed by common explanation words
    movzx   eax, byte [rdi + 4]
    ; 'v' = verify, 'c' = check/create, 'l' = list, 'r' = run
    cmp     al, 'v'
    je      .strip_explanation
    cmp     al, 'c'
    je      .strip_explanation
    cmp     al, 'l'
    je      .strip_explanation
    cmp     al, 'r'
    je      .strip_explanation
    cmp     al, 's'
    je      .strip_explanation    ; "to see"
    cmp     al, 'g'
    je      .strip_explanation    ; "to get"
    cmp     al, 'd'
    je      .strip_explanation    ; "to determine"
    jmp     .scan_next

.strip_explanation:
    ; Truncate at this space (make it null terminator)
    mov     byte [rdi], 0
    jmp     .find_cmd_return

.scan_next:
    inc     rdi
    dec     ecx
    jmp     .scan_explain

.find_cmd_return:
    mov     eax, r15d           ; return action type
    jmp     .epilogue

    ; ---------------------------------------------------------------
    ; Prefix matched — strip "PREFIX: " from command_buf
    ; ---------------------------------------------------------------
.matched_exec:
    lea     rdi, [rel prefix_exec]
    call    str_len             ; rax = length of "EXEC:"
    mov     rbx, rax            ; rbx = prefix length (5 for "EXEC:")
    mov     r15d, ACTION_EXEC
    jmp     .strip_prefix

.matched_think:
    lea     rdi, [rel prefix_think]
    call    str_len
    mov     rbx, rax
    mov     r15d, ACTION_THINK
    jmp     .strip_prefix

.matched_done:
    lea     rdi, [rel prefix_done]
    call    str_len
    mov     rbx, rax
    mov     r15d, ACTION_DONE
    ; fall through to .strip_prefix

    ; ---------------------------------------------------------------
    ; strip_prefix — Remove prefix and leading spaces, shift content
    ; to the beginning of command_buf.
    ;
    ; rbx = number of prefix bytes to skip (e.g. 5 for "EXEC:")
    ; r15d = action type to return
    ; ---------------------------------------------------------------
.strip_prefix:
    lea     r13, [rel command_buf]
    add     r13, rbx            ; r13 = pointer past the prefix (past ':')

    ; Skip any spaces after the colon
.skip_spaces:
    movzx   eax, byte [r13]
    cmp     al, ' '
    jne     .do_shift
    inc     r13
    jmp     .skip_spaces

.do_shift:
    ; Copy char-by-char until newline or null (not str_copy which goes to null)
    lea     r12, [rel command_buf]  ; r12 = write pointer

.do_shift_loop:
    movzx   eax, byte [r13]
    test    al, al
    jz      .do_shift_done
    cmp     al, 10              ; newline = end
    je      .do_shift_done
    cmp     al, 13              ; CR = end
    je      .do_shift_done
    ; Check buffer overflow
    lea     rcx, [rel command_buf]
    add     rcx, COMMAND_BUF_SZ - 2
    cmp     r12, rcx
    jge     .do_shift_done
    mov     [r12], al
    inc     r12
    inc     r13
    jmp     .do_shift_loop

.do_shift_done:
    mov     byte [r12], 0       ; null-terminate

    ; --- Post-process: strip common explanation patterns for EXEC ---
    cmp     r15d, ACTION_EXEC
    jne     .strip_backticks

    lea     rdi, [rel command_buf]
    call    str_len
    test    rax, rax
    jz      .strip_backticks

    lea     rdi, [rel command_buf]
    mov     ecx, eax
.scan_explain2:
    test    ecx, ecx
    jz      .strip_backticks
    cmp     byte [rdi], ' '
    jne     .scan_next2
    cmp     byte [rdi + 1], 't'
    jne     .scan_next2
    cmp     byte [rdi + 2], 'o'
    jne     .scan_next2
    cmp     byte [rdi + 3], ' '
    jne     .scan_next2
    movzx   eax, byte [rdi + 4]
    cmp     al, 'v'
    je      .strip_expl2
    cmp     al, 'c'
    je      .strip_expl2
    cmp     al, 'l'
    je      .strip_expl2
    cmp     al, 'r'
    je      .strip_expl2
    cmp     al, 's'
    je      .strip_expl2
    cmp     al, 'g'
    je      .strip_expl2
    cmp     al, 'd'
    je      .strip_expl2
    jmp     .scan_next2

.strip_expl2:
    mov     byte [rdi], 0
    jmp     .strip_backticks

.scan_next2:
    inc     rdi
    dec     ecx
    jmp     .scan_explain2

.strip_backticks:

    ; --- Strip surrounding backticks if present ---
    lea     rdi, [rel command_buf]
    cmp     byte [rdi], '`'
    jne     .no_backticks
    call    str_len                 ; rax = length
    cmp     rax, 2
    jb      .no_backticks
    cmp     byte [rdi + rax - 1], '`'
    jne     .no_backticks
    mov     byte [rdi + rax - 1], 0  ; remove trailing backtick
    lea     rsi, [rdi + 1]          ; src = command_buf + 1
    call    str_copy                ; shift content left
.no_backticks:

    mov     eax, r15d           ; return the action type
    jmp     .epilogue

    ; -------------------------------------------------------------------
    ; Error paths
    ; -------------------------------------------------------------------
.check_error:
    ; "content" was not found. Check if response contains "error"
    lea     rdi, [rel response_buf]
    lea     rsi, [rel needle_error]
    call    str_find            ; rax = pointer or 0

    ; Regardless of whether "error" was found, we treat this as an error.
    ; If "error" key exists, it's an API error.
    ; If neither "content" nor "error" exists, response is malformed.

    ; Copy a useful portion of response_buf into command_buf for debugging
    lea     rdi, [rel command_buf]
    lea     rsi, [rel response_buf]
    ; Copy up to COMMAND_BUF_SZ - 1 bytes
    xor     rcx, rcx            ; byte counter
.copy_error_msg:
    cmp     rcx, COMMAND_BUF_SZ - 1
    jge     .error_msg_done
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .error_msg_done
    mov     [rdi + rcx], al
    inc     rcx
    jmp     .copy_error_msg

.error_msg_done:
    mov     byte [rdi + rcx], 0     ; null-terminate
    jmp     .return_error

.return_error:
    mov     eax, ACTION_ERROR

    ; -------------------------------------------------------------------
    ; Epilogue — restore registers and return
    ; -------------------------------------------------------------------
.epilogue:
    pop     rbx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret
