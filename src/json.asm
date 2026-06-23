; ============================================================================
; json.asm — ASM-AGENT JSON Payload Builder
; ============================================================================
; Builds the Chat Completions API request JSON in payload_buf.
;
; Output format:
;   {"model":"gpt-4o-mini","messages":[
;     {"role":"system","content":"ESCAPED_SYSTEM_PROMPT"},
;     {"role":"user","content":"TASK: ESCAPED_TASK\n\n--- WORKLOG ---\nESCAPED_WORKLOG"}
;   ],"temperature":0.2,"max_tokens":1024}
;
; Export:
;   build_payload -> rax = total byte length written to payload_buf
;
; Register convention:
;   r12 = running write pointer into payload_buf
;   r13 = base of payload_buf (for computing length at the end)
;   r14 = remaining space in payload_buf
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

; ---------------------------------------------------------------------------
; External data (defined in data.asm / main.asm)
; ---------------------------------------------------------------------------
extern payload_buf              ; resb PAYLOAD_BUF_SZ (131072)
extern task_buf                 ; resb TASK_BUF_SZ    (4096)
extern task_len                 ; resq 1
extern worklog_buf              ; resb WORKLOG_BUF_SZ (65536)
extern worklog_ctx_len          ; resq 1
extern active_system_prompt     ; qword — pointer to current system prompt
extern cwd_buf                  ; current working directory
extern cwd_len                  ; length of cwd

; ---------------------------------------------------------------------------
; External functions (defined in string.asm)
; ---------------------------------------------------------------------------
extern str_len                  ; rdi=str -> rax=length
extern str_copy                 ; rdi=dst, rsi=src -> rax=bytes copied
extern str_concat               ; rdi=dst, rsi=src -> rax=total length
extern str_escape_json          ; rdi=dst, rsi=src, rdx=max_out -> rax=bytes written

; ---------------------------------------------------------------------------
; Export
; ---------------------------------------------------------------------------
global build_payload

; ============================================================================
; Read-only literal fragments for JSON structure
; ============================================================================
section .rodata

; Fragment 1: opening brace + model key
json_p1:    db '{"model":"', 0

; Fragment 2: close model value, open messages array + system role
json_p2:    db '","messages":[{"role":"system","content":"', 0

; Fragment 3: close system message, open user message
json_p3:    db '"},{"role":"user","content":"', 0

; Fragment 4: close user message, params, close object
json_p4:    db '"}],"temperature":0.2,"max_tokens":1024,"stream":false}', 0

; "TASK: " prefix for user content
json_task:  db 'TASK: ', 0

; Working directory hint for system prompt
json_cwd_prefix: db '\\nWorking directory: ', 0

; Worklog separator (JSON-escaped newlines: literal backslash-n sequences)
; In the JSON string, \n is the two-character escape sequence for newline.
json_wl_sep:
    db '\n\n--- WORKLOG (last 20 entries) ---\n', 0

; ============================================================================
section .text
; ============================================================================

; ----------------------------------------------------------------------------
; copy_literal — Copy a null-terminated string to [r12], advance r12
; ----------------------------------------------------------------------------
; Input:
;   rdi = pointer to null-terminated source string
;   r12 = current write pointer (destination)
; Output:
;   r12 = advanced past the copied content (does NOT include null terminator)
; Clobbers: rax, rsi
; ----------------------------------------------------------------------------
copy_literal:
    mov     rsi, rdi            ; rsi = source pointer
.loop:
    lodsb                       ; al = [rsi], rsi++
    test    al, al              ; null terminator?
    jz      .done
    mov     [r12], al           ; store byte
    inc     r12                 ; advance write pointer
    jmp     .loop
.done:
    ret

; ============================================================================
; build_payload — Construct full JSON payload in payload_buf
; ============================================================================
; Returns:
;   rax = total number of bytes written to payload_buf
; Callee-saved registers used: r12, r13, r14 (preserved on stack)
; ============================================================================
build_payload:
    ; --- Prologue: save callee-saved registers ---
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14
    push    rbx                 ; extra save for alignment

    ; --- Initialize write pointer and capacity tracker ---
    lea     r13, [rel payload_buf]      ; r13 = base address (for final length calc)
    mov     r12, r13                    ; r12 = current write pointer
    mov     r14, PAYLOAD_BUF_SZ         ; r14 = remaining capacity

    ; ---------------------------------------------------------------
    ; Part 1: {"model":"
    ; ---------------------------------------------------------------
    lea     rdi, [rel json_p1]
    call    copy_literal

    ; ---------------------------------------------------------------
    ; Part 2: model name (literal, no escaping needed — it's ASCII)
    ; ---------------------------------------------------------------
    lea     rdi, [rel model_name]
    call    copy_literal

    ; ---------------------------------------------------------------
    ; Part 3: ","messages":[{"role":"system","content":"
    ; ---------------------------------------------------------------
    lea     rdi, [rel json_p2]
    call    copy_literal

    ; ---------------------------------------------------------------
    ; Part 4: Escaped system prompt
    ; ---------------------------------------------------------------
    ; Calculate remaining buffer space
    mov     rax, r12
    sub     rax, r13            ; rax = bytes used so far
    mov     rdx, PAYLOAD_BUF_SZ
    sub     rdx, rax            ; rdx = remaining space
    sub     rdx, 256            ; reserve 256 bytes for closing fragments

    mov     rdi, r12            ; dst = current write position
    mov     rsi, [rel active_system_prompt]  ; src = active system prompt
    ; rdx = max output bytes (already set)
    call    str_escape_json     ; rax = bytes written
    add     r12, rax            ; advance write pointer

    ; --- Append working directory hint to system prompt ---
    ; Write "\nWorking directory: " (JSON-escaped)
    lea     rdi, [rel json_cwd_prefix]
    call    copy_literal

    ; Write the actual cwd (already a path, no escaping needed)
    lea     rsi, [rel cwd_buf]
    mov     rdi, r12
.cwd_copy:
    lodsb
    test    al, al
    jz      .cwd_done
    mov     [rdi], al
    inc     rdi
    jmp     .cwd_copy
.cwd_done:
    mov     r12, rdi

    ; ---------------------------------------------------------------
    ; Part 5: "},{"role":"user","content":"
    ; ---------------------------------------------------------------
    lea     rdi, [rel json_p3]
    call    copy_literal

    ; ---------------------------------------------------------------
    ; Part 6: "TASK: " prefix (literal, inside JSON string)
    ; ---------------------------------------------------------------
    lea     rdi, [rel json_task]
    call    copy_literal

    ; ---------------------------------------------------------------
    ; Part 7: Escaped task content
    ; ---------------------------------------------------------------
    mov     rax, r12
    sub     rax, r13
    mov     rdx, PAYLOAD_BUF_SZ
    sub     rdx, rax
    sub     rdx, 256            ; reserve space

    mov     rdi, r12            ; dst
    lea     rsi, [rel task_buf] ; src = task text
    ; rdx = max output bytes
    call    str_escape_json     ; rax = bytes written
    add     r12, rax

    ; ---------------------------------------------------------------
    ; Part 8: Worklog separator (escaped newlines + header)
    ; ---------------------------------------------------------------
    lea     rdi, [rel json_wl_sep]
    call    copy_literal

    ; ---------------------------------------------------------------
    ; Part 9: Escaped worklog content
    ; ---------------------------------------------------------------
    ; Only include worklog if worklog_ctx_len > 0
    mov     rax, [rel worklog_ctx_len]
    test    rax, rax
    jz      .skip_worklog       ; no worklog content, skip

    mov     rax, r12
    sub     rax, r13
    mov     rdx, PAYLOAD_BUF_SZ
    sub     rdx, rax
    sub     rdx, 128            ; reserve space for closing

    ; Clamp: don't try to write more than available
    test    rdx, rdx
    jle     .skip_worklog       ; no room left

    mov     rdi, r12            ; dst
    lea     rsi, [rel worklog_buf]  ; src = worklog text
    ; rdx = max output bytes
    call    str_escape_json     ; rax = bytes written
    add     r12, rax

.skip_worklog:

    ; ---------------------------------------------------------------
    ; Part 9b: Working directory reminder
    ; ---------------------------------------------------------------
    lea     rdi, [rel pwd_hint]
    call    copy_literal

    ; ---------------------------------------------------------------
    ; Part 10: "}],"temperature":0.2,"max_tokens":1024}
    ; ---------------------------------------------------------------
    lea     rdi, [rel json_p4]
    call    copy_literal

    ; ---------------------------------------------------------------
    ; Null-terminate the payload (not counted in length)
    ; ---------------------------------------------------------------
    mov     byte [r12], 0

    ; ---------------------------------------------------------------
    ; Compute total length: r12 - r13
    ; ---------------------------------------------------------------
    mov     rax, r12
    sub     rax, r13            ; rax = total bytes written

    ; --- Epilogue: restore callee-saved registers ---
    pop     rbx
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret
