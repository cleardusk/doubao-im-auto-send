# 豆包输入法语音识别自动发送建模

## 核心公式

```math
t_{\mathrm{send}}
=
\max\left(
t_{\mathrm{release}} + \gamma \, t_{\mathrm{hold}} + d,
\;
t_{\mathrm{lastChange}} + s
\right)
```

为便于阅读，命令行参数与日志输出按毫秒（ms）给出；其中 $`\gamma`$ 的参数单位为 ms/s。
代码内部以秒（s）进行计算；下文默认值均以参数显示值为准。
发送时刻取释放侧下界与文本稳定性下界中的较大值。

## 变量定义

| 符号 | 含义 | 默认值 |
| --- | --- | --- |
| $`t_{\mathrm{send}}`$ | 自动发送实际执行的时刻；代码内部单位为 s。 | - |
| $`t_{\mathrm{release}}`$ | 用户松开触发键的时刻；代码内部单位为 s。 | - |
| $`\gamma`$ | 松手后“识别优化”时长的线性补偿系数。 | 130 ms/s（等价于 0.13 s/s） |
| $`t_{\mathrm{hold}}`$ | 用户按住触发键的时长，用来近似表示说话时长；代码内部单位为 s。 | - |
| $`d`$ | 松手后的基础等待时间。 | 600 ms（等价于 0.6 s） |
| $`t_{\mathrm{lastChange}}`$ | 松手后，当前输入框文本最后一次被观测到发生变化的时刻；代码内部单位为 s。 | - |
| $`s`$ | 文本稳定窗口。 | 450 ms（等价于 0.45 s） |

其中：

```math
t_{\mathrm{hold}} = t_{\mathrm{release}} - t_{\mathrm{press}}
```

说明：$`t_{\mathrm{release}}`$、$`t_{\mathrm{hold}}`$、$`t_{\mathrm{lastChange}}`$ 是运行时观测量；$`t_{\mathrm{send}}`$ 是运行时结果量；这些量本身没有默认值。

## 脚本默认参数

| 参数 | 含义 | 默认值 |
| --- | --- | --- |
| `--left-option` | 默认触发键 | 开启 |
| `--delay-ms` | 最小等待时间 $`d`$ | 600 ms |
| `--per-second-postdelay-ms` | “识别优化”线性补偿系数 $`\gamma`$ | 130 ms/s |
| `--stable-ms` | 文本稳定窗口 $`s`$ | 450 ms |
| `--poll-ms` | 轮询间隔 | 50 ms |
| `--max-wait-ms` | 最大等待时间 | 默认关闭 |
| `--min-hold-ms` | 最短按住时长；低于该阈值则忽略本次触发 | 250 ms |

说明：`--max-wait-ms` 属于实现层兜底参数，不属于核心建模公式；默认关闭，仅在需要超时强制发送时显式开启。
说明：当前实现默认同时写入文件日志，路径为 `~/Library/Logs/doubao-im-auto-send/runtime.log`；`--quiet` 仅静默终端输出，`--no-file-log` 可关闭文件日志。
说明：当前实现默认跳过常见编辑器类应用，如 VS Code、Cursor、Windsurf、JetBrains、Xcode、Sublime。

## 当前 refine 边界

当前实现中的 `--refine` 还有几条实现层边界，和上面的发送公式正交：

1. 当前 refine 白名单仅包含 `iTerm2` 与 `Terminal`；其他前台应用会直接发送，不进入 refine。
2. 默认 refine 最小长度为 `30`，最大长度为 `1000`；超出区间时直接发送原文。
3. 若输入里包含类似 `[Image #1]` 的图片占位，当前会跳过 refine，避免破坏 TUI 附件语义。
4. 启动日志会先输出 provider 初始化状态，用来区分“监听尚未开始”和“refine provider 尚未就绪”。

## 含义

这个模型表达两个约束：

1. 松手后不能立刻发送，至少要经过一个最小等待时间。
2. 即使最小等待已经满足，也要等文本稳定一小段时间后再发送。

## 适用边界

该模型**不能**直接观测豆包内部“识别优化完成”事件，只能利用外部可观测信号：

1. 触发键按住时长。
2. 松手后输入框文本的变化情况。

在这个约束下，该模型保持简单、可解释，并足以覆盖当前自动发送场景。

当前实现还支持以下取消条件：

1. 按下 `Esc`。
2. 再次按下触发键。
3. 前台应用切换、输入法切换，或发生新的鼠标输入。

## 附录：运行示例

### 最简运行

```bash
swift run doubao-im-auto-send
```

使用脚本当前默认参数直接运行。

### 显式全参数运行

```bash
swift run doubao-im-auto-send -- \
  --left-option \
  --delay-ms 600 \
  --per-second-postdelay-ms 130 \
  --stable-ms 450 \
  --poll-ms 50 \
  --min-hold-ms 250

```

适合需要完整复现当前默认配置的场景。

### 含超时兜底的全参数运行

```bash
swift run doubao-im-auto-send -- \
  --left-option \
  --delay-ms 600 \
  --per-second-postdelay-ms 130 \
  --stable-ms 450 \
  --poll-ms 50 \
  --max-wait-ms 5000 \
  --min-hold-ms 250

```

显式开启超时兜底，适合更关注“最终一定发送”的场景。

补充说明：在进入等待自动发送阶段后，按下 `Esc` 可取消本次自动发送。
