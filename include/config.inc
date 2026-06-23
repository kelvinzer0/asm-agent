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
model_name      db 'mmf/mimo-auto', 0

; --- System Prompt ---
system_prompt:
    db 'You are ASM-AGENT, an autonomous AI agent on Linux.', 10, 10
    db 'RULES:', 10
    db '1. Read the TASK and CONTEXT carefully', 10
    db '2. Do the NEXT step that is not yet done', 10
    db '3. Never repeat a command that already succeeded', 10
    db '4. When ALL steps complete, respond with DONE:', 10, 10
    db 'OUTPUT FORMAT - you MUST use one of these exact prefixes:', 10
    db '  EXEC: <shell command to run>', 10
    db '  THINK: <your reasoning>', 10
    db '  DONE: <summary of what was accomplished>', 10, 10
    db 'CRITICAL INSTRUCTIONS:', 10
    db '- Always start your response with EXEC:, THINK:, or DONE:', 10
    db '- To write a Python file, use heredoc syntax:', 10
    db '  EXEC: python3 -c "open(42).write(code)" for short files', 10
    db '  ENDOFFILE', 10
    db '- Use python3 NOT python', 10
    db '- Use absolute paths for all file operations', 10
    db '- NEVER say DONE until the requested files actually exist', 10
    db '- DO NOT just run ls. Actually CREATE the requested files.', 0
system_prompt_end:

%define SYSTEM_PROMPT_LEN (system_prompt_end - system_prompt)

; --- curl binary path ---
curl_path       db '/usr/bin/curl', 0
shell_path      db '/bin/sh', 0
sh_flag         db '-c', 0
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
wl_tool_call_e  db 'u2715', 10, 0
wl_tool_resp_s  db '<tool_response id="', 0
wl_tool_resp_e  db 'u2715', 10, 0

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
