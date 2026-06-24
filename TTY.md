# asm-agent [PID: 8410]

## Task
Edit include/config.inc. Find the tools_json db line that starts with: db ","tools":[{"type":"function"... Before the closing ]} of the tools array, add two new tool definitions:

1. github_search: description "Search GitHub for code, repos, or issues. Returns top 5 results.", parameters: query (string, required, "the search query"), type (string, optional, enum ["code","repositories","issues"], "search type")

2. github_read: description "Read a file from a GitHub repo. Returns raw content up to 8000 bytes.", parameters: owner (string, required), repo (string, required), path (string, required), branch (string, optional, default "main")

Use sed to insert before the closing ]} in tools_json. Then run: make clean && make && git add -A && git commit -m "feat: add github_search and github_read tool definitions" && git push.
---
[1] 2026-06-24T07:04:22 THINK | cat /home/z/my-project/asm-agent/include/config.inc
[2] 2026-06-24T07:04:34 THINK | cd /home/z/my-project/asm-agent && git status
[3] 2026-06-24T07:04:49 THINK | cd /home/z/my-project/asm-agent && git log --oneline -5
[4] 2026-06-24T07:04:58 THINK | cd /home/z/my-project/asm-agent && grep -o '"github_search"[^}]*}' include/config.inc | head -1
[5] 2026-06-24T07:05:08 THINK | cd /home/z/my-project/asm-agent && git diff include/config.inc
[6] 2026-06-24T07:05:18 THINK | cd /home/z/my-project/asm-agent && grep -o '"github_read"[^}]*}' include/config.inc | head -1
[7] 2026-06-24T07:05:28 THINK | cd /home/z/my-project/asm-agent && make clean && make
