; ============================================================================
; tty.asm — TTY Session Persistence for Multi-TTY Scenarios
; ============================================================================
;
; Provides a human-readable TTY.md file that captures the current session
; state so users switching between terminals can quickly understand what
; the agent is doing and continue without confusion.
;
; The file is written in Markdown format with:
;   - Session header (PID, task description)
;   - Timestamped action entries (THINK / EXEC / DONE)
;   - Final status section on completion
;
; Example TTY.md output:
;
;   # asm-agent [PID: 12345]
;
;   ## Task
;   Build a modular calculator in Python
;
;   ---
;   [1] 2024-01-15T10:00:01 THINK | Need to plan calculator structure
;   [2] 2024-01-15T10:00:05 EXEC  | `ls -la` exit:0
;   [3] 2024-01-15T10:00:08 EXEC  | `cat src/calc.py` exit:0
;   [4] 2024-01-15T10:00:12 THINK | All tests pass, task complete
;
;   ---
;
;   ## Status: DONE
;   Calculator built and tested successfully.
;
; Functions:
;   tty_init()                          — Create TTY.md with session header
;   tty_update(type, content, exit_code) — Append action entry
;   tty_close(type, content)            — Write final DONE status
;
; Calling convention:
;   tty_init:    no arguments
;   tty_update:  edi = type (0=EXEC, 1=THINK)
;                rsi = content (null-terminated string)
;                edx = exit code (only used for EXEC type)
;   tty_close:   edi = type (0=DONE)
;                rsi = content (summary, null-terminated)
;
; ============================================================================

%include "constants.inc"
%include "macros.inc"

; ---------------------------------------------------------------------------
; External data (defined in main.asm BSS)
; ---------------------------------------------------------------------------
extern task_buf
extern iteration_count
extern timestamp_buf
extern temp_buf

; ---------------------------------------------------------------------------
; External functions (from strings.asm / timestamp.asm)
; ---------------------------------------------------------------------------
extern str_len
extern uint_to_str
extern get_timestamp

; ---------------------------------------------------------------------------
; Exported symbols
; ---------------------------------------------------------------------------
global tty_init
global tty_update
global tty_close


; ============================================================================
section .rodata
; ============================================================================

; --- File path ---
tty_path        db 'TTY.md', 0

; --- Header template parts ---
tty_hdr_prefix  db '# asm-agent [PID: ', 0
tty_hdr_pid_end db ']', 0
tty_task_title  db 10, '## Task', 10, 0
tty_separator   db 10, '---', 10, 0

; --- Entry type labels ---
tty_type_think  db 'THINK | ', 0
tty_type_exec   db 'EXEC  | `', 0
tty_exec_tail   db '` exit:', 0

; --- Close template ---
tty_done_header db 10, '---', 10, 10, '## Status: DONE', 10, 0


; ============================================================================
section .text
; ============================================================================

; ============================================================================
; tty_init — Create TTY.md with session header
; ============================================================================
;
; Opens TTY.md with O_TRUNC (fresh start), writes:
;
;   # asm-agent [PID: XXXXX]
;
;   ## Task
;   <task content>
;
;   ---
;
; Args:    none (gets PID via SYS_GETPID)
; Returns: none
; Clobbers: all caller-saved registers
; ============================================================================
tty_init:
    push    rbp
    mov     rbp, rsp
    push    rbx                         ; rbx = write cursor
    push    r12                         ; r12 = fd
    push    r13                         ; r13 = temp_buf base
    push    r15                         ; r15 = write limit

    ; ------------------------------------------------------------------
    ; Build the complete header in temp_buf
    ; rbx = write cursor, r15 = write limit, r13 = temp_buf base
    ; ------------------------------------------------------------------
    lea     r13, [rel temp_buf]          ; r13 = base (for length calc)
    lea     rbx, [rel temp_buf]          ; rbx = write cursor
    lea     r15, [rel temp_buf + TEMP_BUF_SZ - 64]  ; r15 = limit

    ; (a) "# asm-agent [PID: "
    lea     rsi, [rel tty_hdr_prefix]
    call    _tty_copy_cursor

    ; (b) PID number via getpid syscall
    mov     rax, SYS_GETPID
    syscall                             ; rax = pid
    mov     rdi, rbx                    ; cursor = destination
    mov     rsi, rax                    ; pid = number
    call    uint_to_str
    add     rbx, rax                    ; advance cursor by length

    ; (c) "]\n"
    lea     rsi, [rel tty_hdr_pid_end]
    call    _tty_copy_cursor
    mov     byte [rbx], 10              ; newline
    inc     rbx

    ; (d) "## Task\n"
    lea     rsi, [rel tty_task_title]
    call    _tty_copy_cursor

    ; (e) Task content
    lea     rsi, [rel task_buf]
    call    _tty_copy_cursor

    ; (f) "\n---\n"
    lea     rsi, [rel tty_separator]
    call    _tty_copy_cursor

    ; Null-terminate (not counted in written length)
    mov     byte [rbx], 0

    ; ------------------------------------------------------------------
    ; Calculate total length = cursor - base
    ; ------------------------------------------------------------------
    mov     rax, rbx
    sub     rax, r13                    ; rax = byte count
    push    rax                         ; [rsp] = length (saved across syscalls)

    ; ------------------------------------------------------------------
    ; Open file: O_WRONLY | O_CREAT | O_TRUNC (fresh start)
    ; ------------------------------------------------------------------
    mov     rax, SYS_OPEN
    lea     rdi, [rel tty_path]
    mov     rsi, O_WRONLY | O_CREAT | O_TRUNC
    mov     rdx, FILE_MODE               ; 0644
    syscall
    test    rax, rax
    js      .init_pop                   ; open failed -> skip silently

    mov     r12, rax                    ; r12 = fd

    ; ------------------------------------------------------------------
    ; Write header to file
    ; ------------------------------------------------------------------
    mov     rax, SYS_WRITE
    mov     rdi, r12                    ; fd
    lea     rsi, [rel temp_buf]         ; buffer
    mov     rdx, [rsp]                  ; length (from stack)
    syscall

    ; ------------------------------------------------------------------
    ; Close file
    ; ------------------------------------------------------------------
    mov     rax, SYS_CLOSE
    mov     rdi, r12                    ; fd
    syscall

.init_pop:
    add     rsp, 8                      ; pop saved length
    pop     r15
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================================
; tty_update — Append an action entry to TTY.md
; ============================================================================
;
; Appends a single-line entry:
;
;   [ITER] TIMESTAMP TYPE | content
;
; For EXEC type:  [3] 2024-01-15T10:00:08 EXEC  | `ls -la` exit:0
; For THINK type: [3] 2024-01-15T10:00:08 THINK | Need to check files
;
; Args:    edi = type (0=EXEC, 1=THINK)
;          rsi = content pointer (null-terminated)
;          edx = exit code (used only for EXEC type)
; Returns: none
; Clobbers: all caller-saved registers
; ============================================================================
tty_update:
    push    rbp
    mov     rbp, rsp
    push    rbx                         ; rbx = write cursor
    push    r12                         ; r12 = type
    push    r13                         ; r13 = content pointer
    push    r14                         ; r14 = exit code
    push    r15                         ; r15 = write limit

    ; ------------------------------------------------------------------
    ; Save arguments in callee-saved registers
    ; ------------------------------------------------------------------
    mov     r12d, edi                   ; r12 = type (0=EXEC, 1=THINK)
    mov     r13, rsi                    ; r13 = content pointer
    mov     r14d, edx                   ; r14 = exit code

    ; ------------------------------------------------------------------
    ; Get current timestamp (fills timestamp_buf)
    ; ------------------------------------------------------------------
    lea     rdi, [rel timestamp_buf]
    call    get_timestamp

    ; ------------------------------------------------------------------
    ; Build entry line in temp_buf
    ; ------------------------------------------------------------------
    lea     rbx, [rel temp_buf]          ; rbx = write cursor
    lea     r15, [rel temp_buf + TEMP_BUF_SZ - 2]  ; r15 = limit

    ; (a) "["
    mov     byte [rbx], '['
    inc     rbx

    ; (b) Iteration number
    mov     rdi, rbx                    ; cursor = destination
    mov     esi, [rel iteration_count]  ; zero-extends to rsi
    call    uint_to_str
    add     rbx, rax                    ; advance cursor by length

    ; (c) "] "
    mov     byte [rbx], ']'
    inc     rbx
    mov     byte [rbx], ' '
    inc     rbx

    ; (d) Timestamp
    lea     rsi, [rel timestamp_buf]
    call    _tty_copy_cursor

    ; (e) " "
    mov     byte [rbx], ' '
    inc     rbx

    ; (f) Type-specific content
    cmp     r12b, 1
    je      .upd_think

    ; --- EXEC type: "EXEC  | `command` exit:N" ---
    lea     rsi, [rel tty_type_exec]
    call    _tty_copy_cursor

    ; Command content
    mov     rsi, r13
    call    _tty_copy_cursor

    ; "` exit:"
    lea     rsi, [rel tty_exec_tail]
    call    _tty_copy_cursor

    ; Exit code number
    mov     rdi, rbx
    mov     esi, r14d                   ; zero-extends to rsi
    call    uint_to_str
    add     rbx, rax
    jmp     .upd_entry_done

.upd_think:
    ; --- THINK type: "THINK | content" ---
    lea     rsi, [rel tty_type_think]
    call    _tty_copy_cursor

    ; Thought content
    mov     rsi, r13
    call    _tty_copy_cursor

.upd_entry_done:
    ; Trailing newline
    mov     byte [rbx], 10
    inc     rbx

    ; Null-terminate
    mov     byte [rbx], 0

    ; ------------------------------------------------------------------
    ; Calculate length and append to file
    ; ------------------------------------------------------------------
    lea     rax, [rbx]
    lea     rcx, [rel temp_buf]
    sub     rax, rcx                    ; rax = byte count
    push    rax                         ; save length

    ; Open file: O_WRONLY | O_CREAT | O_APPEND
    mov     rax, SYS_OPEN
    lea     rdi, [rel tty_path]
    mov     rsi, O_WRONLY | O_CREAT | O_APPEND
    mov     rdx, FILE_MODE
    syscall
    test    rax, rax
    js      .upd_pop                    ; open failed -> skip

    mov     r12, rax                    ; r12 = fd

    ; Write entry
    mov     rax, SYS_WRITE
    mov     rdi, r12
    lea     rsi, [rel temp_buf]
    mov     rdx, [rsp]
    syscall

    ; Close
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall

.upd_pop:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================================
; tty_close — Write final status to TTY.md
; ============================================================================
;
; Appends a closing section:
;
;   ---
;
;   ## Status: DONE
;   <summary content>
;
; Args:    edi = type (0=DONE)
;          rsi = content (summary, null-terminated)
; Returns: none
; Clobbers: all caller-saved registers
; ============================================================================
tty_close:
    push    rbp
    mov     rbp, rsp
    push    rbx                         ; rbx = write cursor
    push    r12                         ; r12 = content pointer
    push    r15                         ; r15 = write limit

    mov     r12, rsi                    ; save content pointer

    ; ------------------------------------------------------------------
    ; Build final section in temp_buf
    ; ------------------------------------------------------------------
    lea     rbx, [rel temp_buf]
    lea     r15, [rel temp_buf + TEMP_BUF_SZ - 2]

    ; (a) "\n---\n\n## Status: DONE\n"
    lea     rsi, [rel tty_done_header]
    call    _tty_copy_cursor

    ; (b) Summary content
    mov     rsi, r12
    call    _tty_copy_cursor

    ; Trailing newline
    mov     byte [rbx], 10
    inc     rbx
    mov     byte [rbx], 0

    ; ------------------------------------------------------------------
    ; Calculate length and append
    ; ------------------------------------------------------------------
    lea     rax, [rbx]
    lea     rcx, [rel temp_buf]
    sub     rax, rcx
    push    rax

    ; Open: O_APPEND
    mov     rax, SYS_OPEN
    lea     rdi, [rel tty_path]
    mov     rsi, O_WRONLY | O_CREAT | O_APPEND
    mov     rdx, FILE_MODE
    syscall
    test    rax, rax
    js      .close_pop

    mov     r12, rax

    ; Write
    mov     rax, SYS_WRITE
    mov     rdi, r12
    lea     rsi, [rel temp_buf]
    mov     rdx, [rsp]
    syscall

    ; Close
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall

.close_pop:
    add     rsp, 8
    pop     r15
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================================
; _tty_copy_cursor — Internal helper: copy string to cursor position
; ============================================================================
; Copies bytes from rsi to [rbx], advancing rbx.
; Stops at null terminator or when rbx reaches r15 (limit).
;
; This is a non-local label (file-scope) so all tty_* functions share it.
;
; Args:    rsi = source (null-terminated)
;          rbx = destination cursor (updated on return)
;          r15 = destination limit (not modified)
; Output:  rbx = updated cursor (past last byte written)
; Clobbers: al, rsi
; ============================================================================
_tty_copy_cursor:
.loop:
    cmp     rbx, r15
    jae     .done
    lodsb                               ; al = [rsi++]
    test    al, al                      ; null terminator?
    jz      .done
    mov     [rbx], al                   ; store byte at cursor
    inc     rbx                         ; advance cursor
    jmp     .loop
.done:
    ret