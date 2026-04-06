# doubao-im-auto-send

**一个 macOS Swift 脚本：监听豆包输入法语音输入结束，在文本稳定后自动发送 `Enter`**。

> 适用前提：macOS、豆包输入法，以及你的终端应用已开启“输入监控”和“辅助功能”权限。

## 安装

```bash
bash install.sh
```

默认安装到 `~/.local/bin/doubao-im-auto-send`。如果该目录不在 `PATH` 中，可直接用完整路径运行或者将其添加到 `PATH` 中。运行命令为：**`doubao-im-auto-send`**。

## 快速开始

```bash
# 使用默认参数运行
doubao-im-auto-send

# 查看当前参数配置等信息
doubao-im-auto-send --check
doubao-im-auto-send --help
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
- 默认文件日志：`~/Library/Logs/doubao-im-auto-send/runtime.log`
- 等待发送阶段按 `Esc` 可取消自动发送

## 常见问题

- 没反应：先检查权限、当前输入法是否为豆包、按住时长是否低于 `250ms`
- 没自动发送：可能被 `Esc`、新的键盘/鼠标输入、输入法切换或前台应用切换打断
- 某些输入框效果不稳定：脚本依赖辅助功能读取文本，部分输入框可能不可稳定读取
- 只想看终端日志：加 `--no-file-log`；只想静默终端：加 `--quiet`

## 相关文件

- [doubao-im-auto-send.swift](./doubao-im-auto-send.swift)：主脚本
- [install.sh](./install.sh)：一键安装脚本
- [doubao-im-auto-send-model.md](./doubao-im-auto-send-model.md)：详细建模与参数说明
