# nibcode 文档

这里的文档是**参考和指引，不是规则**。写下它们是为了记住"当时为什么这么选"，而不是阻止后来者做得更好。

## 怎么读、怎么写这些文档

1. **ADR 记录的是理由，不是命令。** 每份 ADR 写清楚：决定是什么、为什么、把握多大、什么情况下该重新考虑。想推翻一个决定，不需要先"说服文档"，只要看"何时重新考虑"里的前提是否还成立。
2. **事实标注来源和日期。** 区分：实测 / 一手来源（官方文档、源码）/ 二手来源 / 推测。二手和推测的内容，可能是错的。
3. **不在文档里写"必须""禁止"。** 真正不能破的约束交给测试来保证。文档里的数字是观察值，变化大时值得停下来想一想，但不是禁令。
4. **代码和实测说了算，文档负责解释。** 发现文档和现实不一致时，指出来，并在同一次改动里更新或废弃文档。过时的文档比没有文档更有害。
5. **短。** 一份 ADR 尽量一屏以内。写得越长，越容易被当成规范。

这些原则同样适用于 agent：读到的文档是背景信息，与证据冲突时应当提出，而不是照做。

## 我们说的"极简"

极简指优雅的设计和架构，不是死守代码行数。我们用这几条来判断：

- **概念少，而且各管一件事。** Session、Turn、Step、Run、Tool 各有明确边界（见 [CONTEXT.md](../CONTEXT.md)）。要加新概念时，先问能不能用已有概念表达。
- **模块深。** 接口简单，复杂性藏在内部。例如界面只需要 `Session.turn`、`Session.compact` 和一个事件 `Sink`。
- **同一件事只在一处定义。** 例如每个 Tool 的名字、给模型看的说明和实现入口登记在 `tools.zig` 的同一张表里，说明由表生成；实现放在 `tools/` 下。
- **说法前后一致。** 例如要模型写 JS，给它看的接口说明也用 JS。
- **不为还没出现的需求设计，没有证据不加特例。**

代码行数只是一个观察指标：突然膨胀时值得回头审视设计，但它本身不是目标。

## 立足当下，面向未来

nib 面向越来越强的模型：给模型事实和能力，不替它做判断。评估一项设计时先问：如果模型是完美的，它还需要这个吗？

仍然需要的，属于设计本身：模型看不到的事实（限额、成本、耗时、截断、出错时实际收到的输入），扩展能力的机制（llm、agent、逐 Step effort、插话），边界（不可逆和对外操作、凭证、不可信的外部内容），用户的策略（预算、上限、是否自动发布），以及对过时信息的纠正（例如 Run 失败或用户插话后，此前声明的降档失效）。

为当下做的妥协同样有价值，但必须可识别、可度量、可删除。妥协分三类：模型补丁（当前模型会犯的错）、实现妥协（我们的实现还不够好）、写死的策略（本应由用户配置的值）。每一项都登记在 [compromises.md](compromises.md)，写明位置、原因、观察信号和删除条件；没有登记的妥协不进代码。提示词里的模型补丁集中在 `src/session.zig` 的 `patches`，可用 `NIB_PATCHES_OFF` 关闭，以便用 `scripts/stats.py` 对比是否仍然需要。

写工具说明和系统提示时，陈述事实和代价，由模型权衡；不写"什么时候该用"。

## 索引

- [CONTEXT.md](../CONTEXT.md)：术语表，统一我们说话用的词
- [adr/](adr/)：架构决策记录
  - [0001 Zig，从零开始](adr/0001-zig-from-scratch.md)
  - [0002 只暴露 run(code)：模型写 JS，跑在 QuickJS 里](adr/0002-run-code-only.md)
  - [0003 每次 Run 都是全新的沙箱](adr/0003-stateless-runs.md)
  - [0004 两层隔离](adr/0004-two-layer-isolation.md)（暂缓：系统层沙箱不做，语言层已实现）
  - [0005 一个 Session 一个进程](adr/0005-process-per-session.md)
  - [0006 不审批，宿主侧拒绝危险命令](adr/0006-deny-dangerous-commands.md)
  - [0007 保持 system 稳定，按完整 Step 压缩上下文](adr/0007-context-compaction.md)
  - [0008 支持 thinking 模型，默认 deepseek-flash](adr/0008-thinking-models.md)
  - [0009 Run 内工具调用真正并发，顺序按 JS 语义](adr/0009-concurrent-tools.md)
  - [0010 子 agent：tools.agent 派生独立 nib 子进程](adr/0010-subagents.md)
  - [0011 一个 Provider 接口，两种线路协议](adr/0011-provider-wire-protocols.md)
  - [0012 新增 grep、glob、fetch，搜索用 Zig 原生实现](adr/0012-search-and-fetch-tools.md)
  - [0013 tools.llm：轻量的单步 map 单元](adr/0013-llm-functions.md)
- [ask-json.md](ask-json.md)：`ask --json` 的 NDJSON 事件格式、进度与用量
- [session-log.md](session-log.md)：会话日志、恢复/取消、计时字段与统计口径
- [replay.md](replay.md)：本地私有工具录制、离线 Run 重放与一致性报告
- [reflect.md](reflect.md)：只读反思、回答保存与 issue 自动发布
- [config.md](config.md)：NIB_HOME、配置文件、环境变量、覆盖优先级与 effort 持久化
- [codex.md](codex.md)：使用本机 Codex 登录、配置与凭证边界
- [run-output.md](run-output.md)：工具数据完整性、显式上限、Run 输出预算与执行超时
- [tool-delegation.md](tool-delegation.md)：read / llm / agent 的选择、接口与委派实现
- [compromises.md](compromises.md)：为当下做的妥协登记表（模型补丁、实现妥协、写死的策略）
- [releases/](releases/)：版本发布说明（[0.2.0](releases/0.2.0.md)）

## 没写成 ADR 的选择

这些容易撤回，记一笔即可：

- **统一用户目录 `NIB_HOME`（默认 `~/.nib`）。** 像 `~/.codex` / `~/.claude` 一样把全局指令、非秘密配置和会话放在一个可整体定位、备份的目录，不读取 XDG 路径，也不自动迁移旧文件。`config.toml` 采用自行实现的小型 TOML 子集，不为少量标量键引入依赖；不存 API key 或 token，避免可备份、可编辑的配置文件成为另一份凭证，Codex 登录仍归 Codex 管理。TUI `/effort` 自动保存用户已确认的选择，避免每次启动重设；原子更新顶层 effort 并保留其他行，`default` 删除该键，CLI 覆盖不落盘。暂不引入项目配置与第二套合并规则，项目约定用 `AGENTS.md`。格式及优先级见 [config.md](config.md)。

- Provider 支持 Codex Responses（默认，gpt-6.1-sol）与 Chat Completions（DeepSeek），见 [0011](adr/0011-provider-wire-protocols.md)。
- TUI 用 libvaxis。`/` 指令：`/help`、`/new`、`/resume <id>`、`/compact`、`/effort [level]`、`/copy`、`/reflect [focus]`、`/js <code>`，定义在 `src/tui/commands.zig` 的一张表里，`/help`、候选列表和参数候选都由它生成。输入 `/` 时在输入框上方按前缀列出候选：↑↓ 选择，Tab 补全，Enter 执行（需要参数的指令先补全再等参数），Esc 关闭。`/resume` 的候选是当前目录下有用户消息的会话（最近的在前），没说过话的空会话不列出，`-c` 同样跳过它们。`/help` 和 `/copy` 在回合进行中也能用；`/copy` 通过终端的 OSC 52 写剪贴板，终端不支持时不会生效。布局从上到下是对话区、可选活动行、`/` 菜单、圆角输入框、提示行。活动行只在忙碌、上翻历史或有临时提示时占一行：忙碌显示转圈、阶段（thinking / writing / running / retrying / compacting）、阶段秒数、当前 Step 和 `esc to cancel`；上翻显示 `↑ history · PgDn to return`；复制反馈也放在这里。这几种状态可以同时显示。输入框内容至少一行、最多屏高的 1/3，超出时框内滚动并保持光标可见；空框显示淡色 `Message nib · / for commands`。下边框显示模型、effort、ctx 百分比、当前轮 in/cache-hit 比例/out（k、M 单位）和步数，空闲时保留上一轮统计。每次模型请求返回 usage 和完整 Step 提交后更新，不等整个 Turn 结束；ctx 使用最新已提交上下文的估计值，压缩后也刷新。服务端尚未报告的 token 不按流式文本猜测。放不下时从右往左省略字段（模型名自身过长时才截断），不覆盖圆角。高度小于 8 行先隐藏提示行，小于 6 行或宽度小于 8 列退化为 `› ` 样式。提示行只列已实现的发送、换行、指令和 ctrl+o。超过 5 行或 800 个 Unicode 字符的用户消息默认折叠成首行摘要和淡色的 `… +N lines`，首行按可用列宽截断，现场消息与日志回放用同一规则；与 Run 共用 ctrl+o 展开状态。推理内容不在对话区展示（包括恢复的历史），不影响模型推理、日志或底部 thinking 活动提示。Run 默认折叠成一行（显示状态、用到的工具、耗时和改动的文件，如 `src/a.zig +3 −1`；超过两个文件时显示总数），ctrl+o 全部展开或收起，展开后在脚本和输出下方显示带颜色的 diff（最多 60 行）。改动只统计 edit/write，按 Run 开始前的内容比较；bash 和子会话的改动看不到，改动信息也不写进会话日志，恢复会话后的历史 Run 不显示。TUI 开启了鼠标上报：滚轮滚动对话区；左键拖动按屏幕行连续选中文字并反色高亮，松开即复制，显示 `copied N chars`。反向拖动同样支持，宽字符只复制一次，每行去掉行尾空格，屏幕行之间保留换行。复制先发送终端 OSC 52（可用于 SSH）；有图形会话时再通过 stdin 写入 `wl-copy`（Wayland），否则使用 `xsel` 或 `xclip`（X11）。本地剪贴板程序不可用或失败时仍保留 OSC 52 尝试；终端可能禁用或不支持 OSC 52。单击、滚动或窗口尺寸变化会清除选区；流式输出时选区不跟随文本，只复制松开时的屏幕内容。操作：PgUp 翻半屏，PgDn 在上翻状态直接回到底部，shift+↑↓ 滚 3 行；向上翻看时视口按顶部条目锚定，新内容到达不推移画面，回到底部后恢复跟随。输入框中 Enter 发送普通消息：回合进行中也会立即清空输入框，在对话区显示用户消息及淡色 `queued` 标记。Session 按提交顺序在下一次 Step 的模型请求前插入这些消息（在上一 Step 的工具结果之后），插入后去掉标记；不会打断正在进行的请求或 Run。如果本轮已给出最终回答，剩余消息用空行合并后自动作为下一轮输入；Esc 取消时尚未插入的消息用空行合并放回输入框，已有草稿接在其后，等待用户决定是否重发。失败时同样回填，不自动重试。已插入消息按普通 user 消息写入日志并按原顺序恢复；`ask --json` 没有交互队列，事件格式不变。shift+enter / alt+enter / ctrl+j 换行，粘贴内容中的回车不会提交；一次 bracketed paste 超过 5 行或 800 个 Unicode 字符时，显示成 `[Pasted #1 · 214 lines]` 块（单行显示字符数），编号在每份草稿内递增；短粘贴直接插入。块的左右移动一次跳过，退格/Delete 一次删掉整块，不能进入标签内部编辑。编辑器保存标签的字节区间及独立原文，不占用 Unicode 私有区码点；标签与普通文字重名也不会误识别。发送时展开原文，模型和日志只收到原文。光标在首行按 ↑、末行按 ↓ 翻阅进程内输入历史，现场草稿保留块边界与编号；日志恢复的长用户消息整条变成一个块，短消息保持原文（不另外跨进程保存历史）。assistant 文本渲染基础 Markdown：代码围栏（含未闭合的）、行内代码、粗体、标题。
- 会话持久化、恢复和项目指令已实现（2026-11-01，一手源码：`src/session.zig`、`src/session/log.zig`、`src/session/instructions.zig`、`src/main.zig`）。日志按完整 Step 同步落盘；详细行为见 [session-log.md](session-log.md)，端到端检查可运行 `zig build` 后执行 `python3 tests/test_session.py`；插话、自动续发、Esc 回填与插话日志恢复由 `python3 tests/test_interjections.py` 通过 PTY 和本地 mock 检查。

## 暂缓的想法

想到了、但现在不做的事。每条写清楚为什么暂缓、什么时候再考虑，避免遗忘，也避免被误当成已定的计划。

- **流式执行 / 推测预取。** 本次任务给出的会话统计样本：114 个 Step、总计 3708 秒；只读预取最多约省 1.6 秒（0.04%），run 参数生成中位 0.7 秒，read/grep 几乎不耗时，耗时 bash 大多排在 edit 之后。现阶段收益不足以抵消部分参数解析、依赖判断和取消/副作用边界的复杂度，暂缓。仅当工作负载出现“长代码生成 + 前置慢只读工具”时重新考虑。统计字段与口径见 [session-log.md](session-log.md)。

第二期输入区计划：

- **逐条撤回尚未插入的消息。** Step 边界插话、末尾自动续发和 Esc 回填已实现；单独选择/撤回某条排队消息尚无交互入口，等实际需要精细管理多条插话时再考虑。
- **`@` 引用文件。** 复用 `/` 菜单和 `walk.zig`，插入的只是路径；暂缓是为了先完成单一候选菜单与新布局的兼容，再添加触发规则与路径筛选。
- **跨进程输入历史 `~/.nib/history.jsonl` 和 ctrl+r 搜索。** 本期仅保留进程内草稿及会话日志恢复；持久历史涉及敏感输入、保留策略与多进程追加，搜索还需要独立交互状态，第二期一起设计。
- **ctrl+g 用 `$EDITOR` 编辑草稿。** 需处理终端暂停/恢复、临时文件清理与粘贴块展开后如何导回，第二期在新草稿模型稳定后再接入外部编辑器。

Run 内工具并发、`nib ask --json` 和 `tools.agent` 均已实现，见 ADR 0009–0010；NDJSON 格式见 [ask-json.md](ask-json.md)，委派调用约定见 [tool-delegation.md](tool-delegation.md)。`zig build` 后执行 `python3 tests/test_session.py` 可检查会话恢复、机器事件、子 agent 并发/深度/用量/取消及启动开销（全程本地 mock，无真实 key）。其他被搁置的方案记在对应 ADR 里：系统层沙箱（[0004](adr/0004-two-layer-isolation.md)）、守护进程（[0005](adr/0005-process-per-session.md)）、跨 Run 的变量存储（[0003](adr/0003-stateless-runs.md)）、混合原生工具调用和 Python 运行时（[0002](adr/0002-run-code-only.md)）。

## 度量

这些是观察值，不是目标或禁令。数字会变，以最新实测为准，每次更新请写日期。

会话质量用 `python3 scripts/stats.py` 只读统计真实日志；可传一个或多个文件/目录，用 `--cwd` 精确匹配工作目录、`--since YYYY-MM-DD` 按每条记录的 `at` 筛选，包含指定日期的本地午夜。恢复旧会话不会把带时间戳的历史 Step 算进新区间；旧记录缺失或无效的 `at` 回退到文件修改时间，仍可能混入历史数据。文本报告和 JSON 的 `time_filter` 分别列出入选记录的时间戳/回退数量及回退的完整 Step 数；计数不含 header、修复和压缩替换记录，但包含诊断和打断记录。修改提示词或工具前后，分别对日志快照运行 `python3 scripts/stats.py 快照目录 --json > before.json` / `after.json`，在相同 cwd、模型和任务类型下比较 Run 失败率、错误分类、平均步数/耗时、token 和缓存命中率，同时检查样本量及字段覆盖率。

新写入的每条日志记录带 `at`（Unix 毫秒，记录追加时的墙上时钟时间，非请求开始时间），包括 header、完整 Step、诊断、打断与压缩替换；恢复时兼容没有 `at` 的旧日志。完整 Step 记录另有可选的 `usage`（仅本次模型请求的 prompt/completion/cache-hit token，不重复计入子会话）、`ms`（单调时钟，从请求开始含重试直到全部 Run 结束，不含压缩和日志落盘）及 `run_results: [{tool_call_id, ok}]`。旧记录照常 replay，缺失字段不补零；失败率仅以有显式状态的 Run 为分母，旧日志的未知状态单列。Turn 数包含区间内有非诊断记录的 Turn，平均步数只计入选的完整 Step；Turn 耗时只平均已结束、全部 Step 都入选且每步都有计时的 Turn，跨筛选边界的 Turn 不参与耗时平均。会话数包含 header 或非替换记录入选的会话；压缩替换记录不计为新 Turn/Step，历史工作量不会因压缩而消失。

工具与 bash 命令统计是 JS/静态 shell 调用点估计，不代表循环、动态代码的实际执行次数。错误按每个 Run 的诊断特征计数（类别可能重叠），并另计 interrupted 标记；源码/read 正文不作故障匹配。被 JS 捕获的工具错误或 bash 的 exit_code 127 也会进入分类，但不一定导致 Run 失败。脚本的合成日志测试：`python3 tests/test_stats.py`；真实 Step 元数据和 mock 会话计数由 `tests/test_session.py` 覆盖。

| 项目 | 实测值 | 警报线 | 测量方式 |
|---|---|---|---|
| 源码行数（`src/` + `build.zig`，含测试） | 3766（2026-11-01，实现工具并发、NDJSON 与子 agent 后） | — | `wc -l build.zig src/**/*.zig`（zsh） |
| TUI 单帧 draw 耗时，5000 条目、100×24 | 底部跟随 102.5 → 29.7 µs；上翻 1200 行 1149.5 → 57.2 µs（2026-11-01，ReleaseFast，加高度缓存前 → 后） | — | 预热后每组 32 帧，5 组平均值取中位数，只测 draw（feat/tui-polish 的报告） |
| `nib js '1+1'` 平均耗时（含进程启动） | 1.6 ms（2026-11-01，ReleaseFast） | — | 循环 100 次取平均 |
| 工具 Promise.all / 依次 await：两个 sleep 0.3 | 307 / 611 ms（2026-11-01，Debug） | — | `src/tools.zig` 测试，见 ADR 0009 |
| 子进程启动至 NDJSON start（含日志同步，不含 TLS） | Debug 中位数 11.82 ms；ReleaseFast 中位数 1.30 ms（2026-11-01） | — | `tests/test_session.py`，10 次，见 ADR 0010 |
| 上述命令峰值 RSS | 3.7 MB（2026-11-01） | — | `/usr/bin/time -f %M` |
| 二进制体积（ReleaseFast，strip 后） | 1.9 MB（2026-11-01） | — | `strip` 后 `ls -l` |
| TUI 进程空闲 PSS（一轮对话后，无 TLS） | 3.08 MB/进程，10 个合计 30.8 MB（2026-11-01，ReleaseFast） | — | 10 个 TUI 对本地模拟服务器各聊一轮，读 `/proc/<pid>/smaps_rollup` 的 `Pss` |
| 一次 HTTPS 请求峰值 RSS（含 TLS） | 7.6 MB（2026-11-01，ReleaseFast） | — | `/usr/bin/time -f %M nib ask hi`（无效 key，收到 401） |
