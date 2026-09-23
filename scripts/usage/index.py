#!/usr/bin/env python3
"""Incremental index of Claude Code token usage from local transcripts.

Reads ~/.claude/projects/**/*.jsonl (append-only) and keeps ready-made
aggregates in ~/.cache/tmux-claude-usage/.

Two things make this fast and correct:

* only the unread tail of a changed file is parsed, so a warm refresh costs
  ~50-300 ms against ~800 MB of transcripts;
* entries are deduplicated by requestId — resuming or forking a session copies
  earlier messages into the new transcript, which duplicates ~44% of the
  entries and would nearly double every chart.
"""

import json
import os
import shutil
from datetime import datetime, timedelta
from hashlib import blake2b
from pathlib import Path

PROJECTS_DIR = Path.home() / ".claude" / "projects"
CACHE_DIR = Path.home() / ".cache" / "tmux-claude-usage"

INDEX_VERSION = 1
RETENTION_DAYS = 90
HASH_BYTES = 6  # 48-bit request ids; collision odds stay negligible at ~1M entries

# Weights follow the API price ratios: cache reads are ~12x cheaper than fresh
# input, output ~5x more expensive. The weighted metric is the best local proxy
# for what actually eats the 5h/7d caps.
W_INPUT = 1.0
W_CACHE_CREATE = 1.25
W_CACHE_READ = 0.08
W_OUTPUT = 5.0

METRICS = ("weighted", "raw", "output", "msgs")
METRIC_LABELS = {
    "weighted": "ważone",
    "raw": "surowe",
    "output": "output",
    "msgs": "wiadomości",
}
# Extra per-day slots beyond METRICS.
EXTRA = ("cache_read", "cache_create", "input", "thinking")


def _blank():
    return {
        "version": INDEX_VERSION,
        "hours": {},      # "YYYY-MM-DDTHH" -> [weighted, raw, output, msgs]
        "days": {},       # "YYYY-MM-DD"    -> [..., cache_read, cache_create, input, thinking]
        "projects": {},   # day -> {project -> [weighted, raw, output, msgs]}
        "models": {},     # day -> {model   -> [weighted, raw, output, msgs]}
        "sessions": {},   # day -> [session id prefixes]
        "files": {},      # path -> [mtime, size, offset]
        "scanned_at": 0,
    }


def _parse_ts(ts):
    """ISO-8601 UTC string -> local datetime, or None when unusable."""
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()
    except (ValueError, TypeError):
        return None


# Path segments that say nothing about which project you were working on.
_NOISE = {".claude", ".claude-worktrees", "worktrees", "wt", "trees", "src"}


def _project_name(cwd, path):
    """Directory name, qualified by the nearest meaningful parent — worktrees
    live in dirs called 1..8, so a bare basename would lump them together."""
    if cwd:
        parts = [p for p in str(cwd).rstrip("/").split("/") if p]
        if parts:
            name = parts[-1]
            if name.isdigit() or len(name) <= 2:
                for segment in reversed(parts[:-1]):
                    if segment not in _NOISE and not segment.isdigit():
                        return "%s/%s" % (segment, name)
            return name
    return path.parent.name.lstrip("-") or "?"


class UsageIndex:
    def __init__(self, projects_dir=None, cache_dir=None, retention_days=RETENTION_DAYS):
        self.projects_dir = Path(projects_dir or PROJECTS_DIR)
        self.cache_dir = Path(cache_dir or CACHE_DIR)
        self.seen_dir = self.cache_dir / "seen"
        self.index_path = self.cache_dir / "index.json"
        self.retention_days = retention_days
        self.data = _blank()
        self.stale = True

    # ── persistence ────────────────────────────────────────────

    def _load(self):
        try:
            data = json.loads(self.index_path.read_text("utf-8"))
        except (OSError, ValueError):
            return _blank()
        if data.get("version") != INDEX_VERSION:
            return _blank()
        blank = _blank()
        for key in blank:
            data.setdefault(key, blank[key])
        return data

    def _save(self):
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        tmp = self.index_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.data, separators=(",", ":")), "utf-8")
        os.replace(tmp, self.index_path)

    def _load_seen(self, cutoff_day):
        """day -> set of request-id hashes, for days still inside the window."""
        seen = {}
        if not self.seen_dir.is_dir():
            return seen
        for path in self.seen_dir.glob("*.bin"):
            day = path.stem
            if day < cutoff_day:
                path.unlink(missing_ok=True)
                continue
            try:
                blob = path.read_bytes()
            except OSError:
                continue
            seen[day] = {blob[i:i + HASH_BYTES] for i in range(0, len(blob), HASH_BYTES)}
        return seen

    def _save_seen(self, seen, dirty):
        if not dirty:
            return
        self.seen_dir.mkdir(parents=True, exist_ok=True)
        for day in dirty:
            (self.seen_dir / ("%s.bin" % day)).write_bytes(b"".join(sorted(seen.get(day, ()))))

    # ── scanning ───────────────────────────────────────────────

    def refresh(self, force=False, on_progress=None):
        """Bring the index up to date. Returns self."""
        if force:
            self.data = _blank()
            shutil.rmtree(self.seen_dir, ignore_errors=True)
        else:
            self.data = self._load()

        today = datetime.now()
        cutoff_day = (today - timedelta(days=self.retention_days)).strftime("%Y-%m-%d")
        self._prune(cutoff_day)

        seen = {} if force else self._load_seen(cutoff_day)
        dirty = set()
        state = self.data["files"]

        files = sorted(self.projects_dir.rglob("*.jsonl")) if self.projects_dir.is_dir() else []
        alive = set()
        pending = []
        for path in files:
            try:
                st = path.stat()
            except OSError:
                continue
            key = str(path)
            alive.add(key)
            prev = state.get(key)
            if prev and prev[1] == st.st_size and abs(prev[0] - st.st_mtime) < 0.001:
                continue
            if prev and st.st_size < prev[1] and not force:
                # A transcript was rewritten or truncated; its old contribution is
                # already baked into the buckets, so the only honest fix is a rebuild.
                return self.refresh(force=True, on_progress=on_progress)
            pending.append((path, key, st, prev[2] if prev else 0))

        for done, (path, key, st, offset) in enumerate(pending):
            if on_progress:
                on_progress(done, len(pending))
            new_offset = self._scan_file(path, offset, seen, dirty, cutoff_day)
            state[key] = [st.st_mtime, st.st_size, new_offset]

        for key in [k for k in state if k not in alive]:
            del state[key]

        self.data["scanned_at"] = int(datetime.now().timestamp())
        self._save_seen(seen, dirty)
        self._save()
        self.stale = False
        return self

    def load_only(self):
        """Read whatever is cached without touching the transcripts."""
        self.data = self._load()
        return self

    def _prune(self, cutoff_day):
        for bucket in ("days", "projects", "models", "sessions"):
            for key in [k for k in self.data[bucket] if k < cutoff_day]:
                del self.data[bucket][key]
        for key in [k for k in self.data["hours"] if k[:10] < cutoff_day]:
            del self.data["hours"][key]

    def _scan_file(self, path, offset, seen, dirty, cutoff_day):
        hours = self.data["hours"]
        days = self.data["days"]
        projects = self.data["projects"]
        models = self.data["models"]
        sessions = self.data["sessions"]
        try:
            fh = path.open("rb")
        except OSError:
            return offset
        with fh:
            fh.seek(offset)
            for raw in fh:
                if not raw.endswith(b"\n"):
                    break  # partial write — pick it up on the next refresh
                offset += len(raw)
                if b'"usage"' not in raw:
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                msg = entry.get("message") or {}
                usage = msg.get("usage")
                if not isinstance(usage, dict):
                    continue
                model = msg.get("model") or "unknown"
                if model.startswith("<"):
                    continue  # <synthetic> entries carry no real usage
                when = _parse_ts(entry.get("timestamp"))
                if when is None:
                    continue
                day = when.strftime("%Y-%m-%d")
                if day < cutoff_day:
                    continue

                rid = entry.get("requestId") or msg.get("id") or entry.get("uuid")
                if rid:
                    digest = blake2b(str(rid).encode("utf-8"), digest_size=HASH_BYTES).digest()
                    bucket = seen.setdefault(day, set())
                    if digest in bucket:
                        continue
                    bucket.add(digest)
                    dirty.add(day)

                inp = usage.get("input_tokens") or 0
                cc = usage.get("cache_creation_input_tokens") or 0
                cr = usage.get("cache_read_input_tokens") or 0
                out = usage.get("output_tokens") or 0
                think = (usage.get("output_tokens_details") or {}).get("thinking_tokens") or 0

                weighted = inp * W_INPUT + cc * W_CACHE_CREATE + cr * W_CACHE_READ + out * W_OUTPUT
                raw_total = inp + cc + cr + out
                quad = (weighted, raw_total, out, 1)

                hour_key = when.strftime("%Y-%m-%dT%H")
                _add(hours, hour_key, quad, 4)
                _add(days, day, quad + (cr, cc, inp, think), 8)
                _add(projects.setdefault(day, {}), _project_name(entry.get("cwd"), path), quad, 4)
                _add(models.setdefault(day, {}), model, quad, 4)

                sid = entry.get("sessionId")
                if sid:
                    day_sessions = sessions.setdefault(day, [])
                    short = str(sid)[:8]
                    if short not in day_sessions:
                        day_sessions.append(short)
        return offset

    # ── queries ────────────────────────────────────────────────

    def hour_values(self, hours_back, metric, now=None):
        """[(datetime, value)] for each of the last `hours_back` hours, oldest first."""
        now = (now or datetime.now()).replace(minute=0, second=0, microsecond=0)
        i = METRICS.index(metric)
        out = []
        for back in range(hours_back - 1, -1, -1):
            when = now - timedelta(hours=back)
            bucket = self.data["hours"].get(when.strftime("%Y-%m-%dT%H"))
            out.append((when, bucket[i] if bucket else 0.0))
        return out

    def day_values(self, days_back, metric, today=None):
        """[(date, value)] for each of the last `days_back` days, oldest first."""
        today = (today or datetime.now()).date()
        i = METRICS.index(metric)
        out = []
        for back in range(days_back - 1, -1, -1):
            day = today - timedelta(days=back)
            bucket = self.data["days"].get(day.strftime("%Y-%m-%d"))
            out.append((day, bucket[i] if bucket else 0.0))
        return out

    def day_map(self, days_back, metric, today=None):
        return {d.strftime("%Y-%m-%d"): v for d, v in self.day_values(days_back, metric, today)}

    def typical_day(self, days_back, metric, today=None):
        """24 values: average usage per hour-of-day across the range."""
        today = (today or datetime.now()).date()
        i = METRICS.index(metric)
        totals = [0.0] * 24
        for back in range(days_back):
            day = today - timedelta(days=back)
            prefix = day.strftime("%Y-%m-%d")
            for hour in range(24):
                bucket = self.data["hours"].get("%sT%02d" % (prefix, hour))
                if bucket:
                    totals[hour] += bucket[i]
        return [t / days_back for t in totals]

    def _range_days(self, days_back, today=None):
        today = (today or datetime.now()).date()
        return [(today - timedelta(days=b)).strftime("%Y-%m-%d") for b in range(days_back)]

    def top_projects(self, days_back, metric, limit=10, today=None):
        i = METRICS.index(metric)
        totals = {}
        for day in self._range_days(days_back, today):
            for name, bucket in self.data["projects"].get(day, {}).items():
                totals[name] = totals.get(name, 0.0) + bucket[i]
        ranked = sorted(totals.items(), key=lambda kv: kv[1], reverse=True)
        return [(n, v) for n, v in ranked if v > 0][:limit]

    def model_split(self, days_back, metric, today=None):
        i = METRICS.index(metric)
        totals = {}
        for day in self._range_days(days_back, today):
            for name, bucket in self.data["models"].get(day, {}).items():
                totals[name] = totals.get(name, 0.0) + bucket[i]
        return sorted(((n, v) for n, v in totals.items() if v > 0), key=lambda kv: kv[1], reverse=True)

    def totals(self, days_back, today=None):
        """Summed day buckets over the range: dict of METRICS + EXTRA."""
        acc = [0.0] * 8
        for day in self._range_days(days_back, today):
            bucket = self.data["days"].get(day)
            if bucket:
                for i in range(min(len(bucket), 8)):
                    acc[i] += bucket[i]
        keys = METRICS + EXTRA
        return {k: acc[i] for i, k in enumerate(keys)}

    def sessions_count(self, day):
        return len(self.data["sessions"].get(day, []))

    def active_hours(self, day):
        return sum(1 for h in range(24) if self.data["hours"].get("%sT%02d" % (day, h)))

    def streak(self, today=None):
        """Consecutive days with any activity, counting back from today."""
        today = (today or datetime.now()).date()
        count = 0
        for back in range(self.retention_days):
            day = (today - timedelta(days=back)).strftime("%Y-%m-%d")
            bucket = self.data["days"].get(day)
            if bucket and bucket[3]:
                count += 1
            elif back > 0 or not bucket:
                break
        return count

    @property
    def scanned_at(self):
        return self.data.get("scanned_at", 0)

    @property
    def first_day(self):
        return min(self.data["days"]) if self.data["days"] else None

    @property
    def has_data(self):
        return bool(self.data["days"])


def _add(store, key, values, size):
    bucket = store.get(key)
    if bucket is None:
        bucket = [0.0] * size
        store[key] = bucket
    elif len(bucket) < size:
        bucket.extend([0.0] * (size - len(bucket)))
    for i, v in enumerate(values):
        bucket[i] += v


if __name__ == "__main__":
    import time

    started = time.time()
    idx = UsageIndex().refresh()
    print("refresh: %.2fs, dni: %d, godziny: %d" % (
        time.time() - started, len(idx.data["days"]), len(idx.data["hours"])))
