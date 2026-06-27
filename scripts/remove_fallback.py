#!/usr/bin/env python3
"""Remove ALL /bin/sh fallback code from asm-agent source files."""

import re

def edit_executor():
    path = 'src/executor.asm'
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # 1. Remove exec_command_fallback from header comment
    content = content.replace(
        ';   exec_command_fallback    — Legacy fork+exec /bin/sh -c <command>\n',
        ''
    )
    
    # 2. Remove global exec_command_fallback
    content = content.replace(
        'global exec_command_fallback\n',
        ''
    )
    
    # 3. Update exec_command comment
    old_dispatch = """; exec_command — Unified dispatch: VisiBox or fallback /bin/sh
; ----------------------------------------------------------------------------
; Checks use_visibox flag. If set, calls exec_command_visibox.
; Otherwise falls through to exec_command_fallback.
;
; Arguments : none (reads global command_buf)
; Returns   : rax = exit code (0-255)
; ============================================================================
exec_command:
    ; VisiBox is REQUIRED — no fallback to /bin/sh
    call    exec_command_visibox
    ret"""
    
    new_dispatch = """; exec_command — VisiBox-only command execution
; ----------------------------------------------------------------------------
; VisiBox is the sole and only command execution method.
; No fallback. If VisiBox fails, the error propagates.
;
; Arguments : none (reads global command_buf)
; Returns   : rax = exit code (0-255)
; ============================================================================
exec_command:
    call    exec_command_visibox
    ret"""
    
    content = content.replace(old_dispatch, new_dispatch)
    
    # 4. Remove the entire exec_command_fallback function (from the section header to end)
    # Find the fallback function start
    fallback_start = content.find('; exec_command_fallback — Legacy')
    if fallback_start == -1:
        print("WARNING: exec_command_fallback function not found")
    else:
        content = content[:fallback_start].rstrip() + '\n'
    
    # 5. Remove the "→ signal fallback" comment  
    content = content.replace('→ signal fallback', '')
    
    # 6. Remove use_visibox extern (no longer needed since it's always visibox)
    content = content.replace('extern use_visibox              ; byte — 1 = use visibox, 0 = fallback\n', '')
    
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"  Edited {path}")

def edit_main():
    path = 'src/main.asm'
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # 1. Remove extern exec_command_fallback
    content = content.replace('extern exec_command_fallback\n', '')
    
    # 2. Remove use_visibox comment about fallback
    content = content.replace(
        'use_visibox            resb 1                     ; 1 = use visibox, 0 = fallback to /bin/sh\n',
        'use_visibox            resb 1                     ; 1 = visibox available (always 1 if we reach here)\n'
    )
    
    # 3. Remove no_vb_search_msg and no_vb_session_msg strings
    content = content.replace(
        "no_vb_search_msg db 'SEARCH is only available with VisiBox. Use FETCH_PAGE or NEXT_PAGE instead.', 0\n",
        ''
    )
    content = content.replace(
        "no_vb_session_msg db 'SESSION is only available with VisiBox. Using EXEC instead (state not persisted).', 0\n",
        ''
    )
    
    # 4. Remove fallback paths in handle_fetch_page
    # Replace the use_visibox check + fallback with direct cursor check
    old_fetch = """.handle_fetch_page:
    ; --- Try VisiBox cursor pagination first ---
    cmp     byte [rel use_visibox], 1
    jne     .fetch_fallback_local

    ; Check if VisiBox has a cursor (has_next from last execute)
    cmp     byte [rel vb_saved_has_next], 1
    je      .fetch_vb_do

    ; No VisiBox cursor — fall through to local pagination
.fetch_fallback_local:"""
    
    new_fetch = """.handle_fetch_page:
    ; --- VisiBox cursor-based pagination ---
    ; Check if VisiBox has a cursor (has_next from last execute)
    cmp     byte [rel vb_saved_has_next], 1
    je      .fetch_vb_do

    ; No VisiBox cursor — fall through to local pagination
.fetch_no_cursor:"""
    
    content = content.replace(old_fetch, new_fetch)
    
    # 5. Remove fallback in handle_search
    old_search = """.handle_search:
    cmp     byte [rel use_visibox], 1
    jne     .search_fallback

    ; Display search keyword"""
    
    new_search = """.handle_search:
    ; Display search keyword"""
    
    content = content.replace(old_search, new_search)
    
    # 6. Remove .search_fallback block
    old_search_fallback = """.search_fallback:
    ; No visibox — search not available, treat as think
    lea     rdi, [rel command_buf]
    lea     rsi, [rel no_vb_search_msg]
    call    str_copy
    jmp     .handle_think"""
    
    content = content.replace(old_search_fallback, '')
    
    # 7. Remove fallback in handle_session
    old_session = """.handle_session:
    cmp     byte [rel use_visibox], 1
    jne     .session_fallback

    ; Display session command"""
    
    new_session = """.handle_session:
    ; Display session command"""
    
    content = content.replace(old_session, new_session)
    
    # 8. Remove .session_fallback block
    old_session_fallback = """.session_fallback:
    ; No VisiBox — session not available, delegate to EXEC handler
    ; command_buf still has the original command
    jmp     .handle_exec"""
    
    content = content.replace(old_session_fallback, '')
    
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"  Edited {path}")

def edit_tool_search():
    path = 'src/tool_search.asm'
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Remove use_visibox check — it's always 1
    content = content.replace('extern use_visibox\n', '')
    content = content.replace(
        '    cmp     byte [rel use_visibox], 1\n    jne     .err\n\n',
        ''
    )
    
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"  Edited {path}")

def edit_tool_fetch_page():
    path = 'src/tool_fetch_page.asm'
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Remove use_visibox check — it's always 1
    content = content.replace('extern use_visibox\n', '')
    content = content.replace(
        '    cmp     byte [rel use_visibox], 1\n    jne     .no_visibox\n\n',
        ''
    )
    
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"  Edited {path}")

def edit_tool_session():
    path = 'src/tool_session.asm'
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Remove use_visibox extern — no longer needed
    content = content.replace('extern use_visibox\n', '')
    
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"  Edited {path}")

def edit_tool_exec():
    path = 'src/tool_exec.asm'
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Remove use_visibox extern — no longer needed
    content = content.replace('extern use_visibox\n', '')
    
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"  Edited {path}")

def edit_visibox_client():
    path = 'src/visibox_client.asm'
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Remove use_visibox extern — no longer needed
    content = content.replace('extern use_visibox\n', '')
    
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"  Edited {path}")

if __name__ == '__main__':
    import os
    os.chdir('/home/z/my-project/asm-agent')
    edit_executor()
    edit_main()
    edit_tool_search()
    edit_tool_fetch_page()
    edit_tool_session()
    edit_tool_exec()
    edit_visibox_client()
    print("\nAll fallback code removed. VisiBox is now the SOLE execution method.")
