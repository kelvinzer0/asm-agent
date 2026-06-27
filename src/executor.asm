; ============================================================================
; executor.asm — ASM-AGENT Command Executor (v0.2.2 → v0.3.0)
; ============================================================================
; Provides:
;   check_blocked            — Scan command_buf against dangerous patterns
;   exec_command             — Entry point: always uses VisiBox (no fallback)
;   exec_command_visibox     — Pipe JSON to VisiBox, parse structured response
;   visibox_json_escape      — Escape command_buf for JSON string safety
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

; ---------------------------------------------------------------------------
; External data (defined in the BSS of another translation unit)
; ---------------------------------------------------------------------------
extern command_buf              ; COMMAND_BUF_SZ (8192) bytes — command to run
extern output_buf               ; OUTPUT_BUF_SZ  (65536) bytes — captured stdout+stderr
extern output_len               ; qword — actual bytes captured
extern pipe_fds                 ; 2 × dword (8 bytes) — pipe read/write fds
extern wait_status              ; dword — waitpid status word
extern saved_envp               ; qword — pointer to envp array (saved from main)
extern visibox_json_buf         ; COMMAND_BUF_SZ + 64 bytes — JSON request for visibox
extern visibox_pipe_fds         ; 2 × dword — pipe for visibox stdin
extern visibox_resp_pipe_fds    ; 2 × dword — pipe for visibox stdout
extern visibox_response_raw     ; OUTPUT_BUF_SZ — raw JSON response from visibox
extern visibox_resp_len         ; qword — bytes read from visibox response

; ---------------------------------------------------------------------------
; External functions
; ---------------------------------------------------------------------------
extern str_find                 ; str_find(rdi=haystack, rsi=needle) -> rax (ptr or 0)
extern str_len                  ; str_len(rdi=str) -> rax (length)
extern str_copy                 ; str_copy(rdi=dest, rsi=src) -> rax (length)

; ---------------------------------------------------------------------------
; Public API
; ---------------------------------------------------------------------------
global check_blocked
global exec_command
global exec_command_visibox

; ============================================================================
;                         READ-ONLY DATA
; ============================================================================
section .rodata

; --- Blocked command patterns (null-terminated) ---
bp_rm_rf:   db 'rm -rf /', 0
bp_fork:    db ':()', 0
bp_dd:      db 'dd if=/dev', 0
bp_mkfs:    db 'mkfs', 0
bp_shut:    db 'shutdown', 0
bp_reboot:  db 'reboot', 0
bp_sda:     db '> /dev/sda', 0
bp_chmod:   db 'chmod -R 777 /', 0

; Pointer table — terminated by a NULL sentinel
align 8
blocked_list:
    dq bp_rm_rf
    dq bp_fork
    dq bp_dd
    dq bp_mkfs
    dq bp_shut
    dq bp_reboot
    dq bp_sda
    dq bp_chmod
    dq 0                       ; sentinel

; --- Paths ---
devnull_path     db '/dev/null', 0

; --- VisiBox JSON parsing anchors (unique to executor, shared ones in config.inc) ---
vb_quote_char      db '"', 0               ; 1 byte  — opening quote of string value
vb_key_duration    db '"duration_ms":', 0
vb_exec_error_msg  db '"execute_error"', 0

; ============================================================================
;                            CODE
; ============================================================================
section .text

; ============================================================================
; check_blocked — Scan command_buf for dangerous patterns
; ----------------------------------------------------------------------------
; Arguments : none (reads global command_buf)
; Returns   : rax = 0  → command is allowed
;             rax = 1  → command contains a blocked pattern
; Clobbers  : rcx (via str_find), caller-saved registers
; ============================================================================
check_blocked:
    push    rbp
    mov     rbp, rsp
    push    rbx                     ; rbx = iterator through blocked_list
    push    r12                     ; r12 = keeps stack 16-byte aligned

    ; rbx points to the first entry in blocked_list
    lea     rbx, [rel blocked_list]

.check_loop:
    mov     rsi, [rbx]              ; rsi = pointer to current pattern string
    test    rsi, rsi                ; NULL sentinel?
    jz      .allowed                ; yes → all patterns checked, command is safe

    ; str_find(haystack=command_buf, needle=pattern)
    lea     rdi, [rel command_buf]
    call    str_find                ; rax = pointer into haystack, or 0

    test    rax, rax
    jnz     .blocked                ; pattern found → command is blocked

    add     rbx, 8                  ; advance to next pointer in blocked_list
    jmp     .check_loop

.blocked:
    mov     rax, 1                  ; 1 = blocked
    jmp     .done

.allowed:
    xor     eax, eax                ; 0 = allowed

.done:
    pop     r12
    pop     rbx
    pop     rbp
    ret

; ============================================================================
; exec_command — VisiBox-only command execution
; ----------------------------------------------------------------------------
; VisiBox is the sole and only command execution method.
; No fallback. If VisiBox fails, the error propagates.
;
; Arguments : none (reads global command_buf)
; Returns   : rax = exit code (0-255)
; ============================================================================
exec_command:
    call    exec_command_visibox
    ret

; ============================================================================
; exec_command_visibox — Execute command via VisiBox JSON protocol
; ----------------------------------------------------------------------------
; Protocol:
;   1. Build JSON: {"type":"execute","command":"<escaped_cmd>"}
;   2. Fork child process
;   3. Child: execve(visibox_path) with stdin from pipe
;   4. Parent: write JSON to child's stdin, read JSON response from stdout
;   5. Parse "exit_code" and "output" from JSON response
;   6. Copy output to output_buf, return exit_code
;
; Arguments : none (reads global command_buf)
; Returns   : rax = exit code from VisiBox response
;            rax = 254 if visibox binary not found
; ============================================================================
exec_command_visibox:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; ==================================================================
    ; Phase 1: Build JSON request in visibox_json_buf
    ; ==================================================================
    ; visibox_json_buf = {"type":"execute","command":"<escaped_command>"}
    lea     rdi, [rel visibox_json_buf]

    ; Copy request prefix: {"type":"execute","command":"
    lea     rsi, [rel visibox_req_s]
.copy_prefix:
    lodsb
    test    al, al
    jz      .prefix_done
    stosb
    jmp     .copy_prefix
.prefix_done:

    ; Escape command_buf contents for JSON safety
    ; (handle: backslash, double-quote, newline, tab, carriage return, backspace, formfeed)
    ; Also escape all control chars U+0000–U+001F as \uXXXX per JSON spec
    lea     rsi, [rel command_buf]
.escape_loop:
    lodsb
    test    al, al
    jz      .escape_done

    cmp     al, '"'
    je      .esc_quote
    cmp     al, '\'
    je      .esc_backslash
    cmp     al, 10               ; newline
    je      .esc_newline
    cmp     al, 13               ; carriage return
    je      .esc_cr
    cmp     al, 9                ; tab
    je      .esc_tab
    cmp     al, 8                ; backspace
    je      .esc_bs_char
    cmp     al, 12               ; formfeed
    je      .esc_ff_char
    ; Other control chars < 0x20 — escape as \u00XX
    cmp     al, 0x20
    jb      .esc_ctrl_char
    ; Normal character — copy as-is
    stosb
    jmp     .escape_loop

.esc_backslash:
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], '\'
    inc     rdi
    jmp     .escape_loop

.esc_quote:
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], '"'
    inc     rdi
    jmp     .escape_loop

.esc_newline:
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], 'n'
    inc     rdi
    jmp     .escape_loop

.esc_cr:
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], 'r'
    inc     rdi
    jmp     .escape_loop

.esc_tab:
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], 't'
    inc     rdi
    jmp     .escape_loop

.esc_bs_char:
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], 'b'
    inc     rdi
    jmp     .escape_loop

.esc_ff_char:
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], 'f'
    inc     rdi
    jmp     .escape_loop

.esc_ctrl_char:
    ; Generic control char — write \u00XX (6 bytes)
    ; al = control char value (0x00–0x1F, excluding already-handled ones)
    ; We reuse the hex nibble helper: build "u00XX" in temp area
    mov     byte [rdi], '\'
    inc     rdi
    mov     byte [rdi], 'u'
    inc     rdi
    mov     byte [rdi], '0'
    inc     rdi
    mov     byte [rdi], '0'
    inc     rdi
    ; High nibble of al
    mov     ah, al
    shr     ah, 4
    call    .nibble_to_hex
    mov     [rdi], al
    inc     rdi
    ; Low nibble of original al (now in ah was clobbered, re-derive)
    ; al was the original control char, but lodsb put it there.
    ; We need to save it — use stack
    ; Actually we already consumed al above. Let's use a different approach.
    ; Push the original byte before the branch? No — too late.
    ; Simpler: just re-read from the source. rsi-1 points to the char we just lodsb'd.
    movzx   eax, byte [rsi - 1]
    and     al, 0x0F
    call    .nibble_to_hex
    mov     [rdi], al
    inc     rdi
    jmp     .escape_loop

.nibble_to_hex:
    ; Input: al = nibble (0-15)
    ; Output: al = ASCII hex digit
    cmp     al, 9
    jbe     .nth_digit
    add     al, 'a' - 10
    ret
.nth_digit:
    add     al, '0'
    ret

.escape_done:

    ; Copy request suffix: "}
    lea     rsi, [rel visibox_req_e]
.copy_suffix:
    lodsb
    test    al, al
    jz      .suffix_done
    stosb
    jmp     .copy_suffix
.suffix_done:

    ; Null-terminate the JSON request
    mov     byte [rdi], 0
    ; Calculate JSON request length
    lea     rax, [rel visibox_json_buf]
    sub     rdi, rax
    mov     r15, rdi               ; r15 = JSON request length

    ; ==================================================================
    ; Phase 2: Create pipes
    ; ==================================================================
    ; visibox_pipe_fds: parent writes JSON request to child's stdin
    lea     rdi, [rel visibox_pipe_fds]
    mov     rax, SYS_PIPE
    syscall
    test    rax, rax
    js      .vb_pipe_error

    ; visibox_resp_pipe_fds: child writes JSON response, parent reads
    lea     rdi, [rel visibox_resp_pipe_fds]
    mov     rax, SYS_PIPE
    syscall
    test    rax, rax
    js      .vb_close_stdin_pipe   ; close first pipe on error

    ; ==================================================================
    ; Phase 3: Fork
    ; ==================================================================
    mov     rax, SYS_FORK
    syscall
    test    rax, rax
    js      .vb_fork_error         ; negative = error
    jz      .vb_child              ; zero     = child process
    jmp     .vb_parent             ; positive = parent

; ====================== VISIBOX CHILD PROCESS ==========================
.vb_child:
    ; --- Redirect stdin: read from visibox_pipe_fds[0] ---
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax]              ; read end
    mov     esi, STDIN
    mov     eax, SYS_DUP2
    syscall

    ; --- Redirect stdout: write to visibox_resp_pipe_fds[1] ---
    lea     rax, [rel visibox_resp_pipe_fds]
    mov     edi, [rax + 4]          ; write end
    mov     esi, STDOUT
    mov     eax, SYS_DUP2
    syscall

    ; --- Redirect stderr to /dev/null (visibox warnings, not command stderr) ---
    ; Command stderr is included in the JSON "output" field by visibox
    ; We only want clean JSON on stdout
    lea     rdi, [rel devnull_path]
    mov     rax, SYS_OPEN
    mov     esi, O_WRONLY               ; write-only
    xor     edx, edx                   ; mode = 0
    syscall
    ; rax = fd for /dev/null
    mov     rdi, rax
    mov     esi, STDERR
    mov     eax, SYS_DUP2
    syscall

    ; --- Close all pipe fds in child (they're duplicated now) ---
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

    ; --- execve(visibox_path, [visibox_path, "--norc", "--visibox", NULL], envp) ---
    ; --norc: skip bash rc files for clean output
    ; --visibox: activate VisiBox JSON pipe mode
    xor     eax, eax
    push    rax                     ; argv[3] = NULL
    lea     rax, [rel visibox_flag]
    push    rax                     ; argv[2] = "--visibox"
    lea     rax, [rel visibox_norc]
    push    rax                     ; argv[1] = "--norc"
    lea     rax, [rel visibox_path]
    push    rax                     ; argv[0] = visibox_path

    lea     rdi, [rel visibox_path] ; pathname
    mov     rsi, rsp                ; argv
    mov     rdx, [rel saved_envp]   ; envp
    mov     rax, SYS_EXECVE
    syscall

    ; execve failed — exit with special code 127
    EXIT    127

; ====================== VISIBOX PARENT PROCESS =========================
.vb_parent:
    mov     r13, rax                ; r13 = child PID

    ; --- Close pipe ends that parent doesn't use ---
    ; Close visibox_pipe_fds[0] (read end — only child reads from it)
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax]
    mov     eax, SYS_CLOSE
    syscall

    ; Close visibox_resp_pipe_fds[1] (write end — only child writes to it)
    lea     rax, [rel visibox_resp_pipe_fds]
    mov     edi, [rax + 4]
    mov     eax, SYS_CLOSE
    syscall

    ; ==================================================================
    ; Phase 4: Write JSON request to child's stdin
    ; ==================================================================
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax + 4]          ; fd = write end of stdin pipe
    lea     rsi, [rel visibox_json_buf]
    mov     rdx, r15                ; length of JSON request
    mov     rax, SYS_WRITE
    syscall

    ; Close stdin pipe write end (signals EOF to visibox)
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax + 4]
    mov     eax, SYS_CLOSE
    syscall

    ; ==================================================================
    ; Phase 5: Read JSON response from child's stdout
    ; ==================================================================
    xor     r14d, r14d              ; r14 = total bytes read

.vb_read_loop:
    ; Compute remaining space
    mov     rdx, OUTPUT_BUF_SZ - 1
    sub     rdx, r14
    jle     .vb_read_done

    ; read(visibox_resp_pipe_fds[0], visibox_response_raw + r14, remaining)
    lea     rax, [rel visibox_resp_pipe_fds]
    mov     edi, [rax]              ; fd = read end of response pipe
    lea     rsi, [rel visibox_response_raw]
    add     rsi, r14
    mov     rax, SYS_READ
    syscall

    test    rax, rax
    jle     .vb_read_done           ; 0 = EOF, negative = error

    add     r14, rax
    jmp     .vb_read_loop

.vb_read_done:
    ; Null-terminate raw response
    lea     rax, [rel visibox_response_raw]
    mov     byte [rax + r14], 0
    mov     [rel visibox_resp_len], r14

    ; Close response pipe read end
    lea     rax, [rel visibox_resp_pipe_fds]
    mov     edi, [rax]
    mov     eax, SYS_CLOSE
    syscall

    ; ==================================================================
    ; Phase 6: Wait for child
    ; ==================================================================
    mov     rdi, r13                ; pid
    lea     rsi, [rel wait_status]
    xor     edx, edx
    xor     r10d, r10d
    mov     rax, SYS_WAIT4
    syscall

    ; Check if child exited normally
    ; If child exited with 127, visibox binary was not found
    mov     eax, [rel wait_status]
    cmp     al, 0                   ; WIFEXITED?
    je      .vb_child_exited
    ; Child didn't exit normally (signal, etc) — return -1
    mov     rax, -1
    jmp     .vb_cleanup

.vb_child_exited:
    ; Extract WEXITSTATUS
    shr     eax, 8
    and     eax, 0xFF
    cmp     eax, 127
    jne     .vb_parse_response
    ; Exit code 127 = execve failed (visibox not found) 
    mov     rax, 254
    jmp     .vb_cleanup

    ; ==================================================================
    ; Phase 7: Parse VisiBox JSON response
    ; ==================================================================
    ; Response format:
    ;   {"type":"execute_result","exit_code":0,"output":"...","output_truncated":true,...}
    ;
    ; We need to extract:
    ;   1. "exit_code": <number>
    ;   2. "output": "<string>"
    ;   3. "output_truncated": <bool>  (for future pagination)
    ; ==================================================================
.vb_parse_response:
    ; --- Check for error response type ---
    lea     rdi, [rel visibox_response_raw]
    lea     rsi, [rel vb_key_err]
    call    str_find
    test    rax, rax
    jz      .vb_no_error_type

    ; Found "error" key — this is an error response from visibox
    ; Set output to error message and exit code to 1
    lea     rdi, [rel output_buf]
    lea     rsi, [rel vb_exec_error_msg]
    mov     ecx, 17
    cld
    rep     movsb
    mov     byte [rdi], 0
    mov     r14, 17
    jmp     .vb_extract_exit_code

.vb_no_error_type:

    ; --- Extract "output" string ---
    ; Find '"output":' first (works with both compact and spaced JSON)
    lea     rdi, [rel visibox_response_raw]
    lea     rsi, [rel vb_key_output]    ; '"output":' (9 bytes)
    call    str_find
    test    rax, rax
    jz      .vb_output_not_found

    ; rax points to '"' of '"output":'
    ; Skip past '"output":' (9 bytes) to the colon area
    add     rax, 9

    ; Skip optional whitespace after colon
.vb_output_skip_ws:
    movzx   ecx, byte [rax]
    cmp     cl, ' '
    je      .vb_output_ws_adv
    cmp     cl, 10
    je      .vb_output_ws_adv
    cmp     cl, 13
    je      .vb_output_ws_adv
    cmp     cl, 9
    je      .vb_output_ws_adv
    jmp     .vb_output_skip_ws_done
.vb_output_ws_adv:
    inc     rax
    jmp     .vb_output_skip_ws

.vb_output_skip_ws_done:
    ; Now rax should point to the opening '"' of the output string value
    cmp     byte [rax], '"'
    jne     .vb_output_not_found     ; malformed JSON
    inc     rax                       ; skip the opening quote
    mov     r12, rax                  ; r12 = start of output content

    ; Copy output string to output_buf, handling JSON escapes
    lea     rdi, [rel output_buf]
    xor     r14d, r14d               ; r14 = output length
    mov     rsi, r12

.vb_copy_output:
    lodsb
    test    al, al
    jz      .vb_copy_end

    ; Check for end of JSON string: unescaped double-quote
    cmp     al, '"'
    jne     .vb_copy_normal

    ; It's a quote — count consecutive backslashes before it
    ; to distinguish \" (escaped) from \\" (literal \ then end-of-string)
    ; rsi is already past the quote, so rsi-2 is the byte before the quote
    xor     ecx, ecx                ; ecx = backslash count
    mov     r8, rsi
    sub     r8, 2                   ; r8 = pointer to byte before the quote
.vb_count_bs:
    cmp     r8, r12
    jb      .vb_bs_count_done       ; reached start of string
    cmp     byte [r8], '\'
    jne     .vb_bs_count_done
    inc     ecx
    dec     r8
    jmp     .vb_count_bs
.vb_bs_count_done:
    ; Odd count = escaped quote, Even count = real end-of-string
    test    ecx, 1
    jnz     .vb_escaped_quote       ; odd → this " is escaped

    ; Even backslashes → unescaped " → end of JSON string
    jmp     .vb_copy_end

.vb_escaped_quote:
    ; The \" should have already been handled by the \ escape path below,
    ; but if we get here (e.g. standalone \" in output), write the quote
    mov     byte [rdi], '"'
    inc     rdi
    inc     r14
    jmp     .vb_copy_output

.vb_copy_normal:
    ; Handle other JSON escapes
    cmp     al, '\'
    jne     .vb_copy_store

    ; Backslash — peek at next char
    movzx   ebx, byte [rsi]
    cmp     bl, 'n'
    je      .vb_esc_n
    cmp     bl, 'r'
    je      .vb_esc_r
    cmp     bl, 't'
    je      .vb_esc_t
    cmp     bl, 'b'
    je      .vb_esc_b
    cmp     bl, 'f'
    je      .vb_esc_f
    cmp     bl, '\'
    je      .vb_esc_bs
    cmp     bl, '"'
    je      .vb_esc_q
    ; Unknown escape — just store the next char
    lodsb
    stosb
    inc     r14
    jmp     .vb_copy_output

.vb_esc_n:
    mov     byte [rdi], 10          ; newline
    inc     rdi
    inc     r14
    inc     rsi                     ; skip the 'n'
    jmp     .vb_copy_output

.vb_esc_r:
    mov     byte [rdi], 13          ; carriage return
    inc     rdi
    inc     r14
    inc     rsi
    jmp     .vb_copy_output

.vb_esc_t:
    mov     byte [rdi], 9           ; tab
    inc     rdi
    inc     r14
    inc     rsi
    jmp     .vb_copy_output

.vb_esc_b:
    mov     byte [rdi], 8           ; backspace
    inc     rdi
    inc     r14
    inc     rsi
    jmp     .vb_copy_output

.vb_esc_f:
    mov     byte [rdi], 12          ; formfeed
    inc     rdi
    inc     r14
    inc     rsi
    jmp     .vb_copy_output

.vb_esc_bs:
    mov     byte [rdi], '\'
    inc     rdi
    inc     r14
    inc     rsi
    jmp     .vb_copy_output

.vb_esc_q:
    mov     byte [rdi], '"'
    inc     rdi
    inc     r14
    inc     rsi
    jmp     .vb_copy_output

.vb_copy_store:
    stosb
    inc     r14
    jmp     .vb_copy_output

.vb_copy_end:
    ; Null-terminate output_buf
    mov     byte [rdi], 0
    jmp     .vb_extract_exit_code

.vb_output_not_found:
    ; No "output" key — leave output_buf empty
    xor     r14d, r14d
    lea     rdi, [rel output_buf]
    mov     byte [rdi], 0

    ; --- Extract "exit_code" number ---
.vb_extract_exit_code:
    ; Find '"exit_code":' in the raw response
    lea     rdi, [rel visibox_response_raw]
    lea     rsi, [rel vb_key_exit_code]
    call    str_find
    test    rax, rax
    jz      .vb_no_exit_code

    ; rax points to '"exit_code":'
    ; Skip past '"exit_code":' (12 bytes) to get to the number
    add     rax, 12

    ; Skip whitespace
.vb_skip_ws:
    movzx   ecx, byte [rax]
    cmp     cl, ' '
    je      .vb_ws_adv
    cmp     cl, 10
    je      .vb_ws_adv
    cmp     cl, 13
    je      .vb_ws_adv
    cmp     cl, 9
    je      .vb_ws_adv
    jmp     .vb_parse_num
.vb_ws_adv:
    inc     rax
    jmp     .vb_skip_ws

.vb_parse_num:
    ; Parse integer (may be negative)
    xor     ecx, ecx               ; ecx = accumulated number
    mov     r8d, 1                  ; r8d = sign (1 = positive)
    movzx   edx, byte [rax]

    ; Check for negative sign
    cmp     dl, '-'
    jne     .vb_not_neg
    mov     r8d, -1
    inc     rax
    movzx   edx, byte [rax]
.vb_not_neg:

    ; Check for positive sign
    cmp     dl, '+'
    jne     .vb_digit_loop
    inc     rax
    movzx   edx, byte [rax]

.vb_digit_loop:
    cmp     dl, '0'
    jb      .vb_num_done
    cmp     dl, '9'
    ja      .vb_num_done

    ; ecx = ecx * 10 + (dl - '0')
    imul    ecx, ecx, 10
    sub     dl, '0'
    movzx   edx, dl
    add     ecx, edx
    inc     rax
    movzx   edx, byte [rax]
    jmp     .vb_digit_loop

.vb_num_done:
    ; Apply sign
    imul    ecx, r8d

    ; Store output_len
    mov     [rel output_len], r14

    ; Return exit code in rax
    mov     eax, ecx
    jmp     .vb_cleanup

.vb_no_exit_code:
    ; No exit_code found — default to 1 (error)
    mov     [rel output_len], r14
    mov     rax, 1

.vb_cleanup:
    ; If output is empty but exit code is 0, add hint so the model understands
    test    r14, r14
    jnz     .vb_cleanup_done
    ; output_len == 0 — copy "(no stdout output)" to output_buf
    lea     rdi, [rel output_buf]
    lea     rsi, [rel vb_empty_output]
    call    str_copy
    mov     [rel output_len], rax
.vb_cleanup_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; --- Error handlers for pipe/fork failures ---
.vb_close_stdin_pipe:
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax]
    mov     eax, SYS_CLOSE
    syscall
    lea     rax, [rel visibox_pipe_fds]
    mov     edi, [rax + 4]
    mov     eax, SYS_CLOSE
    syscall
.vb_pipe_error:
    mov     rax, -1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

.vb_fork_error:
    ; Close all 4 pipe fds
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
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; ============================================================================
