; ============================================================================
; executor.asm — ASM-AGENT Command Executor
; ============================================================================
; Provides:
;   check_blocked  — Scan command_buf against dangerous patterns (0=ok, 1=blocked)
;   exec_command   — Fork+exec /bin/sh -c <command>, capture output, return exit code
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

; ---------------------------------------------------------------------------
; External data (defined in the BSS of another translation unit)
; ---------------------------------------------------------------------------
extern command_buf          ; COMMAND_BUF_SZ (8192) bytes — command to run
extern output_buf           ; OUTPUT_BUF_SZ  (65536) bytes — captured stdout+stderr
extern output_len           ; qword — actual bytes captured
extern pipe_fds             ; 2 × dword (8 bytes) — pipe read/write fds
extern wait_status          ; dword — waitpid status word
extern saved_envp           ; qword — pointer to envp array (saved from main)

; ---------------------------------------------------------------------------
; External functions
; ---------------------------------------------------------------------------
extern str_find             ; str_find(rdi=haystack, rsi=needle) -> rax (ptr or 0)
extern str_len              ; str_len(rdi=str) -> rax (length)

; ---------------------------------------------------------------------------
; Public API
; ---------------------------------------------------------------------------
global check_blocked
global exec_command

; ============================================================================
;                         READ-ONLY DATA
; ============================================================================
section .rodata

; --- Blocked command patterns (null-terminated) ---
bp_rm_rf:   db 'rm -rf /', 0
bp_fork:    db ':()', 0
bp_dd:      db 'dd if=/dev', 0
bp_mkfs:    db 'mkfs', 0
bp_shut:    db 'shutdown', 0
bp_reboot:  db 'reboot', 0
bp_sda:     db '> /dev/sda', 0
bp_chmod:   db 'chmod -R 777 /', 0

; Pointer table — terminated by a NULL sentinel
align 8
blocked_list:
    dq bp_rm_rf
    dq bp_fork
    dq bp_dd
    dq bp_mkfs
    dq bp_shut
    dq bp_reboot
    dq bp_sda
    dq bp_chmod
    dq 0                       ; sentinel

; ============================================================================
;                            CODE
; ============================================================================
section .text

; ============================================================================
; check_blocked — Scan command_buf for dangerous patterns
; ----------------------------------------------------------------------------
; Arguments : none (reads global command_buf)
; Returns   : rax = 0  → command is allowed
;             rax = 1  → command contains a blocked pattern
; Clobbers  : rcx (via str_find), caller-saved registers
; ============================================================================
check_blocked:
    push    rbp
    mov     rbp, rsp
    push    rbx                     ; rbx = iterator through blocked_list
    push    r12                     ; r12 = unused but keeps stack 16-byte aligned

    ; rbx points to the first entry in blocked_list
    lea     rbx, [rel blocked_list]

.check_loop:
    mov     rsi, [rbx]              ; rsi = pointer to current pattern string
    test    rsi, rsi                ; NULL sentinel?
    jz      .allowed                ; yes → all patterns checked, command is safe

    ; str_find(haystack=command_buf, needle=pattern)
    lea     rdi, [rel command_buf]
    call    str_find                ; rax = pointer into haystack, or 0

    test    rax, rax
    jnz     .blocked                ; pattern found → command is blocked

    add     rbx, 8                  ; advance to next pointer in blocked_list
    jmp     .check_loop

.blocked:
    mov     rax, 1                  ; 1 = blocked
    jmp     .done

.allowed:
    xor     eax, eax                ; 0 = allowed

.done:
    pop     r12
    pop     rbx
    pop     rbp
    ret

; ============================================================================
; exec_command — Execute command_buf via /bin/sh -c, capture output
; ----------------------------------------------------------------------------
; Arguments : none (reads global command_buf, shell_path, sh_flag)
; Returns   : rax = WEXITSTATUS (bits 15..8 of wait_status, masked to 0xFF)
; Clobbers  : caller-saved registers
; ============================================================================
exec_command:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13                     ; r13 = child PID
    push    r14                     ; r14 = total bytes read (accumulator)
    push    r15                     ; r15 = unused, keeps 16-byte alignment

    ; ------------------------------------------------------------------
    ; 1. Create pipe: pipe(pipe_fds)
    ; ------------------------------------------------------------------
    lea     rdi, [rel pipe_fds]
    mov     rax, SYS_PIPE
    syscall
    test    rax, rax
    js      .fork_error
    ; pipe_fds[0] = read end, pipe_fds[1] = write end

    ; ------------------------------------------------------------------
    ; 2. Fork
    ; ------------------------------------------------------------------
    mov     rax, SYS_FORK
    syscall
    test    rax, rax
    js      .fork_error             ; negative = error
    jz      .child                  ; zero     = child process
    jmp     .parent                 ; positive = parent (rax = child pid)

; ======================== CHILD PROCESS ================================
.child:
    ; dup2(pipe_fds[1], STDOUT)  — redirect stdout to pipe write end
    lea     rax, [rel pipe_fds]
    mov     edi, [rax + 4]          ; edi = pipe_fds[1] (write end)
    mov     esi, STDOUT
    mov     eax, SYS_DUP2
    syscall

    ; dup2(pipe_fds[1], STDERR)  — redirect stderr to pipe write end
    lea     rax, [rel pipe_fds]
    mov     edi, [rax + 4]          ; edi = pipe_fds[1]
    mov     esi, STDERR
    mov     eax, SYS_DUP2
    syscall

    ; close(pipe_fds[0])  — child doesn't need the read end
    lea     rax, [rel pipe_fds]
    mov     edi, [rax]              ; edi = pipe_fds[0]
    mov     eax, SYS_CLOSE
    syscall

    ; close(pipe_fds[1])  — already duplicated to stdout/stderr
    lea     rax, [rel pipe_fds]
    mov     edi, [rax + 4]          ; edi = pipe_fds[1]
    mov     eax, SYS_CLOSE
    syscall

    ; ------------------------------------------------------------------
    ; Build argv on stack:
    ;   argv[0] = shell_path  ("/bin/sh")
    ;   argv[1] = sh_flag     ("-c")
    ;   argv[2] = command_buf (the actual command string)
    ;   argv[3] = NULL
    ;
    ; Push in reverse order (stack grows downward):
    ; ------------------------------------------------------------------
    xor     eax, eax
    push    rax                     ; argv[3] = NULL
    lea     rax, [rel command_buf]
    push    rax                     ; argv[2] = &command_buf
    lea     rax, [rel sh_flag]
    push    rax                     ; argv[1] = &sh_flag
    lea     rax, [rel shell_path]
    push    rax                     ; argv[0] = &shell_path

    ; execve(shell_path, argv, envp)
    lea     rdi, [rel shell_path]   ; pathname
    mov     rsi, rsp                ; argv array on stack
    mov     rdx, [rel saved_envp]   ; envp (preserved from main)
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
    ; Read loop — accumulate child output into output_buf
    ; ------------------------------------------------------------------
    xor     r14d, r14d              ; r14 = 0 (total bytes read so far)

.read_loop:
    ; Compute remaining space: OUTPUT_BUF_SZ - 1 - r14
    mov     rdx, OUTPUT_BUF_SZ - 1
    sub     rdx, r14
    jle     .read_done              ; no room left → stop reading

    ; read(pipe_fds[0], output_buf + r14, remaining)
    lea     rax, [rel pipe_fds]
    mov     edi, [rax]              ; fd = pipe_fds[0]
    lea     rsi, [rel output_buf]
    add     rsi, r14                ; buffer offset
    mov     rax, SYS_READ
    syscall

    ; Check return value
    test    rax, rax
    jle     .read_done              ; 0 = EOF, negative = error → done

    add     r14, rax                ; accumulate bytes
    jmp     .read_loop

.read_done:
    ; Store total bytes read
    mov     [rel output_len], r14

    ; Null-terminate the output
    lea     rax, [rel output_buf]
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
    ; Extract WEXITSTATUS: bits 15..8 of the status word
    ;   exit_code = (wait_status >> 8) & 0xFF
    ; ------------------------------------------------------------------
    mov     eax, [rel wait_status]
    shr     eax, 8
    and     eax, 0xFF

    ; rax now holds the child's exit code
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

.fork_error:
    ; Fork failed — close pipe fds to avoid leak, then return -1
    lea     rax, [rel pipe_fds]
    mov     edi, [rax]              ; pipe_fds[0]
    mov     eax, SYS_CLOSE
    syscall
    lea     rax, [rel pipe_fds]
    mov     edi, [rax + 4]          ; pipe_fds[1]
    mov     eax, SYS_CLOSE
    syscall
    mov     rax, -1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
