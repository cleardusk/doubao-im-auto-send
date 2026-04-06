# doubao-im-auto-send

**一个 macOS Swift 命令行工具：监听豆包输入法语音输入结束，在文本稳定后自动发送 `Enter`；可选在发送前接入 MiniMax CN 或 Codex refine。**

> 适用前提：macOS、豆包输入法，以及你的终端应用已开启“输入监控”和“辅助功能”权限。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/cleardusk/doubao-im-auto-send/main/install.sh | bash
```

如果你更想先拉仓库再安装：

```bash
git clone --depth 1 https://github.com/cleardusk/doubao-im-auto-send.git && bash doubao-im-auto-send/install.sh
```

在仓库目录内也可以直接执行：

```bash
bash install.sh
```

> 默认安装到 `~/.local/bin/doubao-im-auto-send`。如果该目录不在 `PATH` 中，可直接用完整路径运行或者将其添加到 `PATH` 中。运行命令为：**`doubao-im-auto-send`**。

## 快速开始

```bash
# 使用默认参数运行
doubao-im-auto-send

# 查看当前参数配置等信息
doubao-im-auto-send --check
doubao-im-auto-send --help

# 启用 refine
doubao-im-auto-send --refine

# 显式使用 MiniMax
doubao-im-auto-send --refine --refine-provider minimax

# 显式使用 MiniMax SSE
doubao-im-auto-send --refine --refine-provider minimax --refine-minimax-transport sse

# 显式使用 Codex SSE
doubao-im-auto-send --refine --refine-provider codex --refine-codex-transport sse

# 显式使用 Codex WebSocket
doubao-im-auto-send --refine --refine-provider codex --refine-codex-transport ws

# 单独测试 refine，不启动监听
doubao-im-auto-send --refine-text "这个事情大概就是这样这样"
```

## 运行示例

终端日志示意如下；颜色仅在 TTY 终端下生效。

![运行日志示例](./assets/runtime-log.webp)

## 默认行为

- 默认触发键：左 `Option`
- `delay-ms=600`
- `per-second-postdelay-ms=130`
- `stable-ms=450`
- `poll-ms=50`
- `min-hold-ms=250`
- `max-wait` 默认关闭
- 默认跳过常见编辑器类应用，如 VS Code、Cursor、Windsurf、JetBrains、Xcode、Sublime
- 默认文件日志：`~/Library/Logs/doubao-im-auto-send/runtime.log`
- 等待发送阶段按 `Esc` 可取消自动发送
- `--refine` 默认关闭；启用后会在自动发送前调用配置的 refine provider
- 默认 refine provider：`codex`
- 默认 refine 模式：`trim`
- 默认 refine 模型：`gpt-5.4-mini`
- 默认 refine 超时：`10000ms`
- 默认 Codex transport：`sse`
- 默认 MiniMax transport：`sync`

## Refine Provider 配置

- `minimax`
- `MINIMAX_API_KEY`：必填；启用 `--refine --refine-provider minimax` 或使用 `--refine-text --refine-provider minimax` 时需要
- `MINIMAX_API_HOST`：可选；默认 `https://api.minimaxi.com`。也兼容 `https://api.minimaxi.com/v1`、`https://api.minimaxi.com/anthropic`、`https://api.minimaxi.com/anthropic/v1`
- 当前实现走 Anthropic 兼容接口：`/anthropic/v1/messages`
- 支持 `--refine-minimax-transport sync|sse|ws`
- `sync` 是默认模式，逻辑最简单，也最接近 OpenClaw 当前 MiniMax provider 的 HTTP 完成式调用
- `sse` 使用 Anthropic 兼容流式事件；当前仍然要等最终文本完成后才会回写并发送
- `ws` 会显式报不支持；官方文档和 OpenClaw 当前都没有 MiniMax 文本 WebSocket provider

- `codex`
- 需要本机已有 `openclaw models auth login --provider openai-codex` 或 `codex login` 登录态
- 只读取本地 token，不自动 refresh
- 支持 `--refine-codex-transport sse|ws`
- `sse` 是默认模式，单次请求更稳
- `ws` 支持同进程连接复用，更适合长时间运行场景

## 常见问题

- 没反应：先检查权限、当前输入法是否为豆包、按住时长是否低于 `250ms`
- 没自动发送：可能被 `Esc`、新的键盘/鼠标输入、输入法切换或前台应用切换打断
- refine 没生效：先用 `doubao-im-auto-send --check` 确认当前 provider、token 或 `MINIMAX_API_KEY` / `MINIMAX_API_HOST` 状态
- MiniMax 太慢：可试 `--refine-provider minimax --refine-minimax-transport sse`，但总完成时间不一定明显短于 `sync`
- Codex 太慢：先试 `--refine-codex-transport ws`；如果只跑单次命令，`sse` 往往更稳
- 某些输入框效果不稳定：脚本依赖辅助功能读取文本，部分输入框可能不可稳定读取
- 只想看终端日志：加 `--no-file-log`；只想静默终端：加 `--quiet`

## 相关文件

- [doubao-im-auto-send.swift](./doubao-im-auto-send.swift)：主脚本
- [Config.swift](./Config.swift)：配置与参数解析
- [AutoSendEngine.swift](./AutoSendEngine.swift)：主状态机与发送 pipeline
- [Accessibility.swift](./Accessibility.swift)：焦点输入框读取与回写
- [MiniMaxClient.swift](./MiniMaxClient.swift)：MiniMax CN API 客户端
- [RefineProvider.swift](./RefineProvider.swift)：refine provider 抽象与分流
- [CodexHTTPProvider.swift](./CodexHTTPProvider.swift)：Codex SSE provider
- [CodexWebSocketTransport.swift](./CodexWebSocketTransport.swift)：Codex WebSocket transport
- [CodexOAuthStore.swift](./CodexOAuthStore.swift)：本地 Codex/OpenClaw token 读取
- [HTTPTransportSupport.swift](./HTTPTransportSupport.swift)：URLSession 与代理支持
- [Logging.swift](./Logging.swift)：终端与文件日志
- [install.sh](./install.sh)：一键安装脚本
- [doubao-im-auto-send-model.md](./doubao-im-auto-send-model.md)：详细建模与参数说明
