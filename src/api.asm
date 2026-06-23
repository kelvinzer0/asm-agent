; ============================================================================
; api.asm — ASM-AGENT API Client (curl-based)
; ============================================================================
; Provides:
;   call_api — Write payload to temp file, fork+exec curl, capture response
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

; ---------------------------------------------------------------------------
; External data (defined in the BSS of another translation unit)
; ---------------------------------------------------------------------------
extern payload_buf          ; PAYLOAD_BUF_SZ (131072) bytes — JSON payload
extern response_buf         ; RESPONSE_BUF_SZ (262144) bytes — curl response
extern response_len         ; qword — actual bytes received
extern pipe_fds             ; 2 × dword (8 bytes) — pipe read/write fds
extern wait_status          ; dword — waitpid status word
extern saved_envp           ; qword — pointer to envp array (saved from main)

; ---------------------------------------------------------------------------
; External functions
; ---------------------------------------------------------------------------
extern str_len              ; str_len(rdi=str) -> rax (length)
extern str_copy             ; str_copy(rdi=dst, rsi=src) -> rax
extern str_concat           ; str_concat(rdi=dst, rsi=src) -> rax
extern str_starts_with      ; str_starts_with(rdi=str, rsi=prefix) -> rax
extern uint_to_str          ; uint_to_str(rdi=buf, esi=value) -> rax
extern worklog_append_entry ; worklog_append_entry(rdi=label, rsi=msg)
extern temp_buf             ; TEMP_BUF_SZ bytes — general purpose temp

; ---------------------------------------------------------------------------
; Public API
; ---------------------------------------------------------------------------
global call_api
global call_api_retry

; --- Retry Constants ---
%define API_MAX_RETRIES      3
%define API_BACKOFF_BASE_NS  1000000000   ; 1 second base

; ============================================================================
;                         READ-ONLY DATA
; ============================================================================
section .rodata

; Temp file where the JSON payload is written for curl to read via @file
payload_tmp_path:   db '/tmp/.asm_agent_payload.json', 0

; curl -d argument: "@/tmp/.asm_agent_payload.json"
curl_data_arg:      db '@/tmp/.asm_agent_payload.json', 0

env_asm_key_prefix: db 'ASM_AGENT_API_KEY=', 0
env_openai_key_prefix: db 'OPENAI_API_KEY=', 0
missing_api_key_msg: db 'Missing API key. Set ASM_AGENT_API_KEY or OPENAI_API_KEY in the environment.', 10, 0

retry_log_label:  db 'API_RETRY', 0
retry_msg_prefix: db 'API call failed, retrying in ', 0
retry_msg_suffix: db 's (attempt ', 0
retry_msg_of:     db '/', 0
retry_msg_end:    db ')', 10, 0

api_error_prefix:  db '{"error"', 0

section .bss
auth_header_buf:    resb 4096

; ============================================================================
;                            CODE
; ============================================================================
section .text

; ============================================================================
; call_api — Send payload_buf to the LLM API via curl, capture response
; ----------------------------------------------------------------------------
; Arguments : none (reads global payload_buf, config strings)
; Returns   : rax = response length on success (>= 0)
;             rax = -1 on error (fork failure or non-zero curl exit)
; Clobbers  : caller-saved registers
; ============================================================================
call_api:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13                     ; r13 = child PID
    push    r14                     ; r14 = total bytes read (accumulator)
    push    r15                     ; r15 = unused, 16-byte alignment

    mov     qword [rel response_len], 0
    lea     rax, [rel response_buf]
    mov     byte [rax], 0

    call    build_auth_header
    test    rax, rax
    jz      .missing_key_return     ; API key is not configured

    ; ==================================================================
    ; STEP 1: Write payload_buf to the temporary file
    ; ==================================================================

    ; open(payload_tmp_path, O_WRONLY | O_CREAT | O_TRUNC, 0644)
    lea     rdi, [rel payload_tmp_path]
    mov     esi, (O_WRONLY | O_CREAT | O_TRUNC)
    mov     edx, FILE_MODE          ; 0644
    mov     eax, SYS_OPEN
    syscall

    test    rax, rax
    js      .error_return           ; open failed

    mov     r12, rax                ; r12 = temp file fd

    ; Get payload length
    lea     rdi, [rel payload_buf]
    call    str_len                 ; rax = length of payload
    mov     r15, rax                ; r15 = payload length

    ; write(fd, payload_buf, length)
    mov     rdi, r12                ; fd
    lea     rsi, [rel payload_buf]  ; buffer
    mov     rdx, r15                ; count
    mov     rax, SYS_WRITE
    syscall

    ; close(fd)
    mov     rdi, r12
    mov     rax, SYS_CLOSE
    syscall

    ; ==================================================================
    ; STEP 2: Create pipe for capturing curl output
    ; ==================================================================
    lea     rdi, [rel pipe_fds]
    mov     rax, SYS_PIPE
    syscall

    test    rax, rax
    js      .error_return           ; pipe failed

    ; ==================================================================
    ; STEP 3: Fork
    ; ==================================================================
    mov     rax, SYS_FORK
    syscall

    test    rax, rax
    js      .error_return           ; fork failed
    jz      .child                  ; child process
    jmp     .parent                 ; parent process

; ======================== CHILD PROCESS ================================
.child:
    ; ------------------------------------------------------------------
    ; Redirect stdout to pipe write end
    ; ------------------------------------------------------------------
    ; dup2(pipe_fds[1], STDOUT)
    lea     rax, [rel pipe_fds]
    mov     edi, [rax + 4]          ; edi = pipe_fds[1] (write end)
    mov     esi, STDOUT
    mov     eax, SYS_DUP2
    syscall

    ; dup2(pipe_fds[1], STDERR) so curl transport/auth errors are visible
    lea     rax, [rel pipe_fds]
    mov     edi, [rax + 4]
    mov     esi, STDERR
    mov     eax, SYS_DUP2
    syscall

    ; close(pipe_fds[0])  — child doesn't read from pipe
    lea     rax, [rel pipe_fds]
    mov     edi, [rax]
    mov     eax, SYS_CLOSE
    syscall

    ; close(pipe_fds[1])  — already dup'd to stdout
    lea     rax, [rel pipe_fds]
    mov     edi, [rax + 4]
    mov     eax, SYS_CLOSE
    syscall

    ; ------------------------------------------------------------------
    ; Build argv on stack for curl:
    ;   argv[ 0] = curl_path        "/usr/bin/curl"
    ;   argv[ 1] = curl_silent      "-sS"
    ;   argv[ 2] = curl_post        "-X"
    ;   argv[ 3] = curl_post_val    "POST"
    ;   argv[ 4] = api_url          "https://..."
    ;   argv[ 5] = curl_header      "-H"
    ;   argv[ 6] = content_type     "Content-Type: application/json"
    ;   argv[ 7] = curl_header      "-H"
    ;   argv[ 8] = auth_header_buf  "Authorization: Bearer <env key>"
    ;   argv[ 9] = curl_data        "-d"
    ;   argv[10] = curl_data_arg    "@/tmp/.asm_agent_payload.json"
    ;   argv[11] = curl_maxtime     "--max-time"
    ;   argv[12] = curl_timeout     "120"
    ;   argv[13] = NULL
    ;
    ; Push in REVERSE order (stack grows downward):
    ; ------------------------------------------------------------------
    xor     eax, eax
    push    rax                         ; argv[13] = NULL

    lea     rax, [rel curl_timeout]
    push    rax                         ; argv[12]

    lea     rax, [rel curl_maxtime]
    push    rax                         ; argv[11]

    lea     rax, [rel curl_data_arg]
    push    rax                         ; argv[10]

    lea     rax, [rel curl_data]
    push    rax                         ; argv[9]

    lea     rax, [rel auth_header_buf]
    push    rax                         ; argv[8]

    lea     rax, [rel curl_header]
    push    rax                         ; argv[7]

    lea     rax, [rel content_type]
    push    rax                         ; argv[6]

    lea     rax, [rel curl_header]
    push    rax                         ; argv[5]

    lea     rax, [rel api_url]
    push    rax                         ; argv[4]

    lea     rax, [rel curl_post_val]
    push    rax                         ; argv[3]

    lea     rax, [rel curl_post]
    push    rax                         ; argv[2]

    lea     rax, [rel curl_silent]
    push    rax                         ; argv[1]

    lea     rax, [rel curl_path]
    push    rax                         ; argv[0]

    ; execve(curl_path, argv, envp)
    lea     rdi, [rel curl_path]        ; pathname
    mov     rsi, rsp                    ; argv (on stack)
    mov     rdx, [rel saved_envp]       ; envp
    mov     rax, SYS_EXECVE
    syscall

    ; execve only returns on error — exit(127)
    EXIT    127

; ======================== PARENT PROCESS ===============================
.parent:
    mov     r13, rax                ; r13 = child PID

    ; close(pipe_fds[1])  — parent doesn't write to the pipe
    lea     rax, [rel pipe_fds]
    mov     edi, [rax + 4]
    mov     eax, SYS_CLOSE
    syscall

    ; ------------------------------------------------------------------
    ; Read loop — accumulate curl output into response_buf
    ; ------------------------------------------------------------------
    xor     r14d, r14d              ; r14 = 0 (total bytes read)

.read_loop:
    ; Compute remaining space: RESPONSE_BUF_SZ - 1 - r14
    mov     rdx, RESPONSE_BUF_SZ - 1
    sub     rdx, r14
    jle     .read_done              ; buffer full → stop

    ; read(pipe_fds[0], response_buf + r14, remaining)
    lea     rax, [rel pipe_fds]
    mov     edi, [rax]              ; fd = pipe_fds[0] (read end)
    lea     rsi, [rel response_buf]
    add     rsi, r14                ; offset into buffer
    mov     rax, SYS_READ
    syscall

    ; Check return value
    test    rax, rax
    jle     .read_done              ; 0 = EOF, negative = error

    add     r14, rax                ; accumulate byte count
    jmp     .read_loop

.read_done:
    ; Store total response length
    mov     [rel response_len], r14

    ; Null-terminate the response
    lea     rax, [rel response_buf]
    mov     byte [rax + r14], 0

    ; close(pipe_fds[0])  — done reading
    lea     rax, [rel pipe_fds]
    mov     edi, [rax]
    mov     eax, SYS_CLOSE
    syscall

    ; ------------------------------------------------------------------
    ; wait4(child_pid, &wait_status, 0, NULL)
    ; ------------------------------------------------------------------
    mov     rdi, r13                ; pid
    lea     rsi, [rel wait_status]  ; &status
    xor     edx, edx                ; options = 0
    xor     r10d, r10d              ; rusage = NULL
    mov     rax, SYS_WAIT4
    syscall

    ; ------------------------------------------------------------------
    ; Extract WEXITSTATUS and check for curl success
    ; ------------------------------------------------------------------
    mov     eax, [rel wait_status]
    shr     eax, 8
    and     eax, 0xFF               ; eax = curl exit code

    test    eax, eax
    jnz     .error_return           ; curl exited non-zero → error

    ; Success — return response length
    mov     rax, r14
    jmp     .cleanup

.error_return:
    mov     rax, -1                 ; signal error
    jmp     .cleanup

.missing_key_return:
    lea     rdi, [rel response_buf]
    lea     rsi, [rel missing_api_key_msg]
    call    str_copy
    mov     [rel response_len], rax
    mov     rax, -1                 ; signal error

.cleanup:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; ============================================================================
; build_auth_header — Build Authorization header from process environment
; ----------------------------------------------------------------------------
; Uses ASM_AGENT_API_KEY first, then OPENAI_API_KEY.
; Returns: rax = 1 if auth_header_buf is ready, 0 if no key was found.
; ============================================================================
build_auth_header:
    push    rbx
    push    r12
    push    r13

    mov     rbx, [rel saved_envp]
    test    rbx, rbx
    jz      .not_found

.scan_asm:
    mov     r12, [rbx]
    test    r12, r12
    jz      .scan_openai_start

    mov     rdi, r12
    lea     rsi, [rel env_asm_key_prefix]
    call    str_starts_with
    test    rax, rax
    jnz     .found_asm

    add     rbx, 8
    jmp     .scan_asm

.scan_openai_start:
    mov     rbx, [rel saved_envp]

.scan_openai:
    mov     r12, [rbx]
    test    r12, r12
    jz      .not_found

    mov     rdi, r12
    lea     rsi, [rel env_openai_key_prefix]
    call    str_starts_with
    test    rax, rax
    jnz     .found_openai

    add     rbx, 8
    jmp     .scan_openai

.found_asm:
    lea     rdi, [rel env_asm_key_prefix]
    call    str_len
    lea     r13, [r12 + rax]
    jmp     .build

.found_openai:
    lea     rdi, [rel env_openai_key_prefix]
    call    str_len
    lea     r13, [r12 + rax]

.build:
    cmp     byte [r13], 0
    je      .not_found

    lea     rdi, [rel auth_header_buf]
    lea     rsi, [rel auth_header_prefix]
    call    str_copy

    lea     rdi, [rel auth_header_buf]
    mov     rsi, r13
    call    str_concat

    mov     rax, 1
    jmp     .done

.not_found:
    xor     rax, rax

.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; call_api_retry — Call API with exponential backoff retry on failure
; ----------------------------------------------------------------------------
; Wraps call_api with up to API_MAX_RETRIES retries.
; On each failure, waits 2^attempt seconds before retrying.
; Arguments : none (reads/writes same globals as call_api)
; Returns   : rax = response length on success (>= 0)
;             rax = -1 on error (all retries exhausted)
; Clobbers  : caller-saved registers
; ============================================================================
call_api_retry:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16                  ; local space for uint_to_str

    xor     r14d, r14d              ; r14 = retry counter (0-based)
    xor     r15d, r15d              ; r15 = backoff seconds (1, 2, 4, ...)

.retry_loop:
    ; Call the actual API
    call    call_api
    test    rax, rax
    js      .check_retry            ; rax < 0 → HTTP failure, maybe retry
    jmp     .success                ; rax >= 0 → success

.check_retry:
    ; Failed — check if we have retries left
    inc     r14d
    cmp     r14d, API_MAX_RETRIES
    jge     .all_failed

    ; Compute backoff: r15 = max(r15 * 2, 1) to ensure minimum 1s
    shl     r15d, 1
    test    r15d, r15d
    jnz     .backoff_ok
    mov     r15d, 1
.backoff_ok:

    ; Log retry message to worklog: "API call failed, retrying in Ns (attempt X/3)"
    lea     rdi, [rsp]
    lea     rsi, [rel retry_msg_prefix]
    call    .copy_str_to_rsp

    ; Convert backoff seconds to string
    mov     rdi, rsp
    mov     esi, r15d
    push    rbx
    mov     rbx, rdi
    sub     rsp, 16
    mov     rdi, rsp
    call    uint_to_str
    mov     rdi, rbx
    mov     rsi, rsp
    call    .copy_str_to_rsp
    add     rsp, 16
    pop     rbx

    ; Append "s (attempt "
    lea     rdi, [rsp]
    lea     rsi, [rel retry_msg_suffix]
    call    .copy_str_to_rsp

    ; Append attempt number
    mov     rdi, rsp
    mov     esi, r14d
    push    rbx
    mov     rbx, rdi
    sub     rsp, 16
    mov     rdi, rsp
    call    uint_to_str
    mov     rdi, rbx
    mov     rsi, rsp
    call    .copy_str_to_rsp
    add     rsp, 16
    pop     rbx

    ; Append "/MAX)"
    lea     rdi, [rsp]
    lea     rsi, [rel retry_msg_of]
    call    .copy_str_to_rsp

    mov     rdi, rsp
    mov     esi, API_MAX_RETRIES
    push    rbx
    mov     rbx, rdi
    sub     rsp, 16
    mov     rdi, rsp
    call    uint_to_str
    mov     rdi, rbx
    mov     rsi, rsp
    call    .copy_str_to_rsp
    add     rsp, 16
    pop     rbx

    lea     rdi, [rsp]
    lea     rsi, [rel retry_msg_end]
    call    .copy_str_to_rsp

    ; Null-terminate
    mov     byte [rsp + r12], 0    ; r12 tracks position from .copy_str_to_rsp
    lea     rdi, [rel temp_buf]
    mov     rsi, rsp
    call    str_copy

    ; Write to worklog
    lea     rdi, [rel retry_log_label]
    lea     rsi, [rel temp_buf]
    call    worklog_append_entry

    ; Sleep for backoff period: r15 seconds
    ; nanosleep({sec = r15, nsec = 0}, NULL)
    mov     rdi, rsp               ; use local space for timespec
    xor     eax, eax
    mov     [rsp], r15d            ; tv_sec
    mov     [rsp + 4], eax         ; tv_sec high dword
    mov     [rsp + 8], eax         ; tv_nsec
    mov     [rsp + 12], eax        ; tv_nsec high dword
    xor     esi, esi               ; NULL (no remainder)
    mov     eax, SYS_NANOSLEEP
    syscall

    jmp     .retry_loop

.success:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

.all_failed:
    mov     rax, -1
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; --- Helper: append string to rsp position, advance r12 ---
; rdi = destination base (rsp), rsi = source string
.copy_str_to_rsp:
    ; r12 holds current write offset into rsp buffer
    ; On first call, r12 might be 0; let's use a simple approach:
    ; scan from rdi for null terminator to find current end
    push    rax
    push    rcx
    mov     rcx, rdi
    xor     al, al
.crs_find_end:
    cmp     byte [rcx], 0
    je      .crs_found_end
    inc     rcx
    jmp     .crs_find_end
.crs_found_end:
    ; rcx = end of string in rdi buffer
.crs_copy:
    lodsb
    test    al, al
    jz      .crs_done
    mov     [rcx], al
    inc     rcx
    jmp     .crs_copy
.crs_done:
    mov     r12, rcx              ; save end position for caller
    pop     rcx
    pop     rax
    ret
