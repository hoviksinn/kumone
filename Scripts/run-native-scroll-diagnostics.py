#!/usr/bin/env python3
"""Run one native-scroll test command and diagnose a stalled journal stage.

The 30-second default is a diagnostic inactivity budget, not a successful-test
deadline. A stall always fails, including when sampling fails or the command
finishes while its stack is being sampled. The Swift test's input and acceptance
checks remain responsible for proving scrolling.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
import traceback
from typing import Any


class JournalReader:
    """Read only completed JSONL records, tolerating a partial final write."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.identity: tuple[int, int] | None = None
        self.offset = 0
        self.pending = b""
        self.errors: list[str] = []

    def read(self) -> list[dict[str, Any]]:
        try:
            with self.path.open("rb") as source:
                stat = os.fstat(source.fileno())
                identity = (stat.st_dev, stat.st_ino)
                if identity != self.identity or stat.st_size < self.offset:
                    self.identity = identity
                    self.offset = 0
                    self.pending = b""
                source.seek(self.offset)
                data = source.read()
                self.offset = source.tell()
        except FileNotFoundError:
            return []
        if not data:
            return []
        complete = (self.pending + data).split(b"\n")
        self.pending = complete.pop()
        records: list[dict[str, Any]] = []
        for line in complete:
            if not line.strip():
                continue
            try:
                record = json.loads(line)
                if not isinstance(record, dict):
                    raise ValueError("record must be an object")
                pid = record.get("testProcessID")
                if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
                    raise ValueError("testProcessID must be a positive integer")
                if not isinstance(record.get("stage"), str) or not record["stage"]:
                    raise ValueError("stage must be a nonempty string")
                records.append(record)
            except (ValueError, UnicodeError) as error:
                self.errors.append(str(error))
        return records


def emit(message: str, log: Any) -> None:
    data = (message + "\n").encode()
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    log.write(data)


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as destination:
        json.dump(value, destination, indent=2, sort_keys=True)
        destination.write("\n")
        destination.flush()
        os.fsync(destination.fileno())


class OwnedCommand:
    """Validate descendants of this invocation, including SwiftPM child groups.

    SwiftPM launches its native test helper in another process group. Group
    equality therefore neither proves nor disproves parentage. Public ps
    parent chains establish ownership; start time, command and group pin that
    identity for later sampling/cleanup after its parent exits. No unrelated
    process can be adopted just because its name resembles a test helper.
    """

    def __init__(self, driver: int) -> None:
        self.driver = driver
        self.admitted: dict[int, dict[str, Any]] = {}

    def table(self) -> dict[int, dict[str, Any]]:
        listing = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,pgid=,stat=,lstart=,comm="],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, timeout=5, check=False)
        if listing.returncode:
            raise RuntimeError(f"ps exited {listing.returncode}: {listing.stderr.strip()}")
        table: dict[int, dict[str, Any]] = {}
        for line in listing.stdout.splitlines():
            fields = line.split(maxsplit=9)
            if len(fields) != 10:
                continue
            try:
                pid, parent, group = map(int, fields[:3])
            except ValueError:
                continue
            table[pid] = {"pid": pid, "parentPID": parent, "processGroup": group,
                          "state": fields[3], "startedAt": " ".join(fields[4:9]),
                          "command": fields[9]}
        return table

    def ancestry(self, pid: int, table: dict[int, dict[str, Any]]) -> list[int] | None:
        chain: list[int] = []
        while pid in table and pid not in chain:
            chain.append(pid)
            if pid == self.driver:
                return chain
            pid = table[pid]["parentPID"]
        return None

    @staticmethod
    def identity(entry: dict[str, Any]) -> tuple[Any, ...]:
        return entry["pid"], entry["startedAt"], entry["command"], entry["processGroup"]

    def verify(self, pid: int, table: dict[int, dict[str, Any]] | None = None
               ) -> tuple[bool, str, bool]:
        table = self.table() if table is None else table
        entry = table.get(pid)
        if entry is None:
            return False, f"PID {pid} no longer appears in the public process snapshot", True
        admitted = self.admitted.get(pid)
        evidence = json.dumps({"expected": admitted, "observed": entry}, sort_keys=True)
        zombie = entry["state"].startswith("Z")
        if admitted is not None and self.identity(entry) != self.identity(admitted):
            # ps may replace a dead process's command with a zombie marker
            # before its parent reaps it. This never authorizes sampling or a
            # signal, and must not accept a changed birth time/group as exit.
            same_birth_and_group = all(entry[key] == admitted[key]
                                       for key in ("pid", "startedAt", "processGroup"))
            if zombie and same_birth_and_group:
                return False, f"admitted PID {pid} is an unavailable zombie: {evidence}", True
            return False, f"PID {pid} no longer matches its admitted process identity: {evidence}", False
        chain = self.ancestry(pid, table)
        if chain is None and admitted is None:
            return False, f"PID {pid} has no parent chain to own driver {self.driver}", False
        driver = table.get(self.driver)
        if chain is not None and (driver is None or driver["processGroup"] != self.driver):
            return False, f"own driver {self.driver} no longer has its isolated process group", False
        if zombie:
            return False, f"owned PID {pid} is an unavailable zombie: {evidence}", True
        try:
            actual_group = os.getpgid(pid)
        except OSError as error:
            return False, f"cannot inspect owned PID {pid}: {error}", isinstance(error, ProcessLookupError)
        if actual_group != entry["processGroup"]:
            return False, f"PID {pid} changed process group during validation", False
        if admitted is None:
            self.admitted[pid] = dict(entry, verifiedParentChain=chain)
        return True, (f"PID {pid} verified as this command's descendant; "
                      f"group {actual_group}, driver {self.driver}, start {entry['startedAt']}"), False

    def current(self) -> list[dict[str, Any]]:
        table = self.table()
        owned: list[dict[str, Any]] = []
        for pid in table:
            if self.ancestry(pid, table) is not None or pid in self.admitted:
                valid, reason, _ = self.verify(pid, table)
                if valid:
                    owned.append(dict(table[pid], pidValidation=reason,
                                      verifiedParentChain=self.admitted[pid]["verifiedParentChain"]))
        return owned


def owned_process_snapshot(owner: OwnedCommand) -> dict[str, Any]:
    """Read public ps metadata, retaining only verified command descendants.

    A missing journal may mean the native runner stalled before a test began,
    or merely that pipe-buffered Swift Testing output has not flushed. Preserve
    this distinction by labelling the selected process; never relabel SwiftPM's
    driver as the actual test PID.
    """
    result: dict[str, Any] = {"processes": [], "selection": None}
    try:
        result["processes"] = owner.current()
        by_pid = {entry["pid"]: entry for entry in result["processes"]}

        candidates = []
        for entry in result["processes"]:
            basename = Path(entry["command"]).name
            known_runner = (basename == "swiftpm-testing" or basename.endswith(".xctest")
                            or basename.startswith("KumonePackageTests"))
            if entry["pid"] != owner.driver and known_runner:
                candidates.append(entry)
        if len(candidates) == 1:
            result["selection"] = dict(candidates[0], role="owned-native-test-runner-candidate",
                                       basis="known runner command and verified driver ancestry/identity; no journal yet")
        elif len(candidates) > 1:
            result["error"] = "multiple owned native runner candidates; actual test PID remains ambiguous"
        elif owner.driver in by_pid:
            result["selection"] = dict(by_pid[owner.driver], role="owned-command-driver",
                                       basis="no verified native test runner; driver stack only, not test stack")
        else:
            result["error"] = "isolated driver has exited; no unique native runner verified"
    except (OSError, subprocess.TimeoutExpired) as error:
        result["error"] = f"cannot inspect owned process metadata: {error}"
    return result


def terminate_own_group(process: subprocess.Popen[bytes], owner: OwnedCommand) -> list[str]:
    """Signal verified owned PIDs, deepest descendants first and driver last.

    Never signal an entire child group: SwiftPM may have moved descendants to
    new groups, and group membership alone is not a sufficient ownership test.
    """
    messages: list[str] = []
    if owner.driver != process.pid or owner.driver == os.getpgrp():
        return ["refused termination: isolated child process-group invariant failed"]
    targets = sorted(owner.current(), key=lambda entry: len(entry["verifiedParentChain"] or []), reverse=True)
    for action, grace in [(signal.SIGTERM, 3.0), (signal.SIGKILL, 1.0)]:
        for target in targets:
            pid = target["pid"]
            valid, reason, _ = owner.verify(pid)
            if not valid:
                messages.append(f"no {action.name} for PID {pid}: {reason}")
                continue
            try:
                os.kill(pid, action)
                messages.append(f"sent {action.name} to verified owned PID {pid}")
            except ProcessLookupError:
                messages.append(f"owned PID {pid} no longer exists")
            except OSError as error:
                messages.append(f"failed to send {action.name} to owned PID {pid}: {error}")
        expires = time.monotonic() + grace
        denied_probes: set[int] = set()
        while time.monotonic() < expires:
            process.poll()
            remaining = []
            for target in targets:
                pid = target["pid"]
                valid, _, _ = owner.verify(pid)
                if not valid:
                    continue
                try:
                    os.kill(pid, 0)
                    remaining.append(pid)
                except ProcessLookupError:
                    continue
                except PermissionError as error:
                    # A denied probe is not proof that the PID has gone.
                    remaining.append(pid)
                    if pid not in denied_probes:
                        messages.append(f"owned PID {pid} signal-zero probe denied: {error}; "
                                        "absence is unconfirmed, continuing bounded cleanup")
                        denied_probes.add(pid)
            if not remaining:
                return messages
            time.sleep(0.05)
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        messages.append("own command did not reap after verified-PID termination")
    return messages


def collect_sample(args: argparse.Namespace, record: dict[str, Any] | None,
                   owner: OwnedCommand, log: Any) -> dict[str, Any]:
    sample_report: dict[str, Any] = {
        "command": None, "attempted": False, "returnCode": None,
        "samplePath": str(args.sample_output), "commandLog": str(args.sample_log),
    }
    args.sample_log.parent.mkdir(parents=True, exist_ok=True)
    with args.sample_log.open("wb", buffering=0) as sample_log:
        if record is None:
            snapshot = owned_process_snapshot(owner)
            sample_report["ownedProcessSnapshot"] = snapshot
            selection = snapshot["selection"]
            if selection is None:
                reason = "no journal PID and no unambiguous owned sampling target"
                sample_report["error"] = reason
                sample_log.write((json.dumps(snapshot, sort_keys=True) + "\n" + reason + "\n").encode())
                emit("NATIVE_SCROLL_SAMPLE_UNAVAILABLE " + reason, log)
                return sample_report
            pid = selection["pid"]
            sample_report["sampledProcessID"] = pid
            sample_report["samplingRole"] = selection["role"]
            sample_report["samplingBasis"] = selection["basis"]
            sample_log.write((json.dumps(snapshot, sort_keys=True) + "\n").encode())
        else:
            pid = record["testProcessID"]
            sample_report["testProcessID"] = pid
            sample_report["samplingRole"] = "journal-identified-test-process"
        valid, reason, _ = owner.verify(pid)
        sample_report["pidValidation"] = reason
        if not valid:
            sample_report["error"] = reason
            sample_log.write((reason + "\n").encode())
            emit("NATIVE_SCROLL_SAMPLE_UNAVAILABLE " + reason, log)
            return sample_report
        sample_report["verifiedProcessIdentity"] = owner.admitted[pid]
        command = [args.sample_command, str(pid), "2", "-file", str(args.sample_output)]
        sample_report.update(command=command, attempted=True)
        emit("NATIVE_SCROLL_SAMPLE_START " + json.dumps(command), log)
        try:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    timeout=15, check=False)
            sample_log.write(result.stdout)
            sample_report["returnCode"] = result.returncode
            if result.returncode:
                sample_report["error"] = f"sample exited with status {result.returncode}"
            elif not args.sample_output.is_file() or not args.sample_output.stat().st_size:
                sample_report["error"] = "sample returned zero without a nonempty stack file"
            emit(f"NATIVE_SCROLL_SAMPLE_EXIT {result.returncode}", log)
        except subprocess.TimeoutExpired as error:
            sample_log.write(error.stdout or b"")
            reason = "sample exceeded its separate 15-second collection budget"
            sample_log.write(("\n" + reason + "\n").encode())
            sample_report["error"] = reason
            emit("NATIVE_SCROLL_SAMPLE_ERROR " + reason, log)
        except OSError as error:
            reason = f"cannot run sample: {error}"
            sample_log.write((reason + "\n").encode())
            sample_report["error"] = reason
            emit("NATIVE_SCROLL_SAMPLE_ERROR " + reason, log)
        sample_log.flush()
        os.fsync(sample_log.fileno())
    return sample_report


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--journal", type=Path, default=Path(".build/native-scroll-journal.jsonl"))
    parser.add_argument("--log", type=Path, default=Path(".build/native-scroll-regression.log"))
    parser.add_argument("--stall-seconds", type=float, default=30.0)
    parser.add_argument("--sample-command", default="/usr/bin/sample")
    parser.add_argument("--sample-output", type=Path, default=Path(".build/native-scroll-stall-sample.txt"))
    parser.add_argument("--sample-log", type=Path, default=Path(".build/native-scroll-sample-command.log"))
    parser.add_argument("--report", type=Path, default=Path(".build/native-scroll-watchdog.json"))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command and args.command[0] == "--":
        args.command.pop(0)
    if not args.command:
        parser.error("a test command is required after --")
    if not math.isfinite(args.stall_seconds) or args.stall_seconds <= 0:
        parser.error("--stall-seconds must be finite and positive")
    paths = [args.journal, args.log, args.sample_output, args.sample_log, args.report]
    if len({path.resolve() for path in paths}) != len(paths):
        parser.error("journal, log, sample output, sample log and report must be distinct files")
    return args


def main() -> int:
    args = parse_arguments()
    for path in [args.journal, args.log, args.sample_output, args.sample_log, args.report]:
        path.parent.mkdir(parents=True, exist_ok=True)
    # Every invocation owns these explicit diagnostic outputs. Never accept a
    # stale journal PID or a previous run's successful stack capture.
    args.journal.write_bytes(b"")
    args.sample_output.unlink(missing_ok=True)
    args.sample_log.unlink(missing_ok=True)
    reader = JournalReader(args.journal)
    last_record: dict[str, Any] | None = None
    records_seen: list[dict[str, Any]] = []
    unavailable_pid_records: list[dict[str, Any]] = []
    started = time.monotonic()
    last_progress = started
    with args.log.open("wb", buffering=0) as log:
        try:
            process = subprocess.Popen(args.command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       bufsize=0, start_new_session=True)
        except OSError as error:
            emit("NATIVE_SCROLL_COMMAND_START_FAILED " + str(error), log)
            write_json(args.report, {"outcome": "command-start-failed", "error": str(error),
                                     "command": args.command, "wrapperExitCode": 127})
            return 127
        group = process.pid
        owner = OwnedCommand(group)
        emit("NATIVE_SCROLL_WATCHDOG_START " + json.dumps({
            "command": args.command, "ownProcessGroup": group,
            "inactivityBudgetSeconds": args.stall_seconds,
            "budgetScope": "diagnostic failure only; no successful-test timing relaxation",
        }, sort_keys=True), log)
        assert process.stdout is not None
        os.set_blocking(process.stdout.fileno(), False)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)

        def output_ready(timeout: float) -> None:
            for key, _ in selector.select(timeout):
                data = os.read(key.fd, 65536)
                if data:
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                    log.write(data)
                else:
                    selector.unregister(key.fileobj)

        def drain_output() -> None:
            # A descendant could retain/write stdout after the driver exits.
            # Do not let log draining bypass the independent watchdog.
            expires = time.monotonic() + 1
            while selector.get_map() and selector.select(0) and time.monotonic() < expires:
                output_ready(0)

        def ingest(records: list[dict[str, Any]]) -> str | None:
            nonlocal last_record, last_progress
            if reader.errors:
                return "journal has malformed completed records: " + "; ".join(reader.errors)
            table = owner.table() if records else None
            for record in records:
                valid, reason, gone = owner.verify(record["testProcessID"], table)
                if not valid and not gone:
                    return reason
                records_seen.append(record)
                if valid:
                    last_record = record
                    last_progress = time.monotonic()
                else:
                    # A fast test runner may already have exited/reaped before
                    # the wrapper reads its last records. Preserve those final
                    # records, but never use an unverified PID as progress or
                    # as a sampling target while the command remains alive.
                    unavailable_pid_records.append({"record": record, "reason": reason})
            return None

        def diagnostic_failure(reason: str, *, outcome: str = "diagnostic-journal-invalid",
                               exception_traceback: str | None = None) -> int:
            emit("NATIVE_SCROLL_DIAGNOSTIC_FAILURE " + reason, log)
            if exception_traceback:
                emit("NATIVE_SCROLL_DIAGNOSTIC_TRACEBACK\n" + exception_traceback, log)
            termination = terminate_own_group(process, owner)
            drain_output()
            write_json(args.report, {
                "outcome": outcome, "reason": reason, "wrapperExitCode": 125,
                "command": args.command, "ownProcessGroup": group,
                "journalRecords": len(records_seen), "lastRecord": last_record,
                "journalParseErrors": reader.errors, "unavailablePIDRecords": unavailable_pid_records,
                "termination": termination, "commandReturnCodeAfterTermination": process.poll(),
                "exceptionTraceback": exception_traceback,
                "elapsedSeconds": time.monotonic() - started,
            })
            return 125

        try:
            while True:
                invalid = ingest(reader.read())
                if invalid:
                    return diagnostic_failure(invalid)
                code = process.poll()
                if code is not None:
                    # Flush currently available output and any final journal
                    # record without waiting on inherited stdout descriptors.
                    drain_output()
                    invalid = ingest(reader.read())
                    if invalid and code == 0:
                        return diagnostic_failure(invalid)
                    if code == 0 and not records_seen:
                        return diagnostic_failure("command returned zero without a complete valid journal record")
                    result = code if code >= 0 else 128 - code
                    emit(f"NATIVE_SCROLL_COMMAND_EXIT {code}", log)
                    write_json(args.report, {
                        "outcome": "command-finished", "command": args.command,
                        "commandReturnCode": code, "wrapperExitCode": result,
                        "journalRecords": len(records_seen),
                        "lastRecord": records_seen[-1] if records_seen else None,
                        "journalParseErrors": reader.errors,
                        "unavailablePIDRecords": unavailable_pid_records,
                        "elapsedSeconds": time.monotonic() - started,
                    })
                    return result
                idle = time.monotonic() - last_progress
                if idle >= args.stall_seconds:
                    emit("NATIVE_SCROLL_STALL " + json.dumps({
                        "idleSeconds": idle, "lastRecord": last_record,
                        "diagnosticBudgetSeconds": args.stall_seconds,
                    }, sort_keys=True), log)
                    sample = collect_sample(args, last_record, owner, log)
                    termination = terminate_own_group(process, owner)
                    for message in termination:
                        emit("NATIVE_SCROLL_TERMINATION " + message, log)
                    drain_output()
                    write_json(args.report, {
                        "outcome": "diagnostic-stall-failure", "command": args.command,
                        "wrapperExitCode": 124, "ownProcessGroup": group,
                        "journalRecords": len(records_seen), "lastRecord": last_record,
                        "journalParseErrors": reader.errors,
                        "unavailablePIDRecords": unavailable_pid_records,
                        "idleSeconds": idle, "diagnosticBudgetSeconds": args.stall_seconds,
                        "sample": sample, "termination": termination,
                        "commandReturnCodeAfterTermination": process.poll(),
                        "elapsedSeconds": time.monotonic() - started,
                    })
                    return 124
                output_ready(min(0.1, args.stall_seconds - idle))
        except KeyboardInterrupt:
            termination = terminate_own_group(process, owner)
            write_json(args.report, {"outcome": "interrupted", "wrapperExitCode": 130,
                                     "termination": termination, "lastRecord": last_record})
            return 130
        except Exception as error:
            return diagnostic_failure(f"{type(error).__name__}: {error}", outcome="diagnostic-harness-error",
                                      exception_traceback=traceback.format_exc())
        finally:
            selector.close()
            process.stdout.close()


if __name__ == "__main__":
    raise SystemExit(main())
