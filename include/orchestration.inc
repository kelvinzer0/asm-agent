; ============================================================================
; orchestration.inc — ASM-AGENT Orchestration Constants (Simplified)
; ============================================================================
; Tool calls architecture: no more HANDOFF/mode system.
; Orchestration is now just logging and tempo control.
; ============================================================================

; --- Checkpoint Magic Number ---
%define CP_MAGIC          0x4D414743  ; "MAGC" in little-endian
%define CP_VERSION        1
%define CP_FILE           db 'checkpoint.json', 0

; --- Checkpoint Structure Offsets (64 bytes) ---
%define CP_SIZE           64

%define CP_MAGIC_OFF      0   ; dword: magic number
%define CP_VERSION_OFF    4   ; byte: version
%define CP_ITERATION_OFF  5   ; dword: iteration count
%define CP_EXEC_STREAK    9   ; dword: consecutive exec streak
%define CP_TASK_LEN_OFF   13  ; dword: task string length
%define CP_TASK_OFF       17  ; 32 bytes: task string (truncated)
%define CP_MUSICAL_OFF    49  ; 15 bytes: key musical state bytes