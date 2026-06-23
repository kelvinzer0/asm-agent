; ============================================================================
; parser.asm — ASM-AGENT API Response Parser (Tool Calls Architecture)
; ============================================================================
; Parses the JSON response from the Chat Completions API.
;
; Extracts from response_buf:
;   1. finish_reason → finish_reason_buf
;   2. tool_calls[0].id → tool_call_id_buf
;   3. tool_calls[0].function.name → tool_call_name_buf
;   4. tool_calls[0].function.arguments → tool_call_args_buf
;   5. content → content_buf
;
; Returns (rax):
;   ACTION_TOOL_CALL (0)  — model returned tool_calls
;   ACTION_DONE     (1)  — tool_call name is "task_complete"
;   ACTION_THINK    (2)  — finish_reason is "stop", no tool_calls
;   ACTION_ERROR    (-1) — parse failure or API error
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

; ---------------------------------------------------------------------------
; External data
; ---------------------------------------------------------------------------
extern response_buf
extern response_len
extern command_buf
extern finish_reason_buf
extern content_buf
extern tool_call_id_buf
extern tool_call_name_buf
extern tool_call_args_buf

; ---------------------------------------------------------------------------
; External functions
; ---------------------------------------------------------------------------
extern str_find
extern str_starts_with
extern str_len
extern str_copy

; ---------------------------------------------------------------------------
; Export
; ---------------------------------------------------------------------------
global parse_response

; ============================================================================
section .rodata
; ============================================================================

; JSON keys to search for
needle_finish_reason:  db '"finish_reason"', 0
needle_tool_calls:     db '"tool_calls"', 0
needle_content:        db '"content"', 0
needle_error:          db '"error"', 0
needle_function:       db '"function"', 0
needle_name:           db '"name"', 0
needle_arguments:      db '"arguments"', 0
needle_id:             db '"id"', 0

; SSE stream markers
sse_data_prefix:  db 'data: ', 0
sse_done_marker:  db 'data: [DONE]', 0

; Tool name for comparison
tc_name_run_command:    db 'run_command', 0
tc_name_task_complete:  db 'task_complete', 0

; ============================================================================
section .text
; ============================================================================

; ============================================================================
; parse_response — Parse API JSON, extract tool_calls or content
; ============================================================================
parse_response:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbx

    ; --- Clear output buffers ---
    lea     rdi, [rel finish_reason_buf]
    xor     al, al
    mov     [rdi], al
    lea     rdi, [rel content_buf]
    mov     [rdi], al
    lea     rdi, [rel tool_call_id_buf]
    mov     [rdi], al
    lea     rdi, [rel tool_call_name_buf]
    mov     [rdi], al
    lea     rdi, [rel tool_call_args_buf]
    mov     [rdi], al

    ; --- Initialize r14 = end of response_buf (used by all parse loops) ---
    lea     r14, [rel response_buf]
    add     r14, [rel response_len]

    ; -------------------------------------------------------------------
    ; Step 0: Handle SSE streaming format
    ; -------------------------------------------------------------------
    lea     rdi, [rel response_buf]
    lea     rsi, [rel sse_data_prefix]
    call    str_starts_with
    test    rax, rax
    jz      .no_sse

    ; SSE detected: in-place strip "data: " from each line
    lea     r12, [rel response_buf]
    lea     r13, [rel response_buf]
    lea     r14, [rel response_buf]
    add     r14, [rel response_len]

.sse_loop:
    cmp     r12, r14
    jge     .sse_done

    lea     rdi, [rel sse_data_prefix]
    mov     rsi, r12
    call    str_starts_with
    test    rax, rax
    jz      .sse_copy_raw

    ; Check for [DONE]
    lea     rdi, [rel sse_done_marker]
    mov     rsi, r12
    call    str_starts_with
    jnz     .sse_skip_line

    ; Skip "data: " prefix (6 bytes)
    add     r12, 6
    jmp     .sse_copy_raw

.sse_skip_line:
    cmp     r12, r14
    jge     .sse_done
    movzx   eax, byte [r12]
    inc     r12
    cmp     al, 10
    jne     .sse_skip_line
    jmp     .sse_loop

.sse_copy_raw:
    cmp     r12, r14
    jge     .sse_done
    movzx   eax, byte [r12]
    inc     r12
    mov     [r13], al
    inc     r13
    cmp     al, 10
    je      .sse_loop
    jmp     .sse_copy_raw

.sse_done:
    mov     byte [r13], 0
    mov     rax, r13
    lea     rcx, [rel response_buf]
    sub     rax, rcx
    mov     [rel response_len], rax
    ; Update r14 to new end after SSE strip
    lea     r14, [rel response_buf]
    add     r14, rax

.no_sse:

    ; -------------------------------------------------------------------
    ; Step 1: Check for API error
    ; -------------------------------------------------------------------
    lea     rdi, [rel response_buf]
    lea     rsi, [rel needle_error]
    call    str_find
    test    rax, rax
    jnz     .api_error

    ; -------------------------------------------------------------------
    ; Step 2: Extract finish_reason
    ; -------------------------------------------------------------------
    lea     rdi, [rel response_buf]
    lea     rsi, [rel needle_finish_reason]
    call    str_find
    test    rax, rax
    jz      .no_finish_reason

    ; Advance past "finish_reason" (15 bytes including quotes)
    add     rax, 15
    mov     r13, rax

    ; Skip to colon and value
.fr_skip:
    cmp     r13, r14
    jge     .no_finish_reason
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, '"'
    jne     .fr_skip

    ; Now r13 points to the first char of the finish_reason value
    ; Copy until closing quote
    lea     rdi, [rel finish_reason_buf]
    mov     r12, rdi
.fr_copy:
    cmp     r13, r14
    jge     .fr_copy_done
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, '"'
    je      .fr_copy_done
    mov     [r12], al
    inc     r12
    jmp     .fr_copy
.fr_copy_done:
    mov     byte [r12], 0
    jmp     .check_tool_calls

.no_finish_reason:
    ; Default: assume stop
    lea     rdi, [rel finish_reason_buf]
    mov     byte [rdi], 's'
    mov     byte [rdi+1], 't'
    mov     byte [rdi+2], 'o'
    mov     byte [rdi+3], 'p'
    mov     byte [rdi+4], 0

.check_tool_calls:

    ; -------------------------------------------------------------------
    ; Step 3: Extract content (always present, may be empty)
    ; -------------------------------------------------------------------
    lea     rdi, [rel response_buf]
    lea     rsi, [rel needle_content]
    call    str_find
    test    rax, rax
    jz      .skip_content

    ; Find the FIRST "content" (the one in the message object, not in tools)
    ; Skip past "content" (9 bytes)
    add     rax, 9
    mov     r13, rax

    ; Skip whitespace and colon
.ct_skip:
    cmp     r13, r14
    jge     .skip_content
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, ' '
    je      .ct_skip
    cmp     al, 9
    je      .ct_skip
    cmp     al, 10
    je      .ct_skip
    cmp     al, ':'
    je      .ct_skip
    cmp     al, '"'
    jne     .skip_content

    ; r13 now past opening quote. Copy until closing quote with unescape.
    lea     rdi, [rel content_buf]
    mov     r12, rdi
.ct_copy:
    cmp     r13, r14
    jge     .ct_copy_done
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, '"'
    je      .ct_copy_done
    cmp     al, '\'
    je      .ct_escape
    mov     [r12], al
    inc     r12
    jmp     .ct_copy

.ct_escape:
    cmp     r13, r14
    jge     .ct_copy_done
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, 'n'
    je      .ct_esc_nl
    cmp     al, 't'
    je      .ct_esc_tab
    cmp     al, 'r'
    je      .ct_esc_cr
    cmp     al, '"'
    je      .ct_esc_store
    cmp     al, '\'
    je      .ct_esc_store
    ; Unknown escape: store as-is
    mov     [r12], al
    inc     r12
    jmp     .ct_copy
.ct_esc_nl:
    mov     byte [r12], 10
    inc     r12
    jmp     .ct_copy
.ct_esc_tab:
    mov     byte [r12], 9
    inc     r12
    jmp     .ct_copy
.ct_esc_cr:
    mov     byte [r12], 13
    inc     r12
    jmp     .ct_copy
.ct_esc_store:
    mov     [r12], al
    inc     r12
    jmp     .ct_copy

.ct_copy_done:
    mov     byte [r12], 0

.skip_content:

    ; -------------------------------------------------------------------
    ; Step 4: Check for tool_calls
    ; -------------------------------------------------------------------
    lea     rdi, [rel response_buf]
    lea     rsi, [rel needle_tool_calls]
    call    str_find
    test    rax, rax
    jz      .no_tool_calls

    ; --- Tool calls found! Parse the first one ---
    ; We need: id, function.name, function.arguments
    ; NOTE: API field order is not guaranteed (arguments may come before name),
    ; so we save a base pointer after "tool_calls" and search all fields from it.

    ; --- Extract tool call ID ---
    ; Find "id" after the tool_calls array
    add     rax, 13            ; skip "tool_calls" (13 bytes)
    mov     r15, rax           ; r15 = base pointer for all field searches

    ; Find "id" within the tool_calls section
    mov     rdi, r15
    lea     rsi, [rel needle_id]
    call    str_find
    test    rax, rax
    jz      .parse_error

    ; Skip past "id" (4 bytes) + colon + quote
    add     rax, 4
    mov     r13, rax
    ; Skip to opening quote of value
.id_skip:
    cmp     byte [r13], '"'
    je      .id_found
    inc     r13
    cmp     r13, r14
    jge     .parse_error
    jmp     .id_skip

.id_found:
    inc     r13            ; skip opening quote
    lea     rdi, [rel tool_call_id_buf]
    mov     r12, rdi
.id_copy:
    cmp     r13, r14
    jge     .id_copy_done
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, '"'
    je      .id_copy_done
    mov     [r12], al
    inc     r12
    jmp     .id_copy
.id_copy_done:
    mov     byte [r12], 0

    ; --- Extract function arguments (search from base r15 for any field order) ---
    mov     rdi, r15
    lea     rsi, [rel needle_arguments]
    call    str_find
    test    rax, rax
    jz      .parse_error

    add     rax, 12         ; skip "arguments" (12 bytes including quotes)
    mov     r13, rax
    ; Skip to opening quote
.args_skip:
    cmp     byte [r13], '"'
    je      .args_found
    inc     r13
    cmp     r13, r14
    jge     .parse_error
    jmp     .args_skip

.args_found:
    inc     r13
    lea     rdi, [rel tool_call_args_buf]
    mov     r12, rdi
.args_copy:
    cmp     r13, r14
    jge     .args_copy_done
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, '"'
    je      .args_copy_done
    ; Handle JSON escape sequences within the arguments string
    cmp     al, '\'
    je      .args_escape
    mov     [r12], al
    inc     r12
    jmp     .args_copy

.args_escape:
    cmp     r13, r14
    jge     .args_copy_done
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, '"'
    je      .args_esc_quote
    cmp     al, '\'
    je      .args_esc_bs
    cmp     al, 'n'
    je      .args_esc_nl
    cmp     al, 't'
    je      .args_esc_tab
    cmp     al, 'r'
    je      .args_esc_cr
    ; Unknown escape: store the char
    mov     [r12], al
    inc     r12
    jmp     .args_copy
.args_esc_quote:
    mov     byte [r12], '"'
    inc     r12
    jmp     .args_copy
.args_esc_bs:
    mov     byte [r12], '\'
    inc     r12
    jmp     .args_copy
.args_esc_nl:
    mov     byte [r12], 10
    inc     r12
    jmp     .args_copy
.args_esc_tab:
    mov     byte [r12], 9
    inc     r12
    jmp     .args_copy
.args_esc_cr:
    mov     byte [r12], 13
    inc     r12
    jmp     .args_copy

.args_copy_done:
    mov     byte [r12], 0

    ; --- Extract function name (search from base r15) ---
    mov     rdi, r15
    lea     rsi, [rel needle_name]
    call    str_find
    test    rax, rax
    jz      .parse_error

    add     rax, 6          ; skip "name" (6 bytes including quotes)
    mov     r13, rax
    ; Skip to opening quote
.name_skip:
    cmp     byte [r13], '"'
    je      .name_found
    inc     r13
    cmp     r13, r14
    jge     .parse_error
    jmp     .name_skip

.name_found:
    inc     r13
    lea     rdi, [rel tool_call_name_buf]
    mov     r12, rdi
.name_copy:
    cmp     r13, r14
    jge     .name_copy_done
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, '"'
    je      .name_copy_done
    mov     [r12], al
    inc     r12
    jmp     .name_copy
.name_copy_done:
    mov     byte [r12], 0

    ; --- Determine action type based on function name ---
    lea     rdi, [rel tool_call_name_buf]
    lea     rsi, [rel tc_name_task_complete]
    call    str_starts_with
    test    rax, rax
    jnz     .is_done

    mov     eax, ACTION_TOOL_CALL
    jmp     .epilogue

.is_done:
    mov     eax, ACTION_DONE
    jmp     .epilogue

.no_tool_calls:
    ; --- No tool_calls: finish_reason should be "stop" ---
    ; This is a THINK or final response
    ; The content is already in content_buf
    mov     eax, ACTION_THINK
    jmp     .epilogue

.api_error:
    ; Copy response to command_buf for error display
    lea     rdi, [rel command_buf]
    lea     rsi, [rel response_buf]
    ; Copy up to COMMAND_BUF_SZ - 1 bytes
    xor     ecx, ecx
.copy_err:
    cmp     ecx, COMMAND_BUF_SZ - 1
    jge     .err_done
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .err_done
    mov     [rdi + rcx], al
    inc     rcx
    jmp     .copy_err
.err_done:
    mov     byte [rdi + rcx], 0
    mov     eax, ACTION_ERROR
    jmp     .epilogue

.parse_error:
    mov     eax, ACTION_ERROR

.epilogue:
    pop     rbx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret