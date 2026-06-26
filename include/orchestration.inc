; ============================================================================
; orchestration.inc — Swarm/LangGraph Orchestration Constants
; ============================================================================
; Hybrid orchestration combining:
;   - OpenAI Swarm: Handoff mechanism
;   - LangGraph: Graph-based routing, checkpointing
;   - CrewAI: Role specialization
;   - MetaGPT: SOP-driven execution
; ============================================================================

; --- Execution Modes (Handoff Targets) ---
%define MODE_PLANNER      0   ; Decompose task into subtasks
%define MODE_RESEARCHER   1   ; Discover environment
%define MODE_EXECUTOR     2   ; Execute commands
%define MODE_VERIFIER     3   ; Verify results
%define MODE_DONE         4   ; Task complete

%define MODE_COUNT        5

; --- Checkpoint Magic Number ---
%define CP_MAGIC          0x4D414743  ; "MAGC" in little-endian
%define CP_VERSION        1
%define CP_FILE           db 'checkpoint.json', 0

; --- Checkpoint Structure Offsets (64 bytes) ---
%define CP_SIZE           64

%define CP_MAGIC_OFF      0   ; dword: magic number
%define CP_VERSION_OFF    4   ; byte: version
%define CP_MODE_OFF       5   ; byte: current mode
%define CP_ITERATION_OFF  6   ; dword: iteration count
%define CP_EXEC_STREAK    10  ; dword: consecutive exec streak
%define CP_TASK_LEN_OFF   14  ; dword: task string length
%define CP_TASK_OFF       18  ; 32 bytes: task string (truncated)
%define CP_MUSICAL_OFF    50  ; 14 bytes: key musical state bytes

; --- Handoff Response Prefixes ---
; (defined in orchestration.asm as global symbols)

; --- Mode Names (for logging) ---
mode_names:
    dq mode_name_planner
    dq mode_name_researcher
    dq mode_name_executor
    dq mode_name_verifier
    dq mode_name_done

mode_name_planner:    db 'Planner', 0
mode_name_researcher: db 'Researcher', 0
mode_name_executor:   db 'Executor', 0
mode_name_verifier:   db 'Verifier', 0
mode_name_done:       db 'Done', 0

; --- Graph Edge Definitions ---
; PLANNER  → always → RESEARCHER
; RESEARCHER → always → EXECUTOR
; EXECUTOR → exit:0 → VERIFIER
; EXECUTOR → exit:non-zero → stay in EXECUTOR (retry)
; VERIFIER → goal met → DONE
; VERIFIER → goal not met → EXECUTOR

; --- Musical Style per Mode ---
; Maps each mode to a musical style for the conductor
mode_style_map:
    db STYLE_CLASSICAL   ; PLANNER: formal, structured
    db STYLE_JAZZ        ; RESEARCHER: improvisational, exploratory
    db STYLE_ROCK        ; EXECUTOR: aggressive, direct
    db STYLE_BAROQUE     ; VERIFIER: complex, thorough
    db STYLE_ELECTRONIC  ; DONE: automated, systematic

; --- Mode-specific Delays (nanoseconds) ---
; Different modes have different tempo characteristics
mode_delays:
    dq 3000000000    ; PLANNER: 3 seconds (think carefully)
    dq 1000000000    ; RESEARCHER: 1 second (quick discovery)
    dq  500000000    ; EXECUTOR: 0.5 seconds (fast execution)
    dq 2000000000    ; VERIFIER: 2 seconds (careful verification)
    dq        0      ; DONE: immediate
