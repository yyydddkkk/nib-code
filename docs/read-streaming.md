# Streaming read: implementation and measurements

`tools.read` scans with a 16 KiB temporary buffer and collects only the requested
lines. Long lines grow the returned text, not the scan buffer. Once a page is
complete, one byte of lookahead distinguishes another line from EOF; bytes
already in the scan buffer provide lookahead without another read. Near-EOF
requests still scan from the beginning. There is no cache, line index or mmap in
the reader, and edit/write are unchanged.

The existing inclusive cap is **16 MiB + 1 byte**, matching the previous
`allocRemaining` call. Initial and final descriptor stats enforce the cap even
when a page stops early. An observed inode/size/mtime change fails with
`FileChangedDuringRead`; a failed read does not refresh the Session observation.
Successful reads remember the original version, preserving subsequent write
conflict checks. Inputs without useful regular-file size metadata scan through
EOF with a byte counter rather than trusting an early page to enforce the cap.
Credential checks and the canonical-path advisory lock remain in place.

## Measurement setup

- Before: `cf751b3d91db4c12a5546e07217f86e632f5b05c`; after: this change.
  Both built with Zig 0.17.0 and `-Doptimize=ReleaseFast`.
- Linux 7.0.0-42, x86-64, Intel Core 5 220H; data on ext4/NVMe, not `/tmp` tmpfs.
- The **same 15 MiB file**, 245,760 lines of 63 ASCII bytes plus LF, is used
  throughout. Each request returns four lines (256 bytes), at offset 1 or 245,753.
- 20 fresh processes per variant/cache/offset, 160 samples in shuffled order.
  An in-process local HTTP mock supplies one Run; no real provider or credentials.
- Hot: read the file before each sample; `mincore` confirms all 3,840 pages
  resident. Cold file page cache: `fsync` then `POSIX_FADV_DONTNEED`; `mincore`
  confirms zero resident pages before each sample. Executables/libraries are warm.
  The benchmark-only mapping queries residency without touching data pages.
- Wall time includes GNU time, process startup, the mock Session and normal
  recording/cleanup. Await time uses JS `Date.now()` around `tools.read`, including
  tool dispatch, with **1 ms resolution**, not native-only timing. Peak RSS is the
  nib process's GNU time `%M`, not a heap-allocation count.

## Results

Medians; arrows are before → after.

| File page cache | Offset | Process wall, ms | Read await, ms | Peak RSS, KiB |
| --- | ---: | ---: | ---: | ---: |
| Hot | 1 | 40.65 → 31.98 | 9 → 0 | 26,296 → 10,884 |
| Hot | 245,753 | 44.07 → 37.92 | 12 → 6 | 26,200 → 11,096 |
| Cold | 1 | 46.37 → 33.01 | 14 → 0 | 26,216 → 11,000 |
| Cold | 245,753 | 50.03 → 44.97 | 17 → 13 | 26,196 → 11,000 |

Await medians of 0 reflect the clock's quantization; they are **not** claims
of zero execution time or reliable sub-millisecond latency. Peak RSS drops by
about 15 MiB for these small pages. Allocation counts were not measured.

Cold-prefix median input blocks (`%I`, 512-byte units) fell from 30,720 to 64;
post-read resident pages fell from 3,840 to 8 (32 KiB, including kernel read-ahead).
Cold near-EOF reads still read the whole file: 30,720 blocks and 3,840 pages for
both versions. These are file-page-cache conditions, **not hardware-cold storage**:
controller/device caches were not flushed. CPU caches and background machine
load were not controlled. Results are local observations, not general guarantees.

## Reproduce

From the repository root, keep a baseline binary before building the change:

```sh
git worktree add --detach /tmp/nib-read-baseline cf751b3
(cd /tmp/nib-read-baseline && zig build -Doptimize=ReleaseFast --prefix /tmp/nib-read-baseline-install)
zig build -Doptimize=ReleaseFast
python3 scripts/bench_read.py /tmp/nib-read-baseline-install/bin/nib zig-out/bin/nib .zig-cache/read-bench-results.json
```

The script requires Linux, GNU time and a disk-backed `.zig-cache`; it refuses
samples whose verified residency does not match the requested condition. It
writes raw per-sample results to the supplied JSON path.

## Regression coverage and limits

`zig build test --summary all` passes 712 tests, including pagination equivalence
across scan boundaries, CRLF/Unicode, empty and unterminated input, long lines,
zero limits, offsets past EOF, inclusive size boundaries and oversized sparse
files. A 1 KiB fixed allocator suffices for the small-page collector over a
16 MiB input; this checks bounded temporary allocation, not whole-process memory.
Deterministic I/O hooks modify the file after a scan read to test growth,
truncation and same-size modification without refreshing observations.
`tests/test_files.py` (9 tests) and `tests/test_undo.py` also pass; the paginated
write-conflict e2e leaves a large unread tail before external modification.

Result storage and JSON serialization still scale with requested text. A large
page or a single long line can therefore use substantial memory. External writers
that bypass the advisory lock can still race after the final stat, or restore
metadata to conceal changes. Metadata checks are not snapshot isolation; the
existing inode/size/mtime observation model has not been replaced by hashing.
