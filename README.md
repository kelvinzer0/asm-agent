# ASM-AGENT

**Autonomous AI Agent — written entirely in x86-64 NASM assembly.**

ASM-AGENT is a zero-dependency, statically-linked Linux binary that implements an autonomous AI agent loop compatible with the OpenAI Chat Completions API. It parses structured responses, executes shell commands, maintains a worklog context, and iterates until the task is complete — all in ~60KB of machine code.

## Features

- **Pure x86-64 Assembly** — NASM, Linux System V ABI, no libc, no runtime dependencies
- **OpenAI-Compatible API** — Works with any `/v1/chat/completions` endpoint (OpenAI, Cloudflare Workers AI, Ollama, LM Studio, etc.)
- **Tool Calling** — 4 built-in tools: `run_command`, `task_complete`, `github_search`, `github_read`
- **VisiBox Integration** — Structured JSON command execution via [VisiBox](https://github.com/kelvinzer0/visibox) pipe protocol, with automatic fallback to `/bin/sh`
- **Swarm/Orchestration Modes** — LangGraph-style multi-agent mode switching (Planner → Researcher → Executor → Verifier)
- **Musical Conductor** — Tempo/dynamics modulation drives the agent loop rhythm
- **Checkpoint/Recovery** — State persistence for agent restart recovery
- **Auto-Pagination** — Handles large tool responses with `NEXT_PAGE` protocol
- **Interactive TUI** — Colored real-time status, ASCII art banner
- **Worklog** — Persistent Markdown worklog with full execution history

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    main.asm                          │
│              (TUI + Agent Loop)                      │
├──────────┬──────────┬───────────┬───────────────────┤
│parser.asm│executor  │api.asm    │conductor.asm      │
│(response │(command  │(HTTP/JSON │(musical tempo +   │
│ parsing) │ execution│ payload)  │ orchestration)    │
├──────────┴──────────┴───────────┴───────────────────┤
│ json.asm │ strings.asm │ timestamp.asm │ worklog.asm│
│ channels.asm │ instruments.asm │ signals.asm │      │
│ checkpoint.asm │ orchestration.asm                   │
└─────────────────────────────────────────────────────┘
         │
    ┌────┴────┐
    │ VisiBox │  (optional — structured JSON command I/O)
    │  v0.3.0 │
    └─────────┘
```

## Quick Start

### Prerequisites

- **Linux x86-64** (glibc or musl)
- **NASM** assembler (`nasm`)
- **LD** linker (`binutils`)
- **curl** (runtime dependency for API calls)

### Build

```bash
# Clone the repository
git clone https://github.com/kelvinzer0/asm-agent.git
cd asm-agent

# Build (downloads VisiBox automatically)
make

# Run
./asm-agent "List all files in /tmp and summarize them"
```

### One-Line Install

```bash
curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/master/install.sh | bash
```

Or with wget:

```bash
wget -qO- https://raw.githubusercontent.com/kelvinzer0/asm-agent/master/install.sh | bash
```

## Usage

### Interactive Mode

```bash
./asm-agent
# Enter your task when prompted
```

### Single-Task Mode

```bash
./asm-agent "Create a Python script that prints hello world"
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ASM_AGENT_API_KEY` | API key for authentication | (none) |
| `OPENAI_API_KEY` | Fallback API key | (none) |
| `ASM_AGENT_API_URL` | Override API endpoint URL | `https://router9.warunglakku.com/v1/chat/completions` |
| `ASM_AGENT_MODEL` | Override model name | `cf/@cf/meta/llama-3.1-8b-instruct-fp8-fast` |

### Makefile Targets

```bash
make            # Release build (stripped) + fetch VisiBox
make debug      # Debug build with DWARF symbols
make run        # Build and run immediately
make clean      # Remove all build artifacts
make visibox-clean  # Remove VisiBox binary only
```

## Tools

ASM-AGENT supports 4 tools in its system prompt:

| Tool | Description |
|------|-------------|
| `run_command` | Execute shell commands with structured JSON output (VisiBox) or raw output (sh) |
| `task_complete` | Signal that the task is done with a summary |
| `github_search` | Search GitHub repositories and code |
| `github_read` | Read file contents from GitHub repositories |

### Command Execution

When VisiBox is available (`./bin/visibox`), commands are executed via JSON pipe protocol:

```json
{"type": "execute", "command": "ls -la /tmp"}
```

Response:
```json
{"exit_code": 0, "output": "...", "output_truncated": false, "duration_ms": 42}
```

If VisiBox is not found, the agent falls back to `/bin/sh -c` with exit code extraction.

### Safety

Dangerous commands are blocked:
- `rm -rf /`, `mkfs`, `shutdown`, `reboot`, `dd if=/dev/zero`
- `:(){ :|:& };:` (fork bomb pattern)
- Commands targeting `/boot`, `/dev/sd*`, `/proc/kcore`

## Orchestration Modes

The agent supports Swarm/LangGraph-style multi-agent orchestration:

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
| `src/main.asm` | Entry point, TUI, agent loop |
| `src/parser.asm` | Response parsing (EXEC/THINK/DONE/NEXT_PAGE) |
| `src/executor.asm` | Command execution (VisiBox + sh fallback) |
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
| `asm-agent` (stripped) | ~60 KB |
| `bin/visibox` | ~1.4 MB |
| **Total** | ~1.5 MB |

## Requirements

- **Build**: NASM ≥ 2.15, binutils (ld), make, curl
- **Runtime**: Linux x86-64, curl
- **Optional**: VisiBox v0.3.0 (auto-downloaded by Makefile)

## License

MIT

## Links

- [Repository](https://github.com/kelvinzer0/asm-agent)
- [VisiBox](https://github.com/kelvinzer0/visibox) — Structured command execution wrapper
- [NASM Documentation](https://www.nasm.us/doc/)