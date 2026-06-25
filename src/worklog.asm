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
global worklog_trim_context


; ============================================================================
section .rodata
; ============================================================================

; Local format strings for entry building
wl_hdr_open     db '>> [', 0           ; entry header open bracket
wl_hdr_close    db '] ', 0             ; close bracket + space
wl_newline      db 10, 0               ; single newline


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

    cmp     ecx, MAX_CONTEXT_ENTRIES    ; found enough entries?
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

    ; Clamp to WORKLOG_BUF_SZ - 1
    mov     rax, WORKLOG_BUF_SZ - 1
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

    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================================
; worklog_trim_context — Trim worklog_buf to fit within a byte budget
; ============================================================================
; Drops the oldest entries from worklog_buf by scanning forward for the
; '>> [' entry boundary pattern and shifting remaining content left.
; Repeats until worklog_ctx_len <= max_bytes or only one entry remains.
;
; Args:    rdi = max_bytes (target budget for worklog context)
; Returns: none (modifies worklog_buf and worklog_ctx_len in place)
; Clobbers: rax, rcx, rdi, rsi
; ============================================================================
worklog_trim_context:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     rbx, rdi                    ; rbx = max_bytes budget

.trim_loop:
    ; Check if current context already fits
    mov     rax, [rel worklog_ctx_len]
    cmp     rax, rbx
    jbe     .trim_done                  ; fits within budget → done

    ; Need to drop the oldest entry.
    ; Scan forward in worklog_buf for the NEXT '>> [' (0x3E 0x3E 0x20 0x5B)
    ; starting from byte index 1 (we skip the first entry's header).
    lea     r12, [rel worklog_buf]      ; r12 = base of worklog_buf

    mov     rax, [rel worklog_ctx_len]
    cmp     rax, 8                      ; need at least 8 bytes to find next entry
    jb      .trim_done                  ; too small to trim further

    ; rdi = scan pointer, rcx = bytes remaining to scan
    lea     rdi, [r12 + 1]             ; start at byte 1
    mov     rcx, rax
    sub     rcx, 4                      ; can't match 4-byte pattern in last 3 bytes

.forward_scan:
    cmp     rcx, 0
    jle     .trim_no_more               ; no more boundary found → give up

    cmp     byte [rdi],   0x3E          ; '>'
    jne     .fwd_next
    cmp     byte [rdi+1], 0x3E          ; '>'
    jne     .fwd_next
    cmp     byte [rdi+2], 0x20          ; ' '
    jne     .fwd_next
    cmp     byte [rdi+3], 0x5B          ; '['
    jne     .fwd_next

    ; Found next entry boundary!
    mov     r14, rdi
    sub     r14, r12                    ; r14 = byte offset of next entry
    jmp     .do_shift

.fwd_next:
    inc     rdi
    dec     rcx
    jmp     .forward_scan

.trim_no_more:
    ; Couldn't find another entry boundary.
    ; As a last resort, just truncate to max_bytes.
    mov     rax, rbx
    cmp     rax, [rel worklog_ctx_len]
    jae     .trim_done                  ; budget >= current, nothing to do
    mov     [rel worklog_ctx_len], rax
    lea     rdi, [r12 + rax]
    mov     byte [rdi], 0               ; null-terminate
    jmp     .trim_done

.do_shift:
    ; Calculate new length: old_length - offset_of_next_entry
    mov     r13, [rel worklog_ctx_len]
    sub     r13, r14                    ; r13 = bytes to keep (from next entry onward)

    ; Shift content left: [base + r14 .. base + old_len] → [base .. base + new_len]
    ; We must use a forward direction, but rep movsb with overlapping regions
    ; is safe when source (rsi) > dest (rdi), which is true here since r14 > 0.
    lea     rsi, [r12 + r14]            ; source = base + offset (further in memory)
    mov     rdi, r12                    ; dest   = base (earlier in memory)
    mov     rcx, r13                    ; count  = new length
    rep     movsb

    ; Null-terminate at new length
    lea     rdi, [r12 + r13]
    mov     byte [rdi], 0

    ; Update context length
    mov     [rel worklog_ctx_len], r13

    ; Loop back — check if still too large (may need to drop more entries)
    jmp     .trim_loop

.trim_done:
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
