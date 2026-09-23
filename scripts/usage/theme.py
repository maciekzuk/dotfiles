"""Vesper palette for the usage dashboard — mirrors the colors in tmux.conf."""

RESET = "\033[0m"
BOLD = "\033[1m"

ACCENT = "#ff8080"
TEXT = "#ffffff"
DIM = "#4e4e4e"
LINE = "#262626"
GREEN = "#87d787"
ORANGE = "#ffaf5f"
RED = "#ff5f5f"
PURPLE = "#b3a3ff"

# Heat ramp for the calendar, dark coral -> accent.
HEAT = ("#2a1c1c", "#6b3a3a", "#b35f5f", "#ff8080")


def fg(hex_color):
    h = hex_color.lstrip("#")
    return "\033[38;2;%d;%d;%dm" % (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def c(text, hex_color, bold=False):
    return "%s%s%s%s" % (BOLD if bold else "", fg(hex_color), text, RESET)


def pct_color(pct):
    """Same thresholds as scripts/color-pct.sh: green < 60, orange 60-84, red >= 85."""
    if pct >= 85:
        return RED
    if pct >= 60:
        return ORANGE
    return GREEN
