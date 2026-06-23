; ============================================================================
; checkpoint.asm — File-based State Persistence (Simplified)
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"
%include "musical.inc"
%include "orchestration.inc"

; --- External data ---
extern current_mode
extern iteration_count
extern musical_state
extern task_buf
extern task_len
extern checkpoint_data
extern temp_buf

; --- External functions ---
extern str_len
extern str_copy
extern str_find
extern uint_to_str
extern worklog_append_raw

; --- Export ---
global checkpoint_save
global checkpoint_restore
global checkpoint_exists
global checkpoint_delete

; ============================================================================
section .rodata
; ============================================================================

checkpoint_path: db 'checkpoint.json', 0

cp_json_open:     db '{', 10, 0
cp_json_magic:    db '  "magic": "MAGC",', 10, 0
cp_json_iter:     db '  "iteration": ', 0
cp_json_sep:      db ',', 10, 0
cp_json_task:     db '  "task": "', 0
cp_json_task_end: db '"', 10, 0
cp_json_close:    db '}', 10, 0

; ============================================================================
section .text
; ============================================================================

; ============================================================================
; checkpoint_save — Save current state to checkpoint.json
; ============================================================================
checkpoint_save:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13

    mov     rax, SYS_OPEN
    lea     rdi, [rel checkpoint_path]
    mov     esi, (O_WRONLY | O_CREAT | O_TRUNC)
    mov     edx, FILE_MODE
    syscall

    test    rax, rax
    js      .save_done
    mov     rbx, rax

    lea     r12, [rel temp_buf]
    mov     r13, r12

    lea     rsi, [rel cp_json_open]
    call    cp_copy_to_buf
    lea     rsi, [rel cp_json_magic]
    call    cp_copy_to_buf

    ; Write iteration
    lea     rsi, [rel cp_json_iter]
    call    cp_copy_to_buf
    mov     eax, [iteration_count]
    mov     esi, eax
    call    cp_write_int_to_buf
    lea     rsi, [rel cp_json_sep]
    call    cp_copy_to_buf

    ; Write task (truncated to 32 chars)
    lea     rsi, [rel cp_json_task]
    call    cp_copy_to_buf
    lea     rsi, [task_buf]
    mov     ecx, 32
.cp_task_loop:
    test    ecx, ecx
    jz      .cp_task_done
    movzx   eax, byte [rsi]
    test    al, al
    jz      .cp_task_done
    cmp     al, '"'
    je      .cp_task_quote
    mov     [r12], al
    inc     r12
    inc     rsi
    dec     ecx
    jmp     .cp_task_loop
.cp_task_quote:
    mov     byte [r12], '\'
    inc     r12
    mov     byte [r12], '"'
    inc     r12
    inc     rsi
    dec     ecx
    jmp     .cp_task_loop
.cp_task_done:
    lea     rsi, [rel cp_json_task_end]
    call    cp_copy_to_buf

    lea     rsi, [rel cp_json_close]
    call    cp_copy_to_buf

    mov     byte [r12], 0

    mov     rdx, r12
    sub     rdx, r13
    mov     rax, SYS_WRITE
    mov     rdi, rbx
    lea     rsi, [rel temp_buf]
    syscall

    mov     rax, SYS_CLOSE
    mov     rdi, rbx
    syscall

.save_done:
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; ============================================================================
; checkpoint_restore — Restore state from checkpoint.json
; ============================================================================
checkpoint_restore:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12

    mov     rax, SYS_OPEN
    lea     rdi, [rel checkpoint_path]
    mov     esi, O_RDONLY
    xor     edx, edx
    syscall

    test    rax, rax
    js      .restore_fail
    mov     rbx, rax

    mov     rax, SYS_READ
    mov     rdi, rbx
    lea     rsi, [rel temp_buf]
    mov     rdx, TEMP_BUF_SZ - 1
    syscall

    test    rax, rax
    js      .restore_close_fail
    mov     r12, rax

    lea     rax, [rel temp_buf]
    mov     byte [rax + r12], 0

    ; Find "iteration": N
    lea     rdi, [rel temp_buf]
    lea     rsi, [rel cp_json_iter]
    call    cp_find_and_extract_int
    cmp     rax, -1
    je      .restore_close_fail
    mov     [iteration_count], eax

    ; Find "task": "..."
    lea     rdi, [rel temp_buf]
    lea     rsi, [rel cp_json_task]
    lea     rdx, [rel task_buf]
    mov     rcx, TASK_BUF_SZ
    call    cp_find_and_extract_string
    cmp     rax, -1
    je      .restore_close_fail
    mov     [task_len], rax

    mov     rax, SYS_CLOSE
    mov     rdi, rbx
    syscall

    call    checkpoint_delete

    mov     rax, 1
    jmp     .restore_done

.restore_close_fail:
    mov     rax, SYS_CLOSE
    mov     rdi, rbx
    syscall

.restore_fail:
    xor     eax, eax

.restore_done:
    pop     r12
    pop     rbx
    pop     rbp
    ret

; ============================================================================
; checkpoint_exists
; ============================================================================
checkpoint_exists:
    mov     rax, SYS_ACCESS
    lea     rdi, [rel checkpoint_path]
    xor     esi, esi
    syscall
    test    rax, rax
    setz    al
    movzx   eax, al
    ret

; ============================================================================
; checkpoint_delete
; ============================================================================
checkpoint_delete:
    mov     rax, SYS_UNLINK
    lea     rdi, [rel checkpoint_path]
    syscall
    ret

; --- Helpers ---

cp_copy_to_buf:
.cp_copy_loop:
    lodsb
    test    al, al
    jz      .cp_copy_done
    mov     [r12], al
    inc     r12
    jmp     .cp_copy_loop
.cp_copy_done:
    ret

cp_write_int_to_buf:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 16
    mov     rdi, rsp
    call    uint_to_str
    mov     rsi, rsp
.cp_int_loop:
    lodsb
    test    al, al
    jz      .cp_int_done
    mov     [r12], al
    inc     r12
    jmp     .cp_int_loop
.cp_int_done:
    add     rsp, 16
    pop     rbp
    ret

cp_find_and_extract_int:
    push    rbx
    push    r12
    push    r13

    mov     rbx, rdi
    mov     r12, rsi

    mov     rdi, rbx
    mov     rsi, r12
    call    str_find
    test    rax, rax
    jz      .cpe_failed

    mov     r13, rax
    mov     rdi, r12
    call    str_len
    add     r13, rax

.cpe_digit:
    movzx   eax, byte [r13]
    test    al, al
    jz      .cpe_failed
    cmp     al, ':'
    je      .cpe_digit_ws
    cmp     al, ' '
    je      .cpe_skip
    cmp     al, 9
    je      .cpe_skip
    cmp     al, 10
    je      .cpe_digit_ws
    cmp     al, 13
    je      .cpe_digit_ws
    cmp     al, '0'
    jl      .cpe_failed
    cmp     al, '9'
    jg      .cpe_failed
    jmp     .cpe_parse
.cpe_digit_ws:
    inc     r13
    jmp     .cpe_digit
.cpe_skip:
    inc     r13
    jmp     .cpe_digit

.cpe_parse:
    xor     eax, eax
.cpe_parse_loop:
    movzx   ecx, byte [r13]
    cmp     cl, '0'
    jl      .cpe_parse_done
    cmp     cl, '9'
    jg      .cpe_parse_done
    imul    eax, 10
    sub     cl, '0'
    add     eax, ecx
    inc     r13
    jmp     .cpe_parse_loop

.cpe_parse_done:
    pop     r13
    pop     r12
    pop     rbx
    ret

.cpe_failed:
    mov     rax, -1
    pop     r13
    pop     r12
    pop     rbx
    ret

cp_find_and_extract_string:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14, rcx

    mov     rdi, rbx
    mov     rsi, r12
    call    str_find
    test    rax, rax
    jz      .cps_failed

    push    rax
    mov     rdi, r12
    call    str_len
    pop     rdi
    add     rdi, rax
    mov     r12, rdi

.cps_seek_quote:
    movzx   eax, byte [r12]
    test    al, al
    jz      .cps_failed
    cmp     al, '"'
    je      .cps_start
    inc     r12
    jmp     .cps_seek_quote

.cps_start:
    inc     r12
    xor     ecx, ecx

.cps_loop:
    cmp     rcx, r14
    jae     .cps_done
    movzx   eax, byte [r12]
    test    al, al
    jz      .cps_done
    inc     r12
    cmp     al, '"'
    je      .cps_done
    cmp     al, '\'
    jne     .cps_copy
    movzx   eax, byte [r12]
    test    al, al
    jz      .cps_done
    inc     r12
    cmp     al, '"'
    je      .cps_copy
    cmp     al, '\'
    je      .cps_copy
.cps_copy:
    mov     [r13 + rcx], al
    inc     rcx
    jmp     .cps_loop

.cps_done:
    mov     byte [r13 + rcx], 0
    mov     rax, rcx
    jmp     .cps_exit

.cps_failed:
    mov     rax, -1

.cps_exit:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret