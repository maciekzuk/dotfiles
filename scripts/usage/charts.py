"""Pure chart renderers: values in, terminal lines out.

Returned strings carry ANSI colour codes, so lay them out with vlen()/pad()
rather than len()/ljust().
"""

import re
from datetime import timedelta

from theme import ACCENT, DIM, HEAT, LINE, RESET, TEXT, c, pct_color

_ANSI = re.compile(r"\033\[[0-9;]*m")


def vlen(s):
    """Visible width, ignoring colour codes."""
    return len(_ANSI.sub("", s))


def pad(s, width):
    gap = width - vlen(s)
    return s + " " * gap if gap > 0 else s


def clip(s, width):
    """Truncate to `width` visible columns, keeping colour codes intact."""
    if vlen(s) <= width:
        return s
    out, seen, i = [], 0, 0
    while i < len(s) and seen < width:
        m = _ANSI.match(s, i)
        if m:
            out.append(m.group())
            i = m.end()
            continue
        out.append(s[i])
        seen += 1
        i += 1
    return "".join(out) + RESET


def fmt_tokens(n):
    n = float(n)
    if n >= 1e9:
        return "%.1fB" % (n / 1e9)
    if n >= 1e6:
        return "%.1fM" % (n / 1e6)
    if n >= 1e3:
        return "%.0fk" % (n / 1e3)
    return "%.0f" % n


def fmt_count(n):
    return "%d" % round(float(n))


def fmt_dur(seconds):
    """Compact duration: 4d 12h / 2h 31m / 12m / 40s."""
    s = int(max(0, seconds))
    if s >= 86400:
        return "%dd %dh" % (s // 86400, (s % 86400) // 3600)
    if s >= 3600:
        return "%dh %dm" % (s // 3600, (s % 3600) // 60)
    if s >= 60:
        return "%dm" % (s // 60)
    return "%ds" % s


# ── braille line chart ─────────────────────────────────────────

_DOTS = ((0x01, 0x02, 0x04, 0x40), (0x08, 0x10, 0x20, 0x80))


class _Canvas:
    """Braille canvas: each cell holds a 2x4 dot matrix."""

    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.g = [[0] * cols for _ in range(rows)]

    def set(self, x, y):
        if 0 <= x < self.cols * 2 and 0 <= y < self.rows * 4:
            self.g[y // 4][x // 2] |= _DOTS[x % 2][y % 4]

    def render(self):
        return ["".join(chr(0x2800 + v) if v else " " for v in row) for row in self.g]


def resample(values, n):
    """Stretch or squash a series onto exactly n points (linear interpolation)."""
    vals = [float(v) for v in values]
    if n <= 0:
        return []
    if not vals:
        return [0.0] * n
    if len(vals) == 1:
        return [vals[0]] * n
    out = []
    for i in range(n):
        pos = i * (len(vals) - 1) / max(n - 1, 1)
        lo = int(pos)
        hi = min(lo + 1, len(vals) - 1)
        frac = pos - lo
        out.append(vals[lo] * (1 - frac) + vals[hi] * frac)
    return out


def axis_labels(labels, width):
    """labels: [(fraction 0..1, text)] placed along a `width` wide axis."""
    buf = [" "] * width
    for frac, text in labels:
        start = int(round(frac * (width - 1)))
        start = max(0, min(start, width - len(text)))
        for i, ch in enumerate(text):
            if 0 <= start + i < width:
                buf[start + i] = ch
    return "".join(buf)


def line_chart(values, width, height, ymax=None, fill=True, fmt=fmt_tokens,
               xlabels=None, color=ACCENT):
    """Braille area/line chart with a y-axis gutter and optional x labels."""
    height = max(2, height)
    nums = [float(v) for v in values] or [0.0]
    peak = float(ymax) if ymax is not None else max(nums)
    if peak <= 0:
        peak = 1.0
    top, mid = fmt(peak), fmt(peak / 2)
    gutter = max(len(top), len(mid), 1)
    plot_w = max(4, width - gutter - 2)

    canvas = _Canvas(plot_w, height)
    dots_h = height * 4
    prev = None
    for x, v in enumerate(resample(nums, plot_w * 2)):
        y = int(round((1 - min(v / peak, 1.0)) * (dots_h - 1)))
        if fill:
            for yy in range(y, dots_h):
                canvas.set(x, yy)
        elif prev is not None:
            for yy in range(min(prev, y), max(prev, y) + 1):
                canvas.set(x, yy)
        else:
            canvas.set(x, y)
        prev = y

    mid_row = height // 2
    out = []
    for i, row in enumerate(canvas.render()):
        if i == 0:
            label, edge = top, "┤"
        elif i == mid_row:
            label, edge = mid, "┤"
        else:
            label, edge = "", "│"
        out.append(c("%*s %s" % (gutter, label, edge), DIM) + c(row, color))
    out.append(c("%*s └%s" % (gutter, "0", "─" * plot_w), DIM))
    if xlabels:
        out.append(c(" " * (gutter + 2) + axis_labels(xlabels, plot_w), DIM))
    return out


# ── block charts ───────────────────────────────────────────────

_EIGHTHS = " ▁▂▃▄▅▆▇█"


def vbar_chart(values, height=4, ymax=None, color=ACCENT, cell_width=1):
    """Column chart, `cell_width` cells per value, drawn with block glyphs."""
    nums = [float(v) for v in values]
    peak = float(ymax) if ymax is not None else max(nums or [0.0])
    if peak <= 0:
        peak = 1.0
    rows = []
    for r in range(height):
        floor = height - 1 - r
        cells = []
        for v in nums:
            eighths = int(round(min(v / peak, 1.0) * height * 8))
            cells.append(_EIGHTHS[max(0, min(8, eighths - floor * 8))] * cell_width)
        rows.append(c("".join(cells), color))
    return rows


def sparkline(values, color=ACCENT):
    nums = [float(v) for v in values]
    peak = max(nums or [0.0]) or 1.0
    return c("".join(_EIGHTHS[max(1, int(round(v / peak * 8)))] if v else _EIGHTHS[0]
                     for v in nums), color)


def hbar(label, value, maxv, width, label_w=14, value_text=None, color=ACCENT):
    frac = (float(value) / float(maxv)) if maxv else 0.0
    filled = int(round(max(0.0, min(1.0, frac)) * width))
    name = label if len(label) <= label_w else label[: label_w - 1] + "…"
    bar = c("█" * filled, color) + c("░" * (width - filled), LINE)
    val = value_text if value_text is not None else fmt_tokens(value)
    return "%s %s %s" % (c("%-*s" % (label_w, name), TEXT), bar, c(val, DIM))


def gauge(pct, width, color=None):
    color = color or pct_color(pct)
    filled = int(round(max(0.0, min(100.0, float(pct))) / 100 * width))
    return c("█" * filled, color) + c("░" * (width - filled), LINE)


def stacked_bar(parts, width):
    """parts: [(value, colour)] rendered as one bar of `width` cells."""
    total = sum(float(v) for v, _ in parts)
    if total <= 0:
        return c("░" * width, LINE)
    out, used = [], 0
    for i, (value, colour) in enumerate(parts):
        n = width - used if i == len(parts) - 1 else int(round(float(value) / total * width))
        n = max(0, min(n, width - used))
        out.append(c("█" * n, colour))
        used += n
    if used < width:
        out.append(c("░" * (width - used), LINE))
    return "".join(out)


# ── calendar heatmap ───────────────────────────────────────────

_HEAT_GLYPHS = ("░", "▒", "▓", "█")
DAY_LABELS = ("pon", "wto", "śro", "czw", "pią", "sob", "nie")


def heat_level(value, peak):
    """0 = no activity, 1..4 = quartile of the peak."""
    if value <= 0:
        return 0
    frac = value / peak if peak else 0.0
    if frac >= 0.75:
        return 4
    if frac >= 0.45:
        return 3
    if frac >= 0.2:
        return 2
    return 1


def heat_calendar(day_values, weeks, today):
    """GitHub-style grid: 7 rows (Mon..Sun) x `weeks` columns, newest on the right."""
    peak = max(day_values.values()) if day_values else 0.0
    last_monday = today - timedelta(days=today.weekday())
    first = last_monday - timedelta(weeks=weeks - 1)
    lines = []
    for row in range(7):
        cells = []
        for col in range(weeks):
            day = first + timedelta(days=col * 7 + row)
            if day > today:
                cells.append("  ")
                continue
            value = day_values.get(day.strftime("%Y-%m-%d"), 0.0)
            level = heat_level(value, peak)
            glyph = "·" if level == 0 else _HEAT_GLYPHS[level - 1]
            cells.append(c(glyph, DIM if level == 0 else HEAT[level - 1]) + " ")
        lines.append(c(DAY_LABELS[row], DIM) + " " + "".join(cells))
    return lines


def heat_legend():
    ramp = "".join(c(g, HEAT[i]) for i, g in enumerate(_HEAT_GLYPHS))
    return c("mniej ", DIM) + c("·", DIM) + ramp + c(" więcej", DIM)


# ── layout helpers ─────────────────────────────────────────────

def join_columns(left, right, gap=4, left_width=None):
    lw = left_width or max([vlen(x) for x in left] or [0])
    out = []
    for i in range(max(len(left), len(right))):
        l = left[i] if i < len(left) else ""
        r = right[i] if i < len(right) else ""
        out.append(pad(l, lw) + " " * gap + r)
    return out


def rule(width, color=LINE):
    return c("─" * width, color)
