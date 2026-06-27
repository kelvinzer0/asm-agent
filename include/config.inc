; ============================================================================
; config.inc — ASM-AGENT API Configuration
; ============================================================================

section .rodata

; --- API Endpoint ---
api_url         db 'https://router9.warunglakku.com/v1/chat/completions', 0

; --- Authorization Header ---
; Built at runtime from ASM_AGENT_API_KEY or OPENAI_API_KEY.
auth_header_prefix db 'Authorization: Bearer ', 0
content_type    db 'Content-Type: application/json', 0

; --- Model ---
model_name      db 'cf/@cf/meta/llama-3.1-8b-instruct-fp8-fast', 0

; --- System Prompt ---
system_prompt:
    db 'You are ASM-AGENT, an autonomous AI agent on Linux with VisiBox shell.', 10, 10
    db 'HOW TO WORK:', 10
    db '1. Read the TASK below carefully', 10
    db '2. Read CONTEXT to see what you already did', 10
    db '3. Do the NEXT step that is not yet done', 10
    db '4. Never repeat a command that already succeeded', 10
    db '5. When all steps complete, respond DONE:', 10, 10
    db 'AVAILABLE TOOLS:', 10
    db '  1. EXEC (tool_call tags): Execute shell commands. Output has line numbers.', 10
    db '  2. FETCH_PAGE: Get next page of truncated output.', 10
    db '  3. SEARCH: <keyword> to jump to output containing that keyword.', 10
    db '  4. SESSION: <command> Run in persistent shell (cd/env/alias kept).', 10, 10
    db 'OUTPUT FORMAT (you MUST use these exact tags):', 10
    db '  To execute a command:', 10
    db '    <tool_call>', 10
    db '    <command>', 10
    db '    </tool_call>', 10
    db '  To think/reason:', 10
    db '  THINK: <reasoning>', 10
    db '  When task is done:', 10
    db '  DONE: <summary>', 10, 10
    db 'IMPORTANT:', 10
    db '- Commands WITHOUT tool_call tags will NOT be executed', 10
    db '- Use absolute paths for file writes', 10
    db '- Use python3 NOT python', 10
    db '- Each step must do something NEW, not repeat', 10
    db '- If output shows [truncated], reply FETCH_PAGE: to see more', 10
    db '- Use SEARCH: <keyword> to find specific info in long output', 10
    db '- Use SESSION: for cd, export, alias, and multi-step workflows', 0

system_prompt_end:

%define SYSTEM_PROMPT_LEN (system_prompt_end - system_prompt)

; --- Binary paths ---
curl_path       db '/usr/bin/curl', 0
visibox_path    db './bin/visibox', 0        ; VisiBox binary (local, bundled with build)
visibox_flag    db '--visibox', 0             ; Flag to activate VisiBox pipe mode
visibox_norc    db '--norc', 0                ; Skip bash rc files (clean output)

; --- VisiBox JSON Protocol Templates ---
; Request template: {"type":"execute","command":"<CMD>"}
visibox_req_s   db '{"type":"execute","command":"', 0
visibox_req_e   db '"}', 0
visibox_req_s_len equ visibox_req_e - visibox_req_s   ; 30 bytes (prefix only)
visibox_req_e_len equ $ - visibox_req_e               ; 3 bytes (suffix only)

; --- VisiBox JSON key anchors (shared across all modules) ---
vb_key_exit_code     db '"exit_code":', 0
vb_key_output        db '"output":', 0
vb_key_truncated     db '"output_truncated":', 0
vb_key_cursor        db '"cursor":', 0
vb_key_has_next      db '"has_next":', 0
vb_key_response_id   db '"response_id":', 0
vb_key_type          db '"type":', 0
vb_key_err           db '"error":', 0
vb_type_error        db 'VisiBox error', 0
vb_empty_output      db '(no stdout output)', 0
vb_required_msg      db 'ERROR: VisiBox not found at ./bin/visibox — cannot continue.', 10, 0

curl_silent     db '-sS', 0
curl_post       db '-X', 0
curl_post_val   db 'POST', 0
curl_header     db '-H', 0
curl_data       db '-d', 0
curl_maxtime    db '--max-time', 0
curl_timeout    db '120', 0

; --- WORKLOG file path ---
worklog_path    db 'WORKLOG.md', 0

; --- WORKLOG entry templates ---
worklog_header  db '# ASM-AGENT Worklog', 10, 10, 0
wl_separator    db 10, '---', 10, 0
wl_entry_think  db '>> [', 0
wl_entry_exec   db '>> [', 0
wl_entry_output db '>> [', 0
wl_entry_done   db '>> [', 0
wl_type_think   db '] THOUGHT', 10, 0
wl_type_exec    db '] EXEC', 10, '`', 0
wl_type_output  db '] OUTPUT [exit:', 0
wl_type_done    db '] DONE', 10, 0
wl_backtick     db '`', 10, 0
wl_codeblock_s  db 10, '```', 10, 0
wl_codeblock_e  db '```', 10, 0
wl_bracket_end  db ']', 10, 0

; Tool call/response tags for structured output
wl_tool_call_s  db '<tool_call id="', 0
wl_tool_call_e  db '</tool_call>', 10, 0
wl_tool_resp_s  db '<tool_response id="', 0
wl_tool_resp_e  db '</tool_call>', 10, 0

; --- Task prompt prefix ---
task_prefix     db 'TASK: ', 0
worklog_prefix  db 10, 10, '--- CONTEXT (past actions, DO NOT echo) ---', 10, 0
pwd_hint        db 92, 110, 92, 110, 'Use absolute paths for file operations.', 0

; ============================================================================
; Mode-specific System Prompts (Swarm/LangGraph style)
; ============================================================================

config_planner_prompt:
    db 'You are PLANNER mode. Decompose tasks into subtasks.', 10
    db 'RESPOND: EXEC: <command> or THINK: <reasoning> or DONE: <summary>', 10
    db 'First: EXEC: ls to see files. When done planning: HANDOFF: EXECUTOR', 0

config_researcher_prompt:
    db 'You are RESEARCHER mode. Discover the environment.', 10
    db 'RESPOND: EXEC: <command> or THINK: <reasoning> or DONE: <summary>', 10
    db 'First: EXEC: ls to see files. When done: HANDOFF: EXECUTOR', 0

config_executor_prompt:
    db 'You are EXECUTOR mode. Execute commands to complete the task.', 10
    db 'RESPOND: EXEC: <command> or THINK: <reasoning> or DONE: <summary>', 10
    db 'Use python3 NOT python. Check --help. When task done: DONE:', 0

config_verifier_prompt:
    db 'You are VERIFIER mode. Verify task completion.', 10
    db 'RESPOND: EXEC: <command> or THINK: <reasoning> or DONE: <summary>', 10
    db 'If goal achieved: DONE: <summary>. If not: EXEC: <verify command>', 0
