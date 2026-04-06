# doubao-im-auto-send

**A macOS Swift CLI that listens for Doubao IME voice input completion and automatically sends `Enter` after text becomes stable, with an optional MiniMax CN refine step before sending.**

> Requirements: macOS, Doubao IME, and your terminal app must have both “Input Monitoring” and “Accessibility” permissions enabled.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/cleardusk/doubao-im-auto-send/main/install.sh | bash
```

If you prefer cloning first:

```bash
git clone --depth 1 https://github.com/cleardusk/doubao-im-auto-send.git && bash doubao-im-auto-send/install.sh
```

Inside the repository directory, you can also run:

```bash
bash install.sh
```

By default, it installs to `~/.local/bin/doubao-im-auto-send`. If that directory is not in your `PATH`, run it with the full path or add the directory to `PATH`. Executable command: **`doubao-im-auto-send`**.

## Quick Start

```bash
# Run with default parameters
doubao-im-auto-send

# Check current environment
doubao-im-auto-send --check
doubao-im-auto-send --help

# Enable MiniMax refine
doubao-im-auto-send --refine

# Test refine only, without event monitoring
doubao-im-auto-send --refine-text "This is basically basically what I mean"
```

## Runtime Example

Terminal log example (colors are enabled only in a TTY terminal):

![Runtime log example](./assets/runtime-log.webp)

## Default Behavior

- Default trigger key: Left `Option`
- `delay-ms=600`
- `per-second-postdelay-ms=130`
- `stable-ms=450`
- `poll-ms=50`
- `min-hold-ms=250`
- `max-wait` disabled by default
- Common editor apps are skipped by default, including VS Code, Cursor, Windsurf, JetBrains IDEs, Xcode, and Sublime
- Default file log: `~/Library/Logs/doubao-im-auto-send/runtime.log`
- Press `Esc` during the waiting-to-send phase to cancel auto-send
- `--refine` is disabled by default; when enabled, MiniMax CN runs before auto-send
- Default refine mode: `trim`
- Default refine model: `MiniMax-M2.5-highspeed`
- Default refine timeout: `6000ms`

## MiniMax Configuration

- `MINIMAX_API_KEY`: required when using `--refine` or `--refine-text`
- `MINIMAX_API_HOST`: optional, defaults to `https://api.minimaxi.com`
- The current implementation uses the OpenAI-compatible endpoint: `/v1/chat/completions`

## FAQ

- No response: check permissions, confirm Doubao IME is active, and make sure hold duration is not below `250ms`
- No auto-send: may be interrupted by `Esc`, new keyboard/mouse input, input method switch, or frontmost app switch
- Refine not working: run `doubao-im-auto-send --check` and confirm `MINIMAX_API_KEY` / `MINIMAX_API_HOST`
- Unstable behavior in some input fields: the script relies on Accessibility APIs to read text, and some fields may not be consistently readable
- Terminal-only logs: use `--no-file-log`; silent terminal output: use `--quiet`

## Related Files

- [doubao-im-auto-send.swift](./doubao-im-auto-send.swift): primary script
- [Config.swift](./Config.swift): config and CLI argument parsing
- [AutoSendEngine.swift](./AutoSendEngine.swift): main state machine and send pipeline
- [Accessibility.swift](./Accessibility.swift): focused element read/write helpers
- [MiniMaxClient.swift](./MiniMaxClient.swift): MiniMax CN API client
- [Logging.swift](./Logging.swift): terminal and file logging
- [install.sh](./install.sh): one-command installer
- [doubao-im-auto-send-model.md](./doubao-im-auto-send-model.md): detailed model and parameter explanation
