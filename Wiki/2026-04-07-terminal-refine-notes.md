# 2026-04-07 Terminal Refine Notes

## 背景

今天主要在 `iTerm2 + Codex TUI + 豆包输入法` 场景下，修 `--refine` 的读取、回写和自动发送。

基线备份 commit：

- `5ca1a83` `Improve terminal refine rewrite stability`

## 今天确认修掉的问题

### 1. 不再把整屏 terminal buffer 误当成 refine 输入

- 之前会把整屏内容读进来，出现几千到几万字符长度。
- 现在 terminal 读取只取当前输入区，避免直接回退整屏 `AXValue`。

### 2. 排除了 Codex TUI 的辅助行和状态栏

- 已排除底部状态栏，如 `gpt-5.4 xhigh fast · ...`
- 已排除提示行，如 `tab to queue message`、`enter to send` 等。
- 已排除本工具自己的时间戳日志行，避免再次被当成输入。

### 3. terminal 回写不再走 AX value 直写

- terminal 改为 rewrite 模式：
  - 定位当前输入
  - 删除旧输入
  - 再写入新文本

### 4. 回写不再优先依赖逐字符输入

- 之前逐字符输入会出现：
  - 重字，如 `刚刚刚刚`
  - 丢空格，如 `warning` 前空格消失
- 现在优先走剪贴板粘贴，再做校验。

### 5. 修了剪贴板恢复时机

- 之前 `Cmd+V` 发出后立刻恢复剪贴板，iTerm2/TUI 可能读到旧剪贴板内容。
- 现在等回写校验后再恢复剪贴板。

### 6. Enter 日志语义更严谨

- 之前 `已发送 Enter` 只表示 `CGEvent` 发出，不代表 TUI 真的提交。
- 现在改为：
  - `已确认发送 Enter`
  - `Enter 已触发，但未确认提交`

### 7. Enter 发送策略更稳

- terminal 场景下，回写后会先短暂 settle。
- 先发一次 `Return`。
- 如果未确认提交，再补一次 `keypad Enter`。

## 现在仍然存在的问题

### 1. Option 在“吐字/回写/确认发送”阶段容易失效

- 原因：当前回写、校验、发送确认仍然是同步串行流程。
- 用户如果正好在这段时间再次按 `Option`，事件容易处理不及时。

### 2. terminal rewrite 仍有偶发写坏

- 仍然出现过：
  - 重字
  - 中英混排空格丢失
  - `check` / `Enter` 这类词附近格式变化
- 说明回写链路还没有完全稳定。

### 3. Enter 确认仍不是 100%

- 有些轮次已经能到 `已确认发送 Enter`。
- 但仍有轮次只到 `Enter 已触发，但未确认提交`。
- 这说明 Codex TUI 对模拟按键的接收还不完全稳定。

### 4. 终端实时日志体感偏弱

- 为了避免日志污染 TUI 输入区，terminal 场景下大部分 stdout 回显被压掉了。
- 文件日志仍然完整，但用户在当前终端里会感觉“没动”。

## 明天建议优先做的事

### P0

- 把 terminal rewrite / submit confirm 从主事件循环里拆出来，降低对下一次 `Option` 的阻塞。

### P1

- 给发送链路加更细的“提交后验证”。
- 目标不是只看输入区是否清空，而是更接近 Codex TUI 的真实提交状态。

### P2

- 恢复一层极轻量终端状态提示，不污染输入区即可。
- 例如只保留：
  - `等待稳定`
  - `已跳过：不是豆包`
  - `已确认发送 Enter`
  - `Enter 已触发，但未确认提交`

## 目前结论

今天已经把这条链路从“经常误读、误贴、误报成功”推进到“多数轮次可以 refine + rewrite + confirm send”。

但 `iTerm2 + Codex TUI` 仍然不是完全稳定场景，剩余问题主要集中在：

- 写入链路偶发失真
- 发送确认不稳定
- 事件循环阻塞导致 `Option` 体感失效
