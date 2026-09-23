"""Behavior checks for the operator viewer; no Arbor runtime is started."""

import contextlib
import copy
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

import council_view as view


class CouncilViewTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = pathlib.Path(self.temp.name) / "snapshot.json"
        self.doc = {
            "schema_version": 1,
            "source": {"run_id": "run-a", "historical": True, "status": "completed"},
            "seats": [{"id": "seat-a", "perspective": "security", "vote": "abstain",
                       "response": None, "concerns": ["Provider unavailable"]}],
        }
        self.path.write_text(json.dumps(self.doc))

    def run_view(self, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = view.main(["--snapshot", str(self.path), "--run-id", "run-a", *args])
        return result, output.getvalue()

    def test_rejects_a_different_council_in_the_same_snapshot_path(self):
        with self.assertRaisesRegex(ValueError, "run_id"):
            view.load_snapshot(self.path, "run-b")

    def test_failure_seat_is_visible_without_fabricating_a_raw_response(self):
        result, output = self.run_view()
        self.assertEqual(result, 0)
        self.assertIn("abstain=1", output)
        self.assertIn("Provider unavailable", output)
        self.assertIn("Raw response unavailable", output)
        self.assertIn("Task: unbound", output)
        self.assertNotIn("approve=1", output)

    def test_repeated_poll_is_quiet_but_same_length_response_change_is_visible(self):
        seats = [{"id": "a", "response": "first"}]
        seen = {}
        self.assertEqual(len(view.changed_seats(seats, seen)), 1)
        self.assertEqual(view.changed_seats(seats, seen), [])
        updated = copy.deepcopy(seats)
        updated[0]["response"] = "other"
        self.assertEqual(len(view.changed_seats(updated, seen)), 1)

    def test_terminal_controls_are_printable_evidence(self):
        rendered = view.safe_text("hello\x1b[2J\u202e\nworld")
        self.assertNotIn("\x1b", rendered)
        self.assertNotIn("\u202e", rendered)
        self.assertIn("\\u001b", rendered)
        self.assertIn("\nworld", rendered)

    def test_incomplete_snapshot_is_not_reported_as_success(self):
        self.path.write_text('{"schema_version":')
        result, output = self.run_view()
        self.assertEqual(result, 1)
        self.assertIn("Snapshot unavailable", output)

    def test_replay_cannot_mislabel_a_live_snapshot(self):
        self.doc["source"]["historical"] = False
        self.path.write_text(json.dumps(self.doc))
        result, output = self.run_view("--replay-delay", "0")
        self.assertEqual(result, 1)
        self.assertIn("replay requires a historical snapshot", output)

    def test_duplicate_seat_records_cannot_inflate_vote_counts(self):
        self.doc["seats"].append(self.doc["seats"][0])
        self.path.write_text(json.dumps(self.doc))
        result, output = self.run_view()
        self.assertEqual(result, 1)
        self.assertIn("duplicate seat", output)

    def test_follow_observes_a_new_seat_without_restarting_the_viewer(self):
        command = [sys.executable, view.__file__, "--snapshot", str(self.path),
                   "--run-id", "run-a", "--follow-seconds", "1", "--interval", "0.1"]
        with subprocess.Popen(command, stdout=subprocess.PIPE, text=True) as child:
            observed = []
            for line in child.stdout:
                observed.append(line)
                if "Observed 1 seat records" in line:
                    break
            self.assertIn("Observed 1 seat records", "".join(observed))
            self.doc["seats"].append({"id": "seat-b", "perspective": "correctness",
                                      "vote": "approve", "response": "Recorded approval"})
            self.path.write_text(json.dumps(self.doc))
            rest, _ = child.communicate(timeout=3)
            self.assertEqual(child.returncode, 0)
            self.assertIn("Recorded approval", rest)
            self.assertIn("Observed 2 seat records", rest)
            self.assertNotIn("[security]", rest)


if __name__ == "__main__":
    unittest.main()
