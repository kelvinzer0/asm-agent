; ============================================================================
; conductor.asm — Musical Orchestration Engine
; ============================================================================
; The Conductor is the brain of the musical orchestration system.
; It manages tempo, rhythm, dynamics, style, and coordinates all modules.
;
; API:
;   conductor_init       — Initialize conductor with default state
;   conductor_beat       — Advance one beat (called each iteration)
;   conductor_adjust_tempo  — Adapt tempo based on success/failure
;   conductor_adjust_dynamics — Adapt dynamics based on context
;   conductor_apply_rhythm  — Apply rhythm pattern to current delay
;   conductor_set_rhythm     — Set active rhythm pattern programmatically
;   conductor_next_measure  — Start new measure cycle
;   conductor_get_delay_ns  — Get current beat delay in nanoseconds
;   conductor_should_stop   — Check if conductor signals stop
;   conductor_log_state     — Log current musical state to worklog
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"
%include "musical.inc"

; --- External data ---
extern temp_buf
extern timestamp_buf
extern iteration_count

; --- External functions ---
extern str_len
extern str_copy
extern str_concat
extern uint_to_str
extern get_timestamp
extern worklog_append_entry
extern worklog_append_raw

; --- Export ---
global conductor_init
global conductor_beat
global conductor_adjust_tempo
global conductor_adjust_dynamics
global conductor_apply_rhythm
global conductor_set_rhythm
global conductor_next_measure
global conductor_get_delay_ns
global conductor_should_stop
global conductor_log_state
global musical_state

; ============================================================================
section .data
; ============================================================================

; Musical state (32 bytes)
musical_state:  times MS_STATE_SIZE db 0

; Beat delay timespec (populated by conductor_get_delay_ns)
beat_delay_ts:  dq 5000000000, 0    ; default 5 seconds

; Success/failure thresholds for tempo adjustment
tempo_accel_threshold equ 3     ; N consecutive successes → speed up
tempo_decel_threshold equ 2     ; N consecutive failures → slow down
dynamic_up_threshold   equ 5    ; N successes → increase dynamics
dynamic_down_threshold equ 2    ; N failures → decrease dynamics

; Rhythm pattern multipliers (applied to base tempo delay)
; Each rhythm has a cycle of multipliers, expressed as fixed-point 8.8
; (value / 256 = actual multiplier)
; Pattern cycle lengths stored separately
rhythm_cycle_len:
    db 2    ; STEADY:     X . X .  (2-beat cycle)
    db 6    ; ACCEL:      X . X . X X X  (6-beat cycle, speeds up)
    db 6    ; DECEL:      X X X X . . .  (6-beat cycle, slows down)
    db 2    ; CALL_RESP:  X .  (2-beat, long pause between)
    db 3    ; WALTZ:      X . .  (3-beat, 2/3 of time is pause)
    db 3    ; SWING:      X..X.. (3-beat, uneven)
    db 4    ; SYNCOPATED: X . . X  (4-beat, off-beat accent)

; Rhythm multiplier tables (fixed-point 8.8: 256 = 1.0x)
; Each entry is a qword to match ns arithmetic
section .rodata
rhythm_steady_mults:
    dq 256, 256                 ; 1.0x, 1.0x — constant
rhythm_accel_mults:
    dq 256, 256, 256, 200, 150, 100   ; 1.0, 1.0, 1.0, 0.78, 0.59, 0.39
rhythm_decel_mults:
    dq 100, 150, 200, 300, 400, 500   ; 0.39, 0.59, 0.78, 1.17, 1.56, 1.95
rhythm_call_resp_mults:
    dq 300, 80                  ; 1.17x action, 0.31x pause
rhythm_waltz_mults:
    dq 350, 30, 30              ; 1.37x, 0.12x, 0.12x
rhythm_swing_mults:
    dq 300, 50, 200             ; 1.17x, 0.20x, 0.78x
rhythm_syncopated_mults:
    dq 350, 50, 30, 300         ; 1.37x, 0.20x, 0.12x, 1.17x

; Table of pointers to rhythm multiplier arrays
rhythm_mult_tables:
    dq rhythm_steady_mults
    dq rhythm_accel_mults
    dq rhythm_decel_mults
    dq rhythm_call_resp_mults
    dq rhythm_waltz_mults
    dq rhythm_swing_mults
    dq rhythm_syncopated_mults

; ============================================================================
section .rodata
; ============================================================================

; Worklog labels for musical state logging
wl_musical_state db 'MUSICAL STATE', 0

; State format strings
state_tempo_pre:     db 'Tempo: ', 0
state_tempo_sep:     db ' | ', 0
state_rhythm_pre:    db 'Rhythm: ', 0
state_dynamics_pre:  db 'Dynamics: ', 0
state_style_pre:     db 'Style: ', 0
state_key_pre:       db 'Key: ', 0
state_measure_pre:   db 'Measure: ', 0
state_beat_pre:      db 'Beat: ', 0
state_confidence_pre: db 'Confidence: ', 0
state_pct:           db '%', 0
state_newline:       db 10, 0

; Rhythm names
rhythm_names:
    dq rhythm_steady
    dq rhythm_accel
    dq rhythm_decel
    dq rhythm_call_response
    dq rhythm_waltz
    dq rhythm_swing
    dq rhythm_syncopated

rhythm_steady:        db 'Steady', 0
rhythm_accel:         db 'Accelerando', 0
rhythm_decel:         db 'Ritardando', 0
rhythm_call_response: db 'Call-Response', 0
rhythm_waltz:         db 'Waltz', 0
rhythm_swing:         db 'Swing', 0
rhythm_syncopated:    db 'Syncopated', 0

; Style names
style_names:
    dq style_classical
    dq style_jazz
    dq style_rock
    dq style_blues
    dq style_electronic
    dq style_folk
    dq style_baroque
    dq style_ambient

style_classical:  db 'Classical', 0
style_jazz:       db 'Jazz', 0
style_rock:       db 'Rock', 0
style_blues:      db 'Blues', 0
style_electronic: db 'Electronic', 0
style_folk:       db 'Folk', 0
style_baroque:    db 'Baroque', 0
style_ambient:    db 'Ambient', 0

; Key names
key_names:
    dq key_c_major
    dq key_g_major
    dq key_d_major
    dq key_a_major
    dq key_e_major
    dq key_f_major
    dq key_bb_major
    dq key_eb_major

key_c_major:   db 'C Major', 0
key_g_major:   db 'G Major', 0
key_d_major:   db 'D Major', 0
key_a_major:   db 'A Major', 0
key_e_major:   db 'E Major', 0
key_f_major:   db 'F Major', 0
key_bb_major:  db 'Bb Major', 0
key_eb_major:  db 'Eb Major', 0

; Form names
form_names:
    dq form_strophic
    dq form_binary
    dq form_ternary
    dq form_rondo
    dq form_sonata
    dq form_fugue
    dq form_theme_var

form_strophic:    db 'Strophic', 0
form_binary:      db 'Binary', 0
form_ternary:     db 'Ternary', 0
form_rondo:       db 'Rondo', 0
form_sonata:      db 'Sonata', 0
form_fugue:       db 'Fugue', 0
form_theme_var:   db 'Theme & Variations', 0

; ============================================================================
section .text
; ============================================================================

; ============================================================================
; conductor_init — Initialize musical state with defaults
; ============================================================================
conductor_init:
    push    rbp
    mov     rbp, rsp

    lea     rdi, [rel musical_state]
    MUSICAL_INIT rdi

    pop     rbp
    ret

; ============================================================================
; conductor_beat — Advance one beat in the musical cycle
; ============================================================================
; Updates beat counter, measure counter, and applies rhythm-based variations.
; ============================================================================
conductor_beat:
    push    rbp
    mov     rbp, rsp
    push    rbx

    lea     rbx, [rel musical_state]

    ; Increment beat counter
    inc     dword [rbx + MS_BEAT_COUNTER]

    ; Check if we've completed a measure
    movzx   eax, byte [rbx + MS_TIME_SIGNATURE]
    cmp     dword [rbx + MS_BEAT_COUNTER], eax
    jl      .beat_done

    ; Completed a measure — reset beat, increment measure
    mov     dword [rbx + MS_BEAT_COUNTER], 0
    inc     dword [rbx + MS_MEASURE_COUNTER]

    ; Apply measure-end dynamics adjustment
    movzx   eax, byte [rbx + MS_DYNAMIC_DELTA]
    test    al, al
    jz      .no_dyn_adjust

    ; Apply delta (signed)
    movsx   ecx, al
    movzx   edx, byte [rbx + MS_DYNAMICS]
    add     edx, ecx
    ; Clamp to valid range (0-6)
    cmp     edx, 0
    jge     .dyn_min_ok
    xor     edx, edx            ; clamp to 0
.dyn_min_ok:
    cmp     edx, DYN_FFF
    jle     .dyn_max_ok
    mov     edx, DYN_FFF        ; clamp to 6
.dyn_max_ok:
    mov     byte [rbx + MS_DYNAMICS], dl

.no_dyn_adjust:
    ; Advance form phase
    inc     byte [rbx + MS_FORM_PHASE]

.beat_done:
    pop     rbx
    pop     rbp
    ret

; ============================================================================
; conductor_adjust_tempo — Adapt tempo based on success/failure
; ============================================================================
; Input:  al = 0 (failure) or 1 (success)
; ============================================================================
conductor_adjust_tempo:
    push    rbp
    mov     rbp, rsp
    push    rbx

    lea     rbx, [rel musical_state]

    test    al, al
    jnz     .on_success

.on_failure:
    ; Increment failure streak
    inc     byte [rbx + MS_FAILURE_STREAK]
    mov     byte [rbx + MS_SUCCESS_STREAK], 0  ; reset success streak

    ; Check if we should slow down (2+ consecutive failures)
    movzx   eax, byte [rbx + MS_FAILURE_STREAK]
    cmp     eax, tempo_decel_threshold
    jl      .tempo_done

    ; Slow down: decrement tempo index (lower index = slower delay)
    ; Index 0 = LARGO (60s, slowest) → Index 6 = PRESTISSIMO (0s, fastest)
    movzx   eax, byte [rbx + MS_TEMPO]
    test    eax, eax
    jz      .tempo_clamp_lo       ; already at slowest
    dec     al
    mov     byte [rbx + MS_TEMPO], al
    ; Update beat interval
    call    .update_beat_interval
    jmp     .tempo_done

.tempo_clamp_lo:
    mov     byte [rbx + MS_TEMPO], TEMPO_LARGO
    jmp     .tempo_done

.on_success:
    ; Increment success streak
    inc     byte [rbx + MS_SUCCESS_STREAK]
    mov     byte [rbx + MS_FAILURE_STREAK], 0  ; reset failure streak

    ; Increase confidence
    movzx   eax, byte [rbx + MS_CONFIDENCE]
    cmp     eax, 100
    jge     .conf_max
    add     al, 5
    mov     byte [rbx + MS_CONFIDENCE], al
.conf_max:

    ; Check if we should speed up (3+ consecutive successes)
    movzx   eax, byte [rbx + MS_SUCCESS_STREAK]
    cmp     eax, tempo_accel_threshold
    jl      .tempo_done

    ; Speed up: increment tempo index (higher index = faster delay)
    ; Index 0 = LARGO (60s, slowest) → Index 6 = PRESTISSIMO (0s, fastest)
    movzx   eax, byte [rbx + MS_TEMPO]
    cmp     eax, TEMPO_PRESTISSIMO
    jge     .tempo_clamp_hi
    inc     al
    mov     byte [rbx + MS_TEMPO], al
    ; Update beat interval
    call    .update_beat_interval
    jmp     .tempo_done

.tempo_clamp_hi:
    mov     byte [rbx + MS_TEMPO], TEMPO_PRESTISSIMO

.tempo_done:
    pop     rbx
    pop     rbp
    ret

; --- Helper: update beat interval from current tempo ---
.update_beat_interval:
    push    rax
    push    rcx
    push    rsi

    movzx   eax, byte [rbx + MS_TEMPO]
    cmp     eax, tempo_interval_count
    jb      .ubi_ok
    mov     eax, TEMPO_MODERATO
.ubi_ok:
    lea     rsi, [rel tempo_intervals]
    mov     rax, [rsi + rax * 8]
    mov     [rbx + MS_BEAT_NS], rax

    pop     rsi
    pop     rcx
    pop     rax
    ret

; ============================================================================
; conductor_adjust_dynamics — Adapt dynamics based on context
; ============================================================================
; Input:  al = exit code of last command (0 = success)
; ============================================================================
conductor_adjust_dynamics:
    push    rbp
    mov     rbp, rsp
    push    rbx

    lea     rbx, [rel musical_state]

    test    al, al
    jnz     .dyn_failure

.dyn_success:
    ; Successful command — consider increasing dynamics
    movzx   eax, byte [rbx + MS_SUCCESS_STREAK]
    cmp     eax, dynamic_up_threshold
    jl      .dyn_done

    ; Increase dynamics (up to forte for safety)
    movzx   eax, byte [rbx + MS_DYNAMICS]
    cmp     eax, DYN_F
    jge     .dyn_done
    inc     al
    mov     byte [rbx + MS_DYNAMICS], al
    jmp     .dyn_done

.dyn_failure:
    ; Failed command — decrease dynamics (be more careful)
    movzx   eax, byte [rbx + MS_DYNAMICS]
    test    al, al
    jz      .dyn_done
    dec     al
    mov     byte [rbx + MS_DYNAMICS], al

.dyn_done:
    pop     rbx
    pop     rbp
    ret

; ============================================================================
; conductor_next_measure — Start a new measure cycle
; ============================================================================
conductor_next_measure:
    push    rbp
    mov     rbp, rsp
    push    rbx

    lea     rbx, [rel musical_state]
    mov     dword [rbx + MS_BEAT_COUNTER], 0
    inc     dword [rbx + MS_MEASURE_COUNTER]

    pop     rbx
    pop     rbp
    ret

; ============================================================================
; conductor_set_rhythm — Set active rhythm pattern
; ============================================================================
; Input:  dil = rhythm pattern index (RHYTHM_STEADY, etc.)
; ============================================================================
conductor_set_rhythm:
    lea     rax, [rel musical_state]
    mov     byte [rax + MS_RHYTHM_PATTERN], dil
    ret

; ============================================================================
; conductor_apply_rhythm — Get delay with rhythm pattern applied
; ============================================================================
; Takes the base tempo delay and modulates it according to the active
; rhythm pattern. Each rhythm defines a cycle of multipliers (fixed-point
; 8.8 format: 256 = 1.0x). The current beat position within the cycle
; determines which multiplier to apply.
;
; Returns: rax = rhythm-modulated delay in nanoseconds
; Clobbers: rcx, rdx
; ============================================================================
conductor_apply_rhythm:
    push    rbx
    push    r12

    lea     rbx, [rel musical_state]

    ; Get base delay
    mov     rax, [rbx + MS_BEAT_NS]
    test    rax, rax
    jz      .rhythm_done          ; prestissimo — no delay, skip rhythm

    mov     r12, rax              ; r12 = base delay (ns)

    ; Get current rhythm pattern index
    movzx   ecx, byte [rbx + MS_RHYTHM_PATTERN]
    cmp     ecx, RHYTHM_COUNT
    jb      .rhythm_idx_ok
    mov     ecx, RHYTHM_STEADY
.rhythm_idx_ok:

    ; Get cycle length for this rhythm
    lea     rax, [rel rhythm_cycle_len]
    movzx   r8, byte [rax + rcx]   ; r8 = cycle length (save in r8, NOT rdx)

    ; Get current beat position within cycle
    ; Compute: position = beat_counter % cycle_length
    movzx   rax, dword [rbx + MS_BEAT_COUNTER]  ; rax = beat counter (dividend)
    xor     edx, edx                              ; rdx = 0 (high bits for div)
    div     r8                                   ; rax = beat/cycle, rdx = beat%cycle = position

    ; Load the multiplier for this position
    ; rhythm_mult_tables[rhythm_idx] gives pointer to qword array
    lea     rsi, [rel rhythm_mult_tables]
    mov     rsi, [rsi + rcx * 8]   ; rsi = pointer to multiplier array
    mov     rdx, [rsi + rdx * 8]   ; rdx = multiplier (fixed-point 8.8)

    ; Apply: delay = (base_delay * multiplier) / 256
    mov     rax, r12               ; rax = base delay
    imul    rdx                    ; rdx:rax = base * multiplier
    shr     rax, 8                 ; rax = (base * mult) / 256

    ; Minimum delay: 100ms (100000000 ns) to prevent near-zero pauses
    cmp     rax, 100000000
    jae     .rhythm_done
    mov     rax, 100000000

.rhythm_done:
    pop     r12
    pop     rbx
    ret

; ============================================================================
; conductor_get_delay_ns — Get current beat delay in nanoseconds
; ============================================================================
; Now applies rhythm pattern modulation on top of base tempo.
; Returns: rax = delay in nanoseconds
; ============================================================================
conductor_get_delay_ns:
    ; Apply rhythm modulation on top of base tempo.
    ; conductor_apply_rhythm reads MS_BEAT_NS directly from musical_state.
    ; Returns: rax = delay in nanoseconds
    call    conductor_apply_rhythm
    ret

; ============================================================================
; conductor_should_stop — Check if conductor signals stop
; ============================================================================
; Returns: rax = 1 if should stop, 0 otherwise
; Stop conditions: max iterations, confidence > 90 with success
; ============================================================================
conductor_should_stop:
    push    rbx

    lea     rbx, [rel musical_state]

    ; Check iteration limit
    mov     eax, [rel iteration_count]
    cmp     eax, MAX_ITERATIONS
    jge     .should_stop

    ; Check if confidence is very high and we have consecutive successes
    movzx   eax, byte [rbx + MS_CONFIDENCE]
    cmp     eax, 90
    jl      .no_stop
    movzx   eax, byte [rbx + MS_SUCCESS_STREAK]
    cmp     eax, 3
    jl      .no_stop

.should_stop:
    mov     rax, 1
    pop     rbx
    ret

.no_stop:
    xor     eax, eax
    pop     rbx
    ret

; ============================================================================
; conductor_log_state — Log current musical state to worklog
; ============================================================================
conductor_log_state:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13

    lea     rbx, [rel musical_state]
    lea     r12, [rel temp_buf]
    mov     r13, r12            ; r13 = base for length calc

    ; Build state string in temp_buf
    ; "Tempo: Moderato | Rhythm: Steady | Dynamics: mf | ..."
    mov     rdi, r12
    lea     rsi, [rel state_tempo_pre]
    call    .copy_str

    ; Tempo name (clamped)
    movzx   eax, byte [rbx + MS_TEMPO]
    cmp     eax, tempo_interval_count
    jb      .log_tempo_ok
    mov     eax, TEMPO_MODERATO
.log_tempo_ok:
    lea     rsi, [rel tempo_names]
    mov     rsi, [rsi + rax * 8]
    mov     rdi, r12
    call    .copy_str_to_r12

    ; " | "
    lea     rsi, [rel state_tempo_sep]
    mov     rdi, r12
    call    .copy_str_to_r12

    ; Rhythm name
    lea     rdi, [r12]
    lea     rsi, [rel state_rhythm_pre]
    call    .copy_str
    movzx   eax, byte [rbx + MS_RHYTHM_PATTERN]
    cmp     eax, RHYTHM_COUNT
    jb      .log_rhythm_ok
    mov     eax, RHYTHM_STEADY
.log_rhythm_ok:
    lea     rsi, [rel rhythm_names]
    mov     rsi, [rsi + rax * 8]
    mov     rdi, r12
    call    .copy_str_to_r12

    lea     rsi, [rel state_tempo_sep]
    mov     rdi, r12
    call    .copy_str_to_r12

    ; Dynamics name
    lea     rdi, [r12]
    lea     rsi, [rel state_dynamics_pre]
    call    .copy_str
    movzx   eax, byte [rbx + MS_DYNAMICS]
    cmp     eax, DYN_COUNT
    jb      .log_dyn_ok
    mov     eax, DYN_MF
.log_dyn_ok:
    lea     rsi, [rel dyn_names]
    mov     rsi, [rsi + rax * 8]
    mov     rdi, r12
    call    .copy_str_to_r12

    lea     rsi, [rel state_tempo_sep]
    mov     rdi, r12
    call    .copy_str_to_r12

    ; Style name
    lea     rdi, [r12]
    lea     rsi, [rel state_style_pre]
    call    .copy_str
    movzx   eax, byte [rbx + MS_STYLE]
    cmp     eax, STYLE_COUNT
    jb      .log_style_ok
    mov     eax, STYLE_ELECTRONIC
.log_style_ok:
    lea     rsi, [rel style_names]
    mov     rsi, [rsi + rax * 8]
    mov     rdi, r12
    call    .copy_str_to_r12

    lea     rsi, [rel state_tempo_sep]
    mov     rdi, r12
    call    .copy_str_to_r12

    ; Key name
    lea     rdi, [r12]
    lea     rsi, [rel state_key_pre]
    call    .copy_str
    movzx   eax, byte [rbx + MS_KEY]
    cmp     eax, KEY_COUNT
    jb      .log_key_ok
    mov     eax, KEY_C_MAJOR
.log_key_ok:
    lea     rsi, [rel key_names]
    mov     rsi, [rsi + rax * 8]
    mov     rdi, r12
    call    .copy_str_to_r12

    ; Newline
    mov     byte [r12], 10
    inc     r12

    ; Null terminate
    mov     byte [r12], 0

    ; Calculate length
    mov     rsi, r12
    sub     rsi, r13    ; rsi = length

    lea     rdi, [rel temp_buf]
    call    worklog_append_raw

    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; --- Helper: copy string (local, updates r12) ---
.copy_str:
    ; rsi = source, rdi = destination (r12)
.copy_loop:
    lodsb
    test    al, al
    jz      .copy_done
    mov     [rdi], al
    inc     rdi
    inc     r12
    jmp     .copy_loop
.copy_done:
    ret

; --- Helper: copy string to current r12 position ---
.copy_str_to_r12:
    ; rsi = source
    mov     rdi, r12
.copy_r12_loop:
    lodsb
    test    al, al
    jz      .copy_r12_done
    mov     [rdi], al
    inc     rdi
    inc     r12
    jmp     .copy_r12_loop
.copy_r12_done:
    ret
