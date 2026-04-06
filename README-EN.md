# doubao-im-auto-send

**A macOS Swift script that listens for Doubao IME voice input completion and automatically sends `Enter` after text becomes stable.**

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

## FAQ

- No response: check permissions, confirm Doubao IME is active, and make sure hold duration is not below `250ms`
- No auto-send: may be interrupted by `Esc`, mouse input, input method switch, or frontmost app switch
- Unstable behavior in some input fields: the script relies on Accessibility APIs to read text, and some fields may not be consistently readable
- Terminal-only logs: use `--no-file-log`; silent terminal output: use `--quiet`

## Related Files

- [doubao-im-auto-send.swift](./doubao-im-auto-send.swift): primary script
- [install.sh](./install.sh): one-command installer
- [doubao-im-auto-send-model.md](./doubao-im-auto-send-model.md): detailed model and parameter explanation
