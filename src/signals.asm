; ============================================================================
; signals.asm — ASM-AGENT Signal Handling
; ============================================================================
; Sets up signal handlers for graceful shutdown and pipe/child safety:
;   - SIGINT  (2)  → sigint_handler: sets shutdown_flag = 1
;   - SIGPIPE (13) → SIG_IGN: prevents crash on broken pipe to curl
;   - SIGCHLD (17) → SIG_IGN: auto-reap child processes
;
; x86_64 Linux requires SA_RESTORER flag and a valid sa_restorer pointer
; in the sigaction struct for rt_sigaction to work correctly.
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

; ---------------------------------------------------------------------------
; External data (defined in main.asm BSS)
; ---------------------------------------------------------------------------
extern shutdown_flag

; ---------------------------------------------------------------------------
; Exported symbols
; ---------------------------------------------------------------------------
global setup_signals

; ============================================================================
section .text
; ============================================================================

; ============================================================================
; setup_signals — Register all signal handlers
; Args:    none
; Returns: rax = 0 on success, negative on error
; Clobbers: rax, rdi, rsi, rdx, r10
; ============================================================================
setup_signals:
    push    rbp
    mov     rbp, rsp
    push    rbx                         ; save callee-saved

    ; ------------------------------------------------------------------
    ; 1) Install SIGINT handler (graceful shutdown)
    ; ------------------------------------------------------------------
    ; Build sigaction struct on stack (32 bytes):
    ;   [rbp-8]   sa_handler   (8 bytes) = sigint_handler
    ;   [rbp-16]  sa_flags     (8 bytes) = SA_RESTORER
    ;   [rbp-24]  sa_restorer  (8 bytes) = restore_rt
    ;   [rbp-32]  sa_mask      (8 bytes) = 0
    sub     rsp, SIGACTION_SIZE         ; allocate 32 bytes for struct

    lea     rax, [rel sigint_handler]
    mov     [rsp],      rax             ; sa_handler = sigint_handler
    mov     qword [rsp+8],  SA_RESTORER ; sa_flags   = SA_RESTORER (0x04000000)
    lea     rax, [rel restore_rt]
    mov     [rsp+16],   rax             ; sa_restorer = restore_rt stub
    mov     qword [rsp+24], 0           ; sa_mask    = 0 (empty mask)

    ; sys_rt_sigaction(signum, act, oldact, sigsetsize)
    ;   rax = SYS_RT_SIGACTION (13)
    ;   rdi = SIGINT (2)
    ;   rsi = &new_act (rsp)
    ;   rdx = NULL (no old action)
    ;   r10 = 8 (sizeof sigset_t for kernel)
    mov     rax, SYS_RT_SIGACTION
    mov     rdi, SIGINT
    mov     rsi, rsp                    ; pointer to our sigaction struct
    xor     rdx, rdx                    ; oldact = NULL
    mov     r10, 8                      ; sigsetsize = 8
    syscall

    ; Check for error
    test    rax, rax
    js      .signal_error

    ; ------------------------------------------------------------------
    ; 2) Ignore SIGPIPE — prevent crash when curl/pipe breaks
    ; ------------------------------------------------------------------
    ; Reuse the same stack space, just change sa_handler
    mov     qword [rsp], SIG_IGN        ; sa_handler = SIG_IGN (1)
    mov     qword [rsp+8], SA_RESTORER  ; sa_flags   = SA_RESTORER
    lea     rax, [rel restore_rt]
    mov     [rsp+16], rax               ; sa_restorer = restore_rt
    mov     qword [rsp+24], 0           ; sa_mask    = 0

    mov     rax, SYS_RT_SIGACTION
    mov     rdi, SIGPIPE
    mov     rsi, rsp
    xor     rdx, rdx
    mov     r10, 8
    syscall

    test    rax, rax
    js      .signal_error

    ; ------------------------------------------------------------------
    ; Success
    ; ------------------------------------------------------------------
    xor     rax, rax                    ; return 0

.signal_done:
    add     rsp, SIGACTION_SIZE         ; deallocate struct
    pop     rbx
    pop     rbp
    ret

.signal_error:
    ; rax already contains negative errno
    jmp     .signal_done


; ============================================================================
; sigint_handler — Signal handler for SIGINT (Ctrl+C)
; ============================================================================
; Called asynchronously by the kernel. Must be signal-safe:
;   - No syscalls, no heap allocation, no stdio
;   - Just set a flag and return
;
; The kernel delivers the signal and expects the handler to return
; via the sa_restorer trampoline (restore_rt).
; ============================================================================
sigint_handler:
    mov     byte [rel shutdown_flag], 1 ; set atomic shutdown flag
    ret                                 ; return to restore_rt trampoline


; ============================================================================
; restore_rt — Signal return trampoline (required by x86_64 Linux)
; ============================================================================
; After a signal handler returns, execution resumes here.
; We must call sys_rt_sigreturn (syscall 15) to restore the interrupted
; context. The kernel set up the stack frame; we just invoke the syscall.
; ============================================================================
restore_rt:
    mov     rax, 15                     ; SYS_RT_SIGRETURN = 15
    syscall
