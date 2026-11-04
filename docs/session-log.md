# 会话日志、恢复与计时

## 恢复会话

恢复：`nib -c` / `nib --continue` 继续当前目录最近的根会话（跳过子会话）；`nib --resume <32位小写十六进制ID>` 指定会话；`ask` 也支持这些选项，放在 prompt 前后均可。

新会话按基础指令、全局 `$NIB_HOME/AGENTS.md`（默认 `~/.nib/AGENTS.md`）、项目 `AGENTS.md` 的顺序拼接 system，后者优先。项目目录是从 cwd 向上遇到的第一个 `.git` 标记所在目录；没有则用 cwd。只读取 `AGENTS.md`。恢复会话沿用日志中的原始 system，之后修改指令文件只影响新会话。

## 实验标签（header）

日志首行是 header，根会话与子会话在新建时记录以下可选字段；旧日志缺失时仍可恢复。标签只用于记录和统计，不发送给 provider，也不改变执行、系统提示或工具说明。恢复会话保留原 header，不用当前构建或环境重算、回填或改写。

| 字段 | 含义 |
| --- | --- |
| `nib_version` | `build.zig.zon` 版本号加构建时注入的 git 短提交号，如 `0.1.0+abc1234`；无法取得提交号时仅版本号。 |
| `system_sha` | `system_template` 实际渲染结果（含 cwd、工具说明和生效补丁，不含全局/项目 AGENTS.md）的 SHA-256 前 12 位小写十六进制。因此 cwd、工具可用性或补丁变化也可能改变它，不只是模板文字修改。 |
| `patches_off` | `NIB_PATCHES_OFF` 实际禁用的已注册补丁 id，去重并排序；未知 id 忽略，`all` 展开为全部已注册 id。没有禁用项时省略字段。 |

## 提交与中断

会话日志位于 `$NIB_HOME/sessions/<ID>.jsonl`（默认 `~/.nib/sessions/`）。新写入的每条日志记录带 `at`（Unix 毫秒，追加时的墙上时钟时间），恢复兼容无时间戳的旧记录；`scripts/stats.py --since` 按记录时间筛选，无效或缺失 `at` 回退文件修改时间并报告数量。日志只在完整 Step 后提交；Codex 请求最终失败时另追加 `diagnostic: {error_name, message, attempts, step}` 诊断记录（message 保留服务端 code/reason），不提交用户消息或失败输出，不改变模型历史和 context_tokens，恢复时跳过；`scripts/stats.py` 将其计入 `errors.provider_failure`，不算 Step/token。取消（TUI 的 Esc、ask 收到 SIGTERM/SIGINT）时额外提交本轮用户消息和已流出的文本，TUI Esc / ask SIGINT 在末尾标记 `[interrupted by user]`，ask SIGTERM 标记 `[interrupted: process terminated]`，未完成的工具调用丢弃；恢复不重执行已提交的 Run；未完成 Step 可能已产生外部副作用，日志不回滚这些变化。

模型请求的两条线路共用 `src/provider/cancel.zig` 的 `std.Io.Select` 取消封装：请求任务实时写入 sink，另一个任务每 20 ms 检查 cancel 标志；取消时中断连接、发送或读取中的阻塞 I/O，并等待请求任务清理后返回 `error.Canceled`，无需等下一块数据。TUI Esc 与 ask SIGINT/SIGTERM 均走此路径，不设读超时，不改变重试策略；已流出的文本继续由原有 `commitInterrupted` 提交。

## Step 计时字段

工具参数与结果的私有录制独立写入同目录 `<ID>.calls.jsonl`，默认开启、`NIB_RECORD=off` 关闭，权限 `0600`。它不属于主日志：恢复、压缩、统计与 `/reflect` 都不读取、上传或引用其内容，仅 [nib replay](replay.md) 为离线重放读取。主日志里的 `calls` 仍只是下述计时元数据，不含录制正文。

完整 Step 的可选计时字段（旧日志缺失时正常恢复）：`model_ms` 是模型请求总耗时，包含重试和退避，`attempts` 是实际尝试数；`first_data_ms` 是 provider.Sink.onData 首次收到任何 SSE 数据（含心跳、元数据）相对 Step 开始的时间，不代表首个模型内容 token。`code` 每个 run 一条 `{tool_call_id, first_ms, last_ms, progress}`，首尾时间相对 Step 开始，`progress` 是 `[ms, 累计参数 UTF-8 字节数]` 数组；接收时按到达顺序写入每调用最多 1024 点的固定缓冲，超出后按 stride 跳采，finish 时一次均匀抽样成最多 32 点并保留首尾；Codex 按 output_index、Chat Completions 按工具 index 跟踪，最终一次性参数如实记录 `first_ms == last_ms`，不推断未收到的片段。重试只保留成功请求的 code，first_data_ms 保留所有尝试中最早 onData 时间。`run_ms` 为此 Step 各 Run 从 sandbox 开始到 `session/output.zig` 格式化完成的总耗时，`run_results[].run_ms` 为单次耗时；未进入 sandbox 的调用无单次 run_ms。`calls` 最多保留 200 个宿主工具调用 `{name, start_ms, end_ms, ok, run_index}`，时间相对各自 Run 开始，run_index 是 run_results 的零起始下标，超出条数记 `calls_omitted`；ok 表示工具返回成功/错误，不等同于 bash 命令退出码。子 agent 只计父进程侧的调用，不追加参数或结果正文。所有计时使用单调 awake 时钟、毫秒单位；固定容量缓冲复用现有调度/完成路径，不新增锁或逐片段分配，不预取或推测执行，也不向 ask --json 新增事件。

## Turn 账单

TUI 在每个 Turn 的内容后追加一行淡色账单，例如：

```text
12 steps · 3m10s · think 1m40 · tools 1m20 · 45k tok (91% cached) · llm ×8 · agent ×1
```

宽度不足时从右向左移除整个字段，不换行；llm/agent 次数为 0 时不显示。失败或取消时开头为 `failed` 或 `canceled`，Step 数、think/tools 和调用次数只计已提交的完整 Step。总耗时是整个 Turn 的单调墙钟时间，不是 Step 耗时之和；think/tools 分别复用 Step 的 `model_ms`/`run_ms`。token 数使用完成 Step 后的本轮累计 usage（prompt + completion，包含截至该点已报告的压缩和委派用量），缓存率为 prompt_cache_hit_tokens / prompt_tokens。取消或失败的未完成 Step 不纳入账单，但墙钟仍包含其等待时间。

Session 累计这些数据并通过 `turn_end` 按值传给 TUI，TUI 不跨线程读取统计；账单只是界面条目，不写入模型历史，恢复旧会话时不重建。`ask --json` 的 `end/error.timing` 与账单计时相同，详见 [ask-json.md](ask-json.md)。

## Step effort 字段

完整 Step 还记录可选 `effort`、`effort_source` 和 `effort_downgraded`。`effort` 是实际请求档位，未指定服务端档位为 `default`；`effort_source` 为 `model|default|guard`，分别表示模型声明生效、用户默认（含 Run 显式 default）、护栏回退。`effort_downgraded` 仅在模型声明实际低于用户有效档位时为 true；服务端 default 下接受的 low 也按降档声明计。等档声明来源可为 model，但不算降档。重试沿用同一档位，压缩不产生 Step effort 记录。旧日志缺字段仍可恢复。

assistant 消息的可选 `step_effort: {effort, source}` 保存界面元数据，让压缩重写后保留的历史 Run 仍显示原来的请求档位；日志恢复以完整 Step 顶层 effort 字段为准。这些元数据不发送给 provider，不影响恢复后的调度；每个新 Turn 首步仍用本次用户设置。调度护栏见 [config.md](config.md#逐-step-effort-调度)。

## 会话统计

会话统计：`python3 scripts/stats.py [日志文件或目录] [--since YYYY-MM-DD] [--cwd 目录] [--group-by version|system|patches] [--json]`，默认只读 `$NIB_HOME/sessions`（默认 `~/.nib/sessions`），用于发现故障和比较改动前后效果。文本和 JSON 均包含“耗时构成”：Step/model/run 的中位数与 p90、首段代码前等待和参数生成跨度、运行时各工具调用次数/总耗时/中位耗时，以及参数到达跨度严格大于 50 ms 的 run 比例；每项列出有效样本数，旧日志缺字段不补零。bash 耗时 Top 10 按保存的 JS 命令字面量前两个 shell 单词启发式分组，无法可靠关联的动态/多调用列为 unmatched，不把整个 bash 耗时分摊给 shell 子命令。

`--group-by version|system|patches` 分别按 header 的 `nib_version`、`system_sha`、`patches_off` 分组，总体报告保留，每组分别输出核心报告；JSON 使用 `group_by` 和 `groups`。缺失标签的旧日志归 `unknown`；新版 header 有版本或系统哈希但省略 `patches_off` 时归 `none`，补丁列表按排序后的集合分组。

完整 Step 新增可选 `turn_step`（Turn 内从 1 开始的 Step 序号），只用于识别日志中的 Turn 边界，运行中插话不会另起 Turn；恢复后新 Turn 从 1 开始。旧日志缺少该字段时仍按 user 消息估算边界，可能把插话算成新 Turn。

“往返结构”（JSON `round_trips`）包含每 Turn 入选 Step 数的中位数/p90（nearest-rank、含零步 Turn），写→仅验证相邻对次数/全部相邻对，以及连续写的不同文件对次数/有效连续写对；每项给出样本数。相邻对限同一 Turn，不跨过滤或取消断点；验证沿用 bash 首两词启发式（build/test/fmt/check/diff 等），多 Run/调用必须全部是可识别验证 bash，动态或复合 shell 保守跳过。写路径只取直接 edit/write 的完整字面量，按 cwd 规范化；两步文件集合不相交才计“不同文件”，缺失/动态路径跳过，不推断 bash 的文件副作用。

耗时构成的 `timing.effort.by_effort` 按完整 Step 的顶层 effort 分组，列出 Step 数、model_ms 分布（含中位数和样本数）、prompt/cache token 总量与缓存命中率。缺 effort 的旧记录跳过，缺计时仍计 Step；缓存率为有效 prompt/cache 成对字段的总和之比，不是各 Step 比例的平均。

各档 `downgraded` 及跨档 `timing.effort.downgraded` 给出降档后的 Run 失败率：分母是有 Run 的降档 Step 数，分子是该 Step 响应后执行的任一 Run 显式 `ok=false` 的 Step 数，不关联后一个 Step，也不把无 Run 的最终回答放入分母。未知 Run 状态仍入分母并单列 `steps_with_unknown_run_status`。降档按 `effort_source=model` 且 `effort_downgraded=true` 判定；缺少后一字段的过渡记录按 model 来源推断，显式 false 排除等档声明。

机器事件接口见 [ask-json.md](ask-json.md)。
