# 用户目录与配置

`NIB_HOME` 指定 nib 的用户目录，未设置时用 `$HOME/.nib`：

```text
~/.nib/
  AGENTS.md       全局指令
  config.toml     非秘密运行配置，可不创建
  sessions/       <32位小写十六进制ID>.jsonl 会话日志；同 ID 的 .calls.jsonl 是私有工具录制
  reflections.md  /reflect 正常结束后的回答与 issue 发布结果
```

不读取 XDG 配置或数据目录，也不搜索或自动迁移旧文件。需要保留旧指令、会话时，由用户自行放入新目录。`NIB_HOME` 不改变 Codex 凭证位置：仍读取 `$CODEX_HOME/auth.json`，默认 `~/.codex/auth.json`。

新会话按基础指令、`$NIB_HOME/AGENTS.md`、项目 `AGENTS.md` 的顺序拼接 system。项目目录从 cwd 向上取第一个 `.git` 标记所在目录，没有则用 cwd；恢复会话沿用日志内的 system。暂不读取项目级 `config.toml`，项目约定仍写在 `AGENTS.md`。

## config.toml

```toml
# 顶层键；均可省略
provider = "codex"
effort = "high"

[codex]
model = "gpt-6.1-sol"
base_url = "https://chatgpt.com/backend-api"
context_window = 500000

[chat_completions]
model = "deepseek-flash"
base_url = "https://api.deepseek.com"
context_window = 1000000

[limits]
llm_concurrency = 4
llm_calls_per_run = 100
llm_input_kib = 256
agent_concurrency = 4
max_steps = 50
```

只使用当前 provider 的段落；切换 provider 不需要改写另一段。环境和配置文件均未指定时，默认 provider 为 `codex`，默认模型 `gpt-6.1-sol`、窗口 500000 tokens；使用本机 Codex 登录，无需 API key。Codex 窗口随模型变化，未知模型需要显式提供 `context_window` 或 `NIB_CONTEXT_WINDOW`。模型、恢复和凭证边界见 [codex.md](codex.md) 与 [ADR 0011](adr/0011-provider-wire-protocols.md)。

DeepSeek 使用 Chat Completions：设置 `NIB_PROVIDER=chat_completions`，配 `DEEPSEEK_API_KEY`（或 `NIB_API_KEY`），默认模型 `deepseek-flash`、窗口 1000000 tokens；其他默认值见上例。

这是无额外依赖的 TOML 子集：支持空行、`#` 注释、单行双引号字符串（支持 `\"`、`\\`、`\n` 转义）、十进制整数（可带符号、下划线分组）和 true/false 布尔值；当前配置键只使用字符串和正整数，布尔值会报告类型错误。仅接受顶层 `provider`、`effort`，`[codex]` / `[chat_completions]` 下的 `model`、`base_url`、`context_window`，以及下述 `[limits]` 键。不支持数组、嵌套表、多行字符串等完整 TOML 语法；未知键、重复键/段落和格式错误会报配置文件路径与行号，不静默忽略。

## [limits]

`[limits]` 适用于当前有效配置，与 provider 无关；各项可独立省略，默认值见示例。所有值必须为范围内的正整数：

| 键 | 含义 | 默认值 | 范围 |
| --- | --- | --- | --- |
| `llm_concurrency` | `tools.llm` 每进程同时进行的请求数，超出排队 | 4 | 1–64 |
| `llm_calls_per_run` | 每个 Run 的 `tools.llm` 调用上限，超出 reject | 100 | 1–10000 |
| `llm_input_kib` | 单次 prompt + 序列化 input 的 UTF-8 字节上限（KiB），超出 reject，不截断 | 256 | 1–65536 |
| `agent_concurrency` | 每进程同时运行的子 agent 数，超出排队 | 4 | 1–64 |
| `max_steps` | 每个 Turn 的 Step 上限，耗尽时返回 `TooManySteps` | 50 | 1–1000 |

这些限额没有环境变量或 CLI 覆盖；随有效配置经 stdin 传给子会话，子会话不读取配置文件。sandbox 内全部工具最多 8 并发是线程调度实现，不由此小节控制。

配置文件不存秘密，也不接受 API key、token、密码或凭证字段。Chat Completions 的 key 使用 `NIB_API_KEY` / `DEEPSEEK_API_KEY`；Codex 使用现有登录文件。不要把秘密放进 URL。

## 覆盖优先级

从高到低：

1. CLI `--effort <level>`（TUI 启动和 `ask` 都支持）。
2. 环境变量：`NIB_PROVIDER`、`NIB_MODEL`、`NIB_BASE_URL`、`NIB_CONTEXT_WINDOW`、`NIB_THINKING`、`NIB_REASONING_EFFORT`。
3. `$NIB_HOME/config.toml`。
4. 内置默认值。

环境中设置 thinking 或 effort 时，不采用文件 effort。`NIB_THINKING=off` 优先于环境 effort；显式 CLI effort 又覆盖两者。未指定任何推理配置时使用服务端默认。CLI `--effort default` 清除本进程的 thinking/effort 覆盖，不修改文件。

子会话通过匿名 stdin 管道继承父会话的有效 provider/模型配置及限额，跳过配置文件读取，不会因文件在中途变化而采用另一套配置；Codex 凭证仍由各进程独立读取。

## 环境变量

| 变量 | 含义 |
|---|---|
| `NIB_HOME` | 用户目录，默认 `~/.nib`；不改变 Codex 凭证位置 |
| `NIB_PROVIDER` | `codex` / `chat_completions` |
| `NIB_BASE_URL` | 当前 provider 的服务地址 |
| `NIB_MODEL` | 当前 provider 的模型 |
| `NIB_CONTEXT_WINDOW` | 上下文窗口 tokens，DeepSeek 默认 1000000 |
| `NIB_THINKING` | `on` / `off`，不设时用服务端默认（若无其他推理配置） |
| `NIB_REASONING_EFFORT` | 推理档位，如 `low` / `high` / `max` |
| `CODEX_HOME` | Codex 登录目录，凭证为其中的 `auth.json`，默认 `~/.codex/auth.json` |
| `NIB_API_KEY` / `DEEPSEEK_API_KEY` | Chat Completions 的凭证，仅从环境读取 |
| `NIB_PATCHES_OFF` | 关闭提示词中的模型补丁：`all` 或逗号分隔的 id，见 [compromises.md](compromises.md) |
| `NIB_ISSUE_REPO` | `/reflect` 自动发布的目标仓库或 `off`，见 [reflect.md](reflect.md) |
| `NIB_RECORD` | 默认录制工具调用到本地 `.calls.jsonl`，`off` 关闭；文件权限 `0600`，仅 `nib replay` 读取，见 [replay.md](replay.md) |

## 逐 Step effort 调度

主模型可调用 `run({code: "...", effort: "low"})`，可选值为 `low|medium|high|default`。声明针对看到本次 Run 结果之后的**下一次主模型 Step 请求**，仅生效一次；后续未再次声明则恢复用户设置。同一 Step 多个 Run 取最后一个声明，未声明的 Run 不覆盖它。`default` 显式恢复用户设置。机械性的下一步适合 low，重新设计或疑难排查不宜降档。

护栏由 Session 统一决定：

- 用户有效 effort 既是默认值也是上限；`low < medium < high < xhigh < max`，声明超过上限则回退用户设置。`off/none/minimal` 也不会被模型声明抬升。
- 服务端 `default` 的实际档位未知，只放行最低档 `low` 或恢复 `default`；`medium/high` 回退默认，不猜测服务端档位。
- 声明所在的 Run 返回 `ok=false` 时忽略该降档，下一次回退默认；其他未声明 Run 的失败不改变最后一个声明的选择。
- Turn 首次请求、以及带有新插话（回合中用户消息）的请求始终用用户设置；压缩保持独立策略；`tools.llm` 保持用户配置及其自己的 effort 参数，不继承主模型的临时降档。
- Codex 仍沿用现有映射，不能关闭推理的模型将 off 映射为 low。调度不修改用户配置、文件或子会话继承的配置。

TUI 的 Run 摘要末尾显示**产生它的模型请求**实际 effort（不是该 Run 对下一步的声明），护栏来源加 `(guard)`；历史从日志恢复，旧日志无 effort 则不显示。下边框显式设置显示为 `effort ≤high`，服务端 default 显示保持原样。

## effort 持久化

`default|off|none|minimal|low|medium|high|xhigh|max` 可用于 `--effort` 或 TUI `/effort`；具体支持档位由模型/服务端决定。

- `nib --effort high`、`nib ask --effort high ...`：仅本进程生效，不写文件。
- TUI `/effort`：查询当前请求配置，不写文件。
- TUI `/effort high`：空闲时切换，后续 Turn 生效，并将顶层 `effort` 原子保存至 `config.toml`；只更新该值，保留其他配置行和注释，不把环境变量或有效配置整体序列化回文件。
- TUI `/effort default`：清除本进程 thinking/effort 覆盖，并移除文件顶层 `effort`，保留其余内容。下次启动仍按正常优先级解析，环境覆盖可能再次生效。

当前有效配置由子会话继承；摘要使用独立的最低推理策略。恢复会话采用本次启动的有效配置，但 provider 和 Codex 模型需符合日志的恢复边界，见 [codex.md](codex.md)。

写回先读入并校验当前文件，再按字节范围仅替换 effort 的值（删除键时保留同行注释）；缺失时插在第一个小节前的顶层末尾。完整内容写入同目录临时文件、sync 后 rename 替换，失败时清理临时文件，原文件不被部分覆盖。保存失败会在对话区提示，不撤销本次 effort 设置。没有跨进程锁：多个 nib 或外部编辑器同时保存时仍可能后写覆盖先写。配置文件上限为 1 MiB；不提供自动迁移和项目级配置。
