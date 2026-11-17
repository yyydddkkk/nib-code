# SQLite metrics index

`scripts/stats_db.py` imports Session metrics into a local SQLite database using Python's standard-library `sqlite3` module. It is an on-demand analysis tool, not a new Session storage backend. The nib executable, startup, tool execution, resume, and recording defaults are unchanged. No database service, native nib dependency, background importer, or telemetry is added.

## Import

```sh
python3 scripts/stats_db.py
python3 scripts/stats_db.py /path/to/sessions --db /path/to/experiment.sqlite3
python3 scripts/stats_db.py /path/to/session.jsonl --db /path/to/experiment.sqlite3 --rebuild
```

Without arguments, input is `$NIB_HOME/sessions` and output is `$NIB_HOME/stats.sqlite3`, with `NIB_HOME` defaulting to `~/.nib`. Directories are not traversed recursively. Overlapping inputs are deduplicated by resolved file path; `.calls.jsonl` recordings are never imported or needed. The script prints imported/unchanged/failed file counts and exits nonzero if any import fails. Python must have SQLite support; the separate `sqlite3` command is optional and only needed for the shell examples below.

New databases are created with mode 0600. They contain paths, working directories, model/configuration labels, and metrics, so treat them as private even though message bodies, system instructions, JS code, tool arguments/results, file contents, diagnostic messages, and credentials are not copied into them. No automatic deletion or retention policy is introduced for databases or source logs.

## Storage boundary

Session JSONL remains authoritative for conversation state. The database is a disposable projection for SQL analysis, not a second authority and not an archive of message bodies. Deleting it does not affect nib; reimport retained logs to recreate it. Keep the logs if reproducibility or Session recovery matters.

There is no runtime dual write. Files with unchanged device/inode, size, modification time, and change time are skipped. Changed files are re-read and replaced transactionally, including their dependent rows. This is file-level incremental indexing, not byte-offset tailing: compaction, repaired/truncated logs, and rewrites must not leave stale rows or duplicate historical work. `--rebuild` reimports selected files even if their metadata is unchanged.

Each source file has its own transaction. An import failure rolls back that file, preserving its previous indexed version; other files can still succeed. Changes detected while reading an active source cause a retryable failure instead of publishing a mixed snapshot. Retry after the Session is idle. Malformed complete JSON lines are skipped and counted in `sessions.invalid_lines`. An unfinished final line is deferred and its size reported in `pending_bytes`; it is reconsidered when the file changes. A complete Session header is required.

Files absent from a later invocation are not deleted from the index. To analyze only a particular collection or remove obsolete snapshots, build a fresh database from that collection. Distinct source paths are distinct indexed Sessions, even if filenames/Session IDs match: do not mix copied experiment snapshots unless intentional.

The database uses SQLite's normal rollback journal and a bounded lock timeout. There is no writer thread or always-on WAL machinery. `application_id` identifies nib metrics databases and `user_version` versions the schema. Foreign databases and unsupported versions are refused without being migrated, reset, or overwritten. For this first schema, use a new database path to rebuild from logs after an incompatible schema change.

## Tables and measurement semantics

| Table | Row and important fields |
| --- | --- |
| `sessions` | One resolved source path; Session ID, parent ID, cwd, version, model/provider/profile, system hash, tuning/patch labels, source fingerprint and import coverage. |
| `steps` | One appended assistant Step record; Session-global assistant ordinal, source line, status, timestamp, effort, timing, token counts, transport and byte counts. |
| `runs` | One Run observation; originating Step/index, source line, phase, explicit outcome, timing, byte counts and omitted-call count. |
| `tool_calls` | Actual bounded `calls[]` timing details attached to a Run; tool name, start/end/duration, outcome, result bytes, dispatch/background flags and task ID. |
| `diagnostics` | Provider diagnostic name, attempt count and Step reference, without the diagnostic message. |

`session_path` links rows to `sessions.path`; `tool_calls.run_id` links to `runs.id`. Foreign-key cascades remove old dependent rows on reimport. Internal Run IDs are not stable across reimports. Source lines are 1-based, Step ordinals are 1-based, and Run indices are 0-based. Interrupted assistant records consume an ordinal and have `status='interrupted'`; filter to `status='complete'` for completed-Step analysis. Compaction replacements update the message-history length but do not create new work rows; original execution observations remain. A replacement initialization header before the first Step updates Session configuration labels, so model/provider switches before execution are attributed to the configuration actually used.

Runs have three phases:

- `foreground`: ordinary Run observation from a complete Step. Missing legacy outcomes remain NULL.
- `background_start`: automatic background handoff, not completion. `ok` is NULL even if a notification says success. Its timing is the foreground wait, not the full execution time.
- `background`: final completion from `messages[].background_run` or a lifecycle `background.completion` envelope, referring to the originating Step/index. Both delivery modes are supported; repeated observations of the same originating Step/index are imported once, using the first completion's timestamp and source line.

Full background execution can overlap other Steps. Do not add background Run durations to Step wall time. A failed Run is not necessarily a failed Step, and `tool_calls.ok` indicates tool settlement, not a bash command's exit status. Parent/child Sessions remain separate; filter `sessions.parent_session_id IS NULL` for roots or group roots and children separately. Do not add child Step time to parent wall time.

Missing/invalid nonnegative integer metrics and non-boolean outcomes are NULL, not zero or success. Invalid end-before-start timing has NULL duration. Step/Run/diagnostic `at_ms` uses record `at`, falling back to source-file mtime for legacy data; `time_source` distinguishes them. Legacy fallback may shift when a file is updated. The Session header timestamp remains NULL when absent.

Call details are bounded by the producer. Retain sample counts and `calls_omitted`; SQL cannot recover missing details, nor does it infer calls by parsing JS. This index is not a replacement for every heuristic/report in `scripts/stats.py`: static tool estimates, output-based error classification, Turn reconstruction, and tool-sidecar analysis remain there. Existing statistics output and its definitions are unchanged.

## Example queries

Query using any SQLite client, for example `sqlite3 ~/.nib/stats.sqlite3`.

Completed root Steps by version:

```sql
SELECT s.nib_version, COUNT(*) AS steps, COUNT(t.ms) AS timed_steps,
       AVG(t.ms) AS mean_step_ms, AVG(t.model_ms) AS mean_model_ms
FROM steps AS t JOIN sessions AS s ON s.path = t.session_path
WHERE t.status = 'complete' AND s.parent_session_id IS NULL
GROUP BY s.nib_version;
```

Actual tool timings by version (root Sessions, foreground and completed background Runs):

```sql
SELECT s.nib_version, c.name, COUNT(*) AS recorded_calls,
       COUNT(c.duration_ms) AS timed_calls, AVG(c.duration_ms) AS mean_ms,
       MAX(c.duration_ms) AS max_ms
FROM tool_calls AS c
JOIN runs AS r ON r.id = c.run_id
JOIN sessions AS s ON s.path = r.session_path
WHERE r.phase IN ('foreground', 'background') AND s.parent_session_id IS NULL
GROUP BY s.nib_version, c.name;
```

Run outcome coverage and failure rate (without counting background handoffs as completions):

```sql
SELECT s.nib_version, COUNT(*) AS runs, COUNT(r.ok) AS known_outcomes,
       SUM(CASE WHEN r.ok = 0 THEN 1 ELSE 0 END) AS failed,
       1.0 * SUM(CASE WHEN r.ok = 0 THEN 1 ELSE 0 END)
           / NULLIF(COUNT(r.ok), 0) AS failure_rate
FROM runs AS r JOIN sessions AS s ON s.path = r.session_path
WHERE r.phase IN ('foreground', 'background') AND s.parent_session_id IS NULL
GROUP BY s.nib_version;
```

Check incomplete/corrupt imports before interpreting results:

```sql
SELECT path, invalid_lines, pending_bytes FROM sessions
WHERE invalid_lines > 0 OR pending_bytes > 0;
```

Validation: `python3 tests/test_stats_db.py` and `python3 tests/test_stats.py`.
