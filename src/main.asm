; ============================================================================
; main.asm — ASM-AGENT Entry Point, Main Loop & Interactive Terminal UI
; ============================================================================
; Build: nasm -f elf64 -I include/ src/main.asm -o src/main.o
;        (link with other .o files)
;
; This is the heart of the orchestrator. It:
;   1. Displays an interactive TUI with ASCII art banner
;   2. Reads user task input
;   3. Runs the autonomous THINK → EXEC → LOG loop
;   4. Shows colored, real-time status for each iteration
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
extern worklog_trim_context
extern build_payload
extern parse_response
extern exec_command
extern exec_command_visibox
extern check_blocked
extern call_api
extern resolve_runtime_config

; --- VisiBox tool handlers (modular) ---
extern tool_exec_handler
extern tool_fetch_page_handler
extern tool_search_handler
extern tool_session_handler

; --- VisiBox client ---
extern vb_saved_has_next

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
extern orchestration_get_prompt
extern orchestration_check_handoff
extern orchestration_handoff
extern orchestration_get_delay
extern orchestration_log_state
extern checkpoint_save
extern checkpoint_restore
extern checkpoint_exists
extern checkpoint_delete
extern current_mode

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

; --- TUI Labels ---
tui_subtitle  db ESC, '[38;5;245m'
              db '    Autonomous AI Orchestrator ', 0xE2, 0x80, 0xA2
              db ' Pure x86_64 Assembly ', 0xE2, 0x80, 0xA2
              db ' Zero Dependencies'
              db ESC, '[0m', 10, 0

tui_divider:
    db ESC, '[38;5;236m'
    db '  ', 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80  ; ───
    db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80          ; ───
    db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80          ; ───
    db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80          ; ───
    db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80          ; ───
    db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80          ; ───
    db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80          ; ───
    db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80          ; ───
    db ESC, '[0m', 10, 0

tui_prompt    db 10
              db ESC, '[38;5;80m', ESC, '[1m'
              db '  ', 0xE2, 0x96, 0xB6, ' '                          ; ▶
              db ESC, '[0m'
              db ESC, '[38;5;255m'
              db 'Enter your task: '
              db ESC, '[0m'
              db ESC, '[38;5;221m', 0

tui_prompt_end db ESC, '[0m', 10, 0

; Status line templates
tui_loop_pre  db 10, ESC, '[38;5;236m', '  '
              db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
              db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
              db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
              db ESC, '[0m', 10, 0

tui_iter_pre  db ESC, '[1m', ESC, '[38;5;75m'
              db '  ', 0xF0, 0x9F, 0x94, 0x84, ' LOOP ['              ; 🔄 LOOP [
              db 0

tui_iter_sep  db '/', 0
tui_iter_post db ']', ESC, '[0m', 10, 0

tui_think_pre db ESC, '[38;5;80m'
              db '  ', 0xF0, 0x9F, 0xA4, 0x94, ' THINKING: '         ; 🤔 THINKING:
              db ESC, '[0m', ESC, '[38;5;245m', 0

tui_exec_pre  db ESC, '[1m', ESC, '[38;5;221m'
              db '  ', 0xE2, 0x9A, 0xA1, ' EXECUTING: '               ; ⚡ EXECUTING:
              db ESC, '[0m', ESC, '[38;5;255m', '`', 0

tui_exec_post db '`', ESC, '[0m', 10, 0

tui_output_pre db ESC, '[38;5;114m'
               db '  ', 0xF0, 0x9F, 0x93, 0x9D, ' OUTPUT'             ; 📝 OUTPUT
               db ESC, '[0m', 0

tui_output_exit_pre db ESC, '[38;5;245m', ' [exit:', 0
tui_output_exit_post db ']', ESC, '[0m', 10, 0

tui_output_body_pre db ESC, '[38;5;245m', '  ', 0xE2, 0x94, 0x82, ' ', ESC, '[0m', ESC, '[38;5;250m', 0
tui_output_nl       db ESC, '[0m', 10, ESC, '[38;5;245m', '  ', 0xE2, 0x94, 0x82, ' ', ESC, '[0m', ESC, '[38;5;250m', 0

tui_fetch_pre  db ESC, '[38;5;183m'
              db '  ', 0xF0, 0x9F, 0x93, 0x84, ' FETCH_PAGE'          ; 📄 FETCH_PAGE
              db ESC, '[0m', 10, 0

tui_search_pre db ESC, '[38;5;180m'
              db '  ', 0xF0, 0x9F, 0x94, 0x8D, ' SEARCH'              ; 🔍 SEARCH
              db ESC, '[0m', ESC, '[38;5;255m', '`', 0
tui_search_post db '`', ESC, '[0m', 10, 0

tui_session_pre db ESC, '[38;5;177m'
              db '  ', 0xF0, 0x9F, 0x92, 0xBB, ' SESSION'            ; 💻 SESSION
              db ESC, '[0m', ESC, '[38;5;255m', '`', 0
tui_session_post db '`', ESC, '[0m', 10, 0

tui_vb_pag_pre db ESC, '[38;5;183m'
              db '  ', 0xE2, 0x96, 0xB6, ' VisiBox: next page (cursor pagination)'  ; ▶ VisiBox: next page
              db ESC, '[0m', 10, 0

tui_vb_pag_end db ESC, '[38;5;245m'
              db '  ', 0xE2, 0x94, 0x82, ' No more pages available via VisiBox cursor.'
              db ESC, '[0m', 10, 0

tui_done_pre  db 10, ESC, '[1m', ESC, '[38;5;114m'
              db '  ', 0xE2, 0x9C, 0x85, ' DONE: '                    ; ✅ DONE:
              db ESC, '[0m', ESC, '[38;5;255m', 0

tui_error_pre db ESC, '[1m', ESC, '[38;5;203m'
              db '  ', 0xE2, 0x9D, 0x8C, ' ERROR: '                   ; ❌ ERROR:
              db ESC, '[0m', ESC, '[38;5;203m', 0

tui_blocked_msg db 'Command blocked by safety filter!', 10, 0
tui_api_err_msg db 'API call failed or returned error.', 10, 0
tui_parse_err   db 'Could not parse LLM response.', 10, 0
parse_err_fatal db 'Too many parse errors (3). API/model may be misconfigured. Check: ASM_AGENT_API_KEY, ASM_AGENT_API_URL, ASM_AGENT_MODEL', 10, 0
streak_warn_msg db 'WARNING: You have executed the same command ', MAX_CONSECUTIVE_EXEC+'0', ' times in a row. '
                db 'The command is not achieving new results. '
                db 'Please analyze the output carefully and either: '
                db '(1) try a different approach, or (2) respond DONE if the task is actually complete.', 0
think_streak_warn db 'WARNING: You have been thinking ', MAX_CONSECUTIVE_THINK+'0', ' times without executing any command. '
                  db 'Please either: (1) EXEC a command to make progress, or (2) DONE if the task is complete.', 0
tui_shutdown    db 10, ESC, '[38;5;221m'
                db '  ', 0xE2, 0x9A, 0x99, ' Shutting down gracefully...'  ; ⚙ Shutting down
                db ESC, '[0m', 10, 0

; Auto-verification messages
verify_hint_msg db 'Next step needed. Check CONTEXT to see what is done and what remains.', 0
tag_warn_msg   db 'Use <tool_call><command></tool_call> to execute commands. Commands without tags are ignored.', 0
force_done_msg  db 'Task completed successfully after multiple verified commands.', 0

tui_complete  db 10, ESC, '[38;5;236m', '  '
              db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
              db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
              db 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80, 0xE2, 0x94, 0x80
              db ESC, '[0m', 10, 10
              db ESC, '[38;5;245m'
              db '  Worklog saved to WORKLOG.md'
              db ESC, '[0m', 10, 10, 0

tui_calling_api db ESC, '[38;5;245m'
                db '  ', 0xE2, 0x97, 0x8F, ' Calling API...'           ; ● Calling API...
                db ESC, '[0m', 10, 0

; Entry type labels for worklog_append_entry
wl_label_thought db 'THOUGHT', 0
wl_label_exec    db 'EXEC', 10, '`', 0
wl_label_output  db 'OUTPUT', 0
wl_label_done    db 'DONE', 0
wl_label_start   db 'TASK STARTED', 0
wl_label_reward  db 'REWARD', 0
prefix_exec      db 'EXEC:', 0
prefix_done      db 'DONE:', 0

tui_reward_pre   db 10, ESC, '[1m', ESC, '[38;5;220m'
                 db '  🏆 REWARD EARNED: ', ESC, '[0m', ESC, '[38;5;255m', '+', 0
tui_reward_post  db ' XP (Efficiency Score: ', 0
tui_reward_end   db '%)', ESC, '[0m', 10, 0

wl_reward_tmpl_1 db 'Earned +', 0
wl_reward_tmpl_2 db ' XP (Efficiency Score: ', 0
wl_reward_tmpl_3 db '%) for completing the task in ', 0
wl_reward_tmpl_4 db ' iterations.', 0

; Number buffer in rodata
max_iter_str     db '50', 0
max_iter_msg     db 'Max iterations reached.', 10, 0

; Pagination messages
tui_page_pre    db 10, ESC, '[1m', ESC, '[38;5;220m', '  ', 0xF0, 0x9F, 0x93, 0x84
                db ' PAGE ', 0              ; 📄 PAGE
tui_page_of     db '/', 0
tui_page_post   db ESC, '[0m', 10, 0

wl_page_notice  db '[PAGINATED] Showing page ', 0
wl_page_of      db ' of ', 0
wl_page_dot     db '. Total output: ', 0
wl_page_bytes   db ' bytes. Reply NEXT_PAGE to see more.', 10, 0

wl_page_last    db '[PAGINATED] Last page shown. All output delivered.', 10, 0

wl_label_page   db 'OUTPUT (page)', 0
wl_vb_more_hint db 'More pages available. Reply FETCH_PAGE to continue.', 10, 0

; Delay timespec (2 seconds)
section .data
    delay_ts    dq LOOP_DELAY_SECS, 0    ; tv_sec, tv_nsec

; ============================================================================
; .bss — All shared mutable data (extern'd by other modules)
; ============================================================================
section .bss

; Shared buffers — these are global so other modules can extern them
global response_buf, command_buf, payload_buf, worklog_buf, output_buf
global timestamp_buf, task_buf, task_len, response_len, output_len
global worklog_ctx_len, pipe_fds, wait_status, saved_envp
global shutdown_flag, iteration_count, temp_buf
global last_command_buf, last_cmd_len, exec_streak, think_streak
global active_system_prompt, active_system_prompt_len
global successful_exec_count
global cwd_buf, cwd_len
global page_buf, page_total_len, page_offset, page_chunk_num, page_active
global visibox_json_buf, visibox_pipe_fds, visibox_resp_pipe_fds, visibox_response_raw, visibox_resp_len, use_visibox
global runtime_api_url, runtime_model

response_buf    resb RESPONSE_BUF_SZ
command_buf     resb COMMAND_BUF_SZ
payload_buf     resb PAYLOAD_BUF_SZ
worklog_buf     resb WORKLOG_BUF_SZ
output_buf      resb OUTPUT_BUF_SZ
timestamp_buf   resb TIMESTAMP_BUF_SZ
task_buf        resb TASK_BUF_SZ
temp_buf        resb TEMP_BUF_SZ
last_command_buf resb COMMAND_BUF_SZ
active_system_prompt resq 1          ; pointer to current system prompt
active_system_prompt_len resq 1     ; length of current system prompt
pipe_fds        resd 2
wait_status     resd 1
saved_envp      resq 1
shutdown_flag   resb 1
iteration_count resd 1
exec_streak     resd 1
think_streak    resd 1
parse_error_streak resd 1
successful_exec_count resd 1
cwd_buf        resb 1024           ; current working directory
cwd_len        resq 1
task_len        resq 1
response_len    resq 1
output_len      resq 1
worklog_ctx_len resq 1
last_cmd_len    resq 1
iter_str_buf    resb 16                 ; for uint_to_str of iteration
exit_str_buf    resb 16                 ; for uint_to_str of exit code

; Pagination state — stores full output when output is too large for one page
page_buf        resb PAGE_BUF_SZ         ; full output for pagination
page_total_len  resq 1                  ; total output length
page_offset     resq 1                  ; next byte offset to send
page_chunk_num  resq 1                  ; current page number (1-based)
page_active     resb 1                  ; 1 = pagination in progress

; VisiBox integration buffers
visibox_json_buf       resb COMMAND_BUF_SZ + 64  ; JSON request built for visibox
visibox_pipe_fds       resd 2                     ; pipe fds for visibox stdin
visibox_resp_pipe_fds  resd 2                     ; pipe fds for visibox stdout
visibox_response_raw   resb OUTPUT_BUF_SZ         ; raw JSON response from visibox
visibox_resp_len       resq 1                     ; bytes read from visibox response
use_visibox            resb 1                     ; 1 = visibox available (always 1 if we reach here)

; Runtime config overrides (from env vars — empty = use compiled-in default)
runtime_api_url        resb 512                    ; ASM_AGENT_API_URL override
runtime_model          resb 256                    ; ASM_AGENT_MODEL override

; ============================================================================
; .text — Main program
; ============================================================================
section .text

; ============================================================================
; _start — Entry point
; ============================================================================
_start:
    ; Save environment pointer (3rd element on initial stack)
    ; Stack at _start: [argc] [argv0] [argv1] ... [NULL] [envp0] [envp1] ... [NULL]
    mov     rdi, [rsp]              ; argc
    lea     rsi, [rsp + 8]          ; argv
    ; envp = argv + (argc + 1) * 8
    lea     rax, [rdi + 1]
    lea     rax, [rsi + rax * 8]
    mov     [saved_envp], rax

    ; Save argc and argv[1] (task from command line, if provided)
    mov     r15, rdi                ; r15 = argc
    lea     r14, [rsp + 8]          ; r14 = argv pointer

    ; --- Phase 0: Initialize ---
    call    setup_signals
    mov     byte [shutdown_flag], 0
    mov     dword [iteration_count], 0
    mov     dword [think_streak], 0
    mov     dword [parse_error_streak], 0
    mov     dword [successful_exec_count], 0

    ; Resolve runtime config from env vars (API URL, model)
    call    resolve_runtime_config

    ; Initialize musical orchestration
    call    conductor_init
    call    instrument_init
    call    channel_init

    ; Initialize Swarm/LangGraph orchestration
    call    orchestration_init

    ; --- Auto-detect VisiBox binary (REQUIRED — no fallback) ---
    ; access(visibox_path, F_OK) — check if the binary exists and is executable
    lea     rdi, [rel visibox_path]
    mov     rax, SYS_ACCESS
    mov     rsi, 1                ; X_OK = 1 (check execute permission)
    syscall
    test    rax, rax
    jnz     .visibox_missing
    mov     byte [rel use_visibox], 1
    jmp     .visibox_detect_done
.visibox_missing:
    ; VisiBox is required — print error and exit
    PRINT   STDERR, vb_required_msg
    mov     rax, 1
    mov     rdi, rax
    mov     rax, SYS_EXIT
    syscall
.visibox_detect_done:

    ; --- Capture working directory via getcwd syscall ---
    ; getcwd(buf, size)
    lea     rdi, [rel cwd_buf]
    mov     rsi, 1024
    mov     rax, SYS_GETCWD
    syscall
    ; Calculate cwd_len
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
    ; Checkpoint restored — continue from saved state
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
    cmp     r15, 2                  ; argc >= 2?
    jge     .task_from_argv

    ; --- Interactive: Read task from user ---
    PRINT   STDOUT, tui_prompt
    ; Read from stdin
    mov     rdi, STDIN
    lea     rsi, [task_buf]
    mov     rdx, TASK_BUF_SZ - 1
    mov     rax, SYS_READ
    syscall
    test    rax, rax
    jle     .exit_clean             ; EOF or error

    ; Remove trailing newline
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
    ; Copy argv[1] to task_buf
    mov     rsi, [r14 + 8]          ; argv[1]
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
; Main Orchestration Loop
; ============================================================================
.start_loop:
    ; Log the task start to WORKLOG
    lea     rdi, [wl_label_start]
    lea     rsi, [task_buf]
    call    worklog_append_entry

    PRINT   STDOUT, tui_divider

.loop_top:
    ; --- Check shutdown flag ---
    cmp     byte [shutdown_flag], 1
    je      .shutdown

    ; --- Check iteration limit ---
    mov     eax, [iteration_count]
    cmp     eax, MAX_ITERATIONS
    jge     .max_iter_reached

    ; --- Increment iteration ---
    inc     dword [iteration_count]

    ; --- Display loop header ---
    PRINT   STDOUT, tui_loop_pre
    PRINT   STDOUT, tui_iter_pre

    ; Print current iteration number
    mov     edi, iter_str_buf
    xor     rsi, rsi
    mov     esi, [iteration_count]
    call    uint_to_str
    PRINT   STDOUT, iter_str_buf

    PRINT   STDOUT, tui_iter_sep
    PRINT   STDOUT, max_iter_str
    PRINT   STDOUT, tui_iter_post

    ; --- Get mode-specific prompt ---
    call    orchestration_get_prompt
    mov     [rel active_system_prompt], rsi
    mov     [rel active_system_prompt_len], rax

    ; --- Log orchestration state ---
    call    orchestration_log_state

    ; --- Phase 1: Read WORKLOG context ---
    call    worklog_read_context
    ; rax = context length (in worklog_buf)

    ; --- Phase 1.5: Pre-calculate payload size & trim worklog if needed ---
    ; Estimate total payload BEFORE building it:
    ;   est = PAYLOAD_FIXED_OVERHEAD
    ;       + active_system_prompt_len * JSON_ESCAPE_OVERHEAD
    ;       + task_len * JSON_ESCAPE_OVERHEAD
    ;       + worklog_ctx_len * JSON_ESCAPE_OVERHEAD
    ; If est > PAYLOAD_SAFE_MAX, compute worklog budget and call trim.
    mov     rax, PAYLOAD_FIXED_OVERHEAD
    mov     rcx, [rel active_system_prompt_len]
    shl     rcx, 1                     ; * JSON_ESCAPE_OVERHEAD (2)
    add     rax, rcx
    mov     rcx, [rel task_len]
    shl     rcx, 1
    add     rax, rcx
    mov     rcx, [rel worklog_ctx_len]
    shl     rcx, 1
    add     rax, rcx                    ; rax = estimated total payload size

    cmp     rax, PAYLOAD_SAFE_MAX
    jbe     .payload_size_ok           ; estimate fits → skip trim

    ; --- Payload would be too large — compute worklog byte budget ---
    ; worklog_budget = (PAYLOAD_SAFE_MAX - overhead - sys_prompt*2 - task*2) / 2
    mov     rdx, PAYLOAD_SAFE_MAX
    sub     rdx, PAYLOAD_FIXED_OVERHEAD
    mov     rcx, [rel active_system_prompt_len]
    shl     rcx, 1
    sub     rdx, rcx
    mov     rcx, [rel task_len]
    shl     rcx, 1
    sub     rdx, rcx
    shr     rdx, 1                     ; reverse the escape factor

    ; Ensure minimum worklog budget of 512 bytes (at least partial context)
    cmp     rdx, 512
    jae     .budget_ok
    mov     rdx, 512
.budget_ok:

    ; Call worklog_trim_context(budget) — drops oldest entries in worklog_buf
    mov     rdi, rdx
    call    worklog_trim_context

.payload_size_ok:

    ; --- Phase 2: Build JSON payload ---
    PRINT   STDOUT, tui_calling_api
    call    build_payload
    ; rax = payload length (in payload_buf)

    ; --- Phase 3: Call API ---
    call    call_api
    test    rax, rax
    js      .api_error
    ; rax = response length (in response_buf)

    ; --- Phase 4: Parse response ---
    call    parse_response
    ; rax = action type
    mov     r12d, eax           ; SAVE action type — handoff check clobbers rax

    ; --- Check for HANDOFF before other actions ---
    lea     rdi, [rel command_buf]
    call    orchestration_check_handoff

    cmp     rax, MODE_DONE
    je      .handle_done
    cmp     rax, -1
    je      .no_handoff

    ; --- Execute HANDOFF ---
    ; Save checkpoint before handoff
    call    checkpoint_save

    ; Execute handoff
    call    orchestration_handoff

    ; Log handoff
    PRINT   STDOUT, tui_think_pre
    PRINT   STDOUT, command_buf
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline

    ; Musical: advance beat
    call    conductor_beat

    ; Delay before next iteration
    call    delay_loop
    jmp     .loop_top

.no_handoff:
    ; --- Route based on parsed action ---
    mov     eax, r12d           ; RESTORE action type from parse_response
    cmp     eax, ACTION_EXEC
    je      .handle_exec
    cmp     eax, ACTION_THINK
    je      .handle_think
    cmp     eax, ACTION_DONE
    je      .handle_done
    cmp     eax, ACTION_NEXT_PAGE
    je      .handle_next_page
    cmp     eax, ACTION_FETCH_PAGE
    je      .handle_fetch_page
    cmp     eax, ACTION_SEARCH_JUMP
    je      .handle_search
    cmp     eax, ACTION_SESSION
    je      .handle_session
    jmp     .handle_parse_error

; ============================================================================
; Handle NEXT_PAGE action
; ============================================================================
; The AI requested the next page of paginated output.
; Appends the next OUTPUT_PAGE_SIZE chunk from page_buf to the worklog.
; ============================================================================
.handle_next_page:
    ; Check if pagination is actually active
    cmp     byte [rel page_active], 1
    jne     .handle_think           ; no active pagination → treat as think

    ; Calculate remaining bytes
    mov     rax, [rel page_total_len]
    sub     rax, [rel page_offset]
    jle     .page_all_done          ; no more data

    ; Determine this chunk size: min(OUTPUT_PAGE_SIZE, remaining)
    mov     rcx, OUTPUT_PAGE_SIZE
    cmp     rax, rcx
    jbe     .page_this_chunk
    mov     rcx, rax                ; remaining < page size → this is the last chunk
.page_this_chunk:
    ; rcx = bytes to copy for this page

    ; --- Build page content in response_buf ---
    ; Format: "<tool_response id="0">\n[page:N]\n```\n<chunk>\n```\n</tool_response>\n"
    lea     rdi, [rel response_buf]

    ; "tool_response id="
    lea     rsi, [rel wl_tool_resp_s]
    call    .copy_local_str

    ; iteration "0" (placeholder — not a real tool call)
    mov     byte [rdi], '"'
    mov     byte [rdi+1], '0'
    mov     byte [rdi+2], '"'
    mov     byte [rdi+3], '>'
    mov     byte [rdi+4], 10
    add     rdi, 5

    ; "[page:N]\n```\n"
    mov     byte [rdi], '['
    mov     byte [rdi+1], 'p'
    mov     byte [rdi+2], 'a'
    mov     byte [rdi+3], 'g'
    mov     byte [rdi+4], 'e'
    mov     byte [rdi+5], ':'
    add     rdi, 6

    ; Append page number
    inc     qword [rel page_chunk_num]
    ; Use push/pop to save rdi across uint_to_str
    push    rdi
    lea     rdi, [rel exit_str_buf]
    mov     rax, [rel page_chunk_num]
    call    uint_to_str
    pop     rdi
    lea     rsi, [rel exit_str_buf]
    call    .copy_local_str

    ; "]\n```\n"
    mov     byte [rdi], ']'
    mov     byte [rdi+1], 10
    mov     byte [rdi+2], '`'
    mov     byte [rdi+3], '`'
    mov     byte [rdi+4], '`'
    mov     byte [rdi+5], 10
    add     rdi, 6

    ; Copy the actual output chunk from page_buf + page_offset
    lea     rsi, [rel page_buf]
    add     rsi, [rel page_offset]
    ; Calculate space remaining in response_buf
    lea     rax, [rel response_buf]
    add     rax, RESPONSE_BUF_SZ - 64
    sub     rax, rdi
    cmp     rcx, rax
    jbe     .page_copy_ok
    mov     rcx, rax                ; clamp to available space
.page_copy_ok:
    ; Copy rcx bytes
    push    rcx                     ; save chunk size
    rep     movsb
    pop     rcx

    ; "\n```\n</tool_response>\n"
    mov     byte [rdi], 10
    mov     byte [rdi+1], '`'
    mov     byte [rdi+2], '`'
    mov     byte [rdi+3], '`'
    mov     byte [rdi+4], 10
    add     rdi, 5
    lea     rsi, [rel wl_tool_resp_e]
    call    .copy_local_str

    ; Null-terminate
    mov     byte [rdi], 0

    ; Log to worklog
    lea     rdi, [wl_label_page]
    lea     rsi, [rel response_buf]
    call    worklog_append_entry

    ; Update page_offset
    add     [rel page_offset], rcx

    ; --- Display page info in TUI ---
    PRINT   STDOUT, tui_page_pre
    lea     rdi, [rel exit_str_buf]
    mov     rax, [rel page_chunk_num]
    call    uint_to_str
    PRINT   STDOUT, exit_str_buf
    PRINT   STDOUT, tui_page_of
    ; Total pages
    mov     rax, [rel page_total_len]
    add     rax, OUTPUT_PAGE_SIZE - 1
    xor     edx, edx
    mov     ecx, OUTPUT_PAGE_SIZE
    div     ecx
    lea     rdi, [rel exit_str_buf]
    call    uint_to_str
    PRINT   STDOUT, exit_str_buf
    PRINT   STDOUT, tui_page_post

    ; Check if more pages remain
    mov     rax, [rel page_total_len]
    cmp     [rel page_offset], rax
    jge     .page_all_done

    ; More pages — append notice and loop back
    ; Reuse the notice builder logic (simplified: just append notice to worklog)
    lea     rdi, [rel temp_buf]
    mov     rbx, rdi
    lea     rsi, [rel wl_page_notice]
    call    .copy_local_str_to_rbx
    lea     rdi, [rel exit_str_buf]
    mov     rax, [rel page_chunk_num]
    call    uint_to_str
    lea     rsi, [rel exit_str_buf]
    call    .copy_local_str_to_rbx
    lea     rsi, [rel wl_page_of]
    call    .copy_local_str_to_rbx
    mov     rax, [rel page_total_len]
    add     rax, OUTPUT_PAGE_SIZE - 1
    xor     edx, edx
    mov     ecx, OUTPUT_PAGE_SIZE
    div     ecx
    lea     rdi, [rel exit_str_buf]
    call    uint_to_str
    lea     rsi, [rel exit_str_buf]
    call    .copy_local_str_to_rbx
    lea     rsi, [rel wl_page_dot]
    call    .copy_local_str_to_rbx
    lea     rdi, [rel exit_str_buf]
    mov     rax, [rel page_total_len]
    call    uint_to_str
    lea     rsi, [rel exit_str_buf]
    call    .copy_local_str_to_rbx
    lea     rsi, [rel wl_page_bytes]
    call    .copy_local_str_to_rbx
    mov     byte [rbx], 0
    lea     rdi, [rel temp_buf]
    call    str_len
    lea     rdi, [rel temp_buf]
    mov     rsi, rax
    call    worklog_append_raw

    call    delay_loop
    jmp     .loop_top

.page_all_done:
    ; No more pages — mark pagination as complete
    mov     byte [rel page_active], 0

    ; Append "last page" notice to worklog
    lea     rdi, [wl_label_thought]
    lea     rsi, [rel wl_page_last]
    call    worklog_append_entry

    ; Display in TUI
    PRINT   STDOUT, tui_think_pre
    PRINT   STDOUT, wl_page_last
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline

    call    delay_loop
    jmp     .loop_top

; ============================================================================
; Handle FETCH_PAGE action — VisiBox cursor-based pagination
; ============================================================================
; Uses the saved response_id + cursor from the last execute call to fetch
; the next page of output directly from VisiBox (server-side pagination).
; This is different from NEXT_PAGE which uses local page_buf pagination.
; ============================================================================
.handle_fetch_page:
    ; --- VisiBox cursor-based pagination ---
    ; Check if VisiBox has a cursor (has_next from last execute)
    cmp     byte [rel vb_saved_has_next], 1
    je      .fetch_vb_do

    ; No VisiBox cursor — fall through to local pagination
.fetch_no_cursor:
    ; Delegate to NEXT_PAGE handler (local page_buf pagination)
    jmp     .handle_next_page

.fetch_vb_do:
    PRINT   STDOUT, tui_vb_pag_pre

    ; Call the modular fetch_page handler
    call    tool_fetch_page_handler
    test    eax, eax
    jnz     .fetch_vb_end

    ; Success — display output
    PRINT   STDOUT, tui_output_pre
    PRINT   STDOUT, tui_output_body_pre
    mov     rax, [output_len]
    cmp     rax, 2048
    jle     .fetch_disp_ok
    mov     rax, 2048
.fetch_disp_ok:
    PRINT_LEN STDOUT, output_buf, rax
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline

    ; Log to worklog as output
    lea     rdi, [wl_label_output]
    lea     rsi, [rel output_buf]
    call    worklog_append_entry

    ; Check if more pages available
    cmp     byte [rel vb_saved_has_next], 1
    je      .fetch_more_pages

.fetch_vb_end:
    call    delay_loop
    jmp     .loop_top

.fetch_more_pages:
    ; Tell the model more pages are available
    lea     rdi, [wl_label_thought]
    lea     rsi, [rel wl_vb_more_hint]
    call    worklog_append_entry

    call    delay_loop
    jmp     .loop_top

; ============================================================================
; Handle SEARCH action — VisiBox search_jump
; ============================================================================
; Searches for a keyword in the last command's output and jumps to the
; page containing that keyword.
; ============================================================================
.handle_search:
    ; Display search keyword
    PRINT   STDOUT, tui_search_pre
    PRINT   STDOUT, command_buf
    PRINT   STDOUT, tui_search_post

    ; Call the modular search handler
    call    tool_search_handler
    test    eax, eax
    jnz     .search_err

    ; Success — display the page containing the keyword
    PRINT   STDOUT, tui_output_pre
    PRINT   STDOUT, tui_output_body_pre
    mov     rax, [output_len]
    cmp     rax, 2048
    jle     .search_disp_ok
    mov     rax, 2048
.search_disp_ok:
    PRINT_LEN STDOUT, output_buf, rax
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline

    ; Log to worklog
    lea     rdi, [wl_label_thought]
    lea     rsi, [rel command_buf]
    call    worklog_append_entry

    lea     rdi, [wl_label_output]
    lea     rsi, [rel output_buf]
    call    worklog_append_entry

    call    conductor_beat
    call    delay_loop
    jmp     .loop_top

.search_err:
    PRINT   STDOUT, tui_error_pre
    PRINT   STDOUT, command_buf
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline
    call    delay_loop
    jmp     .loop_top



; ============================================================================
; Handle SESSION action — VisiBox persistent shell
; ============================================================================
; Runs the command in a VisiBox daemon session where cd, export, alias
; persist across calls. Falls back to EXEC if VisiBox unavailable.
; ============================================================================
.handle_session:
    ; Display session command
    PRINT   STDOUT, tui_session_pre
    PRINT   STDOUT, command_buf
    PRINT   STDOUT, tui_session_post

    ; Call the modular session handler
    call    tool_session_handler
    mov     r12d, eax               ; save exit code

    ; Display output
    PRINT   STDOUT, tui_output_pre
    PRINT   STDOUT, tui_output_body_pre
    mov     rax, [output_len]
    cmp     rax, 2048
    jle     .session_disp_ok
    mov     rax, 2048
.session_disp_ok:
    PRINT_LEN STDOUT, output_buf, rax
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline

    ; Display exit code (saved in r12d)
    PRINT   STDOUT, tui_output_exit_pre
    lea     rdi, [rel exit_str_buf]
    mov     eax, r12d
    call    uint_to_str
    PRINT   STDOUT, exit_str_buf
    PRINT   STDOUT, tui_output_exit_post

    ; Log to worklog as EXEC (session is just a special exec)
    lea     rdi, [wl_label_exec]
    lea     rsi, [rel command_buf]
    call    worklog_append_entry

    lea     rdi, [wl_label_output]
    lea     rsi, [rel output_buf]
    call    worklog_append_entry

    ; Increment streak counters (same as EXEC)
    inc     dword [rel exec_streak]
    mov     dword [rel think_streak], 0
    inc     dword [rel successful_exec_count]

    call    conductor_beat
    call    delay_loop
    jmp     .loop_top



; ============================================================================
; Handle THINK action
; ============================================================================
.handle_think:
    ; Display thought
    PRINT   STDOUT, tui_think_pre
    PRINT   STDOUT, command_buf
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline

    ; --- Check if THINK contains DONE ---
    lea     rdi, [rel command_buf]
    lea     rsi, [rel prefix_done]
    call    str_find            ; rax = pointer to "DONE:" or 0
    test    rax, rax
    jnz     .think_has_done    ; found DONE — treat as completion

    ; No embedded EXEC extraction — strict mode
    ; THINK content is NEVER executed, only logged

    ; --- Check if THINK looks like a command (missing <tool_call>) ---
    lea     rdi, [rel command_buf]
    lea     rsi, [rel prefix_exec]
    call    str_find
    test    rax, rax
    jz      .think_only

    ; THINK contains EXEC: but no <tool_call> tag — warn the model
    lea     rdi, [rel command_buf]
    lea     rsi, [rel tag_warn_msg]
    call    str_copy
    jmp     .think_log_warn

.think_has_done:
    ; Found DONE inside THINK — extract the done message
    mov     r13, rax
    add     r13, 5              ; skip "DONE:"
.skip_done_ws:
    movzx   eax, byte [r13]
    cmp     al, ' '
    je      .done_ws_adv
    cmp     al, 10
    je      .done_ws_adv
    cmp     al, 13
    je      .done_ws_adv
    jmp     .think_done_extract
.done_ws_adv:
    inc     r13
    jmp     .skip_done_ws

.think_done_extract:
    lea     rdi, [rel command_buf]
    mov     rsi, r13
    call    str_copy
    jmp     .handle_done

.think_exec_extract:
    ; rax points to "EXEC:" inside command_buf
    ; Skip past "EXEC:" (5 bytes) and any whitespace
    mov     r13, rax
    add     r13, 5              ; skip "EXEC:"
.skip_think_ws:
    movzx   eax, byte [r13]
    cmp     al, ' '
    je      .ws_advance
    cmp     al, 10              ; newline
    je      .ws_advance
    cmp     al, 13              ; carriage return
    je      .ws_advance
    cmp     al, 9               ; tab
    je      .ws_advance
    jmp     .think_exec_copy
.ws_advance:
    inc     r13
    jmp     .skip_think_ws

.think_exec_copy:
    ; Copy the extracted command to command_buf (shift left)
    ; Only copy up to the first newline (single command only)
    lea     rdi, [rel command_buf]
    mov     rsi, r13
.think_copy_loop:
    lodsb
    test    al, al
    jz      .think_copy_done
    cmp     al, 10              ; newline = end of command
    je      .think_copy_done
    cmp     al, 13              ; carriage return = end of command
    je      .think_copy_done
    stosb
    jmp     .think_copy_loop
.think_copy_done:
    mov     byte [rdi], 0       ; null-terminate

    ; Strip surrounding backticks if present
    lea     rdi, [rel command_buf]
    cmp     byte [rdi], '`'
    jne     .think_no_bt
    call    str_len
    cmp     rax, 2
    jb      .think_no_bt
    cmp     byte [rdi + rax - 1], '`'
    jne     .think_no_bt
    mov     byte [rdi + rax - 1], 0
    lea     rsi, [rdi + 1]
    call    str_copy
.think_no_bt:

    ; Jump to handle_exec (includes duplicate detection + logging)
    jmp     .handle_exec

.think_only:
    ; Log to WORKLOG
    lea     rdi, [wl_label_thought]
    lea     rsi, [command_buf]
    call    worklog_append_entry

.think_log_warn:
    ; --- THINK streak detection ---
    inc     dword [rel think_streak]
    mov     eax, [rel think_streak]
    cmp     eax, MAX_CONSECUTIVE_THINK
    jl      .think_streak_ok

    ; --- THINK streak exceeded: force DONE with warning ---
    lea     rdi, [rel command_buf]
    lea     rsi, [rel think_streak_warn]
    call    str_copy

    ; Reset streak
    mov     dword [rel think_streak], 0

    ; Log as THINK
    lea     rdi, [wl_label_thought]
    lea     rsi, [rel command_buf]
    call    worklog_append_entry

    ; Display warning
    PRINT   STDOUT, tui_error_pre
    PRINT   STDOUT, command_buf
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline

    ; Force DONE
    jmp     .handle_done

.think_streak_ok:
    ; Musical: advance beat for THINK (no execution, but still a beat)
    call    conductor_beat

    ; Delay before next iteration
    call    delay_loop
    jmp     .loop_top

; ============================================================================
; Handle EXEC action
; ============================================================================
.handle_exec:
    ; Display command
    PRINT   STDOUT, tui_exec_pre
    PRINT   STDOUT, command_buf
    PRINT   STDOUT, tui_exec_post

    ; Note: check_blocked is called inside tool_exec_handler

    ; --- Duplicate command detection ---
    ; Compare command_buf with last_command_buf
    lea     rdi, [rel command_buf]
    call    str_len
    mov     r8, rax             ; r8 = current cmd len
    lea     rdi, [rel last_command_buf]
    call    str_len
    cmp     rax, r8
    jne     .cmd_different      ; different length → different command

    ; Same length — check if command_buf starts with last_command_buf
    lea     rdi, [rel command_buf]
    lea     rsi, [rel last_command_buf]
    call    str_starts_with
    test    rax, rax
    jz      .cmd_different      ; not a match → different command

    ; Same command — increment streak
    inc     dword [rel exec_streak]
    jmp     .cmd_streak_ok

.cmd_different:
    ; Different command — copy to last_command_buf and reset streak
    lea     rdi, [rel last_command_buf]
    lea     rsi, [rel command_buf]
    call    str_copy
    mov     [rel last_cmd_len], rax
    mov     dword [rel exec_streak], 1
    mov     dword [rel think_streak], 0    ; reset think streak on EXEC
    mov     dword [rel parse_error_streak], 0  ; reset parse error streak on EXEC

.cmd_streak_ok:
    ; Check if streak exceeds limit
    mov     eax, [rel exec_streak]
    cmp     eax, MAX_CONSECUTIVE_EXEC
    jl      .streak_ok

    ; --- Streak exceeded: force THINK with warning ---
    ; Build warning in command_buf
    lea     rdi, [rel command_buf]
    lea     rsi, [rel streak_warn_msg]
    call    str_copy

    ; Log warning as THINK
    lea     rdi, [wl_label_thought]
    lea     rsi, [rel command_buf]
    call    worklog_append_entry

    ; Display warning
    PRINT   STDOUT, tui_error_pre
    PRINT   STDOUT, command_buf
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline

    ; Reset streak to allow retry after model reconsiders
    mov     dword [rel exec_streak], 0
    mov     dword [rel think_streak], 0

    ; Musical: log state when streak warning triggers
    call    conductor_log_state

    call    delay_loop
    jmp     .loop_top

.streak_ok:
    ; Log EXEC to WORKLOG with tool_call wrapping
    ; Build: "tool_call id=<iteration>\n<command>\ntool_call"
    lea     rdi, [rel response_buf]

    ; Write "tool_call id="
    lea     rsi, [rel wl_tool_call_s]
    call    .copy_local_str

    ; Write iteration number
    push    rdi
    lea     rdi, [rel exit_str_buf]
    mov     esi, [rel iteration_count]
    call    uint_to_str
    pop     rdi
    lea     rsi, [rel exit_str_buf]
    call    .copy_local_str

    ; Write '">'  (close XML tag)
    mov     byte [rdi], '"'
    mov     byte [rdi+1], '>'
    mov     byte [rdi+2], 10
    add     rdi, 3

    ; Write command
    lea     rsi, [rel command_buf]
    call    .copy_local_str

    ; Write "\n</tool_call>\n"
    mov     byte [rdi], 10
    inc     rdi
    lea     rsi, [rel wl_tool_call_e]
    call    .copy_local_str

    ; Null-terminate
    mov     byte [rdi], 0

    lea     rdi, [wl_label_exec]
    lea     rsi, [rel response_buf]
    call    worklog_append_entry

.handle_exec_run:
    ; Execute the command via modular tool handler
    call    tool_exec_handler
    mov     r12d, eax               ; save exit status

    ; Display output header
    PRINT   STDOUT, tui_output_pre
    PRINT   STDOUT, tui_output_exit_pre

    ; Print exit code
    lea     rdi, [exit_str_buf]
    mov     esi, r12d
    call    uint_to_str
    PRINT   STDOUT, exit_str_buf

    PRINT   STDOUT, tui_output_exit_post

    ; Display output body (first 2048 bytes for TUI, full goes to worklog)
    mov     rax, [output_len]
    test    rax, rax
    jz      .skip_output_display

    ; Print output with box drawing prefix
    PRINT   STDOUT, tui_output_body_pre
    ; Print output_buf, replacing \n with the styled newline
    lea     rsi, [output_buf]
    mov     rcx, [output_len]
    cmp     rcx, 2048               ; limit TUI display to 2KB
    jle     .output_len_ok
    mov     rcx, 2048
.output_len_ok:
    ; Simple: just print the raw output for now
    PRINT_LEN STDOUT, output_buf, rcx
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline

.skip_output_display:
    ; --- Pagination check: if output > OUTPUT_PAGE_SIZE, save full output
    ;     and truncate what gets logged to the first page only ---
    mov     byte [rel page_active], 0   ; default: no pagination

    mov     rax, [output_len]
    cmp     rax, OUTPUT_PAGE_SIZE
    jbe     .no_paginate_output          ; small output — log everything

    ; --- Save full output to page_buf ---
    lea     rdi, [rel page_buf]
    lea     rsi, [output_buf]
    mov     rcx, rax                    ; rcx = output_len
    cld
    rep     movsb

    ; Set pagination state
    mov     [rel page_total_len], rcx   ; total output length
    mov     rax, OUTPUT_PAGE_SIZE
    mov     [rel page_offset], rax      ; next read offset = first page size
    mov     qword [rel page_chunk_num], 1
    mov     byte [rel page_active], 1   ; pagination active

    ; Truncate output_len so only first page gets wrapped in worklog
    mov     [output_len], rax

.no_paginate_output:
    ; Build WORKLOG output entry with tool_response wrapping
    ; Format: "tool_response id=<iteration>\n[exit:N]\n<output>\ntool_response"
    lea     rdi, [rel response_buf]

    ; Write "tool_response id="
    lea     rsi, [rel wl_tool_resp_s]
    call    .copy_local_str

    ; Write iteration number
    push    rdi
    lea     rdi, [rel exit_str_buf]
    mov     esi, r12d
    call    uint_to_str
    pop     rdi
    lea     rsi, [rel exit_str_buf]
    call    .copy_local_str

    ; Write '">'  (close XML tag)
    mov     byte [rdi], '"'
    mov     byte [rdi+1], '>'
    mov     byte [rdi+2], 10
    add     rdi, 3

    ; Write "[exit:"
    mov     byte [rdi], '['
    mov     byte [rdi+1], 'e'
    mov     byte [rdi+2], 'x'
    mov     byte [rdi+3], 'i'
    mov     byte [rdi+4], 't'
    mov     byte [rdi+5], ':'
    add     rdi, 6

    ; Write exit code
    push    rdi
    mov     esi, r12d
    call    uint_to_str
    pop     rdi
    add     rdi, rax

    ; Write "]\n```\n"
    mov     byte [rdi], ']'
    mov     byte [rdi+1], 10
    mov     byte [rdi+2], '`'
    mov     byte [rdi+3], '`'
    mov     byte [rdi+4], '`'
    mov     byte [rdi+5], 10
    add     rdi, 6

    ; Copy output (limited)
    mov     rsi, output_buf
    lea     rdx, [rel response_buf]
    add     rdx, RESPONSE_BUF_SZ - 256
    sub     rdx, rdi
    call    str_ncopy
    add     rdi, rax

    ; Write "\n```\n"
    mov     byte [rdi], 10
    mov     byte [rdi+1], '`'
    mov     byte [rdi+2], '`'
    mov     byte [rdi+3], '`'
    mov     byte [rdi+4], 10
    add     rdi, 5

    ; Write "</tool_call>\n"
    lea     rsi, [rel wl_tool_resp_e]
    call    .copy_local_str

    ; Null-terminate
    mov     byte [rdi], 0

    lea     rdi, [wl_label_output]
    lea     rsi, [rel response_buf]
    call    worklog_append_entry

    ; --- If pagination active, append notice to worklog ---
    cmp     byte [rel page_active], 1
    jne     .no_page_notice_append

    ; Build pagination notice in temp_buf:
    ; "[PAGINATED] Showing page 1 of N. Total output: M bytes. Reply NEXT_PAGE to see more."
    lea     rdi, [rel temp_buf]
    mov     rbx, rdi                 ; rbx = write cursor

    ; Copy "[PAGINATED] Showing page "
    lea     rsi, [rel wl_page_notice]
    call    .copy_local_str_to_rbx

    ; Append current page number
    lea     rdi, [rel exit_str_buf]
    mov     rax, [rel page_chunk_num]
    call    uint_to_str
    lea     rsi, [rel exit_str_buf]
    call    .copy_local_str_to_rbx

    ; Append " of "
    lea     rsi, [rel wl_page_of]
    call    .copy_local_str_to_rbx

    ; Calculate total pages: (total + PAGE_SIZE - 1) / PAGE_SIZE
    mov     rax, [rel page_total_len]
    add     rax, OUTPUT_PAGE_SIZE - 1
    xor     edx, edx
    mov     ecx, OUTPUT_PAGE_SIZE
    div     ecx                     ; eax = total pages
    lea     rdi, [rel exit_str_buf]
    call    uint_to_str
    lea     rsi, [rel exit_str_buf]
    call    .copy_local_str_to_rbx

    ; Append ". Total output: "
    lea     rsi, [rel wl_page_dot]
    call    .copy_local_str_to_rbx

    ; Append total byte count
    lea     rdi, [rel exit_str_buf]
    mov     rax, [rel page_total_len]
    call    uint_to_str
    lea     rsi, [rel exit_str_buf]
    call    .copy_local_str_to_rbx

    ; Append " bytes. Reply NEXT_PAGE to see more.\n"
    lea     rsi, [rel wl_page_bytes]
    call    .copy_local_str_to_rbx

    ; Null-terminate
    mov     byte [rbx], 0

    ; Calculate length and write to worklog
    lea     rdi, [rel temp_buf]
    call    str_len                 ; rax = length
    lea     rdi, [rel temp_buf]
    mov     rsi, rax
    call    worklog_append_raw

.no_page_notice_append:

    ; --- Musical Orchestration: Track execution result ---
    ; Advance beat
    call    conductor_beat

    ; Adjust tempo based on success/failure
    mov     eax, r12d
    test    eax, eax
    setz    al                  ; al = 1 if success (exit 0), 0 if failure
    call    conductor_adjust_tempo

    ; Adjust dynamics based on exit code
    mov     eax, r12d
    call    conductor_adjust_dynamics

    ; Log musical state every 5 iterations
    mov     eax, [rel iteration_count]
    mov     ecx, 5
    xor     edx, edx
    div     ecx
    test    edx, edx
    jnz     .no_musical_log
    call    conductor_log_state
.no_musical_log:

    ; --- Auto-verification: Track successful commands ---
    ; If exit code is 0, increment successful_exec_count
    test    r12d, r12d
    jnz     .exec_failed

    ; Success (exit 0) — increment counter
    inc     dword [rel successful_exec_count]

    ; Check if we should force DONE
    mov     eax, [rel successful_exec_count]
    cmp     eax, MAX_SUCCESSFUL_EXEC
    jl      .verify_hint

    ; Force DONE — task likely complete after many successful commands
    lea     rdi, [rel command_buf]
    lea     rsi, [rel force_done_msg]
    call    str_copy
    jmp     .handle_done

.verify_hint:
    ; Append verification hint to worklog after successful command
    ; This nudges the model to verify or complete the task
    lea     rdi, [rel wl_label_thought]
    lea     rsi, [rel verify_hint_msg]
    call    worklog_append_entry
    jmp     .exec_next_iter

.exec_failed:
    ; Failed command — reset successful counter
    mov     dword [rel successful_exec_count], 0

.exec_next_iter:

    ; Delay before next iteration
    call    delay_loop
    jmp     .loop_top

; ============================================================================
; Handle DONE action
; ============================================================================
.handle_done:
    ; Display done message
    PRINT   STDOUT, tui_done_pre
    PRINT   STDOUT, command_buf
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline

    ; Calculate Reward Score: 100 - (iteration_count * 2)
    mov     eax, [rel iteration_count]
    shl     eax, 1                  ; eax = iteration_count * 2
    mov     ecx, 100
    sub     ecx, eax                ; ecx = 100 - (iteration_count * 2)
    cmp     ecx, 10
    jge     .score_ok
    mov     ecx, 10                 ; minimum score = 10
.score_ok:

    ; Convert score to string in exit_str_buf
    lea     rdi, [rel exit_str_buf]
    mov     esi, ecx
    call    uint_to_str

    ; Display Reward in TUI
    PRINT   STDOUT, tui_reward_pre
    PRINT   STDOUT, exit_str_buf
    PRINT   STDOUT, tui_reward_post
    PRINT   STDOUT, exit_str_buf
    PRINT   STDOUT, tui_reward_end

    ; Construct reward text in response_buf
    ; Format: "Earned +N XP (Efficiency Score: N%) for completing the task in N iterations."
    lea     rdi, [rel response_buf]
    cld

    ; wl_reward_tmpl_1
    lea     rsi, [rel wl_reward_tmpl_1]
    call    .copy_local_str

    ; exit_str_buf (score)
    lea     rsi, [rel exit_str_buf]
    call    .copy_local_str

    ; wl_reward_tmpl_2
    lea     rsi, [rel wl_reward_tmpl_2]
    call    .copy_local_str

    ; exit_str_buf (score)
    lea     rsi, [rel exit_str_buf]
    call    .copy_local_str

    ; wl_reward_tmpl_3
    lea     rsi, [rel wl_reward_tmpl_3]
    call    .copy_local_str

    ; iter_str_buf (iterations count string)
    lea     rsi, [rel iter_str_buf]
    call    .copy_local_str

    ; wl_reward_tmpl_4
    lea     rsi, [rel wl_reward_tmpl_4]
    call    .copy_local_str

    ; Null-terminate response_buf
    mov     byte [rdi], 0

    ; Log DONE to WORKLOG
    lea     rdi, [wl_label_done]
    lea     rsi, [command_buf]
    call    worklog_append_entry

    ; Log REWARD to WORKLOG
    lea     rdi, [wl_label_reward]
    lea     rsi, [rel response_buf]
    call    worklog_append_entry

    ; Show completion UI
    PRINT   STDOUT, tui_complete
    jmp     .exit_clean

.copy_local_str:
.cls_loop:
    lodsb
    test    al, al
    jz      .cls_done
    stosb
    jmp     .cls_loop
.cls_done:
    ret

; --- Helper: copy string to [rbx] (used by pagination notice builder) ---
; rsi = source, rbx = write cursor (advanced past last byte written)
.copy_local_str_to_rbx:
.crbx_loop:
    lodsb
    test    al, al
    jz      .crbx_done
    mov     [rbx], al
    inc     rbx
    jmp     .crbx_loop
.crbx_done:
    ret

; ============================================================================
; Error handlers
; ============================================================================
.command_blocked:
    PRINT   STDOUT, tui_error_pre
    PRINT   STDOUT, tui_blocked_msg
    PRINT   STDOUT, ansi_reset

    ; Log blocked command
    lea     rdi, [wl_label_thought]
    lea     rsi, [tui_blocked_msg]
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

    ; API failures are not recoverable by repeating the same request blindly.
.api_error_exit:
    PRINT   STDOUT, ansi_show_cur
    EXIT    1

.handle_parse_error:
    PRINT   STDOUT, tui_error_pre
    PRINT   STDOUT, tui_parse_err
    PRINT   STDOUT, ansi_reset

    ; Increment parse error streak
    inc     dword [rel parse_error_streak]
    mov     eax, [rel parse_error_streak]
    cmp     eax, 3
    jl      .parse_err_continue

    ; 3+ consecutive parse errors — API is broken or model can't follow format
    PRINT   STDOUT, tui_error_pre
    PRINT   STDOUT, parse_err_fatal
    PRINT   STDOUT, ansi_reset
    PRINT   STDOUT, newline
    jmp     .exit_clean

.parse_err_continue:
    ; Reset think streak (this is an error, not a think)
    mov     dword [rel think_streak], 0

    ; Log the raw response as a thought for debugging
    lea     rdi, [wl_label_thought]
    lea     rsi, [command_buf]
    call    worklog_append_entry

    call    delay_loop
    jmp     .loop_top

.max_iter_reached:
    PRINT   STDOUT, tui_error_pre
    PRINT   STDOUT, max_iter_msg
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
; Helper: show_banner — Display the ASCII art banner
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
; Helper: delay_loop — Sleep based on current conductor tempo
; ============================================================================
delay_loop:
    call    conductor_get_delay_ns  ; rax = delay in nanoseconds (total)
    test    rax, rax
    jz      .no_delay               ; prestissimo = no delay
    ; Split nanoseconds into tv_sec + tv_nsec:
    ;   tv_sec  = rax / 1000000000
    ;   tv_nsec = rax % 1000000000
    push    rdx
    xor     edx, edx
    mov     rcx, 1000000000
    div     rcx                     ; rax = seconds, rdx = remaining ns
    mov     [delay_ts], rax         ; tv_sec
    mov     [delay_ts + 8], rdx     ; tv_nsec
    pop     rdx
    lea     rdi, [delay_ts]
    xor     rsi, rsi
    mov     rax, SYS_NANOSLEEP
    syscall
.no_delay:
    ret
