#!/usr/bin/env python3
"""Run an unchanged task, report its outcome, then publish its original result."""
import json
import ctypes
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile


def warn():
    print("job-report: unable to persist execution record; task result is unchanged", file=sys.stderr)


def stop_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=.2)
    except subprocess.TimeoutExpired:
        pass
    # Still kill descendants after the group leader exits.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run_process(command, env, stdout, timeout=None):
    parent = os.getpid()

    def guard_parent():
        # aqsh's CommandContext kills the wrapper with SIGKILL on timeout.
        # On Linux, do not let the original operation keep running afterwards.
        libc = ctypes.CDLL(None, use_errno=True)
        libc.prctl.argtypes = [ctypes.c_int] + [ctypes.c_ulong] * 4
        if libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0:  # PR_SET_PDEATHSIG
            raise OSError(ctypes.get_errno(), "cannot guard task parent lifetime")
        if os.getppid() != parent:
            os.kill(os.getpid(), signal.SIGKILL)

    process = subprocess.Popen(command, env=env, stdout=stdout, start_new_session=True,
                               preexec_fn=guard_parent if sys.platform == "linux" else None)

    def interrupted(signum, _frame):
        # Raise out of Popen.wait first. Waiting again inside a signal handler
        # would deadlock on Popen's non-reentrant waitpid lock.
        raise SystemExit(128 + signum)

    previous = {s: signal.signal(s, interrupted) for s in (signal.SIGTERM, signal.SIGINT)}
    try:
        return process.wait(timeout=timeout)
    except BaseException:
        # Ignore repeat signals during bounded TERM/KILL cleanup.
        for s in previous:
            signal.signal(s, signal.SIG_IGN)
        stop_group(process)
        raise
    finally:
        for s, handler in previous.items():
            signal.signal(s, handler)


def as_bool(value):
    value = str(value).lower()
    if value in ("true", "1", "yes", "on"):
        return True
    if value in ("false", "0", "no", "off"):
        return False
    return None


def outcome(result, code):
    if code != 0 or not isinstance(result, dict):
        return "failure"
    parts = [result]
    if isinstance(result.get("data"), dict):
        parts.append(result["data"])
    failures = {"ERROR", "FAILED", "FAILURE", "BLOCK", "BLOCKED", "CRITICAL", "PARTIAL"}
    for part in parts:
        if str(part.get("status", "")).upper() in failures or str(part.get("state", "")).upper() in failures:
            return "failure"
        if part.get("partial") is True or part.get("success") is False or part.get("code", 0) != 0:
            return "failure"
    successes = {"SUCCESS", "CHANGED", "OK", "READY", "PASS", "WARN", "COMPLETED"}
    return "success" if str(result.get("status", "")).upper() in successes else "failure"


def read_result(path):
    try:
        if path.stat().st_size > 1024 * 1024:
            return None
        return json.loads(path.read_bytes())
    except (OSError, ValueError):
        return None


def should_report(options, env, result):
    if not options["enabled"]:
        return False
    if any(env.get(key, "") != value for key, value in options["when"].items()):
        return False
    parts = []
    if isinstance(result, dict):
        parts.append(result)
        if isinstance(result.get("data"), dict):
            parts.append(result["data"])
    # The task's result describes what ran. A differently parsed request must
    # not hide a real change (including partial changes on a failed operation).
    flags = [as_bool(part[key]) for part in parts for key in ("dry_run", "dryRun") if key in part]
    if True in flags:
        return False
    if False in flags or any(part.get("changed") is True for part in parts):
        return True
    return not (options["dry_run_env"] and as_bool(env.get(options["dry_run_env"], "")) is True)


def main(settings):
    options = json.loads(Path(settings).read_text())
    env = dict(os.environ)
    original_result = env.get("AQSH_RESULT_FILE", "")
    with tempfile.TemporaryDirectory(prefix="job-report-task-") as directory:
        temporary = Path(directory)
        result_file = temporary / "result"
        stdout_file = temporary / "stdout"
        child_env = {**env, "JOB_REPORT_WRAPPED": "true"}
        # Redirect the result file only when aqsh supplied one. Standalone
        # scripts keep their existing stdout-only behavior.
        if original_result:
            child_env["AQSH_RESULT_FILE"] = str(result_file)
        with stdout_file.open("wb") as stdout:
            code = run_process([options["script"]], child_env, stdout)
        public_code = code if code >= 0 else 128 - code
        result = read_result(result_file)
        if not original_result:
            # Standalone tasks can return a final JSON line on stdout.
            for line in reversed(stdout_file.read_bytes().splitlines()):
                try:
                    result = json.loads(line)
                    break
                except ValueError:
                    continue
        if should_report(options, env, result):
            report_env = {**env, "JOB_REPORT_NAME": env.get("JOB_REPORT_NAME") or options["name"]}
            report_env.pop("JOB_REPORT_TARGET_NAME", None)
            if isinstance(result, dict) and "mdb" in result:
                # Keep the selected instance across reporting-time discovery.
                # An explicitly unresolved target must not select another DB.
                target = result["mdb"]
                report_env["JOB_REPORT_TARGET_NAME"] = target if isinstance(target, str) else ""
            summary = (result.get("summary") or result.get("message")) if isinstance(result, dict) else None
            # Never include arbitrary result/data contents (passwords, secrets).
            if not isinstance(summary, str):
                summary = f"Task exited with code {public_code}; no recognized result summary"
            try:
                with open(os.devnull, "wb") as null:
                    rc = run_process(
                        ["bash", str(Path(options["lib_dir"]) / "job-report-task.sh"),
                         outcome(result, public_code), summary],
                        report_env, null, options["timeout"],
                    )
                if rc:
                    warn()
            except (OSError, subprocess.SubprocessError):
                warn()
        # Preserve exact result bytes, including a missing or malformed result.
        if original_result and result_file.exists():
            shutil.copyfile(result_file, original_result)
        with stdout_file.open("rb") as stdout:
            shutil.copyfileobj(stdout, sys.stdout.buffer)
        return public_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
