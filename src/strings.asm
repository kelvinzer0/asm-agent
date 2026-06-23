; ============================================================================
; strings.asm — ASM-AGENT String Utility Functions
; Pure string operations: no external dependencies
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

section .text

; ============================================================================
; str_len — Get length of null-terminated string
; Input:  rdi = pointer to null-terminated string
; Output: rax = length (not including null terminator)
; Clobbers: rcx, rdi (restored via initial save)
; ============================================================================
global str_len
str_len:
    push    rcx
    push    rdi
    xor     rcx, rcx            ; rcx = 0
    not     rcx                 ; rcx = 0xFFFFFFFFFFFFFFFF (max count)
    xor     al, al              ; al = 0 (search for null byte)
    cld                         ; clear direction flag (forward scan)
    repnz   scasb               ; scan until [rdi] == al, decrement rcx each step
    not     rcx                 ; invert: rcx = original_count - remaining = length + 1
    dec     rcx                 ; exclude null terminator
    mov     rax, rcx            ; return length in rax
    pop     rdi
    pop     rcx
    ret

; ============================================================================
; str_copy — Copy null-terminated string (including null terminator)
; Input:  rdi = destination buffer
;         rsi = source string (null-terminated)
; Output: rax = bytes copied (not including null terminator)
; ============================================================================
global str_copy
str_copy:
    push    rbx
    mov     rbx, rdi            ; save original dst pointer
.loop:
    lodsb                       ; al = [rsi], rsi++
    stosb                       ; [rdi] = al, rdi++
    test    al, al              ; check for null
    jnz     .loop
    ; rdi now points one past the null terminator
    lea     rax, [rdi - 1]      ; pointer to null terminator
    sub     rax, rbx            ; bytes copied = (ptr_to_null - original_dst)
    pop     rbx
    ret

; ============================================================================
; str_ncopy — Copy up to maxlen-1 bytes, always null-terminate
; Input:  rdi = destination buffer
;         rsi = source string
;         rdx = max buffer size (including null terminator)
; Output: rax = bytes copied (not including null terminator)
; ============================================================================
global str_ncopy
str_ncopy:
    push    rbx
    push    r12
    mov     rbx, rdi            ; save original dst
    mov     r12, rdx            ; save maxlen
    test    r12, r12            ; if maxlen == 0, nothing to do
    jz      .empty
    dec     r12                 ; max copyable bytes = maxlen - 1
.loop:
    test    r12, r12            ; remaining capacity?
    jz      .terminate
    lodsb                       ; al = [rsi++]
    test    al, al              ; end of source?
    jz      .terminate
    stosb                       ; [rdi++] = al
    dec     r12
    jmp     .loop
.terminate:
    mov     byte [rdi], 0       ; null-terminate
    mov     rax, rdi
    sub     rax, rbx            ; bytes copied (not including null)
    pop     r12
    pop     rbx
    ret
.empty:
    xor     rax, rax
    pop     r12
    pop     rbx
    ret

; ============================================================================
; str_escape_json — Escape JSON special characters
; Input:  rdi = destination buffer
;         rsi = source string (null-terminated)
;         rdx = max destination size (including null terminator)
; Output: rax = number of bytes written to dst (not including null)
;
; Escapes: " -> \"   \ -> \\   \n(10) -> \n   \t(9) -> \t   \r(13) -> \r
; Leaves 2-byte margin to ensure room for escape sequences
; ============================================================================
global str_escape_json
str_escape_json:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi            ; save original dst
    mov     r12, rdx            ; max dst size
    sub     r12, 2              ; 2-byte safety margin
    xor     r13, r13            ; bytes written counter

    test    r12, r12
    jle     .done               ; if max <= 2, nothing to write

.loop:
    movzx   eax, byte [rsi]     ; load source byte
    test    al, al              ; null terminator?
    jz      .done
    inc     rsi                 ; advance source

    ; --- Check for special characters ---
    cmp     al, '"'
    je      .esc_quote
    cmp     al, '\'
    je      .esc_backslash
    cmp     al, 10              ; newline
    je      .esc_newline
    cmp     al, 9               ; tab
    je      .esc_tab
    cmp     al, 13              ; carriage return
    je      .esc_cr

    ; --- Normal character: needs 1 byte ---
    cmp     r13, r12
    jge     .done
    mov     [rdi], al
    inc     rdi
    inc     r13
    jmp     .loop

.esc_quote:
    lea     rax, [r13 + 2]
    cmp     rax, r12
    jg      .done
    mov     byte [rdi], '\'
    mov     byte [rdi + 1], '"'
    add     rdi, 2
    add     r13, 2
    jmp     .loop

.esc_backslash:
    lea     rax, [r13 + 2]
    cmp     rax, r12
    jg      .done
    mov     byte [rdi], '\'
    mov     byte [rdi + 1], '\'
    add     rdi, 2
    add     r13, 2
    jmp     .loop

.esc_newline:
    lea     rax, [r13 + 2]
    cmp     rax, r12
    jg      .done
    mov     byte [rdi], '\'
    mov     byte [rdi + 1], 'n'
    add     rdi, 2
    add     r13, 2
    jmp     .loop

.esc_tab:
    lea     rax, [r13 + 2]
    cmp     rax, r12
    jg      .done
    mov     byte [rdi], '\'
    mov     byte [rdi + 1], 't'
    add     rdi, 2
    add     r13, 2
    jmp     .loop

.esc_cr:
    lea     rax, [r13 + 2]
    cmp     rax, r12
    jg      .done
    mov     byte [rdi], '\'
    mov     byte [rdi + 1], 'r'
    add     rdi, 2
    add     r13, 2
    jmp     .loop

.done:
    mov     byte [rdi], 0       ; null-terminate
    mov     rax, r13            ; return escaped length
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; str_find — Find substring in string (simple O(n*m) search)
; Input:  rdi = haystack (null-terminated)
;         rsi = needle (null-terminated)
; Output: rax = pointer to first match, or 0 if not found
; ============================================================================
global str_find
str_find:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rdi            ; r12 = haystack
    mov     r13, rsi            ; r13 = needle

    ; Check if needle is empty — return haystack
    cmp     byte [r13], 0
    je      .found_at_start

    ; Get needle length
    mov     rdi, r13
    call    str_len
    mov     r14, rax            ; r14 = needle length

.outer:
    cmp     byte [r12], 0       ; end of haystack?
    je      .not_found

    ; Compare needle at current haystack position
    mov     rbx, 0              ; rbx = comparison index
.inner:
    cmp     rbx, r14            ; compared all needle chars?
    je      .found              ; full match!

    movzx   eax, byte [r12 + rbx]
    test    al, al              ; haystack ended mid-compare?
    jz      .not_found

    cmp     al, byte [r13 + rbx]
    jne     .next               ; mismatch, try next position

    inc     rbx
    jmp     .inner

.next:
    inc     r12                 ; advance haystack by one
    jmp     .outer

.found:
    mov     rax, r12            ; return pointer to match
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.found_at_start:
    mov     rax, r12            ; needle is empty, return haystack
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.not_found:
    xor     rax, rax            ; return 0
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; str_starts_with — Check if string starts with prefix
; Input:  rdi = string (null-terminated)
;         rsi = prefix (null-terminated)
; Output: rax = 1 if string starts with prefix, 0 otherwise
; ============================================================================
global str_starts_with
str_starts_with:
.loop:
    movzx   eax, byte [rsi]     ; load prefix char
    test    al, al              ; prefix ended?
    jz      .match              ; yes — full prefix matched

    cmp     al, byte [rdi]      ; compare with string char
    jne     .no_match

    inc     rdi
    inc     rsi
    jmp     .loop

.match:
    mov     rax, 1
    ret

.no_match:
    xor     rax, rax
    ret

; ============================================================================
; str_concat — Append src to end of dst
; Input:  rdi = destination buffer (null-terminated string)
;         rsi = source string to append (null-terminated)
; Output: rax = pointer to new null terminator position
; ============================================================================
global str_concat
str_concat:
    push    rbx
    mov     rbx, rsi            ; save source pointer

    ; Find end of destination (scan for null)
    call    str_len             ; rax = length of dst (rdi preserved by str_len)
    add     rdi, rax            ; rdi now points to dst's null terminator

    ; Copy source to end of destination
    mov     rsi, rbx            ; restore source pointer
.copy:
    lodsb                       ; al = [rsi++]
    stosb                       ; [rdi++] = al
    test    al, al
    jnz     .copy

    ; rdi is now one past the null terminator
    lea     rax, [rdi - 1]      ; return pointer to the null terminator
    pop     rbx
    ret

; ============================================================================
; uint_to_str — Convert unsigned 64-bit integer to decimal ASCII string
; Input:  rdi = output buffer (must be large enough, 21 bytes max for uint64)
;         rsi = unsigned 64-bit number
; Output: rax = length of resulting string (not including null)
; ============================================================================
global uint_to_str
uint_to_str:
    push    rbx
    push    r12
    push    rbp

    mov     rbx, rdi            ; save buffer pointer
    mov     rax, rsi            ; rax = number to convert
    mov     r12, rsp            ; save original stack pointer
    xor     ecx, ecx            ; digit counter = 0

    ; Special case: zero
    test    rax, rax
    jnz     .divide_loop
    mov     byte [rdi], '0'
    mov     byte [rdi + 1], 0
    mov     rax, 1
    pop     rbp
    pop     r12
    pop     rbx
    ret

.divide_loop:
    ; Divide rax by 10, push remainder digit onto stack
    xor     edx, edx            ; clear upper dividend
    mov     rbp, 10
    div     rbp                 ; rax = quotient, rdx = remainder
    add     dl, '0'             ; convert remainder to ASCII
    push    rdx                 ; push digit (as qword, only low byte matters)
    inc     ecx                 ; digit count++
    test    rax, rax            ; more digits?
    jnz     .divide_loop

    ; Pop digits in reverse order (MSD first) into buffer
    mov     edx, ecx            ; save digit count for return
.pop_loop:
    pop     rax                 ; get digit
    mov     [rdi], al           ; store in buffer
    inc     rdi
    dec     ecx
    jnz     .pop_loop

    mov     byte [rdi], 0       ; null-terminate
    mov     eax, edx            ; return digit count
    pop     rbp
    pop     r12
    pop     rbx
    ret

; ============================================================================
; int_to_str_padded — Convert integer to zero-padded decimal string
; Input:  rdi = output buffer
;         rsi = unsigned number
;         rdx = desired width (e.g., 4 for year, 2 for month/day/hour/min/sec)
; Output: rax = length written (= width)
; ============================================================================
global int_to_str_padded
int_to_str_padded:
    push    rbx
    push    r12
    push    r13
    push    rbp

    mov     rbx, rdi            ; save buffer pointer
    mov     rax, rsi            ; number to convert
    mov     r12, rdx            ; desired width
    mov     r13, rsp            ; save original stack pointer
    xor     ecx, ecx            ; digit counter

    ; Extract digits by repeated division
    test    rax, rax
    jnz     .divide
    ; Number is zero: push one '0' digit
    push    '0'
    inc     ecx
    jmp     .pad

.divide:
    xor     edx, edx
    mov     rbp, 10
    div     rbp                 ; rax = quotient, rdx = remainder
    add     dl, '0'
    push    rdx
    inc     ecx
    test    rax, rax
    jnz     .divide

.pad:
    ; If digit count < width, prepend '0' chars
    mov     eax, ecx            ; actual digit count
    cmp     rax, r12
    jge     .write              ; enough digits already

    ; Calculate padding needed
    mov     rdx, r12
    sub     rdx, rax            ; padding count = width - digit_count
.pad_loop:
    mov     byte [rdi], '0'
    inc     rdi
    dec     rdx
    jnz     .pad_loop

.write:
    ; Pop digits (MSD first) into buffer after padding
.write_loop:
    pop     rax
    mov     [rdi], al
    inc     rdi
    dec     ecx
    jnz     .write_loop

    mov     byte [rdi], 0       ; null-terminate
    mov     rax, r12            ; return width as length

    ; If actual digits exceeded width, recalculate actual length
    mov     rcx, rdi
    sub     rcx, rbx            ; actual bytes written
    cmp     rcx, r12
    cmovg   rax, rcx            ; if more digits than width, return actual count

    mov     rdi, rbx            ; restore original rdi
    pop     rbp
    pop     r13
    pop     r12
    pop     rbx
    ret
