# ASM-AGENT

[![Latest Release](https://img.shields.io/github/v/release/kelvinzer0/asm-agent?style=flat-square)](https://github.com/kelvinzer0/asm-agent/releases/latest)
[![Release CI](https://img.shields.io/github/actions/workflow/status/kelvinzer0/asm-agent/release.yml?style=flat-square)](https://github.com/kelvinzer0/asm-agent/actions)
[![Size](https://img.shields.io/github/size/kelvinzer0/asm-agent/asm-agent?style=flat-square&label=binary)](https://github.com/kelvinzer0/asm-agent/releases/latest)

Autonomous AI coding agent written entirely in **x86-64 NASM assembly**. No libc, no runtime dependencies — a single static ELF64 binary that calls an LLM API and executes shell commands in a tool-call loop.

## Features

- Pure x86-64 assembly — ~6,900 lines of NASM
- Zero dependencies (statically linked, no libc)
- Tool-call agentic loop: `run_command` + `task_complete`
- SSE streaming response parsing
- JSON payload construction entirely in assembly
- Built-in worklog with ANSI UI
- Plugin-aware system prompt design

## Quick Install (Latest Release)

```bash
curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/master/install.sh | bash
```

That's it. The installer will:

1. Fetch the latest release from GitHub
2. Verify SHA-256 checksum
3. Install `asm-agent` to `/usr/local/bin`
4. Create `~/.asm-agent.env` for your API key

### Install a Specific Version

```bash
curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/master/install.sh | bash -s -- --version v0.1.1
```

### Custom Install Prefix

```bash
curl -sSL https://raw.githubusercontent.com/kelvinzer0/asm-agent/master/install.sh | bash -s -- --prefix $HOME/.local
```

## Setup

After installing, set your API key:

```bash
export ASM_AGENT_API_KEY="sk-your-api-key-here"
```

Or edit `~/.asm-agent.env` — it gets auto-sourced from `.bashrc`/`.zshrc`.

## Usage

```bash
asm-agent "Create a hello world Python script at /tmp/hello.py"
```

The agent will autonomously:
1. Send your task to the LLM API
2. Receive tool-call instructions
3. Execute shell commands
4. Loop until the task is complete

## Build from Source

Requires [NASM](https://www.nasm.us/) 2.16+ and `ld` (binutils).

```bash
git clone https://github.com/kelvinzer0/asm-agent.git
cd asm-agent

# If system nasm is available, symlink it:
ln -sf $(which nasm) ./nasm

make          # release build (stripped)
make debug    # debug build (DWARF symbols)
```

## Configuration

The binary reads these environment variables:

| Variable | Description | Default |
|---|---|---|
| `ASM_AGENT_API_KEY` | API key for the LLM service | Falls back to `OPENAI_API_KEY` |

API endpoint, model, and system prompt are compiled into `include/config.inc`.

## Release

Tags trigger automatic builds via GitHub Actions:

```bash
git tag v0.2.0
git push origin v0.2.0
```

This builds the binary on Ubuntu, creates a GitHub Release with:
- `asm-agent` — standalone ELF64 binary
- `asm-agent-vX.Y.Z-linux-x86_64.tar.gz` — tarball with binary + installer
- `checksums.sha256` — SHA-256 checksums

## License

MIT