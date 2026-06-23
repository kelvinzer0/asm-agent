; ============================================================================
; instruments.asm — Musical Instrument Registry & Tool Selection
; ============================================================================
; Each "instrument" represents a tool/capability with its own characteristics.
; The instrument system selects the right tool based on:
;   - Current dynamics level
;   - Task requirements
;   - Safety constraints
;   - Historical success rate
;
; API:
;   instrument_init         — Initialize instrument registry
;   instrument_select       — Select best instrument for current context
;   instrument_log_use      — Record instrument usage
;   instrument_get_name     — Get instrument name string
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"
%include "musical.inc"

extern musical_state
extern temp_buf

global instrument_init
global instrument_select
global instrument_log_use
global instrument_get_name
global instrument_stats

; ============================================================================
section .data
; ============================================================================

; Instrument usage statistics (10 instruments × 4 bytes each)
; Format per instrument: [success_count:2][fail_count:2]
instrument_stats:   times (INST_COUNT * 4) dw 0

; Current instrument
current_instrument: db INST_TRUMPET

; ============================================================================
section .rodata
; ============================================================================

; Instrument names
instrument_names:
    dq inst_violin
    dq inst_cello
    dq inst_flute
    dq inst_trumpet
    dq inst_tuba
    dq inst_harp
    dq inst_drums
    dq inst_piano
    dq inst_organ
    dq inst_synth

inst_violin:  db 'Violin (file_read)', 0
inst_cello:   db 'Cello (file_write)', 0
inst_flute:   db 'Flute (echo/print)', 0
inst_trumpet: db 'Trumpet (shell_exec)', 0
inst_tuba:    db 'Tuba (sudo_exec)', 0
inst_harp:    db 'Harp (pipe/redirect)', 0
inst_drums:   db 'Drums (signal/kill)', 0
inst_piano:   db 'Piano (process_ctrl)', 0
inst_organ:   db 'Organ (network_io)', 0
inst_synth:   db 'Synth (api_call)', 0

; Instrument minimum dynamics levels
; (instruments with higher minimum = more dangerous)
inst_min_dynamics:
    db DYN_PP      ; Violin (file_read)
    db DYN_P       ; Cello (file_write)
    db DYN_PP      ; Flute (echo/print)
    db DYN_MP      ; Trumpet (shell_exec)
    db DYN_FF      ; Tuba (sudo_exec)
    db DYN_PP      ; Harp (pipe/redirect)
    db DYN_F       ; Drums (signal/kill)
    db DYN_MP      ; Piano (process_ctrl)
    db DYN_P       ; Organ (network_io)
    db DYN_MP      ; Synth (api_call)

; Instrument capability flags
; Bit 0: read, Bit 1: write, Bit 2: execute, Bit 3: network
inst_capabilities:
    db 0x01        ; Violin: read
    db 0x02        ; Cello: write
    db 0x01        ; Flute: read (echo)
    db 0x04        ; Trumpet: execute
    db 0x04        ; Tuba: execute (elevated)
    db 0x02        ; Harp: write (redirect)
    db 0x04        ; Drums: execute (signals)
    db 0x04        ; Piano: execute (process)
    db 0x08        ; Organ: network
    db 0x08        ; Synth: network (API)

; ============================================================================
section .text
; ============================================================================

; ============================================================================
; instrument_init — Zero out usage statistics
; ============================================================================
instrument_init:
    push    rbp
    mov     rbp, rsp

    lea     rdi, [rel instrument_stats]
    xor     al, al
    mov     rcx, INST_COUNT * 2   ; 20 words = 40 bytes
    rep     stosw

    mov     byte [rel current_instrument], INST_TRUMPET

    pop     rbp
    ret

; ============================================================================
; instrument_select — Select best instrument for current context
; ============================================================================
; Considers:
;   - Current dynamics level (must meet minimum)
;   - Task type (implied by command patterns)
;   - Historical success rate
;
; Returns: rax = instrument index
; ============================================================================
instrument_select:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14

    lea     rbx, [rel musical_state]
    movzx   r12d, byte [rbx + MS_DYNAMICS]  ; r12 = current dynamics

    ; Default to trumpet (shell_exec)
    mov     r13d, INST_TRUMPET
    mov     r14d, -1          ; best success rate

    ; Scan ALL instruments, pick highest rate meeting dynamics
    xor     ecx, ecx            ; ecx = instrument index
    lea     rsi, [rel inst_min_dynamics]

.dyn_loop:
    cmp     ecx, INST_COUNT
    jge     .dyn_done

    movzx   eax, byte [rsi + rcx]
    cmp     eax, r12d
    jg      .dyn_skip2           ; instrument requires higher dynamics

    ; This instrument is available — check success rate
    push    rcx
    call    .get_success_rate
    mov     edx, eax
    pop     rcx

    ; Keep highest success rate
    cmp     edx, r14d
    jle     .dyn_skip2
    mov     r13d, ecx
    mov     r14d, edx

.dyn_skip2:
    inc     ecx
    jmp     .dyn_loop

.dyn_done:
    mov     byte [rel current_instrument], r13b
    mov     rax, r13

    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; --- Helper: get success rate for instrument ---
; Input: ecx = instrument index
; Output: eax = success rate (0-100)
.get_success_rate:
    push    rbx

    lea     rbx, [rel instrument_stats]
    mov     eax, ecx
    shl     eax, 2              ; eax = index * 4
    movzx   edx, word [rbx + rax]     ; edx = success count
    movzx   ecx, word [rbx + rax + 2] ; ecx = fail count

    ; Total = success + fail
    mov     esi, edx
    add     esi, ecx
    test    esi, esi
    jz      .rate_default       ; no data yet

    ; Rate = (success * 100) / total
    mov     eax, edx
    imul    eax, 100
    xor     edx, edx
    div     esi                 ; eax = success rate
    jmp     .rate_done

.rate_default:
    mov     eax, 50             ; default 50% if no data

.rate_done:
    pop     rbx
    ret

; ============================================================================
; instrument_log_use — Record instrument usage result
; ============================================================================
; Input: ecx = instrument index, al = 0 (fail) or 1 (success)
; ============================================================================
instrument_log_use:
    push    rbx
    push    rdx

    lea     rbx, [rel instrument_stats]
    mov     edx, ecx
    shl     edx, 2              ; edx = index * 4

    test    al, al
    jnz     .log_success

.log_fail:
    inc     word [rbx + rdx + 2]
    jmp     .log_done

.log_success:
    inc     word [rbx + rdx]

.log_done:
    pop     rdx
    pop     rbx
    ret

; ============================================================================
; instrument_get_name — Get instrument name string
; ============================================================================
; Input:  rax = instrument index
; Returns: rsi = pointer to name string
; ============================================================================
instrument_get_name:
    lea     rsi, [rel instrument_names]
    mov     rsi, [rsi + rax * 8]
    ret
