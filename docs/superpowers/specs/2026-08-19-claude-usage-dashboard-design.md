# Claude usage dashboard (`prefix + u`)

**Status:** implemented · 2026-08-19

A popup dashboard over local Claude Code usage: four tabs of charts in the
Vesper palette, driven by the transcripts on disk plus the live 5h/7d caps.

## Why

The status bar answers "how full is the cap right now" and nothing else. It
cannot say when the cap will hit, when during the day the tokens go, which repo
ate them, or whether this week is heavier than the last. All of that is already
on disk in `~/.claude/projects/**/*.jsonl` — it just needs aggregating.

## Data sources

| Source | Gives | Limits |
|---|---|---|
| `~/.claude/projects/**/*.jsonl` | per-message tokens, model, `cwd`, `sessionId`, timestamp | no notion of the cap; ~44% duplicate entries |
| `/tmp/claude-usage.txt` | current `5h` / `7d` percentages and reset times | "right now" only, no history |
| `~/.claude/usage-history.log` | `epoch,5h%,7d%` samples | starts empty; grows from the moment the feature ships |

Two processes write the cap cache: `scripts/claude_usage_api.py` (this repo,
OAuth API, epoch resets) and `~/.claude/statusline-command.sh` (Claude Code's
own `rate_limits`, resets pre-formatted). `limits.py` accepts both shapes.

**Cap history** is sampled by `claude-usage.sh` — the tmux-side reader that runs
every second and always sees the freshest cache regardless of which writer
produced it — throttled to one line per 5 minutes.

## Metric

Raw token totals are ~98% cache reads, so they say nothing about cost. The
default metric is **weighted**, following the API price ratios:

```
weighted = input×1.0 + cache_creation×1.25 + cache_read×0.08 + output×5.0
```

`m` cycles to raw / output-only / message count. Charts are identical; only the
value changes. Dollars were rejected: on a subscription they are fiction, and a
price table in the repo is one more thing to keep current.

## Deduplication

Resuming or forking a session copies earlier messages into the new transcript.
Measured on real data: **44% of usage entries are duplicates by `requestId`**.
Ignoring that would nearly double every chart.

Entries are keyed by `requestId` (falling back to `message.id`, then `uuid`),
hashed to 48 bits, and kept in per-day sets under
`~/.cache/tmux-claude-usage/seen/<day>.bin`. Per-day scoping is what makes the
set prunable — a duplicate always carries the same timestamp as its original,
so a same-day check is sufficient.

## Architecture

```
scripts/usage/
├── index.py    transcripts -> aggregates       (knows nothing about terminals)
├── limits.py   cap cache + history log         (knows nothing about charts)
├── charts.py   values -> lines of text         (knows nothing about the data)
├── theme.py    Vesper palette
└── dash.py     tabs, keys, layout, refresh loop
```

`dash.py` is the only module that imports the others; the three below it are
independently testable, and `charts.py` is pure.

### Incremental index

`index.json` stores `(mtime, size, offset)` per transcript. JSONL is append-only,
so an unchanged file is skipped entirely and a changed one is read from its
stored byte offset. A partially written last line is left for the next refresh.
A file that *shrank* means a rewrite, which the offsets cannot express — that
triggers one clean rebuild rather than silently double-counting.

Aggregates: per hour, per day, per day×project, per day×model, plus per-day
session ids. Retention 90 days; buckets and hash files past it are dropped.

Measured on ~800 MB of transcripts: **cold 3.9 s, warm 0.04 s**, cache 736 KB.

### Tabs

1. **limity** — 5h/7d gauges with time-to-reset, both history curves, burn rate
   in %/h and the projected clock time the 5h cap is hit. The slope comes from
   the logged percentages, not from tokens, and readings from before the last
   reset (a drop in utilisation) are discarded.
2. **godziny** — last 48 h as a braille area chart, plus the average day
   hour-by-hour over the selected range.
3. **dni** — calendar heatmap (7 rows × N weeks, never wider than the data),
   daily bars, totals, record day, streak, week-over-week delta.
4. **projekty** — top repos as horizontal bars, model split as a stacked bar,
   cache hit ratio and thinking share. Worktrees live in directories named
   `1`..`8`, so a numeric basename is qualified with its nearest meaningful
   parent (`ediets-web/2`).

### Rendering

Braille (2×4 dots per cell) for curves, block glyphs for bars, a four-level
ramp for the heatmap, truecolor ANSI throughout — no `curses`, which would
fight the RGB palette for no gain. The TUI uses `termios` cbreak, the alternate
screen, and restores the terminal from a `finally` block even on exceptions.
`SIGWINCH` arrives through `signal.set_wakeup_fd`, because a flag-setting
handler would be swallowed by `select`'s automatic restart (PEP 475).

Layout degrades by width: two columns ≥100, one column ≥60, a "make the window
bigger" message below that.

## Keys

`1`–`4` / `Tab` tabs · `m` metric · `[` `]` range (7/30/90 d) · `r` full
re-index · `q`/`Esc` quit · auto-refresh every 10 s.

`prefix + u`, lowercase: TPM binds `prefix + U` to "update plugins" and loads
after `tmux.conf`, so an uppercase binding would be silently overridden.

## Testing

`python3 -m unittest discover -s tests` from `scripts/usage/` — 34 tests over
the index (weighting, dedup within and across files, incremental tails, partial
lines, truncation rebuild, retention, bucketing, corrupt input) and the
renderers (widths with ANSI, chart dimensions, bar proportions, heat levels,
calendar shape). `dash.py --print` renders one frame to stdout for eyeballing
without a terminal.

## Trade-offs accepted

- History of the caps starts empty — there is no honest way to reconstruct past
  utilisation from tokens, and a half-invented curve is worse than none.
- Deleting a transcript leaves its tokens in the buckets until the next `r`.
- The 90-day retention is a policy, not a limit of the data.
