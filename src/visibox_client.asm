; ============================================================================
; visibox_client.asm — Unified VisiBox JSON Protocol Client
; ============================================================================
; Provides reusable functions for communicating with VisiBox:
;
;   vb_send_recv      — Fork/exec visibox, send JSON, read JSON response
;   vb_find_key       — Locate a JSON key in the last response
;   vb_skip_whitespace — Skip spaces/tabs/newlines
;   vb_extract_string — Find key + extract unescaped string value to output_buf
;   vb_parse_int      — Find key + parse integer value, return in eax
;   vb_parse_bool     — Find key + parse boolean, return 0/1
;   vb_json_escape    — Escape a buffer for JSON string safety
;   vb_build_execute  — Build execute JSON request with options
;   vb_build_fetch_page — Build fetch_page JSON request
;   vb_build_search   — Build search_jump JSON request
;
; All functions operate on shared BSS variables defined in main.asm:
;   visibox_json_buf, visibox_pipe_fds, visibox_resp_pipe_fds,
;   visibox_response_raw, visibox_resp_len, use_visibox,
;   output_buf, output_len, command_buf, saved_envp, wait_status
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

; ---------------------------------------------------------------------------
; External data (BSS in main.asm)
; ---------------------------------------------------------------------------
extern visibox_json_buf
extern visibox_pipe_fds
extern visibox_resp_pipe_fds
extern visibox_response_raw
extern visibox_resp_len
extern output_buf
extern output_len
extern command_buf
extern saved_envp
extern wait_status

; ---------------------------------------------------------------------------
; External functions
; ---------------------------------------------------------------------------
extern str_find
extern str_len
extern str_copy
extern str_concat

; ---------------------------------------------------------------------------
; Public API
; ---------------------------------------------------------------------------
global vb_send_recv
global vb_find_key
global vb_skip_whitespace
global vb_extract_string
global vb_parse_int
global vb_parse_bool
global vb_json_escape
global vb_build_execute
global vb_build_fetch_page
global vb_build_search
global vb_build_session
global vb_get_response_id
global vb_get_cursor
global vb_get_has_next

; ============================================================================
;                           READ-ONLY DATA
; ============================================================================
; NOTE: JSON key anchors (vb_key_*) are in config.inc (shared across modules).
;       This section only has visibox_client-specific data.
; ============================================================================
section .rodata

; --- VisiBox paths ---
devnull_path     db '/dev/null', 0

; --- JSON request templates (visibox_client-specific) ---
; execute: {"type":"execute","command":"...","options":{"output_limit":50,"line_numbers":true}}
vb_exec_prefix  db '{"type":"execute","command":"', 0
vb_exec_opts    db '","options":{"output_limit":50,"line_numbers":true}}', 0

; fetch_page: {"type":"fetch_page","response_id":"...","cursor":"...","options":{"output_limit":50}}
vb_fetch_prefix db '{"type":"fetch_page","response_id":"', 0
vb_fetch_mid    db '","cursor":"', 0
vb_fetch_opts   db '","options":{"output_limit":50}}', 0

; search_jump: {"type":"search_jump","response_id":"...","keyword":"...","options":{"case_sensitive":false}}
vb_search_prefix db '{"type":"search_jump","response_id":"', 0
vb_search_mid   db '","keyword":"', 0
vb_search_opts  db '","options":{"case_sensitive":false}}', 0

; session: {"type":"session","command":"...","options":{"output_limit":50,"line_numbers":true}}
vb_session_prefix db '{"type":"session","command":"', 0
vb_session_opts   db '","options":{"output_limit":50,"line_numbers":true}}', 0

; --- Saved response fields (parsed from last response) ---
; These are in BSS but we define the extern names here for other modules
section .bss
; BSS variables for parsed response metadata (shared across modules)
global vb_saved_response_id
global vb_saved_cursor
global vb_saved_has_next
vb_saved_response_id  resb 128    ; last response_id string
vb_saved_cursor       resb 128    ; last cursor string
vb_saved_has_next     resb 1      ; 1 = more pages available
vb_response_id_len    resq 1
vb_cursor_len         resq 1

; ============================================================================
;                            CODE
; ============================================================================
section .text

; ============================================================================
; vb_json_escape — Escape a source buffer for JSON string safety
; ============================================================================
; Args:    rsi = source (null-terminated)
;          rdi = destination buffer
; Returns: rdi updated past last byte written
; Clobbers: rax, rsi, rcx
; ============================================================================
vb_json_escape:
    push    rbp
    mov     rbp, rsp
    push    rbx

.escape_loop:
    lodsb
    test    al, al
    jz      .escape_done

    cmp     al, '"'
    je      .esc_quote
    cmp     al, '\'
    je      .esc_bs
    cmp     al, 10
    je      .esc_n
    cmp     al, 13
    je      .esc_r
    cmp     al, 9
    je      .esc_t
    cmp     al, 8
    je      .esc_bk
    cmp     al, 12
    je      .esc_ff
    cmp     al, 0x20
    jb      .esc_ctrl
    stosb
    jmp     .escape_loop

.esc_quote:
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], '"'
    inc     rdi
    jmp     .escape_loop

.esc_bs:
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], '\'
    inc     rdi
    jmp     .escape_loop

.esc_n:
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], 'n'
    inc     rdi
    jmp     .escape_loop

.esc_r:
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], 'r'
    inc     rdi
    jmp     .escape_loop

.esc_t:
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], 't'
    inc     rdi
    jmp     .escape_loop

.esc_bk:
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], 'b'
    inc     rdi
    jmp     .escape_loop

.esc_ff:
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], 'f'
    inc     rdi
    jmp     .escape_loop

.esc_ctrl:
    ; Control char < 0x20 — write \u00XX (6 bytes)
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], 'u'
    inc     rdi
    mov     byte [rdi], '0'
    inc     rdi
    mov     byte [rdi], '0'
    inc     rdi
    ; High nibble
    mov     ah, al
    shr     ah, 4
    call    .nibble_hex
    mov     byte [rdi], al
    inc     rdi
    ; Low nibble — re-read from source
    movzx   eax, byte [rsi - 1]
    and     al, 0x0F
    call    .nibble_hex
    mov     byte [rdi], al
    inc     rdi
    jmp     .escape_loop

.nibble_hex:
    cmp     al, 9
    jbe     .nh_digit
    add     al, 'a' - 10
    ret
.nh_digit:
    add     al, '0'
    ret

.escape_done:
    pop     rbx
    pop     rbp
    ret


; ============================================================================
; vb_skip_whitespace — Advance pointer past spaces/tabs/newlines
; ============================================================================
; Args:    rax = pointer
; Returns: rax = pointer past whitespace
; ============================================================================
vb_skip_whitespace:
.sw_loop:
    cmp     byte [rax], ' '
    je      .sw_adv
    cmp     byte [rax], 9
    je      .sw_adv
    cmp     byte [rax], 10
    je      .sw_adv
    cmp     byte [rax], 13
    je      .sw_adv
    ret
.sw_adv:
    inc     rax
    jmp     .sw_loop


; ============================================================================
; vb_find_key — Locate a JSON key in visibox_response_raw
; ============================================================================
; Args:    rdi = key string (e.g., '"exit_code":')
; Returns:  rax = pointer to first char AFTER the key's colon and whitespace
;               (i.e., pointing at the value)
;          rax = 0 if key not found
; ============================================================================
vb_find_key:
    push    rsi
    push    rdx

    lea     rsi, [rel visibox_response_raw]
    call    str_find
    test    rax, rax
    jz      .fk_not_found

    ; Skip past the key string
    push    rdi
    mov     rdi, rax
    call    str_len
    add     rax, rdi            ; rax points past key
    pop     rdi

    ; Skip past colon
    cmp     byte [rax], ':'
    jne     .fk_not_found
    inc     rax

    ; Skip whitespace after colon
    call    vb_skip_whitespace
    ret

.fk_not_found:
    xor     eax, eax
    pop     rdx
    pop     rsi
    ret


; ============================================================================
; vb_extract_string — Find key, extract unescaped JSON string to output_buf
; ============================================================================
; Args:    rdi = key string (e.g., '"output":')
; Returns:  r14 = length of extracted string (0 if not found)
;          output_buf filled with unescaped content
; ============================================================================
vb_extract_string:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r15

    call    vb_find_key
    test    rax, rax
    jz      .es_not_found

    ; rax should point to opening '"' of string value
    cmp     byte [rax], '"'
    jne     .es_not_found
    inc     rax
    mov     r13, rax              ; r13 = start of string content

    ; Copy to output_buf, handling JSON escapes
    lea     rdi, [rel output_buf]
    xor     r14d, r14d
    mov     rsi, r13

.es_copy_loop:
    lodsb
    test    al, al
    jz      .es_copy_end

    cmp     al, '"'
    jne     .es_copy_normal

    ; Quote — check if escaped (count preceding backslashes)
    xor     ecx, ecx
    mov     r15, rsi
    sub     r15, 2
.es_count_bs:
    cmp     r15, r13
    jb      .es_bs_done
    cmp     byte [r15], '\'
    jne     .es_bs_done
    inc     ecx
    dec     r15
    jmp     .es_count_bs
.es_bs_done:
    test    ecx, 1
    jnz     .es_escaped_quote       ; odd = escaped
    jmp     .es_copy_end             ; even = end of string

.es_escaped_quote:
    mov     byte [rdi], '"'
    inc     rdi
    inc     r14
    jmp     .es_copy_loop

.es_copy_normal:
    cmp     al, '\'
    jne     .es_store

    ; Backslash escape — peek next char
    movzx   ebx, byte [rsi]
    cmp     bl, 'n'
    je      .es_n
    cmp     bl, 'r'
    je      .es_r
    cmp     bl, 't'
    je      .es_t
    cmp     bl, 'b'
    je      .es_b
    cmp     bl, 'f'
    je      .es_f
    cmp     bl, '\'
    je      .es_backslash
    cmp     bl, '"'
    je      .es_q
    ; Unknown escape — store next char raw
    lodsb
    stosb
    inc     r14
    jmp     .es_copy_loop

.es_n:
    mov     byte [rdi], 10
    inc     rdi
    inc     r14
    inc     rsi
    jmp     .es_copy_loop

.es_r:
    mov     byte [rdi], 13
    inc     rdi
    inc     r14
    inc     rsi
    jmp     .es_copy_loop

.es_t:
    mov     byte [rdi], 9
    inc     rdi
    inc     r14
    inc     rsi
    jmp     .es_copy_loop

.es_b:
    mov     byte [rdi], 8
    inc     rdi
    inc     r14
    inc     rsi
    jmp     .es_copy_loop

.es_f:
    mov     byte [rdi], 12
    inc     rdi
    inc     r14
    inc     rsi
    jmp     .es_copy_loop

.es_backslash:
    mov     byte [rdi], '\'
    inc     rdi
    inc     r14
    inc     rsi
    jmp     .es_copy_loop

.es_q:
    mov     byte [rdi], '"'
    inc     rdi
    inc     r14
    inc     rsi
    jmp     .es_copy_loop

.es_store:
    stosb
    inc     r14
    jmp     .es_copy_loop

.es_copy_end:
    mov     byte [rdi], 0

.es_not_found:
    lea     rdi, [rel output_buf]
    mov     byte [rdi], 0
    xor     r14d, r14d

    pop     r15
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================================
; vb_parse_int — Find key, parse integer value
; ============================================================================
; Args:    rdi = key string
; Returns:  eax = integer value (0 if not found)
; ============================================================================
vb_parse_int:
    push    rbx
    push    rcx
    push    rdx

    call    vb_find_key
    test    rax, rax
    jz      .pi_zero

    ; rax points to the number (may have sign)
    xor     ecx, ecx
    mov     ebx, 1                  ; sign
    movzx   edx, byte [rax]

    cmp     dl, '-'
    jne     .pi_not_neg
    mov     ebx, -1
    inc     rax
    movzx   edx, byte [rax]
.pi_not_neg:
    cmp     dl, '+'
    jne     .pi_digit_loop
    inc     rax
    movzx   edx, byte [rax]

.pi_digit_loop:
    cmp     dl, '0'
    jb      .pi_done
    cmp     dl, '9'
    ja      .pi_done
    imul    ecx, ecx, 10
    sub     dl, '0'
    movzx   edx, dl
    add     ecx, edx
    inc     rax
    movzx   edx, byte [rax]
    jmp     .pi_digit_loop

.pi_done:
    imul    ecx, ebx
    mov     eax, ecx
    pop     rdx
    pop     rcx
    pop     rbx
    ret

.pi_zero:
    xor     eax, eax
    pop     rdx
    pop     rcx
    pop     rbx
    ret


; ============================================================================
; vb_parse_bool — Find key, parse boolean value
; ============================================================================
; Args:    rdi = key string
; Returns:  eax = 1 if true, 0 if false or not found
; ============================================================================
vb_parse_bool:
    call    vb_find_key
    test    rax, rax
    jz      .pb_false

    cmp     byte [rax], 't'
    jne     .pb_false

    mov     eax, 1
    ret

.pb_false:
    xor     eax, eax
    ret


; ============================================================================
; vb_extract_string_to_buf — Find key, extract to specified buffer
; ============================================================================
; Args:    rdi = key string, rsi = destination buffer, rdx = buffer size
; Returns:  rcx = length extracted
; ============================================================================
; Note: This is similar to vb_extract_string but writes to a caller-specified
;       buffer. Used for response_id, cursor, etc.
; ============================================================================
vb_extract_string_to_buf:
    ; For now, we use output_buf internally and then copy.
    ; This avoids duplicating the complex JSON unescape logic.
    push    rbp
    mov     rbp, rsp
    push    rdi
    push    rsi
    push    rdx
    push    r8

    mov     r8, rdx              ; r8 = dest buffer size
    mov     r9, rsi              ; r9 = dest buffer

    ; Use the standard extract to output_buf
    call    vb_extract_string
    ; r14 = length, output_buf has content

    ; Copy from output_buf to dest, respecting size limit
    lea     rsi, [rel output_buf]
    mov     rdi, r9
    mov     rcx, r14
    cmp     rcx, r8
    jbe     .est_copy_ok
    mov     rcx, r8
    dec     rcx
.est_copy_ok:
    cld
    rep     movsb
    mov     byte [rdi], 0
    ; rcx = bytes copied

    pop     r8
    pop     rdx
    pop     rsi
    pop     rdi
    pop     rbp
    ret


; ============================================================================
; vb_get_response_id — Extract and save response_id from last response
; ============================================================================
; Returns: rax = pointer to vb_saved_response_id
; ============================================================================
vb_get_response_id:
    lea     rdi, [rel vb_key_response_id]
    lea     rsi, [rel vb_saved_response_id]
    mov     rdx, 127
    call    vb_extract_string_to_buf
    mov     [rel vb_response_id_len], rcx
    lea     rax, [rel vb_saved_response_id]
    ret


; ============================================================================
; vb_get_cursor — Extract and save cursor from last response
; ============================================================================
; Returns: rax = pointer to vb_saved_cursor
; ============================================================================
vb_get_cursor:
    lea     rdi, [rel vb_key_cursor]
    lea     rsi, [rel vb_saved_cursor]
    mov     rdx, 127
    call    vb_extract_string_to_buf
    mov     [rel vb_cursor_len], rcx
    lea     rax, [rel vb_saved_cursor]
    ret


; ============================================================================
; vb_get_has_next — Check if more pages available
; ============================================================================
; Returns: eax = 1 if has_next is true, 0 otherwise
; ============================================================================
vb_get_has_next:
    lea     rdi, [rel vb_key_has_next]
    call    vb_parse_bool
    mov     [rel vb_saved_has_next], al
    ret


; ============================================================================
; vb_send_recv — Send JSON to VisiBox, receive JSON response
; ============================================================================
; Args:    none (reads visibox_json_buf)
; Returns:  rax = 0 success, -1 error
; Modifies: visibox_response_raw, visibox_resp_len
; ============================================================================
vb_send_recv:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; Calculate JSON length
    lea     rdi, [rel visibox_json_buf]
    call    str_len
    mov     r15, rax               ; r15 = JSON request length

    ; --- Create pipes ---
    lea     rdi, [rel visibox_pipe_fds]
    mov     rax, SYS_PIPE
    syscall
    test    rax, rax
    js      .sr_pipe_err

    lea     rdi, [rel visibox_resp_pipe_fds]
    mov     rax, SYS_PIPE
    syscall
    test    rax, rax
    js      .sr_close_in_pipe

    ; --- Fork ---
    mov     rax, SYS_FORK
    syscall
    test    rax, rax
    js      .sr_fork_err
    jz      .sr_child
    jmp     .sr_parent

; ==================== CHILD PROCESS ====================
.sr_child:
    ; Redirect stdin from pipe
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax]
    mov     esi, STDIN
    mov     eax, SYS_DUP2
    syscall

    ; Redirect stdout to pipe
    lea     rax, [rel visibox_resp_pipe_fds]
    mov     edi, [rax + 4]
    mov     esi, STDOUT
    mov     eax, SYS_DUP2
    syscall

    ; Redirect stderr to /dev/null
    lea     rdi, [rel devnull_path]
    mov     esi, O_WRONLY
    xor     edx, edx
    mov     rax, SYS_OPEN
    syscall
    mov     rdi, rax
    mov     esi, STDERR
    mov     eax, SYS_DUP2
    syscall

    ; Close all pipe fds in child
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax]
    mov     eax, SYS_CLOSE
    syscall
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax + 4]
    mov     eax, SYS_CLOSE
    syscall
    lea     rax, [rel visibox_resp_pipe_fds]
    mov     edi, [rax]
    mov     eax, SYS_CLOSE
    syscall
    lea     rax, [rel visibox_resp_pipe_fds]
    mov     edi, [rax + 4]
    mov     eax, SYS_CLOSE
    syscall

    ; execve(visibox_path, [path, "--norc", "--visibox", NULL], envp)
    xor     eax, eax
    push    rax
    lea     rax, [rel visibox_flag]
    push    rax
    lea     rax, [rel visibox_norc]
    push    rax
    lea     rax, [rel visibox_path]
    push    rax
    lea     rdi, [rel visibox_path]
    mov     rsi, rsp
    mov     rdx, [rel saved_envp]
    mov     rax, SYS_EXECVE
    syscall
    EXIT    127

; ==================== PARENT PROCESS ====================
.sr_parent:
    mov     r13, rax                ; child PID

    ; Close unused pipe ends
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax]
    mov     eax, SYS_CLOSE
    syscall
    lea     rax, [rel visibox_resp_pipe_fds]
    mov     edi, [rax + 4]
    mov     eax, SYS_CLOSE
    syscall

    ; Write JSON request
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax + 4]
    lea     rsi, [rel visibox_json_buf]
    mov     rdx, r15
    mov     rax, SYS_WRITE
    syscall

    ; Close write end (signal EOF)
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax + 4]
    mov     eax, SYS_CLOSE
    syscall

    ; Read JSON response
    xor     r14d, r14d
.sr_read_loop:
    mov     rdx, OUTPUT_BUF_SZ - 1
    sub     rdx, r14
    jle     .sr_read_done

    lea     rax, [rel visibox_resp_pipe_fds]
    mov     edi, [rax]
    lea     rsi, [rel visibox_response_raw]
    add     rsi, r14
    mov     rax, SYS_READ
    syscall
    test    rax, rax
    jle     .sr_read_done
    add     r14, rax
    jmp     .sr_read_loop

.sr_read_done:
    lea     rax, [rel visibox_response_raw]
    mov     byte [rax + r14], 0
    mov     [rel visibox_resp_len], r14

    ; Close read end
    lea     rax, [rel visibox_resp_pipe_fds]
    mov     edi, [rax]
    mov     eax, SYS_CLOSE
    syscall

    ; Wait for child
    mov     rdi, r13
    lea     rsi, [rel wait_status]
    xor     edx, edx
    xor     r10d, r10d
    mov     rax, SYS_WAIT4
    syscall

    xor     eax, eax              ; return 0 = success
    jmp     .sr_cleanup

; ==================== ERROR HANDLERS ====================
.sr_close_in_pipe:
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax]
    mov     eax, SYS_CLOSE
    syscall
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax + 4]
    mov     eax, SYS_CLOSE
    syscall
.sr_pipe_err:
    mov     rax, -1
    jmp     .sr_cleanup

.sr_fork_err:
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax]
    mov     eax, SYS_CLOSE
    syscall
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax + 4]
    mov     eax, SYS_CLOSE
    syscall
    lea     rax, [rel visibox_resp_pipe_fds]
    mov     edi, [rax]
    mov     eax, SYS_CLOSE
    syscall
    lea     rax, [rel visibox_resp_pipe_fds]
    mov     edi, [rax + 4]
    mov     eax, SYS_CLOSE
    syscall
    mov     rax, -1

.sr_cleanup:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================================
; vb_build_execute — Build execute JSON with options
; ============================================================================
; Args:    none (reads command_buf)
; Writes:  visibox_json_buf
; ============================================================================
vb_build_execute:
    push    rbp
    mov     rbp, rsp
    push    rdi
    push    rsi

    ; Start with prefix: {"type":"execute","command":"
    lea     rdi, [rel visibox_json_buf]
    lea     rsi, [rel vb_exec_prefix]
    call    str_copy

    ; Escape command_buf into the JSON
    lea     rsi, [rel command_buf]
    ; rdi is already past the prefix
    call    vb_json_escape

    ; Append options suffix
    lea     rsi, [rel vb_exec_opts]
    call    str_concat

    pop     rsi
    pop     rdi
    pop     rbp
    ret


; ============================================================================
; vb_build_fetch_page — Build fetch_page JSON
; ============================================================================
; Args:    none (reads vb_saved_response_id, vb_saved_cursor)
; Writes:  visibox_json_buf
; ============================================================================
vb_build_fetch_page:
    push    rbp
    mov     rbp, rsp

    lea     rdi, [rel visibox_json_buf]
    lea     rsi, [rel vb_fetch_prefix]
    call    str_copy

    ; Append response_id
    lea     rsi, [rel vb_saved_response_id]
    call    str_concat

    ; Append mid: ","cursor":"
    lea     rsi, [rel vb_fetch_mid]
    call    str_concat

    ; Append cursor
    lea     rsi, [rel vb_saved_cursor]
    call    str_concat

    ; Append opts
    lea     rsi, [rel vb_fetch_opts]
    call    str_concat

    pop     rbp
    ret


; ============================================================================
; vb_build_search — Build search_jump JSON
; ============================================================================
; Args:    none (reads vb_saved_response_id, command_buf = keyword)
; Writes:  visibox_json_buf
; ============================================================================
vb_build_search:
    push    rbp
    mov     rbp, rsp
    push    rdi
    push    rsi

    lea     rdi, [rel visibox_json_buf]
    lea     rsi, [rel vb_search_prefix]
    call    str_copy

    ; Append response_id
    lea     rsi, [rel vb_saved_response_id]
    call    str_concat

    ; Append mid: ","keyword":"
    lea     rsi, [rel vb_search_mid]
    call    str_concat

    ; Escape keyword (from command_buf)
    lea     rsi, [rel command_buf]
    call    vb_json_escape

    ; Append opts
    lea     rsi, [rel vb_search_opts]
    call    str_concat

    pop     rsi
    pop     rdi
    pop     rbp
    ret


; ============================================================================
; vb_build_session — Build session JSON (persistent shell)
; ============================================================================
; Args:    none (reads command_buf = command to run in session)
; Writes:  visibox_json_buf
; ============================================================================
; Session mode uses VisiBox daemon — the shell state (cwd, env vars, aliases)
; persists across calls. Ideal for cd, export, and multi-step workflows.
;
; JSON format:
;   {"type":"session","command":"...","options":{"output_limit":50,"line_numbers":true}}
; ============================================================================
vb_build_session:
    push    rbp
    mov     rbp, rsp
    push    rdi
    push    rsi

    ; Start with prefix: {"type":"session","command":"
    lea     rdi, [rel visibox_json_buf]
    lea     rsi, [rel vb_session_prefix]
    call    str_copy

    ; Escape command_buf into the JSON
    lea     rsi, [rel command_buf]
    ; rdi is already past the prefix
    call    vb_json_escape

    ; Append options suffix
    lea     rsi, [rel vb_session_opts]
    call    str_concat

    pop     rsi
    pop     rdi
    pop     rbp
    ret