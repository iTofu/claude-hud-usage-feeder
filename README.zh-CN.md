# claude-hud-usage-feeder

在 [claude-hud](https://github.com/jarrodwatts/claude-hud) 状态栏里显示**按模型的周配额** —— 就是 Claude 客户端里标成 `Fable` 的那一条。

<!-- 指示线靠字符数对齐：ƒ 在第 63 列。改动示例行后必须重算，否则会偏一列。 -->
```
Usage █░░░░░░░░░ 6% (3h 2m) | Weekly █████░░░░░ 50% (2d 15h) | ƒ ████████░░ 84%
                                                               └── 这一段
```

它之前的部分是 claude-hud 原本就有的。这里的 `ƒ` 是把 `Fable` 改了名，见[改标签](#改标签)。

[English](README.md)

## 为什么需要它

Claude Code 给状态栏插件的 stdin payload 里只有 `rate_limits.five_hour` 和 `rate_limits.seven_day`，**没有** `model_scoped`（按模型的周窗口）。claude-hud 0.7.0+ 能渲染这类窗口，但前提是有人通过 `display.externalUsagePath` 喂给它一份本地快照 —— 而没有任何东西会生成那份快照。

这个仓库就是那个「有人」：定时拉配额、写快照，claude-hud 读它。claude-hud 自己不联网。

哪天 Claude Code 把 `model_scoped` 也塞进 stdin，这套就多余了 —— 直接卸载，状态栏照常工作，因为 **stdin 永远压过快照**。

## 依赖

- claude-hud **0.7.0+**（`display.externalUsagePath` 是那个版本加的）
- Python 3（macOS 自带的就行，不需要任何第三方包）
- 账号确实有按模型的周窗口
- 自带的定时器是 macOS 的；其余部分跨平台，见 [Linux](#linux)

## 安装

```bash
git clone https://github.com/iTofu/claude-hud-usage-feeder.git
cd claude-hud-usage-feeder
./install.sh
```

它会把脚本装到 `~/.claude/scripts/`、把 claude-hud 的配置指向快照、注册一个 10 分钟一跑的 launchd agent，然后跑一次做验证。重复执行是安全的。

```
./install.sh --interval 300              # 5 分钟刷一次
./install.sh --label 'Fable=ƒ'           # 改状态栏上的标签
./install.sh --no-timer                  # 只装不排期，自己调度
```

卸载会清干净，包括它加进配置的那两个键：

```bash
./uninstall.sh
```

## 数据从哪来

三个来源按顺序试，第一个拿到 scoped 窗口的胜出。每一条都靠掐掉上一条实测验证过。

| # | 来源 | 耗时 | 说明 |
|---|---|---|---|
| 1 | [`cswap status --json`](https://github.com/realiti4/claude-swap) | ~0.3s | 首选。自带凭证，不起子进程、不触发 hooks，而且它内部对上游有 TTL 门控（180–600s），高频调用不会变成对应频率的 API 流量。前提是当前账号被 cswap 纳管。 |
| 2 | `GET /api/oauth/usage` | ~0.9s | 零本地依赖。读 Claude Code 的 OAuth token，**钥匙串优先**、凭证文件只当兜底（那个文件会陈旧，实测见过里面的 token 已过期 8.7 小时而钥匙串那份还活着）。绝不自己刷新 token —— 刷新要回写钥匙串，会跟 Claude Code 抢。 |
| 3 | `claude` 的 `get_usage` 控制请求 | ~2.5s | 垫底。不调模型、不花 token，但会起一个 `claude` 子进程，因此会触发 SessionStart/SessionEnd hooks。 |

三条打的是同一个端点、同一份按身份计的预算（非一方 UA 大约 28–30 请求/小时），所以这是 fallback 链，不是并发扇出。

想自己定顺序：`HUD_FEEDER_SOURCES=oauth,cswap`；不想要哪条，不写进去即可。

### 两个值得知道的坑

**CLI 自己那份 `model_scoped` 是空的。** `rate_limits.model_scoped` 会被服务端的 `tengu_usage_overage_included_models` gate 过滤，按最直觉的方式去读只会拿到 `[]`。这里是自己映射 `limits[]`，挑 `kind == "weekly_scoped"`。

**`is_active` 会骗人。** 一个正在生效的 scoped limit 可能报 `is_active: false`。拿它做过滤，恰好会丢掉你想显示的那条。这里绝不按它过滤。

**`CLAUDE_CONFIG_DIR` 会让 cswap 哑火。** 只要这个变量存在 —— 哪怕设的就是它自己的默认值 `~/.claude` —— cswap 0.24.1 就会报 `managed: null`、`usage` 是空对象。把它继承给子进程，来源 1 就静默失效，整套装置一直靠更慢的兜底路径撑着而你毫无察觉。这里会把它从 cswap 的环境里剔掉，`install.sh` 也只在它确实是非默认值时才导出。

## 改标签

快照里的 `display_name` 完全归你 —— claude-hud 只剥 ANSI/控制字符、截断到 64 字符，所以普通字符和 emoji 都能原样通过，而且它的渲染层按 grapheme 算宽度，不会把布局搞歪。

```bash
./install.sh --label 'Fable=ƒ'
```

这张表存在 `~/.claude/plugins/claude-hud/usage-feeder.json`，而不是塞在定时器的环境变量里 —— 所以手工跑 feeder 和定时跑出来的结果完全一致。不带 `--label` 重跑 `install.sh` 不会动它。

想先挑：

```bash
./tools/preview-labels.sh          # 一份精选清单
./tools/preview-labels.sh ƒ 🦊 📜  # 只看这几个
```

它用你真实的状态栏命令逐个渲染，退出时还原快照。

有两件事光看字符列表看不出来，只有渲染出来才知道：

- **普通字符会跟着 claude-hud 的标签色走**，emoji 自带颜色、不吃周围的 ANSI 样式。所以 `ƒ` 和 `Usage` / `Weekly` 融为一体，`🦊` 则是整行里唯一一块彩色。
- **宽度不是想当然的。** 优先选 East Asian Width 是 `N`/`Na` 的字符。像 `✦` 是 `A`（ambiguous），在把 ambiguous 当双宽的 CJK 终端里会悄悄变成 2 格，换台机器布局就不一样。`ƒ`（U+0192）是 `N`，到哪都是 1 格。

改名表匹配不上时会落回上游给的原名 —— 上游改名只会退化成显示真名，而不是静默丢掉标签。

## 配置

全都是可选的，`install.sh` 会把需要的那些写进 launchd agent。

| 变量 | 默认 | 含义 |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code 配置目录 |
| `HUD_FEEDER_PLUGIN_DIR` | `$CLAUDE_CONFIG_DIR/plugins/claude-hud` | 快照和日志的落点 |
| `HUD_FEEDER_LABELS` | 取自 `usage-feeder.json` | JSON 改名表，键不区分大小写。会压过文件。 |
| `HUD_FEEDER_SOURCES` | 三条全开 | 逗号分隔的子集/顺序 |
| `CSWAP_BIN` / `CLAUDE_BIN` | 自动查找 | 绝对路径 |

二进制先查 `$PATH`、再查常见安装位置 —— 因为 launchd 和 cron 给的是一个极简 `PATH`，既没有 `~/.local/bin` 也没有 `/opt/homebrew/bin`，这是「终端里跑得好好的，定时任务却挂了」最常见的原因。

## 隐私

如果你设了 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`，注意它会**连配额接口一起掐掉**，来源 2 和 3 需要它被放行。来源 3 只对**自己那个短命子进程**把它置空，同时置上 `DISABLE_TELEMETRY=1` / `DO_NOT_TRACK=1` —— CLI 的判定链是 `nonessential → telemetry → do_not_track`，于是配额接口放行、分析上报依旧关闭。你的全局设置不会被改动。

OAuth token 只在进程内存里活着，绝不写进快照或日志。快照以 `0600` 权限、通过临时文件原子改名落盘。

## 排查

**那一段不见了。** feeder 挂了。claude-hud 对过期快照的处理是**隐藏**而不是显示一个错误的数字，而且它不会告警 —— 日志是唯一的线索：

```bash
tail ~/.claude/plugins/claude-hud/usage-feeder.log
```

成功那行也会记下被跳过的来源，所以一个挂了几个月的源是看得见的，而不是静静地烂着：

```
2026-08-13T12:46:59+0800 OK via oauth -- Fable 84.0% [skipped: cswap: FileNotFoundError ...]
```

**日志里什么都没有。** 定时器没在跑：

```bash
launchctl print gui/$UID/io.github.itofu.claude-hud-usage-feeder | grep -E 'state|runs|last exit'
```

**报 `no scoped windows`。** 三个源都够到了 API，但没有一个报告按模型的周窗口。通常意味着你的账号当前就没有这个窗口。

## Linux

feeder 本身是跨平台的（没有钥匙串的地方，来源 2 会落到凭证文件）。只有定时器是 macOS 专属 —— 用 `--no-timer`，然后加一条 cron：

```
*/10 * * * * $HOME/.claude/scripts/claude-hud-usage-feeder.py
```

没在 Linux 上实测过，欢迎反馈。

## License

MIT
