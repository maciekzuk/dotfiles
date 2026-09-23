import json
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from index import UsageIndex, W_CACHE_READ, W_OUTPUT  # noqa: E402


def entry(when, request_id, output=100, cache_read=1000, cwd="/Users/x/dev/repo-a",
          model="claude-opus-5", session="sess-1234-abcd"):
    return json.dumps({
        "timestamp": when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "requestId": request_id,
        "sessionId": session,
        "cwd": cwd,
        "message": {
            "model": model,
            "usage": {
                "input_tokens": 10,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": cache_read,
                "output_tokens": output,
                "output_tokens_details": {"thinking_tokens": 20},
            },
        },
    })


class IndexTest(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        root = Path(self.tmp.name)
        self.projects = root / "projects" / "-Users-x-dev-repo-a"
        self.projects.mkdir(parents=True)
        self.cache = root / "cache"
        # Pinned to midday so "3 hours earlier" stays on the same local day.
        self.now = datetime.now().replace(hour=12, minute=30, second=0, microsecond=0)
        self.transcript = self.projects / "a.jsonl"

    def tearDown(self):
        self.tmp.cleanup()

    def build(self):
        return UsageIndex(projects_dir=self.projects.parent, cache_dir=self.cache)

    def write(self, lines, mode="w"):
        with self.transcript.open(mode) as fh:
            for line in lines:
                fh.write(line + "\n")

    def test_weighted_metric_follows_price_ratios(self):
        self.write([entry(self.now, "req-1")])
        idx = self.build().refresh()
        totals = idx.totals(1)
        self.assertAlmostEqual(
            totals["weighted"], 10 * 1.0 + 1000 * W_CACHE_READ + 100 * W_OUTPUT, places=6)
        self.assertEqual(totals["raw"], 10 + 1000 + 100)
        self.assertEqual(totals["output"], 100)
        self.assertEqual(totals["msgs"], 1)
        self.assertEqual(totals["thinking"], 20)

    def test_duplicate_request_ids_are_counted_once(self):
        self.write([entry(self.now, "req-1"), entry(self.now, "req-1"), entry(self.now, "req-2")])
        idx = self.build().refresh()
        self.assertEqual(idx.totals(1)["msgs"], 2)

    def test_duplicates_across_files_are_counted_once(self):
        self.write([entry(self.now, "req-1")])
        (self.projects / "b.jsonl").write_text(entry(self.now, "req-1") + "\n")
        idx = self.build().refresh()
        self.assertEqual(idx.totals(1)["msgs"], 1)

    def test_incremental_refresh_reads_only_the_new_tail(self):
        self.write([entry(self.now, "req-1")])
        idx = self.build().refresh()
        self.assertEqual(idx.totals(1)["msgs"], 1)
        self.write([entry(self.now, "req-2")], mode="a")
        idx = self.build().refresh()
        self.assertEqual(idx.totals(1)["msgs"], 2)

    def test_repeated_refresh_does_not_double_count(self):
        self.write([entry(self.now, "req-1")])
        self.build().refresh()
        idx = self.build().refresh()
        self.assertEqual(idx.totals(1)["msgs"], 1)

    def test_partial_last_line_is_deferred_until_complete(self):
        self.write([entry(self.now, "req-1")])
        with self.transcript.open("a") as fh:
            fh.write(entry(self.now, "req-2"))  # no trailing newline yet
        idx = self.build().refresh()
        self.assertEqual(idx.totals(1)["msgs"], 1)
        with self.transcript.open("a") as fh:
            fh.write("\n")
        idx = self.build().refresh()
        self.assertEqual(idx.totals(1)["msgs"], 2)

    def test_truncated_transcript_triggers_a_clean_rebuild(self):
        self.write([entry(self.now, "req-1"), entry(self.now, "req-2")])
        self.build().refresh()
        self.write([entry(self.now, "req-3")])  # rewritten, shorter
        idx = self.build().refresh()
        self.assertEqual(idx.totals(1)["msgs"], 1)

    def test_entries_outside_retention_are_dropped(self):
        old = self.now - timedelta(days=120)
        self.write([entry(old, "req-old"), entry(self.now, "req-new")])
        idx = self.build().refresh()
        self.assertEqual(idx.totals(90)["msgs"], 1)

    def test_synthetic_model_entries_are_skipped(self):
        self.write([entry(self.now, "req-1", model="<synthetic>")])
        idx = self.build().refresh()
        self.assertEqual(idx.totals(1)["msgs"], 0)

    def test_buckets_split_by_hour_project_and_model(self):
        earlier = self.now - timedelta(hours=3)
        self.write([
            entry(self.now, "req-1", cwd="/Users/x/dev/repo-a", model="claude-opus-5"),
            entry(earlier, "req-2", cwd="/Users/x/dev/repo-b", model="claude-fable-5"),
        ])
        idx = self.build().refresh()
        hours = dict((t.hour, v) for t, v in idx.hour_values(6, "msgs", now=self.now))
        self.assertEqual(hours[self.now.hour], 1)
        self.assertEqual(hours[earlier.hour], 1)
        self.assertEqual(dict(idx.top_projects(1, "msgs")), {"repo-a": 1, "repo-b": 1})
        self.assertEqual(dict(idx.model_split(1, "msgs")), {"claude-opus-5": 1, "claude-fable-5": 1})

    def test_sessions_and_active_hours(self):
        self.write([
            entry(self.now, "req-1", session="aaaaaaaa-1"),
            entry(self.now - timedelta(hours=2), "req-2", session="bbbbbbbb-2"),
        ])
        idx = self.build().refresh()
        today = self.now.strftime("%Y-%m-%d")
        self.assertEqual(idx.sessions_count(today), 2)
        self.assertEqual(idx.active_hours(today), 2)

    def test_missing_projects_dir_yields_empty_index(self):
        idx = UsageIndex(projects_dir=Path(self.tmp.name) / "nope", cache_dir=self.cache).refresh()
        self.assertFalse(idx.has_data)
        self.assertEqual(idx.totals(7)["msgs"], 0)

    def test_corrupt_lines_are_skipped(self):
        self.write(['{"message": {"usage": broken', entry(self.now, "req-1")])
        idx = self.build().refresh()
        self.assertEqual(idx.totals(1)["msgs"], 1)


if __name__ == "__main__":
    unittest.main()
