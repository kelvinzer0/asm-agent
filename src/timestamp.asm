; ============================================================================
; timestamp.asm — ASM-AGENT Timestamp Generation
; Converts Unix epoch to ISO 8601 format: YYYY-MM-DDTHH:MM:SS
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

extern int_to_str_padded

section .rodata

; Days per month (non-leap year): Jan=31, Feb=28, Mar=31, ...
days_per_month:
    dd  31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

section .text

; ============================================================================
; get_timestamp — Get current time as ISO 8601 string
; Input:  rdi = output buffer (must be at least 20 bytes)
; Output: rax = length of written string (19)
; Format: YYYY-MM-DDTHH:MM:SS
;
; Uses clock_gettime(CLOCK_REALTIME) to get epoch seconds, then converts
; to broken-down UTC time using iterative year/month calculation.
; ============================================================================
global get_timestamp
get_timestamp:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, rdi            ; r12 = output buffer pointer

    ; --- Get current time via clock_gettime ---
    sub     rsp, 16             ; allocate timespec {tv_sec, tv_nsec}
    SYSCALL2 SYS_CLOCK_GETTIME, CLOCK_REALTIME, rsp
    mov     rbx, [rsp]          ; rbx = epoch seconds (tv_sec)
    add     rsp, 16             ; free timespec

    ; --- Compute time-of-day fields ---
    ; seconds_in_day = total_seconds % 86400
    ; days_since_epoch = total_seconds / 86400
    mov     rax, rbx
    xor     edx, edx
    mov     rcx, 86400
    div     rcx                 ; rax = days_since_epoch, rdx = seconds_in_day
    mov     r13, rax            ; r13 = days_since_epoch
    mov     r14, rdx            ; r14 = seconds_in_day

    ; hours = seconds_in_day / 3600
    mov     rax, r14
    xor     edx, edx
    mov     rcx, 3600
    div     rcx                 ; rax = hours, rdx = remaining seconds
    mov     r15, rax            ; r15 = hours
    mov     rbp, rdx            ; rbp = remaining seconds after hours

    ; minutes = remaining / 60
    mov     rax, rbp
    xor     edx, edx
    mov     rcx, 60
    div     rcx                 ; rax = minutes, rdx = seconds
    ; Store minutes and seconds on stack
    push    rdx                 ; [rsp] = seconds
    push    rax                 ; [rsp] = minutes
    push    r15                 ; [rsp] = hours

    ; --- Compute date from days_since_epoch ---
    ; r13 = remaining days to process
    mov     rbx, 1970           ; rbx = current year

.year_loop:
    ; Determine days in this year (365 or 366)
    mov     rdi, rbx
    call    .is_leap_year       ; rax = 1 if leap, 0 if not
    mov     rcx, 365
    add     rcx, rax            ; rcx = days in this year (365 or 366)

    cmp     r13, rcx            ; do we have enough days left for this year?
    jl      .year_done          ; no — this is our year
    sub     r13, rcx            ; subtract this year's days
    inc     rbx                 ; next year
    jmp     .year_loop

.year_done:
    ; rbx = year, r13 = day-of-year (0-based)
    push    rbx                 ; save year on stack

    ; Determine if current year is leap
    mov     rdi, rbx
    call    .is_leap_year
    mov     r14, rax            ; r14 = is_leap (1 or 0)

    ; --- Compute month from day-of-year ---
    xor     ebx, ebx            ; rbx = month index (0 = January)
    lea     r15, [rel days_per_month]  ; r15 = pointer to days_per_month table

.month_loop:
    cmp     ebx, 11             ; past December? (safety check)
    jg      .month_done

    mov     ecx, [r15 + rbx * 4] ; ecx = days in this month

    ; Adjust February for leap year
    cmp     ebx, 1              ; is this February (index 1)?
    jne     .no_feb_adjust
    add     ecx, r14d           ; add 1 if leap year
.no_feb_adjust:

    cmp     r13, rcx            ; enough remaining days for this month?
    jl      .month_done
    sub     r13, rcx            ; subtract this month's days
    inc     ebx                 ; next month
    jmp     .month_loop

.month_done:
    ; rbx = month (0-based), r13 = day (0-based)
    inc     ebx                 ; month: 1-based
    inc     r13                 ; day: 1-based

    ; Stack layout now:
    ;   [rsp]     = year
    ;   [rsp+8]   = hours
    ;   [rsp+16]  = minutes
    ;   [rsp+24]  = seconds
    ; Registers: rbx = month, r13 = day

    ; Save month and day
    push    r13                 ; save day
    push    rbx                 ; save month

    ; --- Format output: YYYY-MM-DDTHH:MM:SS ---
    mov     rdi, r12            ; output buffer pointer

    ; YYYY
    mov     rsi, [rsp + 16]     ; year (from stack)
    mov     rdx, 4              ; width = 4
    call    int_to_str_padded
    add     rdi, 4              ; advance past YYYY

    ; '-'
    mov     byte [rdi], '-'
    inc     rdi

    ; MM
    mov     rsi, [rsp]          ; month
    mov     rdx, 2
    call    int_to_str_padded
    add     rdi, 2

    ; '-'
    mov     byte [rdi], '-'
    inc     rdi

    ; DD
    mov     rsi, [rsp + 8]      ; day
    mov     rdx, 2
    call    int_to_str_padded
    add     rdi, 2

    ; 'T'
    mov     byte [rdi], 'T'
    inc     rdi

    ; HH
    mov     rsi, [rsp + 24]     ; hours
    mov     rdx, 2
    call    int_to_str_padded
    add     rdi, 2

    ; ':'
    mov     byte [rdi], ':'
    inc     rdi

    ; MM (minutes)
    mov     rsi, [rsp + 32]     ; minutes
    mov     rdx, 2
    call    int_to_str_padded
    add     rdi, 2

    ; ':'
    mov     byte [rdi], ':'
    inc     rdi

    ; SS
    mov     rsi, [rsp + 40]     ; seconds
    mov     rdx, 2
    call    int_to_str_padded
    add     rdi, 2

    ; Null-terminate
    mov     byte [rdi], 0

    ; Clean up stack: month, day, year, hours, minutes, seconds = 6 pushes
    add     rsp, 48

    mov     rax, 19             ; return length = "YYYY-MM-DDTHH:MM:SS"

    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; .is_leap_year — Internal helper: determine if a year is a leap year
; Input:  rdi = year
; Output: rax = 1 if leap year, 0 if not
; Rules:  Divisible by 4, but not by 100, unless also by 400
; ============================================================================
.is_leap_year:
    push    rbx
    mov     rbx, rdi            ; rbx = year

    ; Check divisible by 4
    mov     rax, rbx
    and     rax, 3              ; rax = year % 4
    test    rax, rax
    jnz     .not_leap           ; not divisible by 4 => not leap

    ; Check divisible by 100
    mov     rax, rbx
    xor     edx, edx
    mov     rcx, 100
    div     rcx                 ; rdx = year % 100
    test    rdx, rdx
    jnz     .is_leap            ; divisible by 4 but not 100 => leap

    ; Check divisible by 400
    mov     rax, rbx
    xor     edx, edx
    mov     rcx, 400
    div     rcx                 ; rdx = year % 400
    test    rdx, rdx
    jnz     .not_leap           ; divisible by 100 but not 400 => not leap

.is_leap:
    mov     rax, 1
    pop     rbx
    ret

.not_leap:
    xor     eax, eax
    pop     rbx
    ret
