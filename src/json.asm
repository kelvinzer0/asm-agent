; ============================================================================
; json.asm — ASM-AGENT JSON Payload Builder (Tool Calls Architecture)
; ============================================================================
; Builds the Chat Completions API request JSON in payload_buf.
; Supports multi-turn conversation via messages_buf.
;
; Architecture:
;   - messages_buf stores the JSON content inside "messages":[...]
;   - Initial messages (system + user) are written by messages_init
;   - After each tool call, messages are appended by messages_append_*
;   - build_payload wraps messages_buf in the full JSON envelope
;
; Export:
;   messages_init        — Write initial system+user messages to messages_buf
;   messages_append_tc   — Append assistant tool_call message to messages_buf
;   messages_append_tr   — Append tool result message to messages_buf
;   build_payload        — Wrap messages_buf in full JSON, return length
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

; ---------------------------------------------------------------------------
; External data
; ---------------------------------------------------------------------------
extern payload_buf              ; PAYLOAD_BUF_SZ bytes
extern task_buf                 ; TASK_BUF_SZ bytes
extern task_len                 ; qword
extern worklog_buf              ; WORKLOG_BUF_SZ bytes
extern worklog_ctx_len          ; qword
extern cwd_buf                  ; current working directory
extern cwd_len                  ; length of cwd
extern messages_buf             ; MESSAGES_BUF_SZ bytes
extern messages_len             ; qword — current length in messages_buf
extern temp_buf                 ; TEMP_BUF_SZ bytes
extern content_buf              ; CONTENT_BUF_SZ — parsed response content
extern tool_call_id_buf         ; TOOL_CALL_ID_SZ — parsed tool call ID
extern tool_call_name_buf       ; TOOL_CALL_NAME_SZ — parsed function name
extern tool_call_args_buf       ; TOOL_CALL_ARGS_SZ — parsed arguments
extern output_buf               ; OUTPUT_BUF_SZ — command output
extern output_len               ; qword

; ---------------------------------------------------------------------------
; External functions
; ---------------------------------------------------------------------------
extern str_len
extern str_copy
extern str_concat
extern str_escape_json
extern str_ncopy
extern str_starts_with
extern str_find

; ---------------------------------------------------------------------------
; Export
; ---------------------------------------------------------------------------
global messages_init
global messages_append_tc
global messages_append_tr
global build_payload

; ============================================================================
; Read-only literal fragments
; ============================================================================
section .rodata

; ========================================================================
section .text
; ========================================================================

; ----------------------------------------------------------------------------
; write_str — Write null-terminated string to [rdi], advance rdi
; Input:  rdi = write pointer, rsi = source string
; Output: rdi = advanced past copied content
; Clobbers: rax, rsi
; ----------------------------------------------------------------------------
write_str:
    mov     rsi, rdi            ; save dst in rsi for lodsb pattern... no wait
    ; Actually: rdi = dst, but we need rsi = src. Let me use r12 pattern.
    ; Simpler: rdi is passed as pointer, we use lodsb from rsi
    ; BUT we want to ADVANCE rdi. So:
    push    rdi
    pop     rsi                 ; rsi = rdi (dst = src, copy in place? No...)
    ; This is wrong. Let me just do it directly.
    ; Actually the caller passes rdi=dst and the string is the second arg.
    ; Let me rethink. The pattern from the old code used r12 as write pointer
    ; and passed source in rdi to call copy_literal.
    ; Here I'll just use a simple inline copy.
.write_str_ret:
    ret

; ============================================================================
; messages_init — Write initial system+user messages to messages_buf
; ============================================================================
; Writes:
;   {"role":"system","content":"ESCAPED_SYSTEM_PROMPT\nWorking directory: CWD"},
;   {"role":"user","content":"TASK: ESCAPED_TASK\n\n--- WORKLOG ---\nESCAPED_WORKLOG\n\nUse absolute paths..."}
;
; Sets messages_len to the total bytes written.
; ============================================================================
messages_init:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14
    push    rbx

    lea     r12, [rel messages_buf]  ; r12 = write pointer
    lea     r13, [rel messages_buf]  ; r13 = base (for length calc)

    ; --- System message opening: {"role":"system","content":" ---
    lea     rdi, [rel json_p2]
    ; json_p2 = '{"model":"...","messages":[', but we don't want the model part here.
    ; Actually, I need to write just the first message starting with {
    ; The payload builder will prepend the model+messages opening.
    ; So messages_buf content is:
    ;   {"role":"system",...},  {"role":"user",...}
    ; And build_payload wraps: {"model":"X","messages":[ CONTENT ],"tools":...}

    ; Write: {"role":"system","content":"
    lea     rsi, [rel msg_sys_start]
    call    jl_copy_r12

    ; Write escaped system prompt
    mov     rax, r12
    sub     rax, r13
    mov     rdx, MESSAGES_BUF_SZ
    sub     rdx, rax
    sub     rdx, 4096            ; reserve space

    mov     rdi, r12
    lea     rsi, [rel system_prompt]
    call    str_escape_json
    add     r12, rax

    ; Write: \nWorking directory:
    lea     rsi, [rel json_cwd_prefix]
    call    jl_copy_r12

    ; Write actual CWD
    lea     rsi, [rel cwd_buf]
.cwd_loop:
    lodsb
    test    al, al
    jz      .cwd_done
    mov     [r12], al
    inc     r12
    jmp     .cwd_loop
.cwd_done:

    ; Write: "},
    mov     byte [r12], '"'
    inc     r12
    mov     byte [r12], '}'
    inc     r12
    mov     byte [r12], ','
    inc     r12

    ; --- User message: {"role":"user","content":"TASK: ---
    lea     rsi, [rel msg_user_start]
    call    jl_copy_r12

    ; Write: TASK:
    lea     rsi, [rel json_task]
    call    jl_copy_r12

    ; Write escaped task
    mov     rax, r12
    sub     rax, r13
    mov     rdx, MESSAGES_BUF_SZ
    sub     rdx, rax
    sub     rdx, 4096

    mov     rdi, r12
    lea     rsi, [rel task_buf]
    call    str_escape_json
    add     r12, rax

    ; Write worklog separator
    lea     rsi, [rel json_wl_sep]
    call    jl_copy_r12

    ; Write escaped worklog (if any)
    mov     rax, [rel worklog_ctx_len]
    test    rax, rax
    jz      .skip_init_wl

    mov     rax, r12
    sub     rax, r13
    mov     rdx, MESSAGES_BUF_SZ
    sub     rdx, rax
    sub     rdx, 2048

    test    rdx, rdx
    jle     .skip_init_wl

    mov     rdi, r12
    lea     rsi, [rel worklog_buf]
    call    str_escape_json
    add     r12, rax

.skip_init_wl:
    ; Write: \n\nUse absolute paths..."}
    lea     rsi, [rel pwd_hint]
    call    jl_copy_r12

    ; Close user message: "}
    mov     byte [r12], '"'
    inc     r12
    mov     byte [r12], '}'
    inc     r12

    ; Null-terminate
    mov     byte [r12], 0

    ; Store messages_len
    mov     rax, r12
    sub     rax, r13
    mov     [rel messages_len], rax

    pop     rbx
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret

; --- Helper: copy null-terminated string from [rsi] to [r12], advance r12 ---
; Input: rsi = source, r12 = write pointer
; Output: r12 advanced
jl_copy_r12:
    push    rax
.jlt_loop:
    lodsb
    test    al, al
    jz      .jlt_done
    mov     [r12], al
    inc     r12
    jmp     .jlt_loop
.jlt_done:
    pop     rax
    ret

; --- Message start literals ---
section .rodata
msg_sys_start:  db '{"role":"system","content":"', 0
msg_user_start: db '{"role":"user","content":"', 0

section .text

; ============================================================================
; messages_append_tc — Append assistant tool_call message to messages_buf
; ============================================================================
; Reads: tool_call_id_buf, tool_call_name_buf, tool_call_args_buf, content_buf
; Appends JSON like:
;   ,{"role":"assistant","content":"REASONING","tool_calls":[{"id":"ID","type":"function","function":{"name":"NAME","arguments":"ARGS"}}]}
;
; Note: content (reasoning) may be empty string.
; Note: tool_call_args is already a JSON string, needs re-escaping for embedding.
; ============================================================================
messages_append_tc:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    rbx

    ; r12 = current end of messages_buf
    lea     r12, [rel messages_buf]
    add     r12, [rel messages_len]

    ; --- ,{"role":"assistant","content":" ---
    lea     rsi, [rel msg_assistant_tc]
    call    jl_copy_r12

    ; --- Escaped content (reasoning) ---
    ; Escape content_buf into temp_buf first, then copy to messages_buf
    lea     rdi, [rel temp_buf]
    lea     rsi, [rel content_buf]
    mov     rdx, TEMP_BUF_SZ - 2
    call    str_escape_json
    ; Now copy from temp_buf to messages_buf
    lea     rsi, [rel temp_buf]
.tc_content_copy:
    lodsb
    test    al, al
    jz      .tc_content_done
    mov     [r12], al
    inc     r12
    jmp     .tc_content_copy
.tc_content_done:

    ; --- ","tool_calls":[{"id":" ---
    lea     rsi, [rel msg_assistant_tc_mid]
    call    jl_copy_r12

    ; --- tool_call_id (literal, no escaping needed) ---
    lea     rsi, [rel tool_call_id_buf]
    call    jl_copy_r12

    ; --- ","type":"function","function":{"name":" ---
    lea     rsi, [rel msg_assistant_tc_fn]
    call    jl_copy_r12

    ; --- function name (literal) ---
    lea     rsi, [rel tool_call_name_buf]
    call    jl_copy_r12

    ; --- ","arguments":" ---
    lea     rsi, [rel msg_assistant_tc_args]
    call    jl_copy_r12

    ; --- arguments (need JSON re-escaping since it's a JSON string inside JSON) ---
    ; The arguments string is like: {"command":"ls -la"}
    ; We need to escape " and \ for embedding inside a JSON string value.
    ; Escape into temp_buf first.
    lea     rdi, [rel temp_buf]
    lea     rsi, [rel tool_call_args_buf]
    mov     rdx, TEMP_BUF_SZ - 2
    call    str_escape_json
    ; Copy from temp_buf to messages_buf
    lea     rsi, [rel temp_buf]
.tc_args_copy:
    lodsb
    test    al, al
    jz      .tc_args_done
    mov     [r12], al
    inc     r12
    jmp     .tc_args_copy
.tc_args_done:

    ; --- "}}]} ---
    lea     rsi, [rel msg_assistant_tc_end]
    call    jl_copy_r12

    ; Null-terminate and update messages_len
    mov     byte [r12], 0
    lea     rax, [rel messages_buf]
    sub     r12, rax
    mov     [rel messages_len], r12

    pop     rbx
    pop     r12
    pop     rbp
    ret

; ============================================================================
; messages_append_tr — Append tool result message to messages_buf
; ============================================================================
; Reads: tool_call_id_buf, output_buf, output_len
; Appends JSON like:
;   ,{"role":"tool","tool_call_id":"ID","content":"ESCAPED_OUTPUT"}
;
; If is_empty flag (rbx=1), appends empty content.
; ============================================================================
messages_append_tr:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    rbx

    ; Check if we should use empty content (for task_complete)
    ; We determine this by checking tool_call_name_buf
    lea     rdi, [rel tool_call_name_buf]
    lea     rsi, [rel tc_name_task_complete]
    call    str_starts_with
    mov     rbx, rax            ; rbx = 1 if task_complete, 0 otherwise

    lea     r12, [rel messages_buf]
    add     r12, [rel messages_len]

    ; --- ,{"role":"tool","tool_call_id":" ---
    lea     rsi, [rel msg_tool_result]
    call    jl_copy_r12

    ; --- tool_call_id ---
    lea     rsi, [rel tool_call_id_buf]
    call    jl_copy_r12

    test    rbx, rbx
    jnz     .empty_result

    ; --- ","content":"ESCAPED_OUTPUT"} ---
    lea     rsi, [rel msg_tool_result_mid]
    call    jl_copy_r12

    ; Escape output_buf into temp_buf
    lea     rdi, [rel temp_buf]
    lea     rsi, [rel output_buf]
    mov     rdx, TEMP_BUF_SZ - 2
    call    str_escape_json
    ; Copy from temp_buf to messages_buf (limit to reasonable size)
    lea     rsi, [rel temp_buf]
    lea     r13, [rel messages_buf]
    add     r13, MESSAGES_BUF_SZ - 256  ; leave 256 bytes margin
.tr_output_copy:
    cmp     r12, r13
    jge     .tr_output_done
    lodsb
    test    al, al
    jz      .tr_output_done
    mov     [r12], al
    inc     r12
    jmp     .tr_output_copy
.tr_output_done:

    ; --- "} ---
    mov     byte [r12], '"'
    inc     r12
    mov     byte [r12], '}'
    inc     r12
    jmp     .tr_done

.empty_result:
    ; --- ","content":""} ---
    lea     rsi, [rel msg_tool_empty_mid]
    call    jl_copy_r12
    lea     rsi, [rel msg_tool_result_end]
    call    jl_copy_r12

.tr_done:
    mov     byte [r12], 0
    lea     rax, [rel messages_buf]
    sub     r12, rax
    mov     [rel messages_len], r12

    pop     rbx
    pop     r13
    pop     r12
    pop     rbp
    ret

section .rodata
tc_name_task_complete: db 'task_complete', 0

section .text

; ============================================================================
; build_payload — Construct full JSON payload in payload_buf
; ============================================================================
; Wraps messages_buf content in:
;   {"model":"mmf/mimo-auto","messages":[MESSAGES],"tools":[...],...}
;
; Returns: rax = total bytes written to payload_buf
; ============================================================================
build_payload:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14

    lea     r13, [rel payload_buf]  ; r13 = base
    mov     r12, r13               ; r12 = write pointer

    ; --- {"model":" ---
    lea     rdi, [rel json_p1]
    call    .copy_to_r12

    ; --- model name ---
    lea     rdi, [rel model_name]
    call    .copy_to_r12

    ; --- ","messages":[ ---
    lea     rdi, [rel json_p2]
    call    .copy_to_r12

    ; --- messages_buf content ---
    lea     rsi, [rel messages_buf]
    mov     rcx, [rel messages_len]
.msg_copy:
    test    rcx, rcx
    jz      .msg_copy_done
    movzx   eax, byte [rsi]
    mov     [r12], al
    inc     rsi
    inc     r12
    dec     rcx
    jmp     .msg_copy
.msg_copy_done:

    ; --- Close the messages array: ] ---
    mov     byte [r12], ']'
    inc     r12

    ; --- tools_json (starts with ,) + tool_choice + temperature + closing } ---
    ; tools_json = ',"tools":[...],"tool_choice":"auto","temperature":0.2,...}'
    lea     rdi, [rel tools_json]
    call    .copy_to_r12

    ; Null-terminate
    mov     byte [r12], 0

    ; Compute length
    mov     rax, r12
    sub     rax, r13

    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret

; --- Helper: copy null-terminated string from [rdi] to [r12], advance r12 ---
.copy_to_r12:
    push    rsi
    mov     rsi, rdi
.copy_r12_loop:
    lodsb
    test    al, al
    jz      .copy_r12_done
    mov     [r12], al
    inc     r12
    jmp     .copy_r12_loop
.copy_r12_done:
    pop     rsi
    ret