; ============================================================================
; main.asm — ASM-AGENT Entry Point (Tool Calls Architecture)
; ============================================================================
; Build: nasm -f elf64 -I include/ src/main.asm -o src/main.o
;
; Tool call loop:
;   1. Display banner, read task
;   2. Initialize conversation (messages_buf)
;   3. Loop:
;      a. build_payload (from messages_buf)
;      b. call_api_retry
;      c. parse_response → tool_calls or content
;      d. If tool_call:
;         - Append assistant message to messages_buf
;         - Execute command (run_command) or handle done (task_complete)
;         - Append tool result to messages_buf
;      e. If content only (finish_reason: stop):
;         - Display, exit
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"
%include "musical.inc"
%include "orchestration.inc"

; --- External functions from other modules ---
extern str_len
extern str_copy
extern str_ncopy
extern str_concat
extern str_escape_json
extern str_find
extern str_starts_with
extern uint_to_str
extern int_to_str_padded
extern get_timestamp
extern setup_signals
extern worklog_init
extern worklog_read_context
extern worklog_append_raw
extern worklog_append_entry
extern build_payload
extern messages_init
extern messages_append_tc
extern messages_append_tr
extern parse_response
extern exec_command
extern check_blocked
extern call_api_retry

; --- Musical Orchestration externs ---
extern conductor_init
extern conductor_beat
extern conductor_adjust_tempo
extern conductor_adjust_dynamics
extern conductor_get_delay_ns
extern conductor_log_state
extern conductor_should_stop
extern musical_state
extern instrument_init
extern instrument_select
extern instrument_log_use
extern channel_init

; --- Swarm/LangGraph Orchestration externs ---
extern orchestration_init
extern orchestration_log_state
extern checkpoint_save
extern checkpoint_restore
extern checkpoint_exists
extern current_mode

; --- TTY Session Persistence externs ---
extern tty_init
extern tty_update
extern tty_close

; --- GitHub Tools externs ---
extern build_gh_search_cmd
extern build_gh_read_cmd

; --- Global entry point ---
global _start

; ============================================================================
; .rodata — Static strings for TUI
; ============================================================================
section .rodata

; --- ASCII Art Banner ---
banner_line1  db ESC, '[38;5;75m'
              db '    ___   _____ __  ___         ___   _____ ______ _   __ ______', 10, 0
banner_line2  db '   /   | / ___//  |/  / ____  /   | / ___// ____// | / //_  __/', 10, 0
banner_line3  db '  / /| | \__ \/ /|_/ / /___/ / /| | \__ \/ __/  /  |/ /  / /   ', 10, 0
banner_line4  db ' / ___ |___/ / /  / /       / ___ |___/ / /___ / /|  /  / /    ', 10, 0
banner_line5  db '/_/  |_/____/_/  /_/       /_/  |_/____/_____//_/ |_/  /_/     ', 10, 0
banner_reset  db ESC, '[0m', 0

tui_subtitle  db ESC, '[38;5;245m'
              db '    Autonomous AI Agent ', 0xE2, 0x80, 0xA2
              db ' Pure x86_64 Assembly ', 0xE2, 0x80, 0xA2
              db ' Tool Calls'
              db ESC, '[0m', 10, 0

tui_divider:
    db ESC, '[38;5;236m'
    db '  ', 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
    db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
    db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
    db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
    db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
    db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
    db ESC, '[0m', 10, 0

tui_prompt    db 10
              db ESC, '[38;5;80m', ESC, '[1m'
              db '  ', 0xE2, 0x96, 0xB6, ' '
              db ESC, '[0m'
              db ESC, '[38;5;255m'
              db 'Enter your task: '
              db ESC, '[0m'
              db ESC, '[38;5;221m', 0

tui_prompt_end db ESC, '[0m', 10, 0

tui_loop_pre  db 10, ESC, '[38;5;236m', '  '
              db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
              db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
              db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
              db ESC, '[0m', 10, 0

tui_iter_pre  db ESC, '[1m', ESC, '[38;5;75m'
              db '  ', 0xF0, 0x9F, 0x94, 0x84, ' LOOP [', 0
tui_iter_sep  db '/', 0
tui_iter_post db ']', ESC, '[0m', 10, 0

tui_tool_pre  db ESC, '[1m', ESC, '[38;5;221m'
              db '  ', 0xE2, 0x9A, 0xA1, ' TOOL CALL: ', 0
              db ESC, '[0m', ESC, '[38;5;255m', 0
tui_tool_name_pre db ESC, '[1m', 0
tui_tool_name_post db ESC, '[0m', 10, 0
tui_tool_args_pre db ESC, '[38;5;245m', '`', 0
tui_tool_args_post db '`', ESC, '[0m', 10, 0

tui_think_pre db ESC, '[38;5;80m'
              db '  ', 0xF0, 0x9F, 0xA4, 0x94, ' REASONING: ', 0
              db ESC, '[0m', ESC, '[38;5;245m', 0

tui_output_pre db ESC, '[38;5;114m'
               db '  ', 0xF0, 0x9F, 0x93, 0x9D, ' OUTPUT', 0
               db ESC, '[0m', 0
tui_output_exit_pre db ESC, '[38;5;245m', ' [exit:', 0
tui_output_exit_post db ']', ESC, '[0m', 10, 0
tui_output_body_pre db ESC, '[38;5;245m', '  ', 0xE2, 0x94, 0x82, ' ', ESC, '[0m', ESC, '[38;5;250m', 0
tui_output_nl       db ESC, '[0m', 10, ESC, '[38;5;245m', '  ', 0xE2, 0x94, 0x82, ' ', ESC, '[0m', ESC, '[38;5;250m', 0

tui_done_pre  db 10, ESC, '[1m', ESC, '[38;5;114m'
              db '  ', 0xE2, 0x9C, 0x85, ' TASK COMPLETE: ', 0
              db ESC, '[0m', ESC, '[38;5;255m', 0

tui_error_pre db ESC, '[1m', ESC, '[38;5;203m'
              db '  ', 0xE2, 0x9D, 0x8C, ' ERROR: ', 0
              db ESC, '[0m', ESC, '[38;5;203m', 0

tui_api_err_msg db 'API call failed or returned error.', 10, 0
tui_parse_err   db 'Could not parse LLM response.', 10, 0
api_err_json_prefix db '{"error"', 0
api_retry_warn  db 'API returned error response, retrying...', 10, 0

tui_shutdown    db 10, ESC, '[38;5;221m'
                db '  ', 0xE2, 0x9A, 0x99, ' Shutting down gracefully...'
                db ESC, '[0m', 10, 0

tui_complete  db 10, ESC, '[38;5;236m', '  '
              db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
              db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
              db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
              db ESC, '[0m', 10, 10
              db ESC, '[38;5;245m'
              db '  Worklog saved to WORKLOG.md'
              db ESC, '[0m', 10, 10, 0

tui_calling_api db ESC, '[38;5;245m'
                db '  ', 0xE2, 0x97, 0x8F, ' Calling API...'
                db ESC, '[0m', 10, 0

; Worklog labels
wl_label_start   db 'TASK STARTED', 0
wl_label_tool    db 'TOOL_CALL', 10, '`', 0
wl_label_output  db 'OUTPUT', 0
wl_label_done    db 'DONE', 0
wl_label_thought db 'THOUGHT', 0

; String for extracting command from JSON args
args_command_key:  db '"command"', 0
args_summary_key:  db '"summary"', 0
tc_name_gh_search: db 'github_search', 0
tc_name_gh_read:   db 'github_read', 0

; Delay timespec
section .data
    delay_ts    dq LOOP_DELAY_SECS, 0

; ============================================================================
; .bss — All shared mutable data
; ============================================================================
section .bss

global response_buf, command_buf, payload_buf, worklog_buf, output_buf
global timestamp_buf, task_buf, task_len, response_len, output_len
global worklog_ctx_len, pipe_fds, wait_status, saved_envp
global shutdown_flag, iteration_count, temp_buf
global messages_buf, messages_len
global tool_call_id_buf, tool_call_name_buf, tool_call_args_buf
global finish_reason_buf, content_buf
global active_system_prompt, active_system_prompt_len
global cwd_buf, cwd_len

response_buf    resb RESPONSE_BUF_SZ
command_buf     resb COMMAND_BUF_SZ
payload_buf     resb PAYLOAD_BUF_SZ
worklog_buf     resb WORKLOG_BUF_SZ
output_buf      resb OUTPUT_BUF_SZ
timestamp_buf   resb TIMESTAMP_BUF_SZ
task_buf        resb TASK_BUF_SZ
temp_buf        resb TEMP_BUF_SZ
messages_buf    resb MESSAGES_BUF_SZ
messages_len    resq 1
tool_call_id_buf   resb TOOL_CALL_ID_SZ
tool_call_name_buf resb TOOL_CALL_NAME_SZ
tool_call_args_buf resb TOOL_CALL_ARGS_SZ
finish_reason_buf  resb FINISH_REASON_SZ
content_buf        resb CONTENT_BUF_SZ
pipe_fds        resd 2
wait_status     resd 1
saved_envp      resq 1
shutdown_flag   resb 1
iteration_count resd 1
cwd_buf        resb 1024
cwd_len        resq 1
task_len        resq 1
response_len    resq 1
output_len      resq 1
worklog_ctx_len resq 1
active_system_prompt resq 1
active_system_prompt_len resq 1
iter_str_buf    resb 16
exit_str_buf    resb 16

; ============================================================================
; .text — Main program
; ============================================================================
section .text

; ============================================================================
; _start — Entry point
; ============================================================================
_start:
    ; Save environment pointer
    mov     rdi, [rsp]              ; argc
    lea     rsi, [rsp + 8]          ; argv
    lea     rax, [rdi + 1]
    lea     rax, [rsi + rax * 8]
    mov     [saved_envp], rax

    mov     r15, rdi                ; r15 = argc
    lea     r14, [rsp + 8]          ; r14 = argv

    ; --- Phase 0: Initialize ---
    call    setup_signals
    mov     byte [shutdown_flag], 0
    mov     dword [iteration_count], 0

    ; Initialize musical orchestration
    call    conductor_init
    call    instrument_init
    call    channel_init

    ; Initialize orchestration
    call    orchestration_init

    ; Capture working directory
    lea     rdi, [rel cwd_buf]
    mov     rsi, 1024
    mov     rax, SYS_GETCWD
    syscall
    lea     rdi, [rel cwd_buf]
    xor     rax, rax
.cwd_len_loop:
    cmp     byte [rdi + rax], 0
    je      .cwd_len_done
    inc     rax
    jmp     .cwd_len_loop
.cwd_len_done:
    mov     [rel cwd_len], rax

    ; Check for checkpoint restore
    call    checkpoint_exists
    test    rax, rax
    jz      .no_checkpoint
    call    checkpoint_restore
    test    rax, rax
    jz      .no_checkpoint
    PRINT   STDOUT, tui_calling_api
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline
.no_checkpoint:

    ; Clear screen & show banner
    PRINT   STDOUT, ansi_clear
    call    show_banner

    ; Initialize worklog
    call    worklog_init
    test    rax, rax
    js      .error_worklog

    ; --- Check for command-line task ---
    cmp     r15, 2
    jge     .task_from_argv

    ; --- Interactive: Read task from user ---
    PRINT   STDOUT, tui_prompt
    mov     rdi, STDIN
    lea     rsi, [task_buf]
    mov     rdx, TASK_BUF_SZ - 1
    mov     rax, SYS_READ
    syscall
    test    rax, rax
    jle     .exit_clean

    dec     rax
    cmp     byte [task_buf + rax], 10
    jne     .no_strip_nl
    mov     byte [task_buf + rax], 0
    jmp     .task_ready
.no_strip_nl:
    inc     rax
    mov     byte [task_buf + rax], 0
.task_ready:
    mov     [task_len], rax
    PRINT   STDOUT, tui_prompt_end
    jmp     .start_loop

.task_from_argv:
    mov     rsi, [r14 + 8]
    lea     rdi, [task_buf]
    mov     rdx, TASK_BUF_SZ - 1
    call    str_ncopy
    mov     [task_len], rax
    jmp     .start_loop

.error_worklog:
    PRINT   STDOUT, tui_error_pre
    PRINT   STDOUT, tui_api_err_msg
    PRINT   STDOUT, ansi_reset
    EXIT    1

; ============================================================================
; Main Tool Call Loop
; ============================================================================
.start_loop:
    ; Log task start
    lea     rdi, [wl_label_start]
    lea     rsi, [task_buf]
    call    worklog_append_entry

    ; Initialize TTY.md session file
    call    tty_init

    ; Read worklog context
    call    worklog_read_context

    ; Initialize conversation (system + user messages)
    call    messages_init

    PRINT   STDOUT, tui_divider

.loop_top:
    ; --- Check shutdown ---
    cmp     byte [shutdown_flag], 1
    je      .shutdown

    ; --- Check iteration limit ---
    mov     eax, [iteration_count]
    cmp     eax, MAX_ITERATIONS
    jge     .max_iter_reached

    inc     dword [iteration_count]

    ; --- Display loop header ---
    PRINT   STDOUT, tui_loop_pre
    PRINT   STDOUT, tui_iter_pre

    mov     edi, iter_str_buf
    xor     rsi, rsi
    mov     esi, [iteration_count]
    call    uint_to_str
    PRINT   STDOUT, iter_str_buf

    PRINT   STDOUT, tui_iter_sep
    ; Print max iterations as string
    lea     rdi, [rel exit_str_buf]
    mov     esi, MAX_ITERATIONS
    call    uint_to_str
    PRINT   STDOUT, exit_str_buf
    PRINT   STDOUT, tui_iter_post

    ; --- Log orchestration state ---
    call    orchestration_log_state

    ; --- Build payload from conversation ---
.api_call_phase:
    PRINT   STDOUT, tui_calling_api
    call    build_payload

    ; --- Call API ---
    call    call_api_retry
    test    rax, rax
    js      .api_error

    ; --- Parse response ---
    call    parse_response
    ; rax = ACTION_TOOL_CALL (0) | ACTION_DONE (1) | ACTION_THINK (2) | ACTION_ERROR (-1)
    mov     r12d, eax           ; save action type

    ; --- Route based on action ---
    cmp     eax, ACTION_TOOL_CALL
    je      .handle_tool_call
    cmp     eax, ACTION_DONE
    je      .handle_done
    cmp     eax, ACTION_THINK
    je      .handle_think
    jmp     .handle_parse_error

; ============================================================================
; Handle TOOL_CALL action (run_command)
; ============================================================================
.handle_tool_call:
    ; Display tool call info
    PRINT   STDOUT, tui_tool_pre
    PRINT   STDOUT, tool_call_name_buf
    PRINT   STDOUT, tui_tool_name_post

    ; Show reasoning/content if any
    lea     rdi, [rel content_buf]
    cmp     byte [rdi], 0
    jz      .tc_no_reasoning
    PRINT   STDOUT, tui_think_pre
    PRINT   STDOUT, content_buf
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline
.tc_no_reasoning:

    ; --- Dispatch based on tool name ---
    lea     rdi, [rel tool_call_name_buf]
    lea     rsi, [rel tc_name_gh_search]
    call    str_starts_with
    test    rax, rax
    jnz     .tc_github_search

    lea     rdi, [rel tool_call_name_buf]
    lea     rsi, [rel tc_name_gh_read]
    call    str_starts_with
    test    rax, rax
    jnz     .tc_github_read

    ; --- Default: run_command ---
    ; Extract command from tool_call_args_buf (JSON: {"command":"..."})
    call    extract_cmd_args
    jmp     .tc_after_dispatch

.tc_github_search:
    call    build_gh_search_cmd
    jmp     .tc_after_dispatch

.tc_github_read:
    call    build_gh_read_cmd

.tc_after_dispatch:
    ; command_buf now has the command to execute

    ; Display command
    PRINT   STDOUT, tui_tool_args_pre
    PRINT   STDOUT, command_buf
    PRINT   STDOUT, tui_tool_args_post

    ; Check if blocked
    call    check_blocked
    test    eax, eax
    jnz     .command_blocked

    ; Log tool call to worklog
    lea     rdi, [wl_label_tool]
    lea     rsi, [command_buf]
    call    worklog_append_entry

    ; Execute command
    call    exec_command
    mov     r12d, eax           ; save exit status

    ; Display output
    PRINT   STDOUT, tui_output_pre
    PRINT   STDOUT, tui_output_exit_pre
    lea     rdi, [exit_str_buf]
    mov     esi, r12d
    call    uint_to_str
    PRINT   STDOUT, exit_str_buf
    PRINT   STDOUT, tui_output_exit_post

    mov     rax, [output_len]
    test    rax, rax
    jz      .tc_skip_output

    PRINT   STDOUT, tui_output_body_pre
    mov     rcx, [output_len]
    cmp     rcx, OUTPUT_BUF_SZ - 1
    jle     .tc_out_len_ok
    mov     rcx, OUTPUT_BUF_SZ - 1
.tc_out_len_ok:
    PRINT_LEN STDOUT, output_buf, rcx
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline

.tc_skip_output:

    ; Log output to worklog
    lea     rdi, [wl_label_output]
    lea     rsi, [output_buf]
    call    worklog_append_entry

    ; Update TTY.md with EXEC result
    mov     edi, 1           ; type = 1 (EXEC)
    lea     rsi, [command_buf]
    mov     edx, r12d        ; exit code
    call    tty_update

    ; --- Append assistant message to conversation ---
    call    messages_append_tc

    ; --- Append tool result to conversation ---
    call    messages_append_tr

    ; Musical beat
    call    conductor_beat

    ; Delay
    call    delay_loop
    jmp     .loop_top

; ============================================================================
; Handle DONE action (task_complete tool called)
; ============================================================================
.handle_done:
    ; Extract summary from tool_call_args (JSON: {"summary":"..."})
    call    extract_summary_args
    ; command_buf now has the summary

    ; Display done
    PRINT   STDOUT, tui_done_pre
    PRINT   STDOUT, command_buf
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline

    ; Append assistant message to conversation (for completeness)
    call    messages_append_tc

    ; Append empty tool result
    call    messages_append_tr

    ; Log to worklog
    lea     rdi, [wl_label_done]
    lea     rsi, [command_buf]
    call    worklog_append_entry

    ; Close TTY.md session
    xor     edi, edi        ; type = 0 (DONE)
    lea     rsi, [command_buf]
    call    tty_close

    PRINT   STDOUT, tui_complete
    jmp     .exit_clean

; ============================================================================
; Handle THINK action (finish_reason: stop, content only)
; ============================================================================
.handle_think:
    PRINT   STDOUT, tui_think_pre
    PRINT   STDOUT, content_buf
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline

    ; Log as thought
    lea     rdi, [wl_label_thought]
    lea     rsi, [content_buf]
    call    worklog_append_entry

    ; Update TTY.md with THINK content
    xor     edi, edi        ; type = 0 (THINK)
    lea     rsi, [content_buf]
    call    tty_update

    ; If content mentions completion or task is done, exit
    ; Otherwise, loop back (model might just be thinking out loud)
    ; For safety, check iteration count to avoid infinite loops
    mov     eax, [iteration_count]
    cmp     eax, MAX_ITERATIONS
    jge     .max_iter_reached

    call    conductor_beat
    call    delay_loop
    jmp     .loop_top

; ============================================================================
; Error handlers
; ============================================================================
.command_blocked:
    PRINT   STDOUT, tui_error_pre
    PRINT   STDOUT, command_buf
    PRINT   STDOUT, ansi_reset

    lea     rdi, [wl_label_thought]
    lea     rsi, [command_buf]
    call    worklog_append_entry

    call    delay_loop
    jmp     .loop_top

.api_error:
    PRINT   STDOUT, tui_error_pre
    PRINT   STDOUT, tui_api_err_msg
    PRINT   STDOUT, ansi_reset
    mov     rax, [rel response_len]
    test    rax, rax
    jz      .api_error_exit
    PRINT   STDOUT, tui_output_body_pre
    PRINT   STDOUT, response_buf
    PRINT   STDOUT, ansi_reset
.api_error_exit:
    PRINT   STDOUT, ansi_show_cur
    EXIT    1

.handle_parse_error:
    ; Check if API error JSON
    lea     rdi, [rel response_buf]
    lea     rsi, [rel api_err_json_prefix]
    call    str_starts_with
    test    rax, rax
    jz      .real_parse_error

    PRINT   STDOUT, tui_error_pre
    PRINT   STDOUT, api_retry_warn
    PRINT   STDOUT, ansi_reset
    call    delay_loop
    jmp     .api_call_phase

.real_parse_error:
    PRINT   STDOUT, tui_error_pre
    PRINT   STDOUT, tui_parse_err
    PRINT   STDOUT, ansi_reset

    lea     rdi, [wl_label_thought]
    lea     rsi, [command_buf]
    call    worklog_append_entry

    call    delay_loop
    jmp     .loop_top

.max_iter_reached:
    PRINT   STDOUT, tui_error_pre
    lea     rsi, [rel max_iter_msg]
    PRINT   STDOUT, rsi
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, tui_complete
    jmp     .exit_clean

; ============================================================================
; Shutdown & Exit
; ============================================================================
.shutdown:
    PRINT   STDOUT, tui_shutdown
    PRINT   STDOUT, tui_complete

.exit_clean:
    PRINT   STDOUT, ansi_show_cur
    EXIT    0

; ============================================================================
; Helpers
; ============================================================================
section .rodata
max_iter_msg db 'Max iterations reached.', 10, 0

section .text

; ============================================================================
; .extract_command_from_args — Parse {"command":"..."} from tool_call_args_buf
; ============================================================================
; Extracts the "command" value from the JSON arguments string.
; Handles JSON escaping (\", \\, \n, etc.)
; Result goes into command_buf.
; ============================================================================
extract_cmd_args:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14

    ; Find "command" key
    lea     rdi, [rel tool_call_args_buf]
    lea     rsi, [rel args_command_key]
    call    str_find
    test    rax, rax
    jz      .ec_not_found

    ; Skip past "command" (10 bytes including quotes)
    add     rax, 10
    mov     r13, rax

    ; Skip whitespace and colon
.ec_skip:
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, ' '
    je      .ec_skip
    cmp     al, 9
    je      .ec_skip
    cmp     al, 10
    je      .ec_skip
    cmp     al, ':'
    je      .ec_skip
    cmp     al, '"'
    jne     .ec_not_found

    ; Now extract the JSON string value
    lea     r12, [rel command_buf]
    lea     r14, [rel command_buf + COMMAND_BUF_SZ - 2]

.ec_copy:
    cmp     r12, r14
    jge     .ec_done
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, '"'
    je      .ec_done
    cmp     al, '\'
    je      .ec_escape
    mov     [r12], al
    inc     r12
    jmp     .ec_copy

.ec_escape:
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, '"'
    je      .ec_esc_quote
    cmp     al, '\'
    je      .ec_esc_bs
    cmp     al, 'n'
    je      .ec_esc_nl
    cmp     al, 't'
    je      .ec_esc_tab
    cmp     al, 'r'
    je      .ec_esc_cr
    ; Unknown escape: store as-is
    mov     [r12], al
    inc     r12
    jmp     .ec_copy
.ec_esc_quote:
    mov     byte [r12], '"'
    inc     r12
    jmp     .ec_copy
.ec_esc_bs:
    mov     byte [r12], '\'
    inc     r12
    jmp     .ec_copy
.ec_esc_nl:
    mov     byte [r12], 10
    inc     r12
    jmp     .ec_copy
.ec_esc_tab:
    mov     byte [r12], 9
    inc     r12
    jmp     .ec_copy
.ec_esc_cr:
    mov     byte [r12], 13
    inc     r12
    jmp     .ec_copy

.ec_done:
    mov     byte [r12], 0

.ec_not_found:
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret

; ============================================================================
; .extract_summary_from_args — Parse {"summary":"..."} from tool_call_args_buf
; ============================================================================
; Same as above but for "summary" key. Result goes into command_buf.
; ============================================================================
extract_summary_args:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14

    lea     rdi, [rel tool_call_args_buf]
    lea     rsi, [rel args_summary_key]
    call    str_find
    test    rax, rax
    jz      .es_not_found

    add     rax, 10             ; "summary" is also 10 bytes with quotes
    mov     r13, rax

.es_skip:
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, ' '
    je      .es_skip
    cmp     al, 9
    je      .es_skip
    cmp     al, 10
    je      .es_skip
    cmp     al, ':'
    je      .es_skip
    cmp     al, '"'
    jne     .es_not_found

    lea     r12, [rel command_buf]
    lea     r14, [rel command_buf + COMMAND_BUF_SZ - 2]

.es_copy:
    cmp     r12, r14
    jge     .es_done
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, '"'
    je      .es_done
    cmp     al, '\'
    je      .es_escape
    mov     [r12], al
    inc     r12
    jmp     .es_copy

.es_escape:
    movzx   eax, byte [r13]
    inc     r13
    cmp     al, '"'
    je      .es_esc_q
    cmp     al, '\'
    je      .es_esc_bs
    cmp     al, 'n'
    je      .es_esc_nl
    cmp     al, 't'
    je      .es_esc_tab
    cmp     al, 'r'
    je      .es_esc_cr
    mov     [r12], al
    inc     r12
    jmp     .es_copy
.es_esc_q:
    mov     byte [r12], '"'
    inc     r12
    jmp     .es_copy
.es_esc_bs:
    mov     byte [r12], '\'
    inc     r12
    jmp     .es_copy
.es_esc_nl:
    mov     byte [r12], 10
    inc     r12
    jmp     .es_copy
.es_esc_tab:
    mov     byte [r12], 9
    inc     r12
    jmp     .es_copy
.es_esc_cr:
    mov     byte [r12], 13
    inc     r12
    jmp     .es_copy

.es_done:
    mov     byte [r12], 0

.es_not_found:
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret

; ============================================================================
; show_banner
; ============================================================================
show_banner:
    PRINT   STDOUT, newline
    PRINT   STDOUT, banner_line1
    PRINT   STDOUT, banner_line2
    PRINT   STDOUT, banner_line3
    PRINT   STDOUT, banner_line4
    PRINT   STDOUT, banner_line5
    PRINT   STDOUT, banner_reset
    PRINT   STDOUT, newline
    PRINT   STDOUT, tui_subtitle
    PRINT   STDOUT, tui_divider
    ret

; ============================================================================
; delay_loop
; ============================================================================
delay_loop:
    call    conductor_get_delay_ns
    test    rax, rax
    jz      .no_delay
    push    rdx
    xor     edx, edx
    mov     rcx, 1000000000
    div     rcx
    mov     [delay_ts], rax
    mov     [delay_ts + 8], rdx
    pop     rdx
    lea     rdi, [delay_ts]
    xor     rsi, rsi
    mov     rax, SYS_NANOSLEEP
    syscall
.no_delay:
    ret