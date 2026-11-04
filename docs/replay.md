# 本地录制与离线重放

每个会话默认把工具调用参数和结果录制到 `$NIB_HOME/sessions/<32位小写十六进制ID>.calls.jsonl`，文件权限为 `0600`。`NIB_RECORD=off` 关闭录制。录制与主日志独立，不改变工具返回值或模型可见的 Run 输出预算。

这些文件只留在本地，仅 `nib replay` 读取；会话恢复、压缩、统计、`/reflect` 提示词和自动 issue 发布路径均不读取、上传或引用其中内容。`/reflect` 查证只允许读取文件名严格为 `<32位小写十六进制ID>.jsonl` 的主日志，不允许扫描 `.calls.jsonl` 或调用 replay。录制可能包含工具返回的完整文件、命令输出等私有数据，分享主日志时应单独排除 sidecar。

## 命令

```sh
nib replay <32hex-id> --run <step>:<run> [--script <file.js>] [--json]
nib replay <32hex-id> --all [--json]
```

`step` 是整个会话累计的 Step 序号，从 1 开始：按主日志中所有 `turn_step` 非 null 的行依次编号。`turn_step` 本身在每个 Turn 内重新从 1 开始，不能直接作为跨 Turn 的定位键。`run` 从 0 开始，对应该 Step 的 `calls.run_index`。例如 `--run 3:0` 定位会话第三个 Step 的第一个 Run。

不传 `--script` 时，执行主日志保存的原始 Run 代码，按调用 index 检查工具名、参数和严格序列，并交回录制结果。传入 `--script` 时执行本地替换脚本，按结构化的 `(name, args)` 匹配录制调用，按新脚本创建调用的顺序交回结果；未录制的调用 reject 为 `not recorded: <name>`，普通 prelude 会像在线工具错误一样加上工具名前缀。同一 `(name, args)` 有多条记录时，替换脚本复用按原创建顺序找到的第一条，重复调用也复用该记录。替换脚本用于尝试不同 JS 逻辑，不作为原始 Run 一致性结论。

## 录制与执行边界

每次工具调用写一行 `{step, run, index, seq, name, args, ok, result | error}`：`index` 是本 Run 内从 0 开始的创建顺序，`seq` 是交回 JS 的顺序，`args` 是 JS 求值后的 JSON 参数。成功的 `result` 保存交给 JS 解析的 JSON 原文字符串，失败保存 `error` 文本。每个 Run 末尾另写 `{step, run, meta: {start_ms_epoch, end}}`，记录起始 Unix 毫秒与 `ok`、`error`、`timeout`、`cancelled` 结束状态。调用先缓存在内存，Run 结束后追加并同步；写盘失败只提示一次并停用录制，不改变 Run 结果。

录制在会话内按结果 SHA-256 去重；重复结果通过 `same_as` 引用此前结果。单个 result 超过 1 MiB 时保存 `{sha, content, truncated: true}`，`sha` 覆盖完整原文，`content` 是不超过 1 MiB 的 UTF-8 前缀；重放报告标记 `incomplete`，此标记表示无法判定重放一致，不能将截断内容当成完整工具结果。截断的 JSON 原文仍交给正常工具结果解析器，缺少闭合部分时会 reject。

总文件大小和每 Run 的内存缓存没有另设上限，取决于调用次数；截断前的完整正文不会额外落盘。子会话有自己的 calls 文件，父会话只记录 `agent` 返回给父 Run 的结果对象。

同目录 `<ID>.calls.sha256` 保存跨恢复的去重索引，权限同为 `0600`，仅含逐行的 64 位小写十六进制 SHA-256，不含工具参数、结果正文或路径。恢复会话只读取这个哈希索引，不读取 `.calls.jsonl`。每次先将 calls 内容写入并同步成功，再追加并同步新哈希；录制或索引失败只停用录制，不影响 Run 结果。`NIB_RECORD=off` 时不读取或生成索引。

重放使用正常 sandbox 的 prelude、内存与 Run 超时等限额。它离线执行 JS，工具桥只交回录制数据，不请求模型、不运行任何真实工具实现，也不会重新执行 bash 或产生其外部副作用。原 Run 超时或取消时，报告保留原结束状态，但不保证重放在同一位置停止。时间固定为 `meta.start_ms_epoch`，通过冻结的 `Date` 提供，`Math.random()` 使用固定序列；`uses_time`、`uses_random` 报告脚本是否使用这些入口。重放验证的是 JS 与录制输入之间的行为，不能重放模型，也不能验证 `read`、`grep` 等工具实现的改动，或证明文件系统、网络在当前环境仍会给出相同结果。

## JSON 报告

单 Run 的 `--json` 报告形如：

```json
{"run":"1:0","match":true,"incomplete":false,"uses_time":false,"uses_random":false,"output":"...","original_end":"ok"}
```

`match` 为 `true` 表示匹配，为 `false` 表示分歧；分歧附带 `divergence: {index, recorded, actual}`。替换脚本、录制不完整、超时或取消时为 `null`，表示无法判定。`original_end` 为原运行的 `ok`、`error`、`timeout` 或 `cancelled`。

`--all --json` 输出汇总：

```json
{"total":4,"matched":2,"divergences":[{"run":"2:0","match":false,"divergence":{"index":0,"recorded":null,"actual":{"name":"read","args":{}}},"incomplete":false,"uses_time":false,"uses_random":false,"output":"...","original_end":"ok"}],"indeterminate":1}
```

`matched`、`indeterminate` 分别统计 `match` 为 `true`、`null` 的 Run；`divergences` 列出 `match` 为 `false` 的完整单 Run 报告；`total` 为全部重放 Run 数。
