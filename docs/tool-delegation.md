# tools.llm、tools.agent 与 tools.race：调用与实现

少量文件直接 read 最便宜，不调用模型。大量数据的单步判断、分类、抽取适合 llm，通常几秒；批量简单判断优先低成本模型和低 effort，强模型留给少量难题。agent 用于独立多步工作：几十行以上改动的提交前只读审查、先约定接口并划分负责文件的并行实现、需要大量读代码的调查；默认新建子会话从零读代码，fork 继承当前父上下文，接续保留子会话已有历史，不代替 read 或 llm。延迟与成本只是量级提示，依任务、模型和 effort 变化，不是保证。

成本参考来自本次统计时本机 `~/.nib/sessions` 的全部 105 个子会话（0.2.0 时期，以 `gpt-6.1-sol` / `high` 为主，含少量模型/effort 覆盖；旧日志部分元数据缺失），不再只用 [#37](https://github.com/yyydddkkk/nib-code/issues/37) 中的 6 个样本。统计命令：

```sh
python3 scripts/stats.py ~/.nib/sessions --json
```

`child_costs` 的每子会话实测分布（p90 为 nearest-rank）：

| 指标 | 中位数 | p90 | 有效子会话数 |
| --- | ---: | ---: | ---: |
| 完整 Step 数 | 12 | 24 | 105 |
| 累计模型时间 | 179,088 ms（约 3 分钟） | 406,863 ms（约 7 分钟） | 87 |
| prompt token 总量（含缓存） | 299,991（约 30 万） | 825,096（约 83 万） | 101 |
| 未缓存 prompt token | 43,350（约 4.3 万） | 75,479（约 7.5 万） | 101 |

输入 token 是每次请求的累计量，含重复上下文；未缓存量逐 Step 用 `prompt_tokens - prompt_cache_hit_tokens` 计算，再按子会话累加。两者同时列出：未缓存部分通常是费用与延迟的主要驱动，但缓存输入也不等于免费，总 token 不是费用。模型时间不含工具执行，亦非端到端墙钟时间，因此这里实测的 p90 约 7 分钟，不沿用约 9 分钟的初始估计。缺字段不补零，表中各指标独立取有效样本，不应将不同指标的分位数相减；失败、取消日志只代表已记录成本的下界。

这批 105 个新建子会话的开头约 6 个只读 Step 消耗约 22% 时间，完整任务约 12 Step、3 分钟、29 万级累计 prompt tokens。fork 复用父上下文的动机是减少重复调查；这不是 fork 的实测节省比例，继承更长 history 的成本与实际缓存收益仍待对照验证。

### `child_costs` 分组与有效样本

`child_costs` 以每个带 `parent_session_id` 的入选子日志为一个样本，含前台和后台；接续仍属于同一子日志，不按每次 agent 调用拆分。`child_costs.by_creation` 按子 header 的创建信息分组：

| 组 | 判定口径 |
| --- | --- |
| `fork` | `forked_from` 是对象，含非空字符串 `session` 和非负整数 `message_count` |
| `new` | header 缺少 `forked_from`，包括没有此字段的旧日志 |
| `unknown` | 显式存在 `forked_from`，但结构或字段值无效 |

只输出实际出现的组；不能把 `unknown` 或旧日志缺字段视为已验证的 fork 对照样本。`child_costs.by_parent_system` 按父会话 `system_sha` 区分工具说明修改前后的实验，每个父 system 组内也有同口径的 `by_creation`。父标签通过本次输入日志中的 `parent_session_id` 关联；父日志缺失或标签无效时归 `unknown`，不回退到子 system。

全局、各父 system 组及各 `fork` / `new` / `unknown` 创建组均包含以下分布；每个指标分别输出 `{ samples, median, p90 }`，例如 `child_costs.by_creation.fork.first_request_cache_hit_rate.samples`：

| JSON 指标 | 每子会话的取值与入样条件 |
| --- | --- |
| `steps`（Step） | 已提交完整 Step 数，不计 header 中继承的父历史 |
| `model_ms` | 各完整 Step 的模型毫秒数之和，含重试/退避，不含工具执行，不是墙钟时间 |
| `prompt_tokens`（prompt） | 各完整 Step 的输入 token 之和，含缓存与重复上下文，不是费用 |
| `uncached_prompt_tokens`（uncached） | 逐 Step 的 `prompt_tokens - prompt_cache_hit_tokens` 之和；两字段均为非负整数且 cache ≤ prompt |
| `first_request_cache_hit_rate` | 首个完整 Step 的 `prompt_cache_hit_tokens / prompt_tokens`，两字段有效、cache ≤ prompt 且 prompt > 0；逐子会话等权，不是汇总 token 后的比值 |

这些分布仅纳入非零 Step、且所有完整 Step 都在筛选范围内的子会话。`sessions` 为入选子日志数，`full_range_sessions` 为上述全范围非零 Step 子会话数，`partial_range_sessions` 记录被 `--since` 等筛选截断的子会话，`no_step_sessions` 记录没有完整 Step 的子会话；后两类不进入分布，不能把截断片段当作整次成本。

`model_ms`、prompt 和 uncached 各自要求该子会话所有完整 Step 的对应字段有效，缺失不补零，也不加父会话 usage 或工具结果中的 usage。首请求命中率只检查首个完整 Step，不因后续 Step 缺字段而排除，也不以之后的有效 usage 替代缺失的首 Step。`samples` 是各指标的有效子会话数，因此同组各指标可能不同；无有效样本时为 0，`median` / `p90` 为 null，p90 使用 nearest-rank。失败、取消或仍运行的日志仍只是已记录成本的下界。这些分组提供观测而非自动选择阈值；口径及其他筛选行为见 [会话统计](session-log.md#会话统计)。

## 接口与限额

Run 中可调用 `await tools.llm({ prompt, input, schema, model, effort })`，返回 `{ text, data, usage }`，执行一次无工具模型请求。prompt 必填，input 可省略；字符串原样传入，其他可 JSON 序列化值按 JSON 编码，与 prompt 分开，不继承会话历史、项目 AGENTS.md 或 nib system。model/effort 默认跟随有效配置，覆盖只影响本次调用。宿主在当前进程代发一次无工具请求，凭证不进入 JS；子 agent 也可用 llm。schema 可选对象：Codex 用 strict json_schema，Chat Completions 用 json_object 加提示约束；schema 仍受服务端支持的子集限制（如 Codex strict 对象的 additionalProperties:false / required）；宿主只验证合法 JSON，不做完整 schema 校验，返回解析后的 data（无 schema 时为 null）。JSON 解析失败附错误重试一次，仍失败 reject 并带有界原始输出片段；两次已报告 usage 都计入本轮累计用量，与 agent 共用归集路径，TUI/ask --json 更新 usage 快照，calls 记录名为 llm。缓存 key 使用 `<session_id>:llm`，与主会话隔离。

llm 限额由 [config.toml 的 `[limits]`](config.md#limits) 配置：同进程并发调用默认 4，可配置，超出排队（不计请求超时）；每 Run 调用上限默认 100，可配置，超出时在沙箱入队前 reject；单次 prompt + 序列化 input 合计上限默认 256 KiB（UTF-8 字节），可配置，超出 reject，不截断。请求超时沿用 provider（当前无额外读超时），限流/临时错误复用 `src/provider/retry.zig` 的主会话重试、退避与服务端延迟提示。Esc/SIGINT/SIGTERM 同时取消在途和排队调用。各 Run 仍是无状态沙箱，中间结果用 JSON 文件传递，见 [ADR 0013](adr/0013-llm-functions.md)。

根会话可调用 `await tools.agent({ prompt, resume, fork, timeout_ms: 1800000, model, effort, background: false })`。fork 为可选 boolean，默认 false。resume 为可选字符串，可省略：不传则新建子会话（fork 决定是否继承父上下文）；传入当前父会话的 agent 任务 id（如 `a1`），接续该任务对应的子会话历史和原始 system，并追加本次 prompt。仅新建时分配任务 id；接续沿用原任务 id，不分配新 id。例如 `resume: "a1"` 的前台结果、后台启动确认和完成消息、progress 事件及 TUI tree 均使用 `a1`。每次仍启动独立的 nib 子进程、运行一个 Turn；内部通过 `nib ask --resume <内部子会话 ID>` 恢复，不是常驻 worker。默认新子会话独立读取指令文件，不继承父会话历史；`fork:true` 的区别如下。

`fork:true` 继承父会话压缩后的当前完整 history，而不是从原始日志重建被压缩丢弃的内容；system 和工具 schema 与父会话逐字节相同。截取点包含发起 fork 的当前 assistant 消息，包括 reasoning（Codex 的加密推理条目也保留）和工具调用。子会话先为该 assistant 的工具调用补齐合成 tool results，再追加本次 prompt 作为 user 消息；这些合成结果不是父 Run 尚未完成的真实结果，也不会在子会话重跑父 Run。

每次 fork 都新建独立子会话和新的 `aN` 任务 id，后续可用 `resume: "aN"` 接续；`fork` 与 `resume` 同时传入是参数错误（即使 `fork:false`），reject。fork 仍使用普通子 agent 的执行深度，不开放递归：虽然继承的 system/schema 仍描述 agent，运行时不能再调用 agent。子会话与父会话共享 cwd，没有独立 worktree；fork 也复制历史截取点已有的文件版本观察，继承内容不是未观察文件，直接 write 仍受过期检测；已有跨进程文件锁、原子替换和过期检测继续生效，但不提供工作区隔离，也不协调 bash 或用户编辑器的写入。

文件版本观察只在新建 fork 时复制，不写入会话日志；与普通恢复一致，后续 resume 重新开始观察。

fork 的 model/effort 可覆盖，默认继承产生当前 assistant 请求的实际有效配置（包括一次性的 Run effort），显式覆盖优先；只有 model 与 effort 都相同时才保留父前缀的缓存复用优势，改变任一项就失去这一优势。Codex fork 与 resume 使用相同的模型一致性约束：不能把父历史中的加密推理条目带到另一模型；覆盖 model 也不绕过此检查。Codex fork 的 `prompt_cache_key` 沿用父值，旨在路由到同一缓存；实际能否命中、节省多少仍是待实测假设，不是协议保证，见 [codex.md](codex.md#fork-与父缓存路由) 与 [ADR 0015](adr/0015-agent-fork.md)。

前台成功返回 `{ ok: true, id, text, usage, changes }`；子会话超时、崩溃、非零退出或 NDJSON error 返回 `{ ok: false, id, error, text, usage, changes }`，不会 reject，也不会取消同一 Run 中的其他子 agent。id 为任务 id（接续时沿用原 id），不是内部子会话 ID；工具返回值、错误诊断和后台结果不向模型暴露内部子会话 ID。只有参数错误（包括 resume 格式错误）和用户取消（Esc/SIGINT/SIGTERM）仍 reject。text 成功时取 end.text；失败时保留已收到的最终文本（text delta，不含思考或工具代码），没有则为空串。error 保留失败原因、实际耗时（含终止宽限）、任务 id 和文件可能不完整的诊断。usage 和 changes 只统计本次调用，不重复累计子会话之前的历史。

父会话日志持久化任务 id 到内部子会话 ID 的映射，恢复父会话时重建；模型只使用任务 id。只能接续当前父会话的 agent 任务：目标子会话日志的 `parent_session_id` 必须等于当前父会话 id；不存在的任务、非本会话 agent（包括非 agent 任务）或没有内部子会话映射的任务均返回 `ok:false`，不 reject；传入内部子会话 ID 也不能接续。父会话恢复后仍可接续其原有子会话，根会话或其他父会话的子会话不能接续，返回 `ok:false`。执行阶段在等待并发槽之前预留目标 agent；同一 agent 一次只允许一个在途调用（含排队、前台和后台），busy 时立即返回 `ok:false`，不排队、不分配新 id。预留在完成、失败或取消时释放，前台和后台共用；日志独占锁另外阻止跨进程同时接续，包括 CLI。失败、超时或取消不删除已有映射；内部子会话日志可恢复时仍可接续，尚未取得内部子会话 ID 的任务没有可接续映射。停止不回滚文件，日志或 changes 不保证包含中断前的全部改动。

timeout_ms 可省略，默认 30 分钟，不计排队时间。model/effort 省略时继承父会话的当前有效配置，接续时也不改为沿用子会话上次覆盖值；覆盖只影响本次子调用，不影响父会话或切换 provider，effort 沿用现有校验与映射。恢复的 provider 必须与日志一致，Codex 模型也必须相同（见 [codex.md](codex.md)）；父会话当前模型与子会话原模型不同时，省略 model 的接续调用仍受此约束。同时运行的子会话上限默认 4，可配置（全部工具最多同时运行 8 个）。子会话沿用 cwd、有效 provider/模型配置及限额（通过 stdin 管道传递，子会话跳过配置文件读取；Codex 凭证各自读取）。内部环境变量 `NIB_AGENT_DEPTH` 从 0 递增，深度达到 1 时，默认新建子会话的工具说明与实际 JS API 都移除 agent；fork 为保留父请求前缀不改写说明/schema，但运行时同样不能调用 agent。`NIB_PARENT_SESSION_ID` 写入新子会话日志首条记录的 `parent_session_id`。显式 `--resume` 子会话仍保留深度限制；`--continue` 跳过子会话。

`background` 可选，默认 false，保留上述前台等待行为。设为 true 时，调用在成功登记后台任务后立即返回 `{ id }` 启动确认；接续 `a1` 时仍为 `{ id: "a1" }`，busy、不存在或非本会话 agent 直接返回 `ok:false`，不登记后台任务。子会话由父会话持有，可跨 Run 继续工作；父模型可继续其他 Step，不需要额外的查询或等待工具。任务完成后，Session 在下一次主模型请求前，把 `[background agent <id> finished]` 和截断后的 `{ok,id,text,changes,error?}` JSON（id 与启动确认相同）作为 user 消息插入历史，不含 usage。结果不会在模型流式响应或 Run 执行中途插入，也不会当作用户新 Turn。若模型已给出无工具回答但仍有后台任务，Session 等待下一条 inbox 消息（后台结果或用户插话），按 FIFO 插入后发起新 Step；不必等待全部后台任务完成。

后台任务与前台调用共用 agent 并发限额、模型/effort 配置、超时和取消路径；同一父会话的各 Run 不会因各自沙箱退出而取消后台任务。父 Turn 取消或失败、Session 退出时停止并清理未完成任务，不留下脱离父会话的子进程；恢复会话保留已写入日志的结果，未完成任务不会重启，而是插入 `[background agent <id> lost: process ended]`。后台 agent 的启动/结果插入通过 `background` 事件报告，见 [ask-json.md](ask-json.md)；结果消息的日志来源标记与统计口径见 [session-log.md](session-log.md)。

`tools.bash({command, background: true})` 同样立即返回含 `id` 的启动确认；后台 bash 独立于 agent 并发限额。agent 与 bash 分别使用会话级编号 `a1、a2…` 和 `b1、b2…`：前后台 agent 仅在新建时分配，接续不递增编号、沿用原 id，后台 bash 在启动时分配，前台 bash 仅运行超过 3 秒、开始显示进度时分配。计数跨 Run/Turn 保留；恢复时根据日志中的任务 id 分别取各前缀最大值继续编号，兼容旧的共用计数日志且不补空号。后台 bash 最多同时运行 8 个，超出时立即 reject 并给出明确错误，不排队；子 agent 内也可使用。结果在下一次主模型请求前作为带来源标记的 user 消息插入，恢复未完成任务时插入 lost 消息。后台 bash 的生命周期也通过 `background` 事件报告。

`tools.bash({command, background: true, detached: true})` 是会话级任务：跨 Run 和正常 Turn 存活，最终回答和 Step 上限收尾只等待普通后台任务，不等待 detached；停止提示只列实际等待的任务。detached 要求 `background:true`，默认 `timeout_ms:0`（无截止时间），也可显式指定正数超时；普通 bash 默认 120000 ms。它与其他 bash 共用 b 计数器、并发和输出上限。完成时只入 inbox，空闲时不自动发起 Turn；下一次 Step/Turn 消费一次。Turn 取消/失败、Session 退出或切换清理全部任务；ask 回答后退出 Session，因此不跨 ask 进程保活。恢复会话不重启进程，沿用 lost 消息。

`tools.stop({id}) → {id,stopped}` 按现有 a/b id 取消并 join 单个后台 bash/agent，清理进程组。停止运行中的任务返回 `stopped:true`；已结束的已知任务返回 false，未知 id reject。并发停止同一任务只 join 一次，完成结果仍经原 inbox 路径投递一次。stop 返回前释放 agent 的执行占用；它不删除任务身份。启动和 stop 都经普通工具统一结算/录制出口，后台结果消息按 UTF-8 字节计入接收它的 Step 的 output_bytes。见 [ADR 0014](adr/0014-session-background-jobs.md)。

后台 agent/bash 的执行失败通常转换成结果消息；若后台工作线程自身出错，无法生成或写入 inbox 结果（例如分配失败），内部错误由轮询路径上报一次，该任务不再计入待结果集合，后续 Run 不会反复收到同一错误。

changes 汇总本次调用中子会话所有 Run（包括失败 Run）已收到的 `run_end.changes`，按路径首次出现顺序返回 `[{ path, added, removed, created }]`：同路径 added/removed 累加，created 取逻辑或，不含 diff 正文。每个 Run 也按本会话每次成功 edit/write 的紧邻 before/after 内容累加，不是 Run 或整个子会话起止文件的净 diff；改后又撤销仍累计两个方向，失败的工具调用不贡献改动。Run 的 diff 按操作拼接，操作间用 `…` 分隔，每路径整个 Run 限 200 行改动/上下文（不含省略标记），不影响完整计数；格式见 [ask-json.md](ask-json.md)。

Run 结束只取已记录的改动，不重新读盘。bash、外部进程、父/其他子会话和后台任务在两次 edit/write 之间或最后一次写入之后的改动不归入当前会话；后续操作读到这些内容时，可以在 diff 中显示为未改动的上下文。后台 agent 的改动只由其自己的 Run 记录，随该任务的结果 changes 返回，不归入启动它或同时运行的前台 Run；子会话的 changes 也不会把父会话或 bash 同期的改动算给自己。这些记录不是当前磁盘状态或文件所有权的证明。write 沿用 16 MiB 的 before 读取上限；已有文件的 before 超限或无法读取时，写入仍可成功，但该次操作不计入 changes。中断时尚未发出 run_end 的改动也可能不在汇总中，失败后仍须检查半成品文件。

## 进度、用量与取消

任意工具调用失败都不会取消同一 Run 的其他调用，不限于返回 `ok:false` 的子 agent。顶层 Run Promise fulfill 和 reject 都继续 drain 在途及排队工具、JS jobs 和 continuation 新发起的调用；顶层 reject 时，Run 仍报告原始拒绝原因。因此 `Promise.all` 中 read 或 llm reject 后，其他前台 agent 仍会工作到完成：父 Run 要承担其剩余等待时间与用量，用户仍可按 Esc 取消。

llm 与 agent 的 usage 都计入本轮累计用量。只有用户取消（Esc/SIGINT/SIGTERM）或 JS 执行超时才中止 Run 内在途及排队工具；工具自身超时不影响其他调用。若中止时还有未完成调用，Run 输出保留一行 `[stopped before completion: bash #0, agent #2]`，索引按该 Run 内全部工具调用的创建顺序从 0 开始，不是后台任务 id。输出预算和 JS 执行预算见 [run-output.md](run-output.md)。

子进程 NDJSON 在运行途中按完整行观察；最终输出仍按原路径解析和统计。进度使用受互斥锁保护、每次调用仅保留最新快照的队列（同任务 id 的各次调用分开记账）；工具线程只更新队列，不调用 Session sink。Run 线程在 sandbox 的 Promise/工具等待循环里约每 20 ms 尝试转发，转发不计入 JS 执行预算；eval 返回前已停止并 join 所有前台工具线程，后台 agent 由父会话持有，不随 Run 结束而 join；进度队列在 Turn 结束时清理，后台任务的原 Run 进度会继续显示到结果插入。TUI 收到事件后复制数据到自身事件循环，在发起任务的 Run 下方默认显示子任务树，每个任务固定一行，按创建顺序排列并按 id 原地更新；接续 `a1` 的 progress 事件和 tree 行仍标为 `a1`，不生成新的任务 id。agent 行为 `  ├─ a1 prompt 摘要 · 状态 · step N · 工具名 变更文件`，bash 行为 `  └─ b2 bash 命令摘要 · 已运行时间 · 状态`（分支符按行位置变化）。前台 bash 运行超过 3 秒才出现在所在 Run 下，此后每秒更新时间，结束后保留最终状态；不到阈值的命令不出现，Run 标题不变。时间小于 60 秒显示为 `42.3s`，否则为 `3m12s`。普通后台任务在结果送达前显示 `background`；detached 任务运行中显示 `detached`，结束或被停止后显示最终状态。prompt 和命令最多预览前 40 个 Unicode 字符；窄屏先缩短 prompt/命令，再缩短末尾文件信息，优先保留 id、状态和 step 或时间，不换行。ctrl+o 只切换 Run 代码、结果及 diff 的展开，不隐藏子任务树。Run 结束恢复工具/耗时/改动摘要，并保留最后收到的子任务状态；从历史恢复的 Run 不重建子任务树。后台结果条目使用相同 id：成功为 `✓ b2 bash · ok · 输出预览`，失败为 `✗ a2 agent · failed · 文本预览`，丢失为 `✗ a2 agent · lost`；ctrl+o 展开仍显示完整 JSON 结果，历史恢复也使用相同格式。工具名来自最近一次 Run，文件仅为 edit/write 报告的变更路径，不代表当前正在执行的命令或任务完成百分比。

bash 与子会话复用标准库子进程等待和进程组执行器。所有 bash（包括 detached）在 shell 退出时清理整组，包括成功返回和 `nohup/&`；主进程退出后只排空管道中已有输出，不等待同组后台子进程。detached 任务随 shell 退出而结束，服务在命令内前台运行；`server & exit 0` 会结束任务并清理服务。stop、超时、Turn 取消/失败、Session 退出同样清理进程组。取消和超时时，子 nib 先收到 SIGTERM，有 500 ms 取消自身工具，之后强制终止。用量按已收到的累计快照统计，无法推知服务端尚未报告的 token。文件工具的 `read` / `edit` / `write` 通过 `$NIB_HOME/locks/` 中按目标规范路径 SHA-256 命名的持久 advisory lock 文件，协调共用 NIB_HOME 的独立进程和子会话；相对路径与符号链接别名共用锁，释放时不 unlink。`edit` / `write` 使用同目录 `.nib-*` 临时文件加 rename 原子替换；会话记录 inode、size、纳秒 mtime，`write` 拒绝覆盖已观察文件的外部改动，重新 `read` 后可重试，未观察过的已有文件仍可直接写入。bash／用户编辑器不参与该锁，版本检查只能发现检查前已经发生的改动，不能消除检查到 rename 之间与不合作写入者的竞争。完整的权限、符号链接、硬链接及持久性边界见 [run-output.md](run-output.md#文件替换会话版本与跨进程协调)。

## 工具说明的生成

新会话构建 system 时，`src/tools.zig` 根据有效 provider 配置生成 llm 的模型列表：Codex 模型取自 `src/provider/codex.zig` 的目录；Chat Completions 至少提供 `src/provider/openai.zig` 的默认模型，另加入当前配置模型并去重。effort 说明只列常用的 low/medium/high，省略 model/effort 仍继承当前配置；完整档位与映射见 [config.md](config.md) 和 [codex.md](codex.md)。选择只在当前 provider 内进行，不隐式切换 provider。

工具说明中的模型名按 JSON 字符串编码，不直接插入原始配置文本。根会话与默认新建子会话使用同一生成路径，但默认子会话隐藏 agent；fork 复用父 system/schema，不重新生成，agent 的不可递归边界由运行时执行。恢复会话仍沿用日志原始 system，不改写历史。架构理由见 [ADR 0010](adr/0010-subagents.md)、[ADR 0013](adr/0013-llm-functions.md) 与 [ADR 0015](adr/0015-agent-fork.md)。

## tools.race

`await tools.race({ branches: [{ prompt }, ...], verify, timeout_ms: 1800000 })` 仅根会话可用。用户先在 TUI 输入 `/race` 授权，再由模型决定是否调用；默认关闭，开关不写配置。再次 `/race` 关闭。下一条用户消息之前会插入 `[race enabled: up to N branches]` 或 `[race disabled]` 的事实，工具说明和 system 不随开关变化。关闭、非 git 目录等执行条件不满足时返回 `ok:false` 的事实，不伪装成模型任务失败。

`branches` 必须 2 到有效 `[limits].race_branches` 个（默认 3，配置范围 2–8）；每项仅提供 prompt，不覆盖 model/effort，按 fork 默认规则继承父请求有效值。race 分支按本次分支上限同时派发，不等待普通 `agent_concurrency` 槽；运行中的 race 分支仍计入活动 agent 数，普通 agent 等待它们释放容量。每项分配独立 `aN`，继承父 history/system，在 NIB_HOME 下的独立临时 git worktree 执行。使用 race 需要本地 Git（支持 `merge-tree --write-tree`）和 Python 3.9+。当前对无 HEAD、symlink、submodule、sparse checkout、冲突 index 和非 UTF-8 路径的仓库返回明确拒绝事实，避免不完整或转换过的起点。应用时禁用仓库自定义的外部 merge driver；需要这类 driver 才能解决的合并保存 patch，不在父目录执行它。互相独立的 worktree 不是恶意代码安全边界。同一 race 的起点相同，包含父工作区未提交内容和非 ignored 的未跟踪文件；父 index 与 HEAD 不变。仓库子目录 cwd 维持其相对位置。race 分支不能再调用 race 或 agent；其临时 worktree 在结束后删除，不能接续已删除工作区中的任务。

verify 可省略；提供时是 shell 命令，在分支子会话成功结束后、同一分支 cwd 执行，exit 0 才通过。省略时只检查子会话 ok。第一个通过者胜出，立即取消并 join 其他分支，沿用进程组清理，随后应用胜者相对起点的 binary patch（包括新建、删除）。返回 `{ ok, winner, text, changes, stopped, failures }`：winner 是任务 id 或 null，text 是胜者文本，stopped 是被停止的任务 id，failures 记录各失败分支与原因。所有分支失败时不修改父工作区。超时、验证失败、git 或应用失败均作为数据；仅参数错误、用户取消 reject。

应用先隔离三方合并，再检查父工作区并发变化；冲突保存 patch 文件并返回路径，不留下部分应用，父 index 不受影响。成功应用计入父 Run 的 changes，包括分支通过 bash 产生的改动。验证不是正确性保证；所有分支（包括失败与停止者）的已报告用量均计入账单。树中以 `aN race` 标识并显示 won/stopped/failed；日志 race 记录用于 stats 的 `race` 次数、胜出耗时与累计用量报告，不把该汇总再加到整体 usage。

继承的历史里仍可能有父项目绝对路径。结构化 read/edit/write/grep/glob 将父仓库根目录下绝对路径映射到当前 worktree；bash cwd 位于 worktree，命令出现父项目绝对根路径则拒绝并提示使用相对路径。合成 fork tool result 告知这些事实。此兼容层不是安全沙箱，不限制仓库外访问或恶意 shell；设计与局限见 [ADR 0016](adr/0016-race.md)、[妥协登记](compromises.md)。
