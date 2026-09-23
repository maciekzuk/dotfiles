import sys
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import charts  # noqa: E402
from theme import ACCENT  # noqa: E402


def plain(line):
    return charts._ANSI.sub("", line)


class TextHelpersTest(unittest.TestCase):
    def test_vlen_ignores_colour_codes(self):
        self.assertEqual(charts.vlen(charts.c("abc", ACCENT)), 3)

    def test_pad_uses_visible_width(self):
        padded = charts.pad(charts.c("ab", ACCENT), 6)
        self.assertEqual(charts.vlen(padded), 6)

    def test_clip_keeps_colour_and_visible_width(self):
        clipped = charts.clip(charts.c("abcdefgh", ACCENT), 4)
        self.assertEqual(plain(clipped), "abcd")

    def test_clip_leaves_short_lines_alone(self):
        line = charts.c("ab", ACCENT)
        self.assertIs(charts.clip(line, 10), line)

    def test_fmt_tokens_scales(self):
        self.assertEqual(charts.fmt_tokens(950), "950")
        self.assertEqual(charts.fmt_tokens(12_300), "12k")
        self.assertEqual(charts.fmt_tokens(12_400_000), "12.4M")
        self.assertEqual(charts.fmt_tokens(2_000_000_000), "2.0B")

    def test_fmt_dur_picks_units(self):
        self.assertEqual(charts.fmt_dur(45), "45s")
        self.assertEqual(charts.fmt_dur(600), "10m")
        self.assertEqual(charts.fmt_dur(9060), "2h 31m")
        self.assertEqual(charts.fmt_dur(390_000), "4d 12h")


class SeriesTest(unittest.TestCase):
    def test_resample_hits_both_ends(self):
        out = charts.resample([0, 10], 5)
        self.assertEqual(len(out), 5)
        self.assertAlmostEqual(out[0], 0)
        self.assertAlmostEqual(out[-1], 10)

    def test_resample_handles_empty_and_single(self):
        self.assertEqual(charts.resample([], 3), [0.0, 0.0, 0.0])
        self.assertEqual(charts.resample([7], 3), [7.0, 7.0, 7.0])

    def test_axis_labels_never_overflow(self):
        line = charts.axis_labels([(0.0, "00:00"), (1.0, "23:59")], 20)
        self.assertEqual(len(line), 20)
        self.assertTrue(line.startswith("00:00"))
        self.assertTrue(line.rstrip().endswith("23:59"))


class ChartShapeTest(unittest.TestCase):
    def test_line_chart_has_expected_height_and_width(self):
        out = charts.line_chart([1, 5, 3, 9, 2], width=40, height=6, xlabels=[(0.0, "a")])
        self.assertEqual(len(out), 6 + 1 + 1)  # plot rows + axis + labels
        for line in out:
            self.assertLessEqual(charts.vlen(line), 40)

    def test_line_chart_survives_all_zero_series(self):
        out = charts.line_chart([0, 0, 0], width=30, height=4)
        self.assertEqual(len(out), 5)

    def test_line_chart_draws_braille(self):
        out = charts.line_chart([0, 5, 10], width=30, height=4)
        body = "".join(plain(line) for line in out[:4])
        self.assertTrue(any(0x2800 <= ord(ch) <= 0x28FF for ch in body))

    def test_vbar_chart_rows_and_columns(self):
        rows = charts.vbar_chart([1, 2, 3], height=3, cell_width=2)
        self.assertEqual(len(rows), 3)
        for row in rows:
            self.assertEqual(charts.vlen(row), 6)

    def test_vbar_chart_tops_out_the_peak_column(self):
        rows = charts.vbar_chart([0, 10], height=2)
        self.assertEqual(plain(rows[0])[1], "█")   # peak reaches the top row
        self.assertEqual(plain(rows[0])[0], " ")   # empty column stays blank

    def test_hbar_fills_proportionally(self):
        line = charts.hbar("repo", 5, 10, width=10, label_w=6)
        self.assertEqual(plain(line).count("█"), 5)
        self.assertEqual(plain(line).count("░"), 5)

    def test_hbar_truncates_long_labels(self):
        line = plain(charts.hbar("very-long-project-name", 1, 1, width=4, label_w=8))
        self.assertTrue(line.startswith("very-lo…"))

    def test_gauge_rounds_to_width(self):
        self.assertEqual(plain(charts.gauge(50, 10)).count("█"), 5)
        self.assertEqual(plain(charts.gauge(0, 10)).count("█"), 0)
        self.assertEqual(plain(charts.gauge(100, 10)).count("█"), 10)

    def test_stacked_bar_uses_exactly_width_cells(self):
        bar = charts.stacked_bar([(1, ACCENT), (3, ACCENT)], 12)
        self.assertEqual(charts.vlen(bar), 12)

    def test_stacked_bar_with_no_data_is_empty_track(self):
        self.assertEqual(plain(charts.stacked_bar([(0, ACCENT)], 5)), "░░░░░")


class HeatmapTest(unittest.TestCase):
    def test_heat_level_buckets(self):
        self.assertEqual(charts.heat_level(0, 100), 0)
        self.assertEqual(charts.heat_level(10, 100), 1)
        self.assertEqual(charts.heat_level(30, 100), 2)
        self.assertEqual(charts.heat_level(50, 100), 3)
        self.assertEqual(charts.heat_level(90, 100), 4)

    def test_calendar_has_seven_rows_and_blanks_the_future(self):
        today = date(2026, 8, 19)  # a Wednesday
        lines = charts.heat_calendar({"2026-08-17": 10.0}, weeks=2, today=today)
        self.assertEqual(len(lines), 7)
        monday = plain(lines[0])
        self.assertTrue(monday.startswith("pon"))
        self.assertEqual(monday[-2:], "█ ")          # Monday this week has data
        self.assertEqual(plain(lines[4])[-2:], "  ")  # Friday is still ahead


if __name__ == "__main__":
    unittest.main()
