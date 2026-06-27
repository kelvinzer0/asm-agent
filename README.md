# ASM-AGENT

[![Release Build](https://github.com/kelvinzer0/asm-agent/actions/workflows/release.yml/badge.svg)](https://github.com/kelvinzer0/asm-agent/actions/workflows/release.yml)
[![Latest Release](https://img.shields.io/github/v/release/kelvinzer0/asm-agent?color=green&label=release)](https://github.com/kelvinzer0/asm-agent/releases/latest)

**Autonomous AI Agent — written entirely in x86-64 NASM assembly.**

ASM-AGENT is a zero-dependency, statically-linked Linux binary that implements an autonomous AI agent loop compatible with the OpenAI Chat Completions API. It parses structured responses, executes shell commands via [VisiBox](https://github.com/kelvinzer0/visibox), maintains a worklog context, and iterates until the task is complete — all in ~100KB of machine code.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/master/install.sh | bash
```

Installs to `/usr/local/bin/` by default. The installer will prompt you for:
- **API key** (hidden input, stored in `~/.asm-agent.env` with `chmod 600`)
- **API endpoint URL** (default: Cloudflare Workers AI)
- **Model name** (default: LLaMA 3.1 8B FP8)

After install:

```bash
asm-agent-run "List all files in /tmp and summarize them"
```

`asm-agent-run` auto-sources `~/.asm-agent.env` and sets up visibox symlinks in your working directory.

### Non-interactive install

```bash
curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/master/install.sh | bash -s -- --api-key=sk-xxx
```

```bash
# Full options (--api-url auto-appends /chat/completions if missing)
curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/master/install.sh | bash -s -- \
  --api-key=sk-xxx \
  --api-url=https://api.openai.com/v1 \
  --model=gpt-4o
```

### Custom prefix

```bash
bash install.sh --prefix=/opt
# Installs to /opt/bin/asm-agent, /opt/lib/asm-agent/...
```

### Build from source

```bash
git clone https://github.com/kelvinzer0/asm-agent.git
cd asm-agent
make
```

> Requires: NASM ≥ 2.15, binutils (ld), make, curl

## Usage

```bash
# Interactive mode (auto-sources ~/.asm-agent.env)
asm-agent-run

# Single task
asm-agent-run "Create a Python script that prints hello world"

# Direct binary (env vars must be set manually)
source ~/.asm-agent.env
asm-agent "your task"
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ASM_AGENT_API_KEY` | **Yes** | API key (checked first) |
| `OPENAI_API_KEY` | **Yes** | Fallback API key (used if `ASM_AGENT_API_KEY` not set) |
| `ASM_AGENT_API_URL` | No | Override API endpoint URL |
| `ASM_AGENT_MODEL` | No | Override model name |

> One of the two API key variables is required. URL and model fall back to compiled-in defaults if not set. The installer writes these to `~/.asm-agent.env` for you.

**Examples:**
```bash
# Use OpenAI
export ASM_AGENT_API_KEY="sk-..."
export ASM_AGENT_API_URL="https://api.openai.com/v1/chat/completions"
export ASM_AGENT_MODEL="gpt-4o"
asm-agent "your task"

# Or via installer (one-liner) — URL auto-appends /chat/completions
curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/master/install.sh | bash -s -- \
  --api-key=sk-xxx \
  --api-url=https://api.openai.com/v1 \
  --model=gpt-4o
asm-agent-run "your task"
```

## Features

- **Pure x86-64 Assembly** — NASM, Linux syscalls, no libc, no runtime dependencies
- **VisiBox-Only Execution** — [VisiBox](https://github.com/kelvinzer0/visibox) v0.3.0 is the sole command execution engine. No `/bin/sh` fallback.
- **OpenAI-Compatible API** — Works with any `/v1/chat/completions` endpoint (OpenAI, Cloudflare Workers AI, Ollama, LM Studio, etc.)
- **Tool Calling** — Built-in tools: `EXEC`, `FETCH_PAGE`, `SEARCH`, `SESSION`, `DONE`
- **Swarm/Orchestration Modes** — LangGraph-style multi-agent mode switching (Planner, Researcher, Executor, Verifier)
- **Checkpoint/Recovery** — State persistence for agent restart recovery
- **Interactive TUI** — Colored real-time status, ASCII art banner
- **Worklog** — Persistent Markdown worklog with full execution history

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    main.asm                          │
│              (TUI + Agent Loop)                      │
├──────────┬──────────┬───────────┬───────────────────┤
│parser.asm│tool_exec │api.asm    │conductor.asm      │
│(response │.asm      │(HTTP/JSON │(musical tempo +   │
│ parsing) │(VisiBox  │ payload)  │ orchestration)    │
│          │ execute) │           │                   │
├──────────┴──────────┴───────────┴───────────────────┤
│ json.asm │ strings.asm │ timestamp.asm │ worklog.asm│
│ channels.asm │ instruments.asm │ signals.asm │      │
│ checkpoint.asm │ orchestration.asm                   │
└─────────────────────────────────────────────────────┘
         │
    ┌────┴────┐
    │ VisiBox │  (REQUIRED — JSON command execution)
    │  v0.3.0 │
    └─────────┘
```

## Tools

| Tool | Prefix | Description |
|------|--------|-------------|
| `EXEC` | `EXEC: <cmd>` or `<tool_call>` tags | Execute shell commands via VisiBox JSON protocol |
| `FETCH_PAGE` | `FETCH_PAGE:` | Get next page of truncated command output |
| `SEARCH` | `SEARCH: <keyword>` | Jump to output page containing a keyword |
| `SESSION` | `SESSION: <cmd>` | Run command in persistent shell (cd, env, alias preserved) |
| `DONE` | `DONE: <summary>` | Signal that the task is complete |

### Command Execution

All commands are executed via VisiBox JSON pipe protocol:

```json
{"type": "execute", "command": "ls -la /tmp"}
```

Response:
```json
{"exit_code": 0, "output": "...", "output_truncated": false, "duration_ms": 42}
```

VisiBox is **required**. If `./bin/visibox` is not found, the agent exits with an error.

### Safety

Dangerous commands are blocked:
- `rm -rf /`, `mkfs`, `shutdown`, `reboot`, `dd if=/dev/zero`
- `:(){ :|:& };:` (fork bomb pattern)
- Commands targeting `/boot`, `/dev/sd*`, `/proc/kcore`

## Orchestration Modes

| Mode | Role |
|------|------|
| **Planner** | Decomposes tasks into subtasks |
| **Researcher** | Discovers the environment |
| **Executor** | Executes commands to complete the task |
| **Verifier** | Verifies task completion |

Mode switching is triggered by `HANDOFF: <MODE>` in the LLM response.

## Source Files

| File | Description |
|------|-------------|
| `src/main.asm` | Entry point, TUI, agent loop, tool dispatch |
| `src/parser.asm` | Response parsing (EXEC/THINK/DONE/FETCH_PAGE/SEARCH/SESSION) |
| `src/executor.asm` | Command safety filter + VisiBox execution |
| `src/visibox_client.asm` | VisiBox JSON protocol layer (send/recv, parse, build) |
| `src/tool_exec.asm` | EXEC tool handler |
| `src/tool_fetch_page.asm` | FETCH_PAGE tool handler (cursor-based pagination) |
| `src/tool_search.asm` | SEARCH tool handler (keyword search_jump) |
| `src/tool_session.asm` | SESSION tool handler (persistent shell) |
| `src/api.asm` | HTTP API calls via curl, JSON payload building |
| `src/conductor.asm` | Musical tempo/dynamics modulation, orchestration |
| `src/json.asm` | JSON construction helpers |
| `src/strings.asm` | String operations (copy, concat, find, escape) |
| `src/timestamp.asm` | ISO 8601 timestamp generation |
| `src/worklog.asm` | Worklog read/write/trim |
| `src/signals.asm` | Signal handling (SIGINT, SIGPIPE, SIGCHLD) |
| `src/channels.asm` | Multi-channel output routing |
| `src/instruments.asm` | Instrument state management |
| `src/checkpoint.asm` | State persistence for recovery |
| `src/orchestration.asm` | Swarm/LangGraph mode definitions |
| `include/constants.inc` | Syscall numbers, buffer sizes, limits |
| `include/config.inc` | API config, prompts, templates |
| `include/macros.inc` | NASM macros |
| `include/musical.inc` | Musical state constants |
| `include/orchestration.inc` | Orchestration mode data |

## Binary Size

| Component | Size |
|-----------|------|
| `asm-agent` (stripped) | ~100 KB |
| `bin/visibox` | ~1.4 MB |
| **Total** | ~1.5 MB |

## Requirements

- **Runtime**: Linux x86-64, curl
- **VisiBox**: v0.3.0 (bundled with installer and release tarball)
- **Build** (from source only): NASM ≥ 2.15, binutils (ld), make
- **Install**: write permission to `${PREFIX}/bin` and `${PREFIX}/lib/` (default: `/usr/local`)

## Installed Files

| Path | Description |
|------|-------------|
| `/usr/local/bin/asm-agent` | Main binary |
| `/usr/local/bin/asm-agent-run` | Wrapper (auto-sources env, sets up visibox) |
| `/usr/local/lib/asm-agent/bin/visibox` | VisiBox execution engine |
| `/usr/local/lib/asm-agent/config/visibox.conf` | VisiBox configuration |
| `~/.asm-agent.env` | API key, URL, model (chmod 600) |

## License

MIT

## Links

- [Releases](https://github.com/kelvinzer0/asm-agent/releases)
- [VisiBox](https://github.com/kelvinzer0/visibox) — Structured command execution engine
- [NASM Documentation](https://www.nasm.us/doc/)