#!/usr/bin/env python3
"""Exercise the diagnostic harness with disposable processes on Linux/macOS."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


WRAPPER = Path(__file__).with_name("run-native-scroll-diagnostics.py")


class WatchdogTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native-scroll-watchdog-")
        self.root = Path(self.temporary.name)
        self.journal = self.root / "journal.jsonl"
        self.log = self.root / "command.log"
        self.report = self.root / "report.json"
        self.sample = self.root / "sample.txt"
        self.sample_log = self.root / "sample-command.log"
        self.sample_command = self.root / "fake-sample.py"
        self.sample_command.write_text(
            "#!" + sys.executable + "\n"
            "import pathlib, sys\n"
            "pathlib.Path(sys.argv[sys.argv.index('-file') + 1]).write_text('sampled actual PID ' + sys.argv[1])\n"
            "print('sample collector ran')\n"
        )
        self.sample_command.chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    def command(self, body):
        path = self.root / "fixture.py"
        path.write_text(textwrap.dedent(body))
        return [sys.executable, str(path), str(self.journal)]

    def run_case(self, body, *, budget=0.15, sample_command=None, deny_zero_probe=False):
        command = self.command(body)
        launch = [sys.executable, str(WRAPPER)]
        if deny_zero_probe:
            # Exercise Darwin's observed cleanup error path on Linux too,
            # without modifying the tested signal sends or their ownership.
            bootstrap = self.root / 'deny-zero-probe.py'
            bootstrap.write_text(
                "import errno, os, runpy, sys\n"
                "original = os.killpg\n"
                "def killpg(group, action):\n"
                "    if action == 0:\n"
                "        raise PermissionError(errno.EPERM, 'simulated Darwin group probe denial')\n"
                "    return original(group, action)\n"
                "os.killpg = killpg\n"
                "sys.argv = sys.argv[1:]\n"
                "runpy.run_path(sys.argv[0], run_name='__main__')\n"
            )
            launch = [sys.executable, str(bootstrap), str(WRAPPER)]
        result = subprocess.run([
            *launch, "--journal", str(self.journal),
            "--log", str(self.log), "--report", str(self.report),
            "--sample-output", str(self.sample), "--sample-log", str(self.sample_log),
            "--sample-command", str(sample_command or self.sample_command),
            "--stall-seconds", str(budget), "--", *command,
        ], capture_output=True, text=True, timeout=15)
        return result, json.loads(self.report.read_text())

    def test_success_keeps_partial_final_line_out_of_records(self):
        result, report = self.run_case("""
            import json, os, pathlib, sys
            path = pathlib.Path(sys.argv[1])
            path.write_text(json.dumps({'testProcessID': os.getpid(), 'stage': 'test-complete'}) + '\\n' + '{"stage":')
            print('native checks passed')
        """)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(report["journalRecords"], 1)
        self.assertEqual(report["lastRecord"]["stage"], "test-complete")
        self.assertIn("native checks passed", self.log.read_text())
        self.assertFalse(self.sample.exists())

    def test_command_failure_code_is_preserved(self):
        result, report = self.run_case("""
            import sys
            print('expected test failure')
            sys.exit(23)
        """)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(report["commandReturnCode"], 23)

    def test_denied_zero_probe_preserves_stall_failure_and_stack_evidence(self):
        result, report = self.run_case("""
            import json, os, pathlib, sys, time
            pathlib.Path(sys.argv[1]).write_text(json.dumps({'testProcessID': os.getpid(), 'stage': 'native-call-enter'}) + '\\n')
            time.sleep(60)
        """, deny_zero_probe=True)
        self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
        self.assertEqual(report["outcome"], "diagnostic-stall-failure")
        self.assertEqual(report["sample"]["returnCode"], 0)
        self.assertTrue(self.sample.is_file())
        self.assertTrue(any('signal-zero probe denied' in message for message in report["termination"]))
        self.assertFalse(any('group absence is confirmed' in message for message in report["termination"]))
        self.assertIsNotNone(report["commandReturnCodeAfterTermination"])

    def test_denied_zero_probe_preserves_foreign_journal_failure(self):
        foreign_pid = os.getpid()
        result, report = self.run_case(f"""
            import json, pathlib, sys, time
            pathlib.Path(sys.argv[1]).write_text(json.dumps({{'testProcessID': {foreign_pid}, 'stage': 'foreign-pid'}}) + '\\n')
            time.sleep(60)
        """, deny_zero_probe=True)
        self.assertEqual(result.returncode, 125, result.stdout + result.stderr)
        self.assertEqual(report["outcome"], "diagnostic-journal-invalid")
        self.assertIn('expected own group', report["reason"])
        self.assertTrue(any('signal-zero probe denied' in message for message in report["termination"]))
        self.assertNotIn('sample', report)
        self.assertFalse(self.sample.exists())
        os.kill(foreign_pid, 0)

    def test_stall_samples_actual_test_child_pid_not_driver_pid(self):
        child_source = (
            "import json, os, pathlib, sys, time\n"
            "pathlib.Path(sys.argv[1]).write_text(json.dumps({'testProcessID': os.getpid(), 'stage': 'scroll-enter'}) + '\\n')\n"
            "time.sleep(60)\n"
        )
        result, report = self.run_case(
            "import subprocess, sys\n"
            f"child = subprocess.Popen([sys.executable, '-c', {child_source!r}, sys.argv[1]])\n"
            "child.wait()\n"
        )
        self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
        self.assertEqual(report["outcome"], "diagnostic-stall-failure")
        actual = report["lastRecord"]["testProcessID"]
        self.assertNotEqual(actual, report["ownProcessGroup"])
        self.assertEqual(report["sample"]["testProcessID"], actual)
        self.assertIn(str(actual), self.sample.read_text())
        self.assertEqual(report["sample"]["returnCode"], 0)
        self.assertTrue(report["termination"])

    def test_sample_failure_is_persisted_and_still_fails(self):
        self.sample_command.write_text("#!" + sys.executable + "\nimport sys\nprint('collector failed')\nsys.exit(17)\n")
        result, report = self.run_case("""
            import json, os, pathlib, sys, time
            pathlib.Path(sys.argv[1]).write_text(json.dumps({'testProcessID': os.getpid(), 'stage': 'display-enter'}) + '\\n')
            time.sleep(60)
        """)
        self.assertEqual(result.returncode, 124)
        self.assertEqual(report["sample"]["returnCode"], 17)
        self.assertIn("collector failed", self.sample_log.read_text())
        self.assertIn("status 17", report["sample"]["error"])

    def test_missing_sample_executable_is_preserved_and_still_fails(self):
        result, report = self.run_case("""
            import json, os, pathlib, sys, time
            pathlib.Path(sys.argv[1]).write_text(json.dumps({'testProcessID': os.getpid(), 'stage': 'layout-enter'}) + '\\n')
            time.sleep(60)
        """, sample_command=self.root / "no-sample-tool")
        self.assertEqual(result.returncode, 124)
        self.assertIn("cannot run sample", report["sample"]["error"])
        self.assertIn("cannot run sample", self.sample_log.read_text())

    def test_no_journal_labels_driver_sample_without_claiming_test_pid(self):
        result, report = self.run_case("""
            import time
            time.sleep(60)
        """)
        self.assertEqual(result.returncode, 124)
        self.assertTrue(report["sample"]["attempted"])
        self.assertNotIn("testProcessID", report["sample"])
        self.assertEqual(report["sample"]["sampledProcessID"], report["ownProcessGroup"])
        self.assertEqual(report["sample"]["samplingRole"], "owned-command-driver")
        self.assertIn("not test stack", report["sample"]["samplingBasis"])

    def test_no_journal_finds_known_owned_runner_and_preserves_driver_ancestry(self):
        actual_pid_file = self.root / "actual-runner-pid"
        runner_path = self.root / "swiftpm-testing"
        result, report = self.run_case(f"""
            import os, pathlib, shutil, subprocess
            runner = pathlib.Path({str(runner_path)!r})
            shutil.copyfile('/bin/sleep', runner)
            runner.chmod(0o755)
            child = subprocess.Popen([str(runner), '60'])
            pathlib.Path({str(actual_pid_file)!r}).write_text(str(child.pid))
            child.wait()
        """, budget=0.3)
        self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
        self.assertTrue(report["sample"]["attempted"])
        self.assertNotIn("testProcessID", report["sample"])
        actual = int(actual_pid_file.read_text())
        self.assertEqual(report["sample"]["sampledProcessID"], actual)
        self.assertNotEqual(actual, report["ownProcessGroup"])
        self.assertEqual(report["sample"]["samplingRole"], "owned-native-test-runner-candidate")
        self.assertIn(str(actual), self.sample.read_text())

    def test_no_journal_does_not_select_foreign_known_runner(self):
        runner = self.root / 'swiftpm-testing'
        import shutil
        shutil.copyfile('/bin/sleep', runner)
        runner.chmod(0o755)
        foreign = subprocess.Popen([str(runner), '60'], start_new_session=True)
        try:
            result, report = self.run_case("""
                import time
                time.sleep(60)
            """)
            self.assertEqual(result.returncode, 124)
            self.assertEqual(report["sample"]["samplingRole"], "owned-command-driver")
            self.assertNotEqual(report["sample"]["sampledProcessID"], foreign.pid)
            self.assertTrue(all(entry["pid"] != foreign.pid for entry in
                                report["sample"]["ownedProcessSnapshot"]["processes"]))
            self.assertIsNone(foreign.poll())
        finally:
            foreign.terminate()
            foreign.wait(timeout=3)

    def test_foreign_pid_is_neither_sampled_nor_signaled(self):
        foreign_pid = os.getpid()
        result, report = self.run_case(f"""
            import json, pathlib, sys, time
            pathlib.Path(sys.argv[1]).write_text(json.dumps({{'testProcessID': {foreign_pid}, 'stage': 'foreign-pid'}}) + '\\n')
            time.sleep(60)
        """)
        self.assertEqual(result.returncode, 125)
        self.assertEqual(report["outcome"], "diagnostic-journal-invalid")
        self.assertNotIn("sample", report)
        self.assertIn("expected own group", report["reason"])
        os.kill(foreign_pid, 0)
        self.assertFalse(self.sample.exists())

    def test_success_without_completed_journal_record_is_invalid(self):
        result, report = self.run_case("""
            print('driver zero is insufficient without the journal')
        """)
        self.assertEqual(result.returncode, 125)
        self.assertEqual(report["outcome"], "diagnostic-journal-invalid")
        self.assertIn("without a complete valid journal", report["reason"])

    def test_completed_malformed_journal_is_invalid(self):
        result, report = self.run_case("""
            import pathlib, sys
            pathlib.Path(sys.argv[1]).write_text('{broken}\\n')
        """)
        self.assertEqual(result.returncode, 125)
        self.assertEqual(report["outcome"], "diagnostic-journal-invalid")
        self.assertTrue(report["journalParseErrors"])

    def test_unexpected_reader_error_terminates_own_group(self):
        result, report = self.run_case("""
            import pathlib, sys, time
            journal = pathlib.Path(sys.argv[1])
            journal.unlink()
            journal.mkdir()
            time.sleep(60)
        """)
        self.assertEqual(result.returncode, 125)
        self.assertEqual(report["outcome"], "diagnostic-harness-error")
        self.assertIn("IsADirectoryError", report["reason"])
        self.assertIn("Traceback (most recent call last)", report["exceptionTraceback"])
        self.assertIn("IsADirectoryError", report["exceptionTraceback"])
        self.assertIn("reader.read()", report["exceptionTraceback"])
        self.assertIn("NATIVE_SCROLL_DIAGNOSTIC_TRACEBACK", self.log.read_text())
        self.assertTrue(report["termination"])

    def test_nonfinite_budgets_are_rejected_before_launch(self):
        for budget in ["nan", "inf", "-inf"]:
            result = subprocess.run([
                sys.executable, str(WRAPPER), "--stall-seconds=" + budget,
                "--", sys.executable, "-c", "raise RuntimeError('must not launch')",
            ], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertIn("finite and positive", result.stderr)

    def test_budget_tracks_stage_progress_not_total_runtime(self):
        result, report = self.run_case("""
            import json, os, pathlib, sys, time
            with pathlib.Path(sys.argv[1]).open('a') as journal:
                for index in range(7):
                    journal.write(json.dumps({'testProcessID': os.getpid(), 'stage': 'phase-' + str(index)}) + '\\n')
                    journal.flush()
                    os.fsync(journal.fileno())
                    time.sleep(0.06)
        """, budget=0.2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(report["journalRecords"], 7)
        self.assertGreater(report["elapsedSeconds"], 0.2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
