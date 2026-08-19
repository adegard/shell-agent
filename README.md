# shell-agent

Local coding assistant for **Termux on Android**. Opencode-style workflow powered by Ollama — reads, writes, searches, builds, and tests code entirely on your phone. No cloud APIs, no internet needed after setup.

Inspired by [opencode](https://opencode.ai) — brings the same agent loop to your terminal.

## One-line install (Termux)

Paste this into Termux:

```bash
pkg update -y && pkg install -y git && git clone https://github.com/adegard/shell-agent.git && bash shell-agent/setup-termux.sh
```

That's it. It installs Ollama, pulls a coding model, and sets up the agent.

## After install

```bash
source ~/.bashrc

# Single prompt:
agent "write a fizzbuzz in python"

# Interactive mode:
agent

# Fresh session (skip old context):
agent --fresh
```

## Choose your model

The default model is `qwen2.5-coder:1.5b` (~1 GB). Pick based on your phone's RAM:

| RAM | Command | Size |
|-----|---------|------|
| 2-3 GB | `bash setup-termux.sh` | ~1 GB |
| 4-6 GB | `bash setup-termux.sh qwen2.5-coder:3b` | ~2 GB |
| 8+ GB | `bash setup-termux.sh qwen2.5-coder:7b` | ~4.4 GB |

To switch later:

```bash
ollama pull qwen2.5-coder:3b
export OLLAMA_MODEL=qwen2.5-coder:3b
# Add to ~/.bashrc to persist
```

## What it does

Same core loop as opencode — LLM thinks, calls tools, gets results, repeats:

| Feature | Tool | Description |
|---|---|---|
| Read files | `read_file` | Read any file |
| Write/create files | `write_file` | Create or overwrite files |
| Edit files | `edit_file` | Find & replace in files |
| Search code | `search_files` | Grep across project |
| Find files | `glob_files` | Pattern matching |
| Run commands | `bash_exec` | Build, test, git, curl, etc. |
| List directories | `list_dir` | Browse project structure |
| Fetch web pages | `web_fetch` | curl URLs for docs/APIs |
| Track tasks | `todowrite` | Todo list for complex tasks |

## Agents (like opencode)

Switch between **build** and **plan** mode during a session:

| Mode | What it does |
|---|---|
| **Build** (default) | Full access — read, write, edit, run commands |
| **Plan** | Read-only — analyzes code, suggests changes, no modifications |

Toggle with `/plan` command. In plan mode, write/edit/bash tools are blocked.

## Session management

The agent remembers your conversation across turns:

| Command | What it does |
|---|---|
| `/clear` or `/fresh` | Start a fresh session |
| `/plan` | Toggle between build and plan mode |
| `/undo` | Restore previous session state |
| `/history` | Show current context messages |
| `/restart` | Restart Ollama server |
| `quit` / `exit` | Exit the agent |

- Sessions auto-save to `~/.shell-agent/session.json`
- Previous session resumes automatically on startup
- Use `--fresh` flag or `/fresh` command to skip old sessions
- Context auto-compacts when it gets too long (keeps system + last 6 messages)

## Interactive commands

```
agent                           # Start interactive session
agent "do something"            # Single prompt, then exit
agent --fresh                   # Start fresh (ignore saved session)
agent -m qwen2.5-coder:0.5b    # Use a different model
agent --test                    # Test Ollama connection
agent --debug                   # Show debug output
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_HOST` | `http://127.0.0.1:11434` | Ollama server URL |
| `OLLAMA_MODEL` | `qwen2.5-coder:1.5b` | Model to use |
| `WORKSPACE` | current dir | Working directory |
| `DEBUG` | `0` | Set to `1` for verbose output |

## Useful commands

```bash
ollama serve &          # Start Ollama (auto-starts on boot after install)
ollama pull <model>     # Download a different model
ollama list             # List installed models
agent                   # Start interactive coding session
```

## How it works

```
agent.sh                 Main loop — reads input, calls Ollama, dispatches tools
├── lib/config.sh        Settings, colors, paths
├── lib/ollama.sh        Ollama API, tool-call parsing, session persistence, compaction
└── tools/               Each tool is a standalone bash function
    ├── read_file.sh
    ├── write_file.sh
    ├── edit_file.sh
    ├── search_files.sh
    ├── glob_files.sh
    ├── bash_exec.sh
    ├── list_dir.sh
    ├── web_fetch.sh
    └── todowrite.sh
```

## Requirements

- [Termux](https://f-droid.org/en/packages/com.termux/) (install from F-Droid, not Play Store)
- ~2 GB free storage (for Ollama + model)
- 2+ GB RAM (8 GB recommended for bigger models)

## License

MIT
