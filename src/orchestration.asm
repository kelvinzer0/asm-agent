; ============================================================================
; orchestration.asm — Swarm/LangGraph Orchestration Engine
; ============================================================================
; Core orchestration implementing:
;   - Mode-based execution (Planner/Researcher/Executor/Verifier)
;   - Handoff detection and routing (Swarm pattern)
;   - Graph-based conditional edges (LangGraph pattern)
;   - Integration with Musical Conductor
;
; API:
;   orchestration_init          — Initialize orchestration system
;   orchestration_get_prompt    — Get system prompt for current mode
;   orchestration_check_handoff — Check if response contains HANDOFF
;   orchestration_handoff       — Execute mode switch
;   orchestration_get_delay     — Get mode-specific delay
;   orchestration_log_state     — Log current orchestration state
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"
%include "musical.inc"
%include "orchestration.inc"

; --- External data ---
extern musical_state
extern temp_buf
extern timestamp_buf
extern iteration_count
extern task_buf
extern command_buf

; --- External functions ---
extern str_len
extern str_copy
extern str_concat
extern str_find
extern str_starts_with
extern uint_to_str
extern get_timestamp
extern worklog_append_entry
extern worklog_append_raw
extern exec_streak

; --- Export ---
global orchestration_init
global orchestration_get_prompt
global orchestration_check_handoff
global orchestration_handoff
global orchestration_get_delay
global orchestration_log_state
global orchestration_validate_handoff
global current_mode
global checkpoint_data

; ============================================================================
section .data
; ============================================================================

; Current execution mode
current_mode:   db MODE_RESEARCHER   ; Start in researcher mode

; Checkpoint data (64 bytes)
checkpoint_data: times CP_SIZE db 0

; Mode-specific prompt pointers
mode_prompts:
    dq planner_prompt_ptr
    dq researcher_prompt_ptr
    dq executor_prompt_ptr
    dq verifier_prompt_ptr
    dq 0   ; DONE has no prompt

mode_prompt_ptrs:
planner_prompt_ptr:     dq 0    ; will be set to config.inc prompts
researcher_prompt_ptr:  dq 0
executor_prompt_ptr:    dq 0
verifier_prompt_ptr:    dq 0

; ============================================================================
section .rodata
; ============================================================================

; Orchestration log label
wl_orch_state:  db 'ORCHESTRATION', 0

; State format
orch_fmt_mode:      db 'Mode: ', 0
orch_fmt_sep:       db ' | ', 0
orch_fmt_iteration: db 'Iter: ', 0
orch_fmt_streak:    db 'Streak: ', 0

; Invalid handoff log messages
wl_orch_invalid:          db 'ORCHESTRATION', 0
invalid_handoff_prefix:   db 'Invalid handoff rejected: ', 0
invalid_handoff_from:     db ' -> ', 0
invalid_handoff_suffix:   db ' (not in graph edges)', 10, 0

; --- Graph Edge Table ---
; Bitmask of valid target modes per source mode
; Bit 0=PLANNER 1=RESEARCHER 2=EXECUTOR 3=VERIFIER 4=DONE
graph_edges:
    db 0b00000010  ; PLANNER    -> RESEARCHER
    db 0b00000100  ; RESEARCHER -> EXECUTOR
    db 0b00011010  ; EXECUTOR   -> RESEARCHER, VERIFIER, DONE
    db 0b00000110  ; VERIFIER   -> RESEARCHER, EXECUTOR
    db 0b00000000  ; DONE       -> nowhere

; Handoff prefixes (exported for parser.asm)
global handoff_prefix
global done_prefix
handoff_prefix:     db 'HANDOFF:', 0
done_prefix:        db 'DONE:', 0
handoff_planner:    db 'PLANNER', 0
handoff_researcher: db 'RESEARCHER', 0
handoff_executor:   db 'EXECUTOR', 0
handoff_verifier:   db 'VERIFIER', 0

; ============================================================================
section .text
; ============================================================================

; ============================================================================
; orchestration_init — Initialize orchestration system
; ============================================================================
orchestration_init:
    push    rbp
    mov     rbp, rsp

    ; Set initial mode
    mov     byte [current_mode], MODE_RESEARCHER

    ; Clear checkpoint data
    lea     rdi, [rel checkpoint_data]
    xor     al, al
    mov     rcx, CP_SIZE
    rep     stosb

    ; Set prompt pointers from config.inc
    lea     rax, [rel config_planner_prompt]
    mov     [rel planner_prompt_ptr], rax
    lea     rax, [rel config_researcher_prompt]
    mov     [rel researcher_prompt_ptr], rax
    lea     rax, [rel config_executor_prompt]
    mov     [rel executor_prompt_ptr], rax
    lea     rax, [rel config_verifier_prompt]
    mov     [rel verifier_prompt_ptr], rax

    pop     rbp
    ret

; ============================================================================
; orchestration_get_prompt — Get system prompt for current mode
; ============================================================================
; Returns: rsi = prompt pointer, rax = prompt length
orchestration_get_prompt:
    push    rbx

    movzx   eax, byte [current_mode]
    cmp     eax, MODE_DONE
    jge     .no_prompt

    ; Get prompt pointer from table (double indirection)
    lea     rbx, [rel mode_prompts]
    mov     rsi, [rbx + rax * 8]   ; rsi = address of prompt_ptr
    mov     rsi, [rsi]             ; rsi = actual prompt string address

    ; Get prompt length
    call    str_len
    jmp     .done

.no_prompt:
    xor     eax, eax
    xor     esi, esi

.done:
    pop     rbx
    ret

; ============================================================================
; orchestration_check_handoff — Check if response contains HANDOFF
; ============================================================================
; Input: rdi = response string (command_buf)
; Returns: rax = target mode (MODE_*) or -1 if no handoff
orchestration_check_handoff:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, -1             ; default: no handoff

    ; First check for DONE:
    lea     rsi, [rel done_prefix]
    mov     rdi, rbx
    call    str_starts_with
    test    rax, rax
    jnz     .found_done

    ; Check for HANDOFF: prefix
    lea     rsi, [rel handoff_prefix]
    mov     rdi, rbx
    call    str_starts_with
    test    rax, rax
    jz      .not_found          ; no HANDOFF prefix

    ; Skip past "HANDOFF:" (8 bytes) and whitespace
    lea     r13, [rbx + 8]
.skip_ws:
    movzx   eax, byte [r13]
    cmp     al, ' '
    je      .ws_ok
    cmp     al, 9               ; tab
    je      .ws_ok
    jmp     .check_modes
.ws_ok:
    inc     r13
    jmp     .skip_ws

.check_modes:
    ; Check PLANNER
    lea     rsi, [rel handoff_planner]
    mov     rdi, r13
    call    str_starts_with
    test    rax, rax
    jnz     .found_planner

    ; Check RESEARCHER
    lea     rsi, [rel handoff_researcher]
    mov     rdi, r13
    call    str_starts_with
    test    rax, rax
    jnz     .found_researcher

    ; Check EXECUTOR
    lea     rsi, [rel handoff_executor]
    mov     rdi, r13
    call    str_starts_with
    test    rax, rax
    jnz     .found_executor

    ; Check VERIFIER
    lea     rsi, [rel handoff_verifier]
    mov     rdi, r13
    call    str_starts_with
    test    rax, rax
    jnz     .found_verifier

    jmp     .not_found

.found_planner:
    mov     r12d, MODE_PLANNER
    jmp     .validate_edge
.found_researcher:
    mov     r12d, MODE_RESEARCHER
    jmp     .validate_edge
.found_executor:
    mov     r12d, MODE_EXECUTOR
    jmp     .validate_edge
.found_verifier:
    mov     r12d, MODE_VERIFIER
    jmp     .validate_edge
.found_done:
    mov     r12d, MODE_DONE

.validate_edge:
    ; Skip validation for DONE (terminal state, always allowed)
    ; and for -1 (no handoff found)
    cmp     r12d, -1
    je      .not_found
    cmp     r12d, MODE_DONE
    je      .not_found

    ; Call orchestration_validate_handoff(target=r12d)
    mov     edi, r12d
    call    orchestration_validate_handoff
    test    rax, rax
    jnz     .not_found              ; valid edge → proceed

    ; --- Invalid edge: log warning and reject ---
    push    rax
    push    rcx
    push    rdx

    ; Build warning: "Invalid handoff rejected: <from> -> <to> (not in graph edges)\n"
    lea     rdi, [rel temp_buf]
    lea     rsi, [rel invalid_handoff_prefix]
    call    str_copy

    ; Append source mode name
    movzx   eax, byte [current_mode]
    lea     rcx, [rel mode_names]
    mov     rsi, [rcx + rax * 8]
    lea     rdi, [rel temp_buf]
    call    str_concat

    ; Append " -> "
    lea     rsi, [rel invalid_handoff_from]
    lea     rdi, [rel temp_buf]
    call    str_concat

    ; Append target mode name
    mov     eax, r12d
    lea     rcx, [rel mode_names]
    mov     rsi, [rcx + rax * 8]
    lea     rdi, [rel temp_buf]
    call    str_concat

    ; Append suffix
    lea     rsi, [rel invalid_handoff_suffix]
    lea     rdi, [rel temp_buf]
    call    str_concat

    ; Log to worklog
    lea     rdi, [rel wl_orch_invalid]
    lea     rsi, [rel temp_buf]
    call    worklog_append_entry

    pop     rdx
    pop     rcx
    pop     rax

    ; Reject: treat as no handoff
    mov     r12d, -1

.not_found:
    mov     rax, r12
    pop     r12
    pop     rbx
    ret

; ============================================================================
; orchestration_handoff — Execute mode switch
; ============================================================================
; Input: rax = target mode
orchestration_handoff:
    push    rbx
    push    rcx

    mov     bl, al              ; bl = target mode

    ; Update current mode
    mov     [current_mode], al

    ; Update musical style based on mode
    lea     rcx, [rel musical_state]
    lea     rsi, [rel mode_style_map]
    movzx   eax, bl
    movzx   eax, byte [rsi + rax]
    mov     [rcx + MS_STYLE], al

    ; Update tempo based on mode
    lea     rsi, [rel mode_delays]
    movzx   eax, bl
    mov     rax, [rsi + rax * 8]
    mov     [rcx + MS_BEAT_NS], rax

    pop     rcx
    pop     rbx
    ret

; ============================================================================
; orchestration_get_delay — Get mode-specific delay in nanoseconds
; ============================================================================
; Returns: rax = delay in nanoseconds
orchestration_get_delay:
    movzx   eax, byte [current_mode]
    lea     rcx, [rel mode_delays]
    mov     rax, [rcx + rax * 8]
    ret

; ============================================================================
; orchestration_validate_handoff — Check if handoff follows graph edges
; Input:  dil = target mode
; Returns: rax = 1 if valid, 0 if invalid
orchestration_validate_handoff:
    movzx   eax, byte [current_mode]
    lea     rcx, [rel graph_edges]
    movzx   edx, byte [rcx + rax]
    mov     ecx, edi
    mov     eax, 1
    shl     eax, cl
    and     eax, edx
    setnz   al
    movzx   eax, al
    ret

; orchestration_log_state — Log current orchestration state
; ============================================================================
orchestration_log_state:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13

    lea     rbx, [rel current_mode]
    lea     r12, [rel temp_buf]
    mov     r13, r12            ; r13 = base for length calc

    ; Build state string: "Mode: Executor | Iter: 5 | Streak: 2"
    mov     rdi, r12
    lea     rsi, [rel orch_fmt_mode]
    call    .copy_str

    ; Mode name
    movzx   eax, byte [rbx]
    lea     rcx, [rel mode_names]
    mov     rsi, [rcx + rax * 8]
    mov     rdi, r12
    call    .copy_str_to_r12

    ; " | "
    lea     rsi, [rel orch_fmt_sep]
    mov     rdi, r12
    call    .copy_str_to_r12

    ; "Iter: N"
    lea     rdi, [r12]
    lea     rsi, [rel orch_fmt_iteration]
    call    .copy_str
    mov     eax, [iteration_count]
    mov     rdi, r12
    mov     esi, eax
    push    rbx
    mov     rbx, rdi
    sub     rsp, 16
    mov     rdi, rsp
    call    uint_to_str
    mov     rdi, rbx
    mov     rsi, rsp
    call    .copy_str_to_r12
    add     rsp, 16
    pop     rbx

    ; " | Streak: N"
    lea     rsi, [rel orch_fmt_sep]
    mov     rdi, r12
    call    .copy_str_to_r12

    lea     rdi, [r12]
    lea     rsi, [rel orch_fmt_streak]
    call    .copy_str
    mov     eax, [rel exec_streak]
    mov     rdi, r12
    mov     esi, eax
    push    rbx
    mov     rbx, rdi
    sub     rsp, 16
    mov     rdi, rsp
    call    uint_to_str
    mov     rdi, rbx
    mov     rsi, rsp
    call    .copy_str_to_r12
    add     rsp, 16
    pop     rbx

    ; Newline
    mov     byte [r12], 10
    inc     r12

    ; Null terminate
    mov     byte [r12], 0

    ; Calculate length
    mov     rsi, r12
    sub     rsi, r13

    lea     rdi, [rel temp_buf]
    call    worklog_append_raw

    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; --- Helper: copy string ---
.copy_str:
.copy_loop:
    lodsb
    test    al, al
    jz      .copy_done
    mov     [rdi], al
    inc     rdi
    inc     r12
    jmp     .copy_loop
.copy_done:
    ret

; --- Helper: copy string to r12 position ---
.copy_str_to_r12:
    mov     rdi, r12
.copy_r12_loop:
    lodsb
    test    al, al
    jz      .copy_r12_done
    mov     [rdi], al
    inc     rdi
    inc     r12
    jmp     .copy_r12_loop
.copy_r12_done:
    ret
