; ============================================================================
; worklog.asm — ASM-AGENT Worklog Manager
; ============================================================================
; Manages the WORKLOG.md file which serves as the agent's persistent memory:
;   - worklog_init:          Create/initialize the worklog file
;   - worklog_read_context:  Read last N entries for LLM context window
;   - worklog_append_raw:    Append raw bytes to worklog
;   - worklog_append_entry:  Append a formatted timestamped entry
;
; The worklog uses markdown format with ## [TIMESTAMP] TYPE headers
; so entries can be parsed and the last MAX_CONTEXT_ENTRIES can be
; extracted for the LLM's context window.
; ============================================================================

%include "constants.inc"
%include "macros.inc"
%include "config.inc"

; ---------------------------------------------------------------------------
; External data (defined in main.asm BSS)
; ---------------------------------------------------------------------------
extern worklog_buf                      ; WORKLOG_BUF_SZ bytes
extern worklog_ctx_len                  ; resq 1
extern temp_buf                         ; TEMP_BUF_SZ bytes
extern timestamp_buf                    ; TIMESTAMP_BUF_SZ bytes

; ---------------------------------------------------------------------------
; External functions (defined in strings.asm / timestamp.asm)
; ---------------------------------------------------------------------------
extern str_len
extern str_copy
extern str_concat
extern get_timestamp

; ---------------------------------------------------------------------------
; Exported symbols
; ---------------------------------------------------------------------------
global worklog_init
global worklog_read_context
global worklog_append_raw
global worklog_append_entry
global worklog_maybe_archive


; ============================================================================
section .rodata
; ============================================================================

; Local format strings for entry building
wl_hdr_open     db '>> [', 0           ; entry header open bracket
wl_hdr_close    db '] ', 0             ; close bracket + space
wl_newline      db 10, 0               ; single newline

; Archive paths
memory_dir      db 'memory', 0
archive_prefix  db 'memory/archive_', 0
archive_ext     db '.md', 0


; ============================================================================
section .text
; ============================================================================

; ============================================================================
; worklog_init — Initialize the worklog file
; ============================================================================
; Creates the worklog file if it doesn't exist. If the file is empty
; (newly created), writes the worklog header.
;
; Args:    none
; Returns: rax = 0 on success, -1 on error
; Clobbers: rax, rdi, rsi, rdx, r10
; ============================================================================
worklog_init:
    push    rbp
    mov     rbp, rsp
    push    rbx                         ; rbx = saved fd
    push    r12                         ; r12 = saved for use
    sub     rsp, 144                    ; 144 bytes for fstat struct (struct stat)

    ; ------------------------------------------------------------------
    ; Open worklog file: O_WRONLY | O_CREAT | O_APPEND
    ; ------------------------------------------------------------------
    mov     rax, SYS_OPEN
    lea     rdi, [rel worklog_path]
    mov     rsi, O_WRONLY | O_CREAT | O_APPEND
    mov     rdx, FILE_MODE              ; 0644
    syscall

    ; Check for open error
    test    rax, rax
    js      .init_error

    mov     rbx, rax                    ; rbx = fd

    ; ------------------------------------------------------------------
    ; fstat(fd, &stat_buf) to check file size
    ; ------------------------------------------------------------------
    mov     rax, SYS_FSTAT
    mov     rdi, rbx                    ; fd
    lea     rsi, [rsp]                  ; stat struct on stack
    syscall

    test    rax, rax
    js      .init_close_error

    ; ------------------------------------------------------------------
    ; Check st_size (at offset STAT_SIZE=48 in struct stat)
    ; If size == 0, file is new — write header
    ; ------------------------------------------------------------------
    mov     rax, [rsp + STAT_SIZE]      ; st_size
    test    rax, rax
    jnz     .init_close_ok              ; file not empty, skip header

    ; Write worklog header to the file
    ; First get the length of the header string
    push    rdi
    lea     rdi, [rel worklog_header]
    call    str_len                     ; rax = length of header
    pop     rdi

    mov     rdx, rax                    ; length
    mov     rax, SYS_WRITE
    mov     rdi, rbx                    ; fd
    lea     rsi, [rel worklog_header]   ; buffer
    syscall

    ; Fall through to close

.init_close_ok:
    ; Close the file
    mov     rax, SYS_CLOSE
    mov     rdi, rbx
    syscall

    ; Return success
    xor     rax, rax                    ; return 0

.init_done:
    add     rsp, 144                    ; deallocate stat struct
    pop     r12
    pop     rbx
    pop     rbp
    ret

.init_close_error:
    ; Close fd before returning error
    mov     rax, SYS_CLOSE
    mov     rdi, rbx
    syscall

.init_error:
    mov     rax, -1                     ; return -1
    jmp     .init_done


; ============================================================================
; worklog_read_context — Read last MAX_CONTEXT_ENTRIES entries into buffer
; ============================================================================
; Opens the worklog, mmaps it, reverse-scans for '## [' patterns,
; and copies the last 20 entries into worklog_buf for the LLM context.
;
; Args:    none
; Returns: rax = number of bytes placed in worklog_buf (0 on error/empty)
; Clobbers: rax, rdi, rsi, rdx, r10, r8, r9
; ============================================================================
worklog_read_context:
    push    rbp
    mov     rbp, rsp
    push    rbx                         ; rbx = fd
    push    r12                         ; r12 = mmap base address
    push    r13                         ; r13 = file size
    push    r14                         ; r14 = tail start offset
    push    r15                         ; r15 = tail length
    sub     rsp, 144                    ; stat struct on stack

    ; ------------------------------------------------------------------
    ; Open worklog file for reading
    ; ------------------------------------------------------------------
    mov     rax, SYS_OPEN
    lea     rdi, [rel worklog_path]
    mov     rsi, O_RDONLY
    xor     rdx, rdx                    ; mode ignored for O_RDONLY
    syscall

    test    rax, rax
    js      .read_ctx_zero              ; open failed → return 0

    mov     rbx, rax                    ; rbx = fd

    ; ------------------------------------------------------------------
    ; fstat to get file size
    ; ------------------------------------------------------------------
    mov     rax, SYS_FSTAT
    mov     rdi, rbx
    lea     rsi, [rsp]
    syscall

    test    rax, rax
    js      .read_ctx_close_zero

    mov     r13, [rsp + STAT_SIZE]      ; r13 = file size (st_size)
    test    r13, r13
    jz      .read_ctx_close_zero        ; empty file → return 0

    ; ------------------------------------------------------------------
    ; mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0)
    ; ------------------------------------------------------------------
    mov     rax, SYS_MMAP
    xor     rdi, rdi                    ; addr = NULL (let kernel choose)
    mov     rsi, r13                    ; length = file size
    mov     rdx, PROT_READ              ; prot = PROT_READ
    mov     r10, MAP_PRIVATE            ; flags = MAP_PRIVATE
    mov     r8,  rbx                    ; fd
    xor     r9,  r9                     ; offset = 0
    syscall

    ; Check for mmap error (returns -1 on failure, or addr > 0xFFFF...)
    cmp     rax, -4096
    ja      .read_ctx_close_zero        ; mmap failed

    mov     r12, rax                    ; r12 = mmap base address

    ; ------------------------------------------------------------------
    ; Close fd now — we have the mmap, don't need the fd anymore
    ; ------------------------------------------------------------------
    push    rax                         ; preserve mmap addr (already in r12)
    mov     rax, SYS_CLOSE
    mov     rdi, rbx
    syscall
    pop     rax

    ; ------------------------------------------------------------------
    ; Reverse scan for '>> [' pattern (0x3E 0x3E 0x20 0x5B)
    ; Count up to MAX_CONTEXT_ENTRIES occurrences from the end
    ; ------------------------------------------------------------------
    ; r12 = base, r13 = size
    ; We scan backwards from (base + size - 4) looking for the 4-byte pattern
    xor     ecx, ecx                    ; ecx = entry count
    mov     r14, 0                      ; r14 = tail_start (default: beginning)

    ; We need at least 4 bytes to check the pattern
    cmp     r13, 4
    jb      .read_ctx_no_entries

    lea     rdi, [r12 + r13 - 4]        ; rdi = last possible position for 4-byte match

.scan_loop:
    cmp     rdi, r12                    ; have we reached the start?
    jb      .scan_done                  ; yes, done scanning

    ; Check for '>> [' pattern: 0x3E, 0x3E, 0x20, 0x5B
    cmp     byte [rdi],   0x3E          ; '>'
    jne     .scan_next
    cmp     byte [rdi+1], 0x3E          ; '>'
    jne     .scan_next
    cmp     byte [rdi+2], 0x20          ; ' '
    jne     .scan_next
    cmp     byte [rdi+3], 0x5B          ; '['
    jne     .scan_next

    ; Found a match!
    inc     ecx                         ; count++
    mov     r14, rdi                    ; update tail_start to this position
    sub     r14, r12                    ; r14 = offset from base

    cmp     ecx, 20                       ; found enough entries? (was MAX_CONTEXT_ENTRIES)
    jge     .scan_done

.scan_next:
    dec     rdi                         ; move backwards one byte
    jmp     .scan_loop

.scan_done:
.read_ctx_no_entries:
    ; ------------------------------------------------------------------
    ; Calculate tail region to copy
    ; r14 = tail_start offset (from base)
    ; tail_len = min(file_size - tail_start, WORKLOG_BUF_SZ - 1)
    ; ------------------------------------------------------------------
    mov     r15, r13                    ; r15 = file_size
    sub     r15, r14                    ; r15 = tail_len = size - tail_start

    ; Clamp to WORKLOG_CTX_MAX (12KB) to keep API payload small
    mov     rax, WORKLOG_CTX_MAX
    cmp     r15, rax
    jbe     .tail_len_ok
    mov     r15, rax                    ; clamp

.tail_len_ok:
    ; ------------------------------------------------------------------
    ; Copy tail_len bytes from mmap+tail_start to worklog_buf
    ; ------------------------------------------------------------------
    lea     rsi, [r12 + r14]            ; source = mmap_base + tail_start
    lea     rdi, [rel worklog_buf]      ; dest   = worklog_buf
    mov     rcx, r15                    ; count  = tail_len
    rep     movsb                       ; copy bytes

    ; Null-terminate
    lea     rdi, [rel worklog_buf]
    mov     byte [rdi + r15], 0         ; worklog_buf[tail_len] = '\0'

    ; Store context length
    mov     [rel worklog_ctx_len], r15

    ; ------------------------------------------------------------------
    ; munmap(base, size)
    ; ------------------------------------------------------------------
    mov     rax, SYS_MUNMAP
    mov     rdi, r12                    ; addr = mmap base
    mov     rsi, r13                    ; length = file size
    syscall

    ; Return tail_len
    mov     rax, r15

.read_ctx_done:
    add     rsp, 144
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

.read_ctx_close_zero:
    ; Close fd and return 0
    mov     rax, SYS_CLOSE
    mov     rdi, rbx
    syscall

.read_ctx_zero:
    xor     rax, rax                    ; return 0
    jmp     .read_ctx_done


; ============================================================================
; worklog_append_raw — Append raw bytes to the worklog file
; ============================================================================
; Opens the worklog in append mode, writes the given bytes, closes.
;
; Args:    rdi = pointer to text data
;          rsi = length of data
; Returns: rax = bytes written (or negative errno on error)
; Clobbers: rax, rdi, rsi, rdx
; ============================================================================
worklog_append_raw:
    push    rbp
    mov     rbp, rsp
    push    rbx                         ; rbx = fd
    push    r12                         ; r12 = text pointer
    push    r13                         ; r13 = text length
    push    r14                         ; r14 = write result

    mov     r12, rdi                    ; save text pointer
    mov     r13, rsi                    ; save text length

    ; ------------------------------------------------------------------
    ; Open worklog: O_WRONLY | O_CREAT | O_APPEND
    ; ------------------------------------------------------------------
    mov     rax, SYS_OPEN
    lea     rdi, [rel worklog_path]
    mov     rsi, O_WRONLY | O_CREAT | O_APPEND
    mov     rdx, FILE_MODE
    syscall

    test    rax, rax
    js      .raw_error                  ; open failed

    mov     rbx, rax                    ; rbx = fd

    ; ------------------------------------------------------------------
    ; Write data
    ; ------------------------------------------------------------------
    mov     rax, SYS_WRITE
    mov     rdi, rbx                    ; fd
    mov     rsi, r12                    ; buffer
    mov     rdx, r13                    ; length
    syscall

    mov     r14, rax                    ; save write result

    ; ------------------------------------------------------------------
    ; Close file
    ; ------------------------------------------------------------------
    mov     rax, SYS_CLOSE
    mov     rdi, rbx
    syscall

    mov     rax, r14                    ; return write result

.raw_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

.raw_error:
    ; rax already has negative errno
    jmp     .raw_done


; ============================================================================
; worklog_append_entry — Append a formatted timestamped entry
; ============================================================================
; Builds a formatted worklog entry in temp_buf and appends it:
;
;   \n---\n## [TIMESTAMP] TYPE_LABEL\nCONTENT\n
;
; Args:    rdi = type_label pointer (null-terminated, e.g. "THOUGHT")
;          rsi = content pointer   (null-terminated)
; Returns: rax = bytes written (from worklog_append_raw)
; Clobbers: rax, rdi, rsi, rdx, rcx
; ============================================================================
worklog_append_entry:
    push    rbp
    mov     rbp, rsp
    push    rbx                         ; rbx = running write pointer
    push    r12                         ; r12 = type_label
    push    r13                         ; r13 = content
    push    r14                         ; r14 = temp_buf base (for length calc)
    push    r15                         ; r15 = temp_buf write limit
    sub     rsp, 8                      ; keep stack 16-byte aligned before calls

    ; Save arguments in callee-saved registers
    mov     r12, rdi                    ; r12 = type_label
    mov     r13, rsi                    ; r13 = content

    ; ------------------------------------------------------------------
    ; Get timestamp first
    ; ------------------------------------------------------------------
    lea     rdi, [rel timestamp_buf]
    call    get_timestamp               ; fills timestamp_buf with ISO timestamp

    ; ------------------------------------------------------------------
    ; Build formatted entry in temp_buf
    ; We keep rbx as a running pointer into temp_buf
    ; ------------------------------------------------------------------
    lea     rbx, [rel temp_buf]         ; rbx = write cursor
    lea     r14, [rel temp_buf]         ; r14 = base for length calculation
    lea     r15, [rel temp_buf]
    add     r15, TEMP_BUF_SZ - 2        ; reserve room for newline/null safety

    ; (a) Copy wl_separator: '\n---\n'
    lea     rsi, [rel wl_separator]
    mov     rdi, rbx
    call    .copy_str                   ; returns updated rbx

    ; (b) Copy '## ['
    lea     rsi, [rel wl_hdr_open]
    mov     rdi, rbx
    call    .copy_str

    ; (c) Copy timestamp
    lea     rsi, [rel timestamp_buf]
    mov     rdi, rbx
    call    .copy_str

    ; (d) Copy '] '
    lea     rsi, [rel wl_hdr_close]
    mov     rdi, rbx
    call    .copy_str

    ; (e) Copy type_label
    mov     rsi, r12
    mov     rdi, rbx
    call    .copy_str

    ; (f) Copy newline
    cmp     rbx, r15
    jae     .skip_newline_after_type
    mov     byte [rbx], 10              ; '\n'
    inc     rbx
.skip_newline_after_type:

    ; (g) Copy content
    mov     rsi, r13
    mov     rdi, rbx
    call    .copy_str

    ; (h) Copy trailing newline
    cmp     rbx, r15
    jae     .skip_trailing_newline
    mov     byte [rbx], 10              ; '\n'
    inc     rbx
.skip_trailing_newline:

    ; ------------------------------------------------------------------
    ; Calculate total length and call worklog_append_raw
    ; ------------------------------------------------------------------
    mov     rsi, rbx
    sub     rsi, r14                    ; rsi = total length (rbx - temp_buf base)

    lea     rdi, [rel temp_buf]         ; rdi = text pointer
    call    worklog_append_raw          ; write to file

    ; Return value from worklog_append_raw is already in rax

    ; ------------------------------------------------------------------
    ; Check if worklog needs archiving (file too large)
    ; ------------------------------------------------------------------
    push    rax                         ; preserve return value
    call    worklog_maybe_archive
    pop     rax                         ; restore return value

    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================================
; .copy_str — Internal helper: copy null-terminated string
; ============================================================================
; Copies bytes from rsi to rdi until null terminator.
; Updates rbx to point past the last byte written.
;
; Args:    rsi = source (null-terminated)
;          rdi = destination (rbx, the running cursor)
; Returns: rbx = updated write cursor (past last byte written)
; Clobbers: al, rsi
; Note:    This is a local helper, not exported.
; ============================================================================
.copy_str:
    ; rdi is the destination (= rbx, our running pointer)
    ; rsi is the source string
    ; We copy bytes from [rsi] to [rbx], advancing both
.copy_loop:
    cmp     rbx, r15
    jae     .copy_done
    lodsb                               ; al = [rsi], rsi++
    test    al, al                      ; null terminator?
    jz      .copy_done
    mov     [rbx], al                   ; store byte
    inc     rbx                         ; advance write cursor
    jmp     .copy_loop
.copy_done:
    ret


; ============================================================================
; worklog_maybe_archive — Archive old worklog entries if file too large
; ============================================================================
; If WORKLOG.md exceeds WORKLOG_FILE_MAX (48KB), this function:
;   1. Creates "memory/" directory if it doesn't exist
;   2. Finds next available archive number (memory/archive_001.md, etc.)
;   3. Moves old content (first half) to the archive file
;   4. Rewrites WORKLOG.md with only the recent half
;
; This keeps the worklog file small so API payloads stay manageable.
;
; Args:    none
; Returns: nothing (best-effort, errors silently ignored)
; Clobbers: all caller-saved registers
; ============================================================================
worklog_maybe_archive:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 144                   ; stat struct

    ; ------------------------------------------------------------------
    ; 1. fstat WORKLOG.md to get file size
    ; ------------------------------------------------------------------
    mov     rax, SYS_OPEN
    lea     rdi, [rel worklog_path]
    mov     rsi, O_RDONLY
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .archive_done               ; can't open, skip
    mov     rbx, rax                    ; rbx = fd

    mov     rax, SYS_FSTAT
    mov     rdi, rbx
    lea     rsi, [rsp]
    syscall
    test    rax, rax
    js      .archive_close_done

    mov     rax, [rsp + STAT_SIZE]      ; rax = file size
    cmp     rax, WORKLOG_FILE_MAX
    jb      .archive_close_done         ; file small enough, skip

    mov     r13, rax                    ; r13 = file_size

    ; ------------------------------------------------------------------
    ; 2. mmap the file for reading
    ; ------------------------------------------------------------------
    mov     rax, SYS_MMAP
    xor     rdi, rdi
    mov     rsi, r13
    mov     rdx, PROT_READ
    mov     r10, MAP_PRIVATE
    mov     r8,  rbx
    xor     r9,  r9
    syscall
    cmp     rax, -4096
    ja      .archive_close_done
    mov     r12, rax                    ; r12 = mmap base

    ; Close fd (we have mmap)
    mov     rax, SYS_CLOSE
    mov     rdi, rbx
    syscall

    ; ------------------------------------------------------------------
    ; 3. Create memory/ directory (ignore EEXIST)
    ; ------------------------------------------------------------------
    mov     rax, SYS_MKDIR
    lea     rdi, [rel memory_dir]
    mov     rsi, FILE_MODE | 0o111       ; 0755
    syscall                             ; ignore error (may already exist)

    ; ------------------------------------------------------------------
    ; 4. Find split point: scan for '>> [' from midpoint
    ;    We keep the last ~24KB and archive the rest
    ; ------------------------------------------------------------------
    mov     rax, r13
    shr     rax, 1                       ; midpoint
    mov     r14, rax                    ; r14 = split offset (default: midpoint)

    ; Scan forward from midpoint to find next '>> [' entry boundary
    cmp     r13, 4
    jb      .archive_no_split

    lea     rdi, [r12 + r14]            ; start scanning from midpoint
    mov     rcx, r13
    sub     rcx, r14
    sub     rcx, 3                      ; need at least 4 bytes
    jb      .archive_no_split

.find_entry:
    cmp     rcx, 0
    je      .archive_no_split
    cmp     byte [rdi],   0x3E          ; '>'
    jne     .find_next
    cmp     byte [rdi+1], 0x3E          ; '>'
    jne     .find_next
    cmp     byte [rdi+2], 0x20          ; ' '
    jne     .find_next
    cmp     byte [rdi+3], 0x5B          ; '['
    jne     .find_next
    ; Found entry boundary!
    mov     r14, rdi
    sub     r14, r12                    ; r14 = split offset
    jmp     .found_split

.find_next:
    inc     rdi
    dec     rcx
    jmp     .find_entry

.found_split:
.archive_no_split:
    ; r14 = byte offset where we split
    ; If r14 == 0, nothing to archive
    test    r14, r14
    jz      .archive_unmap

    ; ------------------------------------------------------------------
    ; 5. Find next archive number (001, 002, ...)
    ;    We use SYS_ACCESS to check if memory/archive_NNN.md exists
    ; ------------------------------------------------------------------
    xor     r15d, r15d                 ; r15d = archive number

.find_num_loop:
    ; Build path: memory/archive_NNN.md
    ; Use temp_buf for the path
    lea     rdi, [rel temp_buf]
    lea     rsi, [rel archive_prefix]
    call    .quick_copy

    ; Append 3-digit number
    mov     eax, r15d
    ; Convert to 3-digit decimal with zero padding
    lea     rdi, [rel temp_buf]
    call    str_len
    add     rdi, rax                    ; rdi -> end of prefix

    ; Hundreds digit
    xor     edx, edx
    mov     ecx, 100
    div     ecx                         ; eax = quotient, edx = remainder
    add     al, '0'
    mov     [rdi], al
    inc     rdi

    ; Tens digit
    mov     eax, edx
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    add     al, '0'
    mov     [rdi], al
    inc     rdi

    ; Ones digit
    add     dl, '0'
    mov     [rdi], dl
    inc     rdi

    ; Append .md
    lea     rsi, [rel archive_ext]
    call    .quick_copy_at             ; copy from rsi to rdi

    ; Null-terminate
    mov     byte [rdi], 0

    ; Check if file exists
    mov     rax, SYS_ACCESS
    lea     rdi, [rel temp_buf]
    mov     rsi, 0                      ; F_OK
    syscall
    test    rax, rax
    jz      .num_exists                 ; exists, try next
    jmp     .num_found

.num_exists:
    inc     r15d
    cmp     r15d, 999
    jb      .find_num_loop
    jmp     .archive_unmap              ; too many archives, give up

.num_found:
    ; temp_buf now has the archive path

    ; ------------------------------------------------------------------
    ; 6. Write old content (0..split_offset) to archive file
    ; ------------------------------------------------------------------
    mov     rax, SYS_OPEN
    lea     rdi, [rel temp_buf]
    mov     rsi, O_WRONLY | O_CREAT | O_TRUNC
    mov     rdx, FILE_MODE
    syscall
    test    rax, rax
    js      .archive_unmap
    mov     rbx, rax                    ; rbx = archive fd

    ; Write split_offset bytes from mmap
    mov     rax, SYS_WRITE
    mov     rdi, rbx
    mov     rsi, r12                    ; mmap base
    mov     rdx, r14                    ; length = split_offset
    syscall

    mov     rax, SYS_CLOSE
    mov     rdi, rbx
    syscall

    ; ------------------------------------------------------------------
    ; 7. Rewrite WORKLOG.md with only the recent content (split_offset..end)
    ; ------------------------------------------------------------------
    mov     rax, SYS_OPEN
    lea     rdi, [rel worklog_path]
    mov     rsi, O_WRONLY | O_CREAT | O_TRUNC
    mov     rdx, FILE_MODE
    syscall
    test    rax, rax
    js      .archive_unmap
    mov     rbx, rax

    ; Write header first
    lea     rdi, [rel worklog_header]
    call    str_len
    mov     rdx, rax
    mov     rax, SYS_WRITE
    mov     rdi, rbx
    lea     rsi, [rel worklog_header]
    syscall

    ; Write remaining content (from split_offset to end)
    mov     rax, r13
    sub     rax, r14                    ; remaining bytes
    test    rax, rax
    jz      .rewrite_done

    mov     rdx, rax                    ; length
    mov     rax, SYS_WRITE
    mov     rdi, rbx
    lea     rsi, [r12 + r14]           ; mmap + split_offset
    syscall

.rewrite_done:
    mov     rax, SYS_CLOSE
    mov     rdi, rbx
    syscall

.archive_unmap:
    ; munmap
    mov     rax, SYS_MUNMAP
    mov     rdi, r12
    mov     rsi, r13
    syscall
    jmp     .archive_done

.archive_close_done:
    mov     rax, SYS_CLOSE
    mov     rdi, rbx
    syscall

.archive_done:
    add     rsp, 144
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================================
; .quick_copy — Copy null-terminated string from rsi to rdi
; ============================================================================
.quick_copy:
    ; rdi = dest, rsi = src
.qc_loop:
    lodsb
    test    al, al
    jz      .qc_done
    mov     [rdi], al
    inc     rdi
    jmp     .qc_loop
.qc_done:
    ret

; ============================================================================
; .quick_copy_at — Copy null-terminated string, rdi is already at write pos
; ============================================================================
.quick_copy_at:
    ; rdi = dest (write position), rsi = src
.qca_loop:
    lodsb
    test    al, al
    jz      .qca_done
    mov     [rdi], al
    inc     rdi
    jmp     .qca_loop
.qca_done:
    ret
