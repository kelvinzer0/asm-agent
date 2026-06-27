#!/usr/bin/env python3
"""Fix config.inc: remove duplicate IMPORTANT section, fix duplicate label, fix indentation."""

path = '/home/z/my-project/asm-agent/include/config.inc'

with open(path, 'rb') as f:
    data = f.read()

# Convert to list of lines (preserving exact bytes)
lines = data.split(b'\n')

new_lines = []
skip_old_important = False
i = 0
while i < len(lines):
    line = lines[i]

    # Detect start of OLD IMPORTANT section
    # It starts with "    db 'IMPORTANT:', 10" right after the old FETCH_PAGE hint
    # The OLD section has "If output is truncated, reply FETCH_PAGE:" (without [truncated])
    # and ends with ", 0, 10, 10" on the last line
    if b"db 'IMPORTANT:', 10" in line and i > 0:
        prev = lines[i-1]
        if b'[truncated]' not in prev and b'FETCH_PAGE' in prev:
            skip_old_important = True

    if skip_old_important:
        if b', 0, 10, 10' in line:
            skip_old_important = False
            i += 1
            continue
        else:
            i += 1
            continue

    # Fix duplicate label
    if b'system_prompt_end:system_prompt_end:' in line:
        line = line.replace(b'system_prompt_end:system_prompt_end:', b'system_prompt_end:')

    # Fix indentation on "To execute a command:" line
    if line.startswith(b"db '  To execute a command:'"):
        line = b'    ' + line

    new_lines.append(line)
    i += 1

result = b'\n'.join(new_lines)

with open(path, 'wb') as f:
    f.write(result)

print(f"Fixed config.inc: {len(lines)} lines -> {len(new_lines)} lines")

# Verify
with open(path, 'rb') as f:
    verify = f.read()

if b'system_prompt_end:system_prompt_end:' in verify:
    print("ERROR: Duplicate label still present!")
else:
    print("OK: Duplicate label fixed")

count = verify.count(b"db 'IMPORTANT:', 10")
print(f"IMPORTANT sections: {count} (should be 1)")