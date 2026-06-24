; ============================================================================
; github_tools.asm — GitHub API Tool Implementations
; ============================================================================
;
; Provides github_search and github_read tools that wrap the GitHub REST API
; in Python scripts, so the model doesn't need to know curl/gh API syntax.
;
; Architecture:
;   1. Write tool_call_args_buf (JSON) to /tmp/.asm_gh.json via syscall
;   2. Write static Python script to /tmp/.asm_gh_tool.py via syscall
;   3. Set command_buf = "python3 /tmp/.asm_gh_tool.py # github_search"
;   4. Normal exec_command pipeline executes it
;
; Functions:
;   build_gh_search_cmd() — Prepare github_search for execution
;   build_gh_read_cmd()   — Prepare github_read for execution
;
; ============================================================================

%include "constants.inc"
%include "macros.inc"

; ---------------------------------------------------------------------------
; External data (defined in main.asm BSS)
; ---------------------------------------------------------------------------
extern tool_call_args_buf
extern command_buf

; ---------------------------------------------------------------------------
; External functions (from strings.asm)
; ---------------------------------------------------------------------------
extern str_len
extern str_copy

; ---------------------------------------------------------------------------
; Exported symbols
; ---------------------------------------------------------------------------
global build_gh_search_cmd
global build_gh_read_cmd


; ============================================================================
section .rodata
; ============================================================================

; --- Temp file paths ---
gh_args_path       db '/tmp/.asm_gh.json', 0
gh_tool_path       db '/tmp/.asm_gh_tool.py', 0
gh_run_cmd         db 'python3 /tmp/.asm_gh_tool.py', 0

; --- TTY comment suffixes ---
gh_search_comment  db ' # github_search', 0
gh_read_comment    db ' # github_read', 0

; --- Python script for github_search ---
; Reads /tmp/.asm_gh.json for {"query":"...","type":"code|repositories|issues"}
; Calls GitHub Search API, formats results for LLM consumption.
gh_search_script:
    db 'import json,urllib.request,sys,os', 10
    db 'try:', 10
    db '  a=json.loads(open("/tmp/.asm_gh.json").read())', 10
    db '  if not a:print("Error: no args",file=sys.stderr);sys.exit(1)', 10
    db '  q=a.get("query","").replace(" ","+")', 10
    db '  if not q:print("Error: no query",file=sys.stderr);sys.exit(1)', 10
    db '  t=a.get("type","code")', 10
    db '  u="https://api.github.com/search/"+t+"?q="+q+"&per_page=5"', 10
    db '  h={"Accept":"application/vnd.github.v3+json","User-Agent":"asm-agent"}', 10
    db '  tk=os.environ.get("GITHUB_TOKEN","")', 10
    db '  if tk:h["Authorization"]="Bearer "+tk', 10
    db '  r=urllib.request.Request(u,headers=h)', 10
    db '  resp=urllib.request.urlopen(r,timeout=30)', 10
    db '  data=json.loads(resp.read().decode())', 10
    db '  out=[]', 10
    db '  if data and "items" in data:', 10
    db '    for item in data["items"][:5]:', 10
    db '      if t=="code":', 10
    db '        out.append(item["repository"]["full_name"]+" | "+item["path"]+" | score:"+str(item.get("score",0)))', 10
    db '      elif t=="repositories":', 10
    db '        out.append(item["full_name"]+" | "+item.get("description","")[:100]+" | stars:"+str(item.get("stargazers_count",0)))', 10
    db '      elif t=="issues":', 10
    db '        out.append(item["html_url"]+" | "+item["title"]+" | state:"+item["state"])', 10
    db '  print("\\n".join(out))', 10
    db '  if data and data.get("total_count",0)>5:', 10
    db '    print("... and %d more results" % (data["total_count"]-5))', 10
    db 'except Exception as e:', 10
    db '  print("GitHub API Error: %s" % e, file=sys.stderr)', 10
    db '  sys.exit(1)', 10, 0

; --- Python script for github_read ---
; Reads /tmp/.asm_gh.json for {"owner":"...","repo":"...","path":"...","branch":"..."}
; Fetches raw file content from GitHub.
gh_read_script:
    db 'import json,urllib.request,sys,os', 10
    db 'try:', 10
    db '  a=json.loads(open("/tmp/.asm_gh.json").read())', 10
    db '  if not a:print("Error: no args",file=sys.stderr);sys.exit(1)', 10
    db '  o=a.get("owner");rp=a.get("repo");p=a.get("path")', 10
    db '  if not o or not rp or not p:print("Error: missing owner/repo/path",file=sys.stderr);sys.exit(1)', 10
    db '  b=a.get("branch","main")', 10
    db '  u="https://raw.githubusercontent.com/"+o+"/"+rp+"/"+b+"/"+p', 10
    db '  h={"User-Agent":"asm-agent"}', 10
    db '  tk=os.environ.get("GITHUB_TOKEN","")', 10
    db '  if tk:h["Authorization"]="Bearer "+tk', 10
    db '  r=urllib.request.Request(u,headers=h)', 10
    db '  resp=urllib.request.urlopen(r,timeout=30)', 10
    db '  content=resp.read().decode()', 10
    db '  print(content[:8000])', 10
    db '  if len(content)>8000:', 10
    db '    print("... truncated (%d bytes total)" % len(content))', 10
    db 'except Exception as e:', 10
    db '  print("GitHub Read Error: %s" % e, file=sys.stderr)', 10
    db '  sys.exit(1)', 10, 0


; ============================================================================
section .text
; ============================================================================

; ============================================================================
; _write_args_json — Write tool_call_args_buf to /tmp/.asm_gh.json
; ============================================================================
;
; Uses direct syscalls to write the JSON arguments to a temp file.
; This avoids all shell-escaping issues.
;
; Clobbers: rax, rdi, rsi, rdx, r12
; ============================================================================
_write_args_json:
    ; --- Open file: O_WRONLY | O_CREAT | O_TRUNC ---
    mov     rax, SYS_OPEN
    lea     rdi, [rel gh_args_path]
    mov     rsi, O_WRONLY | O_CREAT | O_TRUNC
    mov     rdx, FILE_MODE               ; 0644
    syscall
    test    rax, rax
    js      .waj_done                    ; open failed -> skip
    mov     r12, rax                     ; r12 = fd

    ; --- Get args length ---
    lea     rdi, [rel tool_call_args_buf]
    call    str_len                      ; rax = length
    test    rax, rax
    jz      .waj_close                   ; empty args -> skip write

    ; --- Write args to file ---
    mov     rdx, rax                     ; length
    lea     rsi, [rel tool_call_args_buf] ; buffer
    mov     rax, SYS_WRITE
    mov     rdi, r12                     ; fd
    syscall

.waj_close:
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall

.waj_done:
    ret


; ============================================================================
; _write_script_file — Write a static Python script to /tmp/.asm_gh_tool.py
; ============================================================================
;
; Args: rdi = pointer to script content (null-terminated)
; Clobbers: rax, rdi, rsi, rdx, r12, r13
; ============================================================================
_write_script_file:
    push    r13
    mov     r13, rdi                    ; r13 = script pointer

    ; --- Open file ---
    mov     rax, SYS_OPEN
    lea     rdi, [rel gh_tool_path]
    mov     rsi, O_WRONLY | O_CREAT | O_TRUNC
    mov     rdx, FILE_MODE
    syscall
    test    rax, rax
    js      .wsf_done
    mov     r12, rax                     ; r12 = fd

    ; --- Get script length ---
    lea     rdi, [r13]
    call    str_len                      ; rax = length
    test    rax, rax
    jz      .wsf_close

    ; --- Write script ---
    mov     rdx, rax                     ; length
    lea     rsi, [r13]                   ; buffer
    mov     rax, SYS_WRITE
    mov     rdi, r12                     ; fd
    syscall

.wsf_close:
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall

.wsf_done:
    pop     r13
    ret


; ============================================================================
; build_gh_search_cmd — Prepare github_search tool for execution
; ============================================================================
;
; 1. Writes tool_call_args_buf to /tmp/.asm_gh.json
; 2. Writes search Python script to /tmp/.asm_gh_tool.py
; 3. Sets command_buf = "python3 /tmp/.asm_gh_tool.py # github_search"
;
; After this returns, the normal exec_command pipeline will execute it.
;
; Clobbers: all caller-saved registers
; ============================================================================
build_gh_search_cmd:
    push    rbp
    mov     rbp, rsp
    push    rbx                         ; str_copy clobbers rbx (pushed internally)

    ; --- Write args JSON to temp file ---
    call    _write_args_json

    ; --- Write search Python script to temp file ---
    lea     rdi, [rel gh_search_script]
    call    _write_script_file

    ; --- Set command_buf = "python3 /tmp/.asm_gh_tool.py" ---
    lea     rdi, [rel command_buf]
    lea     rsi, [rel gh_run_cmd]
    call    str_copy

    ; --- Append " # github_search" for TTY.md readability ---
    lea     rdi, [rel command_buf]
    call    str_len                      ; rax = current length
    add     rdi, rax                     ; rdi -> null terminator
    lea     rsi, [rel gh_search_comment]
    call    str_copy

    pop     rbx
    pop     rbp
    ret


; ============================================================================
; build_gh_read_cmd — Prepare github_read tool for execution
; ============================================================================
;
; 1. Writes tool_call_args_buf to /tmp/.asm_gh.json
; 2. Writes read Python script to /tmp/.asm_gh_tool.py
; 3. Sets command_buf = "python3 /tmp/.asm_gh_tool.py # github_read"
;
; After this returns, the normal exec_command pipeline will execute it.
;
; Clobbers: all caller-saved registers
; ============================================================================
build_gh_read_cmd:
    push    rbp
    mov     rbp, rsp
    push    rbx                         ; str_copy clobbers rbx (pushed internally)

    ; --- Write args JSON to temp file ---
    call    _write_args_json

    ; --- Write read Python script to temp file ---
    lea     rdi, [rel gh_read_script]
    call    _write_script_file

    ; --- Set command_buf = "python3 /tmp/.asm_gh_tool.py" ---
    lea     rdi, [rel command_buf]
    lea     rsi, [rel gh_run_cmd]
    call    str_copy

    ; --- Append " # github_read" for TTY.md readability ---
    lea     rdi, [rel command_buf]
    call    str_len                      ; rax = current length
    add     rdi, rax                     ; rdi -> null terminator
    lea     rsi, [rel gh_read_comment]
    call    str_copy

    pop     rbx
    pop     rbp
    ret
