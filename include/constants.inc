; ============================================================================
; constants.inc — ASM-AGENT Core Constants
; ============================================================================

; --- Linux x86_64 Syscall Numbers ---
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_FSTAT           5
%define SYS_MMAP            9
%define SYS_MUNMAP          11
%define SYS_ACCESS          21
%define SYS_RT_SIGACTION    13
%define SYS_PIPE            22
%define SYS_DUP2            33
%define SYS_NANOSLEEP       35
%define SYS_FORK            57
%define SYS_EXECVE          59
%define SYS_EXIT            60
%define SYS_WAIT4           61
%define SYS_UNLINK          87
%define SYS_GETCWD          79
%define SYS_CLOCK_GETTIME   228
%define SYS_GETRANDOM       318

; --- File Open Flags ---
%define O_RDONLY            0
%define O_WRONLY            1
%define O_RDWR              2
%define O_CREAT             0o100
%define O_TRUNC             0o1000
%define O_APPEND            0o2000

; --- File Permissions ---
%define S_IRUSR             0o400
%define S_IWUSR             0o200
%define S_IRGRP             0o040
%define S_IROTH             0o004
%define FILE_MODE           (S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)  ; 0644

; --- mmap Constants ---
%define PROT_READ           1
%define MAP_PRIVATE         2

; --- Signal Numbers ---
%define SIGINT              2
%define SIGPIPE             13
%define SIGCHLD             17
%define SIG_IGN             1

; --- Standard File Descriptors ---
%define STDIN               0
%define STDOUT              1
%define STDERR              2

; --- Buffer Sizes ---
%define RESPONSE_BUF_SZ     262144      ; 256KB — API response
%define COMMAND_BUF_SZ      8192        ; 8KB   — parsed command
%define PAYLOAD_BUF_SZ      131072      ; 128KB — JSON payload
%define WORKLOG_BUF_SZ      65536       ; 64KB  — context window
%define OUTPUT_BUF_SZ       65536       ; 64KB  — command output
%define TIMESTAMP_BUF_SZ    64          ; 64B   — ISO timestamp
%define TASK_BUF_SZ         4096        ; 4KB   — user input task
%define TEMP_BUF_SZ         8192        ; 8KB   — general purpose temp
%define INPUT_LINE_SZ       1024        ; 1KB   — single line input

; --- Orchestrator Limits ---
%define MAX_ITERATIONS      50
%define API_TIMEOUT_SECS    120
%define CMD_TIMEOUT_SECS    60
%define LOOP_DELAY_SECS     2
%define MAX_CONTEXT_ENTRIES 2
%define MAX_CONSECUTIVE_EXEC 3
%define MAX_CONSECUTIVE_THINK 3
%define MAX_SUCCESSFUL_EXEC 5    ; force DONE after this many successful commands

; --- Action Types (returned by parser) ---
%define ACTION_EXEC         0
%define ACTION_THINK        1
%define ACTION_DONE         2
%define ACTION_NEXT_PAGE    3
%define ACTION_FETCH_PAGE   4          ; VisiBox fetch_page
%define ACTION_SEARCH_JUMP  5          ; VisiBox search_jump
%define ACTION_SESSION      6          ; VisiBox session (persistent shell)
%define ACTION_ERROR        -1

; --- Output Pagination ---
%define OUTPUT_PAGE_SIZE     3072       ; 3KB max output per page in worklog

; --- Agent States ---
%define STATE_INIT              0
%define STATE_READ_WORKLOG      1
%define STATE_BUILD_CONTEXT     2
%define STATE_BUILD_PAYLOAD     3
%define STATE_CALL_API          4
%define STATE_PARSE_RESPONSE    5
%define STATE_EXEC_CMD          6
%define STATE_CAPTURE_OUTPUT    7
%define STATE_LOG               8
%define STATE_EXIT              9

; --- fstat struct offsets (struct stat) ---
%define STAT_SIZE           48          ; offset of st_size in struct stat

; --- sigaction struct size ---
%define SA_RESTORER         0x04000000
%define SIGACTION_SIZE      32

; --- Clock ---
%define CLOCK_REALTIME      0

; --- Payload Size Management ---
%define PAYLOAD_SAFE_MAX       32768      ; 32KB — safe max payload for API call
%define PAGE_BUF_SZ           65536      ; 64KB — stores full output for pagination
%define WORKLOG_CTX_MAX        20480      ; 20KB — max worklog context sent to API
%define WORKLOG_FILE_MAX       65536      ; 64KB — trigger archive/split when file exceeds this
%define JSON_ESCAPE_OVERHEAD   2          ; worst-case multiplier for JSON escaping
%define PAYLOAD_FIXED_OVERHEAD 768        ; fixed JSON structure + model + cwd + separators

; --- Boolean ---
%define TRUE                1
%define FALSE               0
