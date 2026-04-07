# 测试

## 目标

验证以下链路是否正常：

1. 豆包语音输入结束后能检测到文本稳定。
2. 若启用 `--refine`，能正确调用 `Codex` 或 `MiniMax` 做 refine。
3. refine 成功后能回写当前输入框并自动发送。
4. 用户中途打断时能取消发送。
5. provider 超时或失败时能回退到原文发送。

## 0. 仓库与构建

在仓库根目录执行：

```bash
cd /Users/guojianzhu/gjzprojects/learn-codex-and-cc/doubao-auto-send-llm
swift build -c release
```

构建成功后，二进制路径为：

```bash
.build/release/doubao-im-auto-send
```

## 1. 前置检查

先执行：

```bash
.build/release/doubao-im-auto-send --version
.build/release/doubao-im-auto-send --check
```

重点确认：

- 版本号输出为合法的 `YYYY-MM-DD`
- 当前输入法是豆包输入法
- 如果要验证 `refine`，当前前台应用应为 `iTerm2` 或 `Terminal`
- 如果测 `MiniMax`，`MINIMAX_API_KEY` 已设置
- 如果测 `Codex`，`Codex 登录态` 不是 `未检测到`
- 如果测 `Codex`，`Codex 登录态` 不是 `已配置但已过期`

系统权限也要提前确认：

- 终端或你实际运行脚本的 App 已授予 `辅助功能`
- 终端或你实际运行脚本的 App 已授予 `输入监控`

## 2. refine 单独验证

先不走 GUI，只验证 provider 本身。

### 2.1 Codex SSE

```bash
.build/release/doubao-im-auto-send \
  --refine-text "我我我今天想说明一下这个事情的背景、当前判断，以及接下来准备怎么处理。" \
  --refine-provider codex \
  --refine-mode correct \
  --refine-codex-transport sse
```

预期：

- 能返回一段整理后的文本
- 不应输出解释、Markdown、代码块

### 2.2 Codex WS

```bash
.build/release/doubao-im-auto-send \
  --refine-text "这个 PR 你先帮我 review 一下，然后那个 TODO 先不要动，最后直接 merge 到 main 就行" \
  --refine-provider codex \
  --refine-mode trim \
  --refine-codex-transport ws
```

预期：

- 能返回整理后的文本
- 术语如 `PR`、`TODO`、`merge`、`main` 不应被乱改

### 2.3 MiniMax sync

```bash
.build/release/doubao-im-auto-send \
  --refine-text "我我我今天想说明一下这个事情的背景、当前判断，以及接下来准备怎么处理。" \
  --refine-provider minimax \
  --refine-mode correct \
  --refine-minimax-transport sync
```

预期：

- 能返回整理后的文本
- 若当前 token plan 不支持某模型，应明确报错

### 2.4 MiniMax SSE

```bash
.build/release/doubao-im-auto-send \
  --refine-text "这个 PR 你先帮我 review 一下，然后那个 TODO 先不要动，最后直接 merge 到 main 就行" \
  --refine-provider minimax \
  --refine-mode trim \
  --refine-minimax-transport sse
```

预期：

- 能返回整理后的文本
- 如果超时，应有明确错误提示

## 3. 真正端到端测试

若要验证 `refine`，建议直接在 `iTerm2` 或 `Terminal` 中测试；当前实现只在这两个应用里进入 refine。

### 3.1 启动常驻进程

先选一条最稳的链路，例如 `Codex + SSE`：

```bash
.build/release/doubao-im-auto-send \
  --refine \
  --refine-provider codex \
  --refine-mode trim \
  --refine-codex-transport sse
```

也可以分别测试：

```bash
.build/release/doubao-im-auto-send \
  --refine \
  --refine-provider codex \
  --refine-mode trim \
  --refine-codex-transport ws
```

```bash
.build/release/doubao-im-auto-send \
  --refine \
  --refine-provider minimax \
  --refine-mode trim \
  --refine-minimax-transport sync
```

```bash
.build/release/doubao-im-auto-send \
  --refine \
  --refine-provider minimax \
  --refine-mode trim \
  --refine-minimax-transport sse
```

### 3.2 手工操作步骤

1. 切到豆包输入法。
2. 打开 `iTerm2` 或 `Terminal` 的输入区。
3. 长按默认触发键 `左 Option`。
4. 说一句包含明显口语重复的话。
5. 松开按键。
6. 观察文本是否先被 refine，再自动发送。

推荐测试句：

- `我我我今天想说明一下这个事情的背景、当前判断，以及接下来准备怎么处理。`
- `这个 PR 你先帮我 review 一下，然后那个 TODO 先不要动，最后直接 merge 到 main 就行`
- `我们等会儿用 Codex 跑一下这个 script，然后把 output 发到微信群里，URL 还是用那个 staging link`

### 3.3 成功路径预期

预期现象：

- 松手后不会立刻发送，而是先等待稳定
- 启用 `--refine` 时，会先调用 provider
- provider 成功时，输入框文本会被替换成 refine 结果
- 随后自动发送 `Enter`

## 4. 取消路径测试

下面几种都应该取消发送：

### 4.1 按 `Esc`

松手后立刻按 `Esc`。

预期：

- 不发送
- 输入框保持当前状态

### 4.2 继续输入

松手后立刻继续敲键盘。

预期：

- 不发送

### 4.3 切应用

松手后立刻切到别的 App。

预期：

- 不发送

### 4.4 切输入法

松手后立刻切到非豆包输入法。

预期：

- 不发送

### 4.5 切焦点输入框

同一应用内，把焦点从当前输入框切到另一个输入框。

预期：

- 不发送

## 5. fallback 路径测试

### 5.1 provider 超时

故意把 timeout 设得极小：

```bash
.build/release/doubao-im-auto-send \
  --refine \
  --refine-provider codex \
  --refine-timeout-ms 1
```

预期：

- refine 失败
- 原文仍继续发送

### 5.2 非法参数

```bash
.build/release/doubao-im-auto-send --check --refine-provider nope
```

预期：

- 直接报参数错误
- 不应静默回退到默认 provider

### 5.3 Codex 过期登录态

如果本地 Codex token 已过期，预期：

- `--check` 显示 `已配置但已过期`
- `--refine` 或 `--refine-text` 会直接 fail-fast
- 不会尝试自动 refresh

## 6. refine 边界测试

### 6.1 短文本跳过

说一句明显短于 `--refine-min-chars` 的话。

预期：

- 日志出现 `跳过：文本长度 ... 小于 refine 最小长度 ...`
- 直接发送，不调用 provider

### 6.2 超长文本跳过

构造一段大于 `--refine-max-chars` 的文本，或临时把 `--refine-max-chars` 调小后测试。

预期：

- 日志出现 `跳过：文本长度 ... 大于 refine 最大长度 ...`
- 直接发送，不调用 provider

### 6.3 图片占位跳过

在 TUI 输入中带上类似 `[Image #1]` 的占位，再触发发送。

预期：

- 日志出现 `跳过：检测到图片占位，直接发送原文`
- 不进入 refine

## 7. 日志位置

默认日志文件：

```text
~/Library/Logs/doubao-im-auto-send/runtime.log
```

建议重点看：

- `provider`
- `transport`
- `mode`
- 耗时
- 是否成功
- 是否发生 fallback
- 是否命中取消条件

## 8. 建议测试顺序

建议按这个顺序做：

1. `--check`
2. `--refine-text + codex + sse`
3. `--refine-text + codex + ws`
4. `--refine-text + minimax + sync`
5. `--refine-text + minimax + sse`
6. `iTerm2` 或 `Terminal` 输入区下做 `Codex + SSE` 端到端
7. 测取消路径
8. 测 timeout/fallback 路径

## 9. 当前已知说明

- `Codex` 只读取本地 token，不自动 refresh
- `MiniMax-M2.7-highspeed` 当前 token plan 不支持
- `MiniMax ws` 当前不支持，会明确报错
- `Codex ws` 的价值主要在同进程多次请求复用，单次请求不一定比 `sse` 快
