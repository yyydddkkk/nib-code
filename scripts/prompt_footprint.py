#!/usr/bin/env python3
"""Estimate fixed input from the Zig renderer's JSONL fixtures (not provider usage)."""
import json
import sys

import tiktoken


def main():
    encoding = tiktoken.get_encoding("o200k_base")
    if sys.argv[1:] not in ([], ["--json"]):
        raise SystemExit("usage: zig build prompt-footprint | python3 scripts/prompt_footprint.py [--json]")

    def tokens(text):
        return len(encoding.encode_ordinary(text))

    rows = []
    for line in sys.stdin:
        item = json.loads(line)
        system = tokens(item.pop("system"))
        tools = item.pop("tools", None)
        count = tokens(json.dumps(tools, ensure_ascii=False, separators=(",", ":"))) if tools is not None else None
        rows.append(dict(item, system_tokens=system, tool_definition_tokens=count,
                         fixed_tokens=system + count if count is not None else None))
    if not rows or rows[0]["tool_definition_tokens"] is not None:
        raise SystemExit("prompt fixture input missing the shared baseline")
    if sys.argv[1:]:
        print(json.dumps(rows, indent=2))
    else:
        for row in rows:
            if row["fixed_tokens"] is None:
                print(f'Common: {row["system_tokens"]:,} tokens')
            else:
                print(f'{row["provider"]}/{row["model"]} ({row["family"]} → {row["profile"]}): '
                      f'{row["system_tokens"]:,} system + {row["tool_definition_tokens"]:,} tools '
                      f'= {row["fixed_tokens"]:,} tokens')


if __name__ == "__main__":
    main()
