; ============================================================================
; musical.inc — Musical Orchestration Constants & Data Structures
; ============================================================================
; Maps musical concepts to AI agent orchestration parameters.

; --- Tempo Indices (BPM mapping) ---
%define TEMPO_LARGO         0   ; 1/60s = ultra-cautious
%define TEMPO_ADAGIO        1   ; 1/30s = slow, methodical
%define TEMPO_ANDANTE       2   ; 1/10s = walking pace
%define TEMPO_MODERATO      3   ; 1/5s  = moderate
%define TEMPO_ALLEGRO       4   ; 1/2s  = fast
%define TEMPO_PRESTO        5   ; 0s    = immediate
%define TEMPO_PRESTISSIMO   6   ; burst = fire-and-forget

; --- Tempo Intervals (nanoseconds) ---
; Each tempo maps to a delay between iterations
section .rodata
tempo_intervals:
    dq 60000000000    ; LARGO:     60 seconds
    dq 30000000000    ; ADAGIO:    30 seconds
    dq 10000000000    ; ANDANTE:   10 seconds
    dq  5000000000    ; MODERATO:   5 seconds
    dq  2000000000    ; ALLEGRO:    2 seconds
    dq        500000  ; PRESTO:     0.5ms
    dq              0 ; PRESTISSIMO: immediate
tempo_interval_count equ 7

; --- Tempo Names ---
tempo_names:
    dq tempo_name_largo
    dq tempo_name_adagio
    dq tempo_name_andante
    dq tempo_name_moderato
    dq tempo_name_allegro
    dq tempo_name_presto
    dq tempo_name_prestissimo

section .rodata
tempo_name_largo:       db 'Largo', 0
tempo_name_adagio:      db 'Adagio', 0
tempo_name_andante:     db 'Andante', 0
tempo_name_moderato:    db 'Moderato', 0
tempo_name_allegro:     db 'Allegro', 0
tempo_name_presto:      db 'Presto', 0
tempo_name_prestissimo: db 'Prestissimo', 0

; --- Rhythm Patterns ---
%define RHYTHM_STEADY        0   ; X . X . X . (regular)
%define RHYTHM_ACCEL         1   ; X . X . X X XXXX (accelerate on success)
%define RHYTHM_DECEL         2   ; X X X X . X . . (decelerate on complexity)
%define RHYTHM_CALL_RESPONSE 3   ; X ... x ... (action → verify)
%define RHYTHM_WALTZ         4   ; X . . X . . (3/4: plan → execute → review)
%define RHYTHM_SWING         5   ; X..X..X.. (adaptive groove)
%define RHYTHM_SYNCOPATED    6   ; X . . X . X . . (creative, off-beat)

%define RHYTHM_COUNT         7

; --- Dynamics Levels ---
%define DYN_PP     0   ; pianissimo:  observe only
%define DYN_P      1   ; piano:       safe commands only (ls, cat, echo)
%define DYN_MP     2   ; mezzo-piano: standard commands + file creation
%define DYN_MF     3   ; mezzo-forte: + file modification
%define DYN_F      4   ; forte:       + system commands (apt, etc.)
%define DYN_FF     5   ; fortissimo:  + elevated privileges (sudo)
%define DYN_FFF    6   ; triple-forte: + destructive operations

%define DYN_COUNT  7

; --- Dynamics Names ---
section .rodata
dyn_names:
    dq dyn_name_pp
    dq dyn_name_p
    dq dyn_name_mp
    dq dyn_name_mf
    dq dyn_name_f
    dq dyn_name_ff
    dq dyn_name_fff

dyn_name_pp: db 'pp', 0
dyn_name_p:  db 'p', 0
dyn_name_mp: db 'mp', 0
dyn_name_mf: db 'mf', 0
dyn_name_f:  db 'f', 0
dyn_name_ff: db 'ff', 0
dyn_name_fff: db 'fff', 0

; --- Dynamics Multipliers (for intensity calculation) ---
; Higher = more aggressive
section .text
dyn_multipliers:
    db 1, 2, 4, 8, 16, 32, 64

; --- Style Profiles ---
%define STYLE_CLASSICAL    0   ; Formal, structured
%define STYLE_JAZZ         1   ; Improvisational, creative
%define STYLE_ROCK         2   ; Aggressive, direct
%define STYLE_BLUES        3   ; Pattern-based, learning
%define STYLE_ELECTRONIC   4   ; Automated, systematic
%define STYLE_FOLK         5   ; Simple, human-readable
%define STYLE_BAROQUE      6   ; Complex, layered
%define STYLE_AMBIENT      7   ; Minimal, background

%define STYLE_COUNT        8

; --- Key (Mood) ---
%define KEY_C_MAJOR    0   ; Bright, happy
%define KEY_G_MAJOR    1   ; Confident, bold
%define KEY_D_MAJOR    2   ; Triumphant
%define KEY_A_MAJOR    3   ; Warm, friendly
%define KEY_E_MAJOR    4   ; Brilliant, fast
%define KEY_F_MAJOR    5   ; Pastoral, calm
%define KEY_BB_MAJOR   6   ; Regal, formal
%define KEY_EB_MAJOR   7   ; Dramatic

%define KEY_COUNT      8

; --- Form (Task Structure) ---
%define FORM_STROPHIC           0   ; A A A A (repetitive)
%define FORM_BINARY             1   ; A B (two-phase)
%define FORM_TERNARY            2   ; A B A (try → fix → verify)
%define FORM_RONDO              3   ; A B A C A (main + variations)
%define FORM_SONATA             4   ; Exposition → Dev → Recap
%define FORM_FUGUE              5   ; Multiple interwoven themes
%define FORM_THEME_VARIATIONS   6   ; Core task + adaptive approaches

%define FORM_COUNT              7

; --- Time Signatures ---
%define TIME_4_4     4   ; Standard: think → execute → observe → reflect
%define TIME_3_4     3   ; Waltz: plan → execute → review
%define TIME_2_4     2   ; March: execute → verify
%define TIME_6_8     6   ; Compound: plan → sub1 → sub2 → exec → verify → reflect

; --- Channels ---
%define CH_SOPRANO   0   ; Primary output (stdout)
%define CH_ALTO      1   ; Secondary output
%define CH_TENOR     2   ; Debug/trace output
%define CH_BASS      3   ; Persistent log (worklog)
%define CH_HARP      4   ; Error stream
%define CH_TIMPANI   5   ; Signal/event stream

%define CH_COUNT     6

; Channel bitmask
%define CH_MASK_SOPRANO   0x01
%define CH_MASK_ALTO      0x02
%define CH_MASK_TENOR     0x04
%define CH_MASK_BASS      0x08
%define CH_MASK_HARP      0x10
%define CH_MASK_TIMPANI   0x20
%define CH_MASK_ALL       0x3F

; --- Instruments ---
%define INST_VIOLIN    0   ; file_read
%define INST_CELLO     1   ; file_write
%define INST_FLUTE     2   ; echo/print
%define INST_TRUMPET   3   ; shell_exec
%define INST_TUBA      4   ; sudo_exec
%define INST_HARP      5   ; pipe/redirect
%define INST_DRUMS     6   ; signal/kill
%define INST_PIANO     7   ; process_ctrl
%define INST_ORGAN     8   ; network_io
%define INST_SYNTH     9   ; api_call

%define INST_COUNT     10

; --- Musical State Structure Offsets ---
; MusicalState: 32 bytes
; Layout: qword + dwords first for natural alignment on x86-64
%define MS_STATE_SIZE           32

%define MS_BEAT_NS              0   ; qword (aligned): nanoseconds per beat
%define MS_BEAT_COUNTER         8   ; dword (aligned): current beat in measure
%define MS_MEASURE_COUNTER      12  ; dword (aligned): current measure number
%define MS_TEMPO                16  ; byte: current tempo index
%define MS_RHYTHM_PATTERN       17  ; byte: rhythm pattern
%define MS_DYNAMICS             18  ; byte: dynamics level
%define MS_DYNAMIC_DELTA        19  ; byte: dynamics change per measure
%define MS_STYLE                20  ; byte: style profile
%define MS_KEY                  21  ; byte: key/mood
%define MS_FORM                 22  ; byte: form type
%define MS_FORM_PHASE           23  ; byte: current phase in form
%define MS_TIME_SIGNATURE       24  ; byte: beats per measure
%define MS_ACTIVE_CHANNELS      25  ; byte: channel bitmask
%define MS_CURRENT_INSTRUMENT   26  ; byte: current instrument
%define MS_CONFIDENCE           27  ; byte: confidence score (0-100)
%define MS_SUCCESS_STREAK       28  ; byte: consecutive successes
%define MS_FAILURE_STREAK       29  ; byte: consecutive failures
%define MS_TEMP                 30  ; byte: reserved
%define MS_TEMP2                31  ; byte: reserved

; ============================================================================
; Macros for Musical State Access
; ============================================================================

%macro MUSICAL_INIT 1
    ; Initialize MusicalState at address %1
    mov     rax, 5000000000
    mov     qword [%1 + MS_BEAT_NS], rax         ; 5 seconds
    mov     dword [%1 + MS_BEAT_COUNTER], 0
    mov     dword [%1 + MS_MEASURE_COUNTER], 0
    mov     byte [%1 + MS_TEMPO], TEMPO_MODERATO
    mov     byte [%1 + MS_RHYTHM_PATTERN], RHYTHM_STEADY
    mov     byte [%1 + MS_DYNAMICS], DYN_MF
    mov     byte [%1 + MS_DYNAMIC_DELTA], 0
    mov     byte [%1 + MS_STYLE], STYLE_ELECTRONIC
    mov     byte [%1 + MS_KEY], KEY_C_MAJOR
    mov     byte [%1 + MS_FORM], FORM_STROPHIC
    mov     byte [%1 + MS_FORM_PHASE], 0
    mov     byte [%1 + MS_TIME_SIGNATURE], TIME_4_4
    mov     byte [%1 + MS_ACTIVE_CHANNELS], CH_MASK_SOPRANO | CH_MASK_BASS
    mov     byte [%1 + MS_CURRENT_INSTRUMENT], INST_TRUMPET
    mov     byte [%1 + MS_CONFIDENCE], 50
    mov     byte [%1 + MS_SUCCESS_STREAK], 0
    mov     byte [%1 + MS_FAILURE_STREAK], 0
    mov     byte [%1 + MS_TEMP], 0
    mov     byte [%1 + MS_TEMP2], 0
%endmacro
