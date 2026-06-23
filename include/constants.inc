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
%define COMMAND_BUF_SZ      8192        ; 8KB   — parsed command (from tool_call args)
%define PAYLOAD_BUF_SZ      262144      ; 256KB — JSON payload (increased for conversation history)
%define WORKLOG_BUF_SZ      65536       ; 64KB  — context window
%define OUTPUT_BUF_SZ       65536       ; 64KB  — command output
%define TIMESTAMP_BUF_SZ    64          ; 64B   — ISO timestamp
%define TASK_BUF_SZ         4096        ; 4KB   — user input task
%define TEMP_BUF_SZ         8192        ; 8KB   — general purpose temp
%define INPUT_LINE_SZ       1024        ; 1KB   — single line input
%define MESSAGES_BUF_SZ     196608      ; 192KB — conversation history JSON
%define TOOL_CALL_ID_SZ     128         ; 128B  — tool call ID
%define TOOL_CALL_NAME_SZ   64          ; 64B   — function name
%define TOOL_CALL_ARGS_SZ   8192        ; 8KB   — function arguments JSON
%define FINISH_REASON_SZ    32          ; 32B   — finish_reason string
%define CONTENT_BUF_SZ      8192        ; 8KB   — response content text

; --- Agent Limits ---
%define MAX_ITERATIONS      50
%define API_TIMEOUT_SECS    120
%define CMD_TIMEOUT_SECS    60
%define LOOP_DELAY_SECS     1

; --- Action Types (returned by parser) ---
%define ACTION_TOOL_CALL    0           ; model returned tool_calls
%define ACTION_DONE         1           ; task_complete tool called
%define ACTION_THINK        2           ; model returned content only (finish_reason: stop)
%define ACTION_ERROR        -1          ; parse failure or API error

; --- fstat struct offsets (struct stat) ---
%define STAT_SIZE           48          ; offset of st_size in struct stat

; --- sigaction struct size ---
%define SA_RESTORER         0x04000000
%define SIGACTION_SIZE      32

; --- Clock ---
%define CLOCK_REALTIME      0

; --- Boolean ---
%define TRUE                1
%define FALSE               0