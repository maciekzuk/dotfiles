"""Live 5h/7d caps and the history logged next to them.

The API only ever reports "right now", so scripts/claude_usage_api.py appends
every reading to ~/.claude/usage-history.log and this module reads it back.
"""

import os
import re
import subprocess
import sys
import time
from pathlib import Path

STATUS_CACHE = Path("/tmp/claude-usage.txt")  # written by scripts/claude_usage_api.py
HISTORY_PATH = Path.home() / ".claude" / "usage-history.log"
API_SCRIPT = Path.home() / ".tmux" / "scripts" / "claude_usage_api.py"
MAX_AGE = 600  # same debounce as the status bar


_DUR = re.compile(r"(\d+)\s*([dhm])")


def parse_reset(text):
    """Reset marker -> epoch. Accepts an epoch or the '4h 9m' form the
    statusline writer produces, which is relative to now."""
    text = (text or "").strip()
    if not text:
        return None
    if text.isdigit():
        return int(text)
    seconds = 0
    for value, unit in _DUR.findall(text):
        seconds += int(value) * {"d": 86400, "h": 3600, "m": 60}[unit]
    return int(time.time()) + seconds if seconds else None


def current():
    """{'5h': {'pct': float, 'reset': epoch|None}, '7d': {...}} from the cache file.

    Two writers feed that file: scripts/claude_usage_api.py (this repo, epoch
    resets) and ~/.claude/statusline-command.sh (Claude Code's own rate_limits,
    resets already formatted). Both shapes are accepted, plus the older
    stand-alone '7dr:<epoch>' line.
    """
    out = {}
    try:
        text = STATUS_CACHE.read_text("utf-8")
    except OSError:
        return out
    legacy = {}
    for line in text.splitlines():
        key, sep, value = line.partition(":")
        if not sep:
            continue
        if key in ("5hr", "7dr"):
            legacy[key[:-1]] = parse_reset(value)
            continue
        if key not in ("5h", "7d"):
            continue
        pct_text, _, reset_text = value.partition("|")
        try:
            pct = float(pct_text.strip().rstrip("%"))
        except ValueError:
            continue
        out[key] = {"pct": pct, "reset": parse_reset(reset_text)}
    for key, reset in legacy.items():
        if key in out and out[key]["reset"] is None:
            out[key]["reset"] = reset
    return out


def cache_age():
    try:
        return time.time() - STATUS_CACHE.stat().st_mtime
    except OSError:
        return None


def refresh_async():
    """Kick off an API refresh if the status-bar cache went stale. Never blocks."""
    age = cache_age()
    if age is not None and age <= MAX_AGE:
        return False
    if not API_SCRIPT.exists():
        return False
    try:
        subprocess.Popen([sys.executable, str(API_SCRIPT)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        STATUS_CACHE.touch()  # debounce repeated triggers, same as claude-usage.sh
    except OSError:
        return False
    return True


def history(since_epoch=None, path=None):
    """[(epoch, five_pct, seven_pct)] oldest first, from the append-only log."""
    path = Path(path or HISTORY_PATH)
    try:
        text = path.read_text("utf-8")
    except OSError:
        return []
    rows = []
    for line in text.splitlines():
        parts = line.split(",")
        if len(parts) < 3:
            continue
        try:
            epoch = int(float(parts[0]))
            five = float(parts[1])
            seven = float(parts[2])
        except ValueError:
            continue
        if since_epoch and epoch < since_epoch:
            continue
        rows.append((epoch, five, seven))
    rows.sort(key=lambda r: r[0])
    return rows


def resample(samples, column, start, end, slots):
    """Sample the step function onto `slots` evenly spaced points in [start, end].

    Gaps carry the previous reading forward; anything before the first sample
    reads as 0, which is honest — we simply were not logging yet.
    """
    if slots <= 0:
        return []
    out, i, last = [], 0, 0.0
    span = max(end - start, 1)
    for slot in range(slots):
        edge = start + span * (slot + 1) / slots
        while i < len(samples) and samples[i][0] <= edge:
            last = samples[i][column]
            i += 1
        out.append(last)
    return out


def burn_rate(samples, window_s=5400, now=None):
    """(percent_per_hour, eta_epoch|None) for the 5h cap, from the current window.

    Readings from before the last reset (a drop in utilisation) are ignored, so
    the slope always describes the window you are actually in.
    """
    now = now or time.time()
    recent = [s for s in samples if s[0] >= now - window_s]
    if len(recent) < 2:
        return None, None
    start = 0
    for i in range(1, len(recent)):
        if recent[i][1] < recent[i - 1][1] - 1:  # utilisation dropped -> window reset
            start = i
    segment = recent[start:]
    if len(segment) < 2:
        return None, None
    hours = (segment[-1][0] - segment[0][0]) / 3600.0
    if hours < 0.15:  # too short a baseline to extrapolate from
        return None, None
    slope = (segment[-1][1] - segment[0][1]) / hours
    if slope <= 0.5:
        return slope, None
    remaining = max(0.0, 100.0 - segment[-1][1])
    return slope, segment[-1][0] + remaining / slope * 3600.0


def prune(path=None, keep_days=90):
    """Drop log lines older than `keep_days`. Cheap, runs from the writer side."""
    path = Path(path or HISTORY_PATH)
    try:
        if path.stat().st_size < 200_000:
            return
        cutoff = time.time() - keep_days * 86400
        kept = [line for line in path.read_text("utf-8").splitlines()
                if line[:line.find(",")].isdigit() and int(line[:line.find(",")]) >= cutoff]
        tmp = path.with_suffix(".tmp")
        tmp.write_text("\n".join(kept) + "\n", "utf-8")
        os.replace(tmp, path)
    except (OSError, ValueError):
        pass
