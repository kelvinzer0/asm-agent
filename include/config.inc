; ============================================================================
; config.inc — ASM-AGENT API Configuration (Tool Calls Architecture)
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

; --- System Prompt (tool calls approach) ---
system_prompt:
    db 'You are ASM-AGENT, an autonomous AI agent running on Linux x86-64.', 10
    db 'You have access to tools to execute commands and signal completion.', 10, 10
    db 'RULES:', 10
    db '1. Read the TASK and CONTEXT carefully before acting.', 10
    db '2. Plan ALL steps mentally first, then execute them ONE tool call at a time.', 10
    db '3. Each run_command call must contain a SINGLE complete shell command.', 10
    db '4. For creating files, use ONE command per file. Use heredoc syntax:', 10
    db '   cat > /absolute/path/to/file.py << ENDHEREDOC', 10
    db '   <full file content here>', 10
    db '   ENDHEREDOC', 10
    db '5. Never repeat a command that already succeeded (check CONTEXT).', 10
    db '6. After creating a file, verify it exists with: wc -l /path/to/file', 10
    db '7. Use task_complete ONLY when ALL files are created AND verified.', 10
    db '8. Use python3 NOT python. Use absolute paths for all file operations.', 10
    db '9. DO NOT just run ls or pwd. Actually CREATE the requested files with real content.', 10
    db '10. Keep each tool call focused. Do NOT combine unrelated operations.', 0
system_prompt_end:

%define SYSTEM_PROMPT_LEN (system_prompt_end - system_prompt)

; --- Tools Definition (literal JSON, included in every payload) ---
; This is the "tools" array sent to the API.
; We build it as a static string since it never changes.
tools_json:
    db ',"tools":[{"type":"function","function":{"name":"run_command","description":"Execute a shell command on the system. Use this to create files, run programs, check status, install packages, etc.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"}},"required":["command"]}}},{"type":"function","function":{"name":"task_complete","description":"Signal that the task is complete. Call this when all requested work has been done successfully.","parameters":{"type":"object","properties":{"summary":{"type":"string","description":"Summary of what was accomplished"}},"required":["summary"]}}}],'
    db '"tool_choice":"auto",'
    db '"temperature":0.2,"max_tokens":8192,"stream":false}', 0

%define TOOLS_JSON_LEN (tools_json_end - tools_json)
; Note: NASM can't compute length across sections, so we hardcode it
; The tools_json string is ~580 bytes. We'll use str_len at runtime.

tools_json_end:

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

; Worklog entry labels for tool_calls
wl_tool_call_label db 'TOOL_CALL', 10, '`', 0
wl_tool_result_label db 'TOOL_RESULT', 10, '`', 0

; --- Task prompt prefix ---
task_prefix     db 'TASK: ', 0
worklog_prefix  db 10, 10, '--- CONTEXT (past actions, DO NOT echo) ---', 10, 0
pwd_hint        db 92, 110, 92, 110, 'Use absolute paths for file operations.', 0

; ============================================================================
; JSON fragments for payload construction
; ============================================================================

; Opening: {"model":"
json_p1:    db '{"model":"', 0

; After model: ","messages":[
json_p2:    db '","messages":[', 0

; After messages content: closing of the object
; This is appended after tools_json, so it just needs to be empty
; (tools_json already includes the closing "}")
; Actually tools_json starts with "," so we need:
; After system_prompt_content: ","content":"SYSTEM_PROMPT"},{"role":"user","content":"
json_sys_end: db '","content":"', 0
json_user_msg: db '"},{"role":"user","content":"', 0

; "TASK: " prefix for user content (inside JSON string)
json_task:  db 'TASK: ', 0

; Working directory hint for system prompt (JSON-escaped)
json_cwd_prefix: db '\\nWorking directory: ', 0

; Worklog separator (JSON-escaped newlines)
json_wl_sep:
    db '\\n\\n--- WORKLOG (last 20 entries) ---\\n', 0

; --- Messages buffer append fragments ---
; For assistant message with tool_calls:
msg_assistant_tc:
    db ',{"role":"assistant","content":"', 0
msg_assistant_tc_mid:
    db '","tool_calls":[{"id":"', 0
msg_assistant_tc_fn:
    db '","type":"function","function":{"name":"', 0
msg_assistant_tc_args:
    db '","arguments":"', 0
msg_assistant_tc_end:
    db '"}}]}', 0

; For tool result message:
msg_tool_result:
    db ',{"role":"tool","tool_call_id":"', 0
msg_tool_result_mid:
    db '","content":"', 0
msg_tool_result_end:
    db '"}', 0

; For task_complete tool result (always empty string):
msg_tool_empty_result:
    db ',{"role":"tool","tool_call_id":"', 0
msg_tool_empty_mid:
    db '","content":""}', 0