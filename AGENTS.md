# nibcode

用 Zig 0.17 写的编码 agent，命令名 `nib`。

## 常用命令

- 构建：`zig build`；测试：`zig build test --summary all`；端到端（本地 mock，无真实 key）：`zig build` 后 `python3 tests/test_session.py`、`python3 tests/test_agent.py`、`python3 tests/test_codex.py`、`python3 tests/test_llm.py`、`python3 tests/test_stats.py`、`python3 tests/test_effort.py`、`python3 tests/test_interjections.py`、`python3 tests/test_limits.py`、`python3 tests/test_replay.py`
- 安装到 `~/.local/bin/nib`：`zig build -Doptimize=ReleaseFast --prefix ~/.local`；版本号在 `build.zig.zon`，`nib --version` 查看。
- 运行：`./zig-out/bin/nib`（TUI）、`nib ask '<prompt>'`、`nib js '<code>'`；TUI 用 `/compact` 手动压缩上下文。
- 恢复：`nib -c` / `nib --continue`；`nib --resume <32位小写十六进制ID>`。`ask` 同样支持，选项可放在 prompt 前后。
- 统计：`python3 scripts/stats.py [日志文件或目录] [--since YYYY-MM-DD] [--cwd 目录] [--group-by version|system|patches] [--json]`。
- 反思：TUI `/reflect [focus]`（会自动发布 issue，开关与安全边界见 [docs/reflect.md](docs/reflect.md)）。

## 按需参考

- provider、凭证、effort、配置与环境变量：[docs/config.md](docs/config.md)、[docs/codex.md](docs/codex.md)、[ADR 0011](docs/adr/0011-provider-wire-protocols.md)。
- `ask --json` 的 NDJSON 格式：[docs/ask-json.md](docs/ask-json.md)。
- 会话日志、恢复/取消语义、计时字段与统计口径：[docs/session-log.md](docs/session-log.md)。
- `tools.llm({ prompt, input, schema, model, effort }) → { text, data, usage }`；`tools.agent({ prompt, timeout_ms, model, effort }) → { ok, text, usage, changes, error? }`（子会话失败为数据，仅参数错误/用户取消 reject；changes 仅 edit/write）：[接口、限额、用量与取消](docs/tool-delegation.md)。

## 代码地图

目录按 [CONTEXT.md](CONTEXT.md) 的概念划分。`x.zig` 是该部分的入口和对外接口，`x/` 放它的内部实现；新代码放进所属概念的目录，不再往 `src/` 顶层平铺。

- `src/main.zig`：命令行入口，分派到 TUI、`ask`、`js`。
- `src/config.zig`：解析 `NIB_HOME/config.toml`、合并环境配置、解析用户目录与原子写回 effort。
- `src/session.zig`：Session 引擎（Turn、Step、压缩、取消）；`session/` 下是日志、指令拼接、事件、Run 输出格式化。
- `src/provider.zig`：Provider 接口与配置；`provider/` 下是各线路协议和 SSE 解析，`provider/timing.zig` 只负责 run 参数到达进度采样；首个接收活动时间由 Session 复用 Sink.onData 记录。
- `src/sandbox.zig`：QuickJS Run 与宿主桥接；`sandbox/console.zig` 捕获有界 console 首尾，`sandbox/timing.zig` 在原生工具调度/完成路径记录 Run 内工具调用耗时。
- `src/tools.zig`：工具表（给模型看的 JS 说明集中在这里）、`Tools` 共享状态与调度。`tools/` 下每个工具族一个入口文件，函数名即工具名：`files.zig`（read/edit/write）、`search.zig`（grep/glob）、`web.zig`（fetch）、`bash.zig`、`agent.zig`、`llm.zig`（进程内单步纯模型调用，限额也集中在这里）；其余是它们的辅助模块。加工具：在 `tools/` 写入口函数，再在表里加一行。
- `src/tui.zig`：TUI 事件循环（按键、`/` 指令分派、Session 事件、后台 Turn）；`tui/` 下：`transcript.zig`（对话条目与折叠）、`viewport.zig`（滚动锚定）、`view.zig`（一帧的布局绘制）、`status.zig`（活动行与下边框元数据）、`menu.zig`（`/` 候选菜单）、`commands.zig`（指令表）、`reflect.zig` + `reflect.md`（/reflect 的提示词与 reflections.md 追加）、`editor.zig`（输入框、原子粘贴块与进程内草稿历史）、`long_text.zig`（长文本阈值与计数）、`markdown.zig`、`selection.zig`（鼠标选区、高亮与剪贴板复制）。
- `tests/`：端到端测试和 mock 服务器；`scripts/`：辅助脚本。

## 工具与代码约定

工具返回给 JS 的是完整数据，不能为保护模型上下文而悄悄截断或往正文里添加提示；否则 `read → JS 替换 → write` 会把截断标记写回文件，造成数据损坏。模型侧整个 Run 共用 16 KiB 展示预算，不改变 Run 内的数据；工具显式分页/有界结果、console 捕获上限及 Run 执行超时见 [docs/run-output.md](docs/run-output.md)。

搜索优先用 tools.grep/tools.glob，不在 bash 里调 rg/find/grep。写包含反引号、`${` 或反斜杠的文件/命令文本时，用 JSON 转义的双引号 JS 字符串，不用模板字符串或 String.raw；工具表的示例由 sandbox 测试逐字节验证。

**代码的读者是 agent。** 不写复述代码、解释思路或记录改动历史的注释；过时的注释比没有注释更容易误导模型。只在代码表达不了、不知道就会改错的地方写一行：外部限制、协议怪癖、内存归属、并发不变量。含义靠命名、类型和测试承载；给人看的解释写进 `docs/`。

术语见 [CONTEXT.md](CONTEXT.md)，决策记录见 [docs/adr/](docs/adr/)。

**文档是参考，不是规则。** 读到的 ADR 与代码、实测或更好的方案冲突时，指出来并更新文档，不要为了迁就文档而迁就代码。详见 [docs/README.md](docs/README.md)。

新会话按基础指令、全局 `$NIB_HOME/AGENTS.md`（默认 `~/.nib/AGENTS.md`）、项目 `AGENTS.md` 的顺序拼接 system，后者优先。项目目录是从 cwd 向上遇到的第一个 `.git` 标记所在目录；没有则用 cwd。只读取 `AGENTS.md`。恢复会话沿用日志中的原始 system，之后修改指令文件只影响新会话。
