#!/usr/bin/env python3
"""Claude usage dashboard for tmux — bound to prefix + U.

Four tabs over two data sources: the local transcript index (index.py) for
history, and the 5h/7d caps plus their logged samples (limits.py) for "how
close am I to the wall right now".
"""

import argparse
import os
import select
import signal
import sys
import termios
import time
import tty
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import limits  # noqa: E402
from charts import (clip, fmt_count, fmt_dur, fmt_tokens, gauge, hbar,  # noqa: E402
                    heat_calendar, heat_legend, join_columns, line_chart, pad,
                    rule, stacked_bar, vbar_chart, vlen)
from index import METRIC_LABELS, METRICS, UsageIndex  # noqa: E402
from theme import (ACCENT, DIM, GREEN, LINE, ORANGE, PURPLE, RED, TEXT,  # noqa: E402
                   c, pct_color)

RANGES = (7, 30, 90)
AUTO_REFRESH_S = 10
MIN_WIDTH, MIN_HEIGHT = 60, 18
WIDE = 100
PL_DAYS = ("pon", "wto", "śro", "czw", "pią", "sob", "nie")
MODEL_COLORS = (ACCENT, PURPLE, GREEN, ORANGE)


class State:
    def __init__(self, tab=0, metric=0, span=1):
        self.tab = tab
        self.metric_i = metric
        self.span_i = span

    @property
    def metric(self):
        return METRICS[self.metric_i]

    @property
    def span(self):
        return RANGES[self.span_i]


def fmt_metric(value, metric):
    return fmt_count(value) if metric == "msgs" else fmt_tokens(value)


def metric_fmt(metric):
    return fmt_count if metric == "msgs" else fmt_tokens


def short_model(name):
    return name.replace("claude-", "").replace("-20", " ")


# ── tabs ───────────────────────────────────────────────────────

def tab_limits(state, idx, w, h):
    now = time.time()
    caps = limits.current()
    samples = limits.history(since_epoch=now - 8 * 86400)
    lines = []

    bar_w = min(46, max(16, w // 3))
    for key, label in (("5h", "5h"), ("7d", "7d")):
        cap = caps.get(key)
        if not cap:
            lines.append(c("%-3s brak danych z Claude Code" % label, DIM))
            continue
        pct = cap["pct"]
        left = ""
        if cap["reset"]:
            left = c("   reset za %s" % fmt_dur(cap["reset"] - now), DIM)
        lines.append("%s %s %s%s" % (
            c("%-3s" % label, TEXT, bold=True),
            gauge(pct, bar_w),
            c("%3d%%" % round(pct), pct_color(pct), bold=True),
            left))
    lines.append("")

    if len(samples) < 2:
        lines.append(c("historia limitów zbiera się od dziś — próbka co 5 min ze status bara", DIM))
        lines.append(c("(%d %s w logu)" % (len(samples), "próbka" if len(samples) == 1 else "próbek"), DIM))
    else:
        chart_h = max(3, min(8, (h - 10) // 2 if w < WIDE else h - 9))
        chart_w = (w - 6) // 2 if w >= WIDE else w - 2
        five = limits.resample(samples, 1, now - 86400, now, 48)
        seven = limits.resample(samples, 2, now - 7 * 86400, now, 56)
        left = [c("okno 5h · ostatnie 24 h", DIM)] + line_chart(
            five, chart_w, chart_h, ymax=100, fmt=lambda v: "%d%%" % round(v),
            xlabels=_clock_labels(now - 86400, now, "%H:%M"), color=ACCENT)
        right = [c("okno 7d · ostatnie 7 dni", DIM)] + line_chart(
            seven, chart_w, chart_h, ymax=100, fmt=lambda v: "%d%%" % round(v),
            xlabels=_clock_labels(now - 7 * 86400, now, "%d.%m"), color=ORANGE)
        lines.extend(join_columns(left, right, gap=2, left_width=chart_w + 2)
                     if w >= WIDE else left + [""] + right)

        slope, eta = limits.burn_rate(samples, now=now)
        if slope is None:
            lines.append(c("tempo: za mało próbek, żeby liczyć trend", DIM))
        elif eta is None:
            lines.append(c("tempo: ", DIM) + c("%+.1f %%/h" % slope, GREEN) +
                         c("  — bez zagrożenia w tym oknie", DIM))
        else:
            when = datetime.fromtimestamp(eta)
            hit = eta - now
            colour = RED if hit < 3600 else ORANGE
            lines.append(c("tempo: ", DIM) + c("%+.1f %%/h" % slope, colour) +
                         c(" → limit 5h ok. ", DIM) +
                         c(when.strftime("%H:%M"), colour, bold=True) +
                         c(" (za %s)" % fmt_dur(hit), DIM))

    lines.append("")
    today = datetime.now().strftime("%Y-%m-%d")
    totals = idx.totals(1)
    sessions = idx.sessions_count(today)
    lines.append(
        c("dzisiaj  ", DIM) +
        c(fmt_metric(totals[state.metric], state.metric), TEXT, bold=True) +
        c(" %s · " % METRIC_LABELS[state.metric], DIM) +
        c("%d" % sessions, TEXT) + c(" sesji · ", DIM) +
        c("%d" % idx.active_hours(today), TEXT) + c(" h aktywnych · ", DIM) +
        c("%d" % totals["msgs"], TEXT) + c(" wiadomości", DIM))
    return lines


def tab_hours(state, idx, w, h):
    series = idx.hour_values(48, state.metric)
    values = [v for _, v in series]
    peak_at, peak = max(series, key=lambda p: p[1]) if series else (None, 0)

    chart_h = max(4, min(12, h - 10))
    lines = [
        c("ostatnie 48 h · ", DIM) + c(METRIC_LABELS[state.metric], TEXT) +
        c("      szczyt ", DIM) +
        (c("%s %02d:00 · %s" % (PL_DAYS[peak_at.weekday()], peak_at.hour,
                                fmt_metric(peak, state.metric)), TEXT) if peak else c("–", DIM))
    ]
    lines += line_chart(values, w - 2, chart_h, fmt=metric_fmt(state.metric),
                        xlabels=_series_labels(series, "%H:%M"))
    lines.append("")

    typical = idx.typical_day(state.span, state.metric)
    cell = 2 if w >= 90 else 1
    lines.append(c("typowa doba · średnia z %d dni" % state.span, DIM))
    lines += vbar_chart(typical, height=4, cell_width=cell)
    axis = "".join(("%02d" % hour).ljust(3 * cell) for hour in range(0, 24, 3))
    lines.append(c(axis[:24 * cell], DIM))
    total = sum(typical)
    if total:
        busiest = max(range(24), key=lambda i: typical[i])
        lines.append(c("najmocniejsza godzina: ", DIM) + c("%02d:00" % busiest, TEXT) +
                     c("  ·  średnio %s dziennie" % fmt_metric(total, state.metric), DIM))
    return lines


def tab_days(state, idx, w, h):
    metric = state.metric
    today = datetime.now().date()
    weeks = max(4, min(18, (w - 46) // 2 if w >= WIDE else (w - 8) // 2))
    if idx.first_day:  # never stretch the grid past the data we actually have
        first = datetime.strptime(idx.first_day, "%Y-%m-%d").date()
        weeks = max(4, min(weeks, ((today - first).days + today.weekday()) // 7 + 1))
    day_map = idx.day_map(weeks * 7, metric)

    heat = [c("ostatnie %d tygodni" % weeks, DIM)] + heat_calendar(day_map, weeks, today)
    heat.append(heat_legend())

    days = idx.day_values(state.span, metric)
    week_now = sum(v for _, v in days[-7:])
    week_prev = sum(v for _, v in idx.day_values(14, metric)[:7])
    delta = ((week_now - week_prev) / week_prev * 100) if week_prev else None
    best_day, best = max(days, key=lambda p: p[1]) if days else (None, 0)
    totals = idx.totals(state.span)

    stats = [
        c("zakres %d dni" % state.span, DIM),
        c("suma        ", DIM) + c(fmt_metric(totals[metric], metric), TEXT, bold=True),
        c("dziennie    ", DIM) + c(fmt_metric(totals[metric] / state.span, metric), TEXT),
        c("rekord      ", DIM) + (c("%s · %s" % (best_day.strftime("%d.%m"),
                                                 fmt_metric(best, metric)), TEXT) if best else c("–", DIM)),
        c("seria       ", DIM) + c("%d dni z rzędu" % idx.streak(), TEXT),
        c("ten tydzień ", DIM) + c(fmt_metric(week_now, metric), TEXT) +
        (c("  %+.0f%% vs poprzedni" % delta, GREEN if delta >= 0 else ORANGE) if delta is not None else ""),
    ]
    lines = join_columns(heat, stats, gap=4) if w >= WIDE else heat + [""] + stats

    lines.append("")
    tail = days[-min(len(days), max(7, (w - 4) // 3)):]
    lines.append(c("ostatnie %d dni" % len(tail), DIM))
    lines += vbar_chart([v for _, v in tail], height=max(3, min(6, h - len(lines) - 3)), cell_width=3)
    lines.append(c("".join(("%-3s" % d.strftime("%d")) for d, _ in tail), DIM))
    return lines


def tab_projects(state, idx, w, h):
    metric = state.metric
    span = state.span
    rows = max(4, min(10, h - 8))
    projects = idx.top_projects(span, metric, limit=rows)
    totals = idx.totals(span)
    top = projects[0][1] if projects else 0

    bar_w = min(34, max(10, (w // 2) - 34)) if w >= WIDE else max(10, w - 34)
    left = [c("projekty · %d dni" % span, DIM)]
    if not projects:
        left.append(c("brak danych w tym zakresie", DIM))
    for name, value in projects:
        share = value / totals[metric] * 100 if totals[metric] else 0
        left.append(hbar(name, value, top, bar_w, label_w=16,
                         value_text="%s  %2.0f%%" % (fmt_metric(value, metric), share)))

    models = idx.model_split(span, metric)
    right = [c("modele · %d dni" % span, DIM)]
    if models:
        right.append(stacked_bar([(v, MODEL_COLORS[i % len(MODEL_COLORS)])
                                  for i, (_, v) in enumerate(models)], min(40, max(12, bar_w))))
        mtotal = sum(v for _, v in models)
        for i, (name, value) in enumerate(models[:4]):
            right.append(c("█ ", MODEL_COLORS[i % len(MODEL_COLORS)]) +
                         c("%-22s" % short_model(name), TEXT) +
                         c("%5.1f%%" % (value / mtotal * 100 if mtotal else 0), DIM))
    else:
        right.append(c("brak danych", DIM))

    reads = totals["cache_read"]
    fresh = totals["cache_create"] + totals["input"]
    ratio = reads / (reads + fresh) * 100 if (reads + fresh) else 0
    think = totals["thinking"] / totals["output"] * 100 if totals["output"] else 0
    right += [
        "",
        c("cache hit   ", DIM) + c("%.1f%%" % ratio, GREEN if ratio >= 80 else ORANGE) +
        c("   (%s z cache)" % fmt_tokens(reads), DIM),
        c("thinking    ", DIM) + c("%.1f%%" % think, TEXT) +
        c("   (%s z %s output)" % (fmt_tokens(totals["thinking"]), fmt_tokens(totals["output"])), DIM),
        c("wiadomości  ", DIM) + c(fmt_count(totals["msgs"]), TEXT) +
        c("   w %d dniach" % span, DIM),
    ]
    return join_columns(left, right, gap=4) if w >= WIDE else left + [""] + right


TABS = (("limity", tab_limits), ("godziny", tab_hours), ("dni", tab_days), ("projekty", tab_projects))


# ── chrome ─────────────────────────────────────────────────────

def _clock_labels(start, end, fmt):
    return [(f, datetime.fromtimestamp(start + (end - start) * f).strftime(fmt))
            for f in (0.0, 0.25, 0.5, 0.75, 1.0)]


def _series_labels(series, fmt):
    if not series:
        return []
    out = []
    for f in (0.0, 0.25, 0.5, 0.75, 1.0):
        when = series[min(len(series) - 1, int(f * (len(series) - 1)))][0]
        out.append((f, when.strftime(fmt)))
    return out


def header(state, idx, width):
    tabs = []
    for i, (name, _) in enumerate(TABS):
        tabs.append(c(" %d %s " % (i + 1, name), ACCENT if i == state.tab else DIM,
                      bold=i == state.tab))
    left = c(" ● claude usage ", ACCENT, bold=True) + c("│", LINE) + "".join(tabs)
    age = time.time() - idx.scanned_at if idx.scanned_at else None
    right = c("%s · %dd · dane %s temu " % (
        METRIC_LABELS[state.metric], state.span,
        fmt_dur(age) if age is not None else "?"), DIM)
    return pad(left, max(0, width - vlen(right))) + right


def footer(width):
    keys = [("1-4", "zakładki"), ("m", "metryka"), ("[ ]", "zakres"),
            ("r", "odśwież"), ("q", "wyjście")]
    return " " + c("  ".join("%s %s" % (k, v) for k, v in keys), DIM)


def render(state, idx, size):
    w, h = size
    if w < MIN_WIDTH or h < MIN_HEIGHT:
        return [c(" powiększ okno (min %dx%d)" % (MIN_WIDTH, MIN_HEIGHT), DIM)]
    body_h = h - 5
    if not idx.has_data:
        body = [c(" brak danych w ~/.claude/projects — nic jeszcze nie zaindeksowano", DIM)]
    else:
        body = TABS[state.tab][1](state, idx, w - 2, body_h)
    lines = [header(state, idx, w), rule(w), ""]
    lines += [" " + line for line in body[:body_h]]
    while len(lines) < h - 1:
        lines.append("")
    lines.append(footer(w))
    return lines


def draw(lines, size):
    w, h = size
    buf = ["\033[H"]
    for i in range(h):
        buf.append(clip(lines[i] if i < len(lines) else "", w) + "\033[K")
        if i < h - 1:
            buf.append("\r\n")
    buf.append("\033[J")
    sys.stdout.write("".join(buf))
    sys.stdout.flush()


def splash(message):
    return ["", c("  ● claude usage", ACCENT, bold=True), "", c("  %s" % message, DIM)]


@contextmanager
def raw_terminal():
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        sys.stdout.write("\033[?1049h\033[?25l")
        sys.stdout.flush()
        yield
    finally:
        sys.stdout.write("\033[?25h\033[?1049l")
        sys.stdout.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


def read_key(timeout, wake_fd=None):
    """One keypress, or None on timeout / terminal resize.

    The resize signal arrives through `wake_fd` (signal.set_wakeup_fd): a bare
    handler would only set a flag, and select() restarts itself after it
    returns, so a resize would sit unnoticed until the next auto-refresh.
    """
    watch = [sys.stdin] + ([wake_fd] if wake_fd is not None else [])
    try:
        ready, _, _ = select.select(watch, [], [], timeout)
    except (InterruptedError, OSError):
        return None
    if not ready:
        return None
    if wake_fd is not None and wake_fd in ready:
        try:
            os.read(wake_fd, 64)
        except OSError:
            pass
        return None
    ch = sys.stdin.read(1)
    if ch != "\033":
        return ch
    ready, _, _ = select.select([sys.stdin], [], [], 0.05)
    if not ready:
        return "esc"
    seq = sys.stdin.read(1)
    if seq == "[":
        rest = sys.stdin.read(1)
        return {"Z": "shift-tab", "C": "right", "D": "left"}.get(rest, "esc")
    return "esc"


def terminal_size():
    try:
        size = os.get_terminal_size()
        return size.columns, size.lines
    except OSError:
        return 120, 40


def run():
    state = State()
    idx = UsageIndex()
    wake_r = None
    try:
        wake_r, wake_w = os.pipe()
        os.set_blocking(wake_r, False)
        os.set_blocking(wake_w, False)
        signal.set_wakeup_fd(wake_w)
        signal.signal(signal.SIGWINCH, lambda *_: None)
    except (ValueError, AttributeError, OSError):
        wake_r = None

    with raw_terminal():
        size = terminal_size()
        draw(splash("indeksuję transkrypty…"), size)

        def progress(done, total):
            if total and done % 40 == 0:
                draw(splash("indeksuję transkrypty… %d/%d" % (done, total)), size)

        idx.refresh(on_progress=progress)
        limits.refresh_async()
        limits.prune()
        last = time.time()

        while True:
            size = terminal_size()
            draw(render(state, idx, size), size)
            key = read_key(AUTO_REFRESH_S, wake_r)

            if key in ("q", "esc"):
                return
            if key in ("1", "2", "3", "4"):
                state.tab = int(key) - 1
            elif key == "\t" or key == "right":
                state.tab = (state.tab + 1) % len(TABS)
            elif key in ("shift-tab", "left"):
                state.tab = (state.tab - 1) % len(TABS)
            elif key == "m":
                state.metric_i = (state.metric_i + 1) % len(METRICS)
            elif key == "]":
                state.span_i = min(state.span_i + 1, len(RANGES) - 1)
            elif key == "[":
                state.span_i = max(state.span_i - 1, 0)
            elif key == "r":
                draw(splash("pełne przeindeksowanie…"), size)
                idx.refresh(force=True, on_progress=progress)
                limits.refresh_async()
                last = time.time()
            elif key is None and time.time() - last >= AUTO_REFRESH_S:
                idx.refresh()
                limits.refresh_async()
                last = time.time()


def main():
    parser = argparse.ArgumentParser(description="Claude usage dashboard")
    parser.add_argument("--print", dest="once", action="store_true",
                        help="render one frame to stdout and exit (debugging)")
    parser.add_argument("--tab", type=int, default=1)
    parser.add_argument("--metric", default="weighted", choices=list(METRICS))
    parser.add_argument("--span", type=int, default=30, choices=list(RANGES))
    parser.add_argument("--width", type=int, default=0)
    parser.add_argument("--height", type=int, default=0)
    args = parser.parse_args()

    if args.once:
        size = terminal_size()
        w = args.width or size[0]
        h = args.height or size[1]
        state = State(tab=max(0, min(args.tab - 1, len(TABS) - 1)),
                      metric=METRICS.index(args.metric), span=RANGES.index(args.span))
        idx = UsageIndex().refresh()
        limits.prune()
        print("\n".join(clip(line, w) for line in render(state, idx, (w, h))))
        return

    if not sys.stdin.isatty():
        print("dash.py wymaga terminala (albo użyj --print)", file=sys.stderr)
        sys.exit(1)
    try:
        run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
