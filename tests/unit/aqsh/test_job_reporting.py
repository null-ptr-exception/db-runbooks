#!/usr/bin/env python3
"""Contracts for YAML reporting, without Docker, Redis or a cluster."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[3]
LIB = ROOT / "aqsh-tasks/lib"
spec = importlib.util.spec_from_file_location("report_config", LIB / "job-report-config.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tasks = self.root / "tasks"
        self.tasks.mkdir()
        self.script = self.tasks / "operation.sh"
        self.script.write_text("#!/usr/bin/env bash\nexit 0\n")
        self.script.chmod(0o755)

    def task(self, **options):
        return {"script": "operation.sh", "job_report": options,
                "input": [{"name": "namespace", "env": "DB_NAMESPACE", "type": "string"}]}

    def compile(self, tasks, **extra):
        source = self.root / "tasks.json"
        source.write_text(json.dumps({"tasks": tasks, **extra}))
        return config.compile_config(source, self.tasks, self.root / "compiled", LIB)


class ConfigTests(Fixture):
    def test_enabling_yaml_preserves_script_and_adds_optional_name(self):
        path = self.compile({"restart": self.task(enabled=True, name="internal-restart")},
                            defaults={"queue": "mariadb", "max_retry": 0})
        document = json.loads(path.read_text())
        task = document["tasks"]["restart"]
        self.assertNotIn("job_report", task)
        self.assertEqual(document["defaults"], {"queue": "mariadb", "max_retry": 0})
        self.assertEqual(task["input"][-1], {"name": "job_name", "env": "JOB_REPORT_NAME",
                                           "type": "string", "required": False})
        settings = json.loads(next(p for p in path.parent.glob("*.json") if p != path).read_text())
        self.assertEqual(settings["script"], str(self.script.resolve()))
        self.assertEqual(settings["name"], "internal-restart")
        self.assertTrue(Path(task["script"]).stat().st_mode & 0o100)

    def test_no_metadata_keeps_original_config_path(self):
        source = self.root / "tasks.json"
        source.write_text(json.dumps({"tasks": {"status": {"script": "operation.sh"}}}))
        self.assertEqual(config.compile_config(source, self.tasks, self.root / "out", LIB), source.absolute())

    def test_disabled_still_wraps_to_disable_legacy_reporting_without_new_input(self):
        path = self.compile({"restart": self.task(enabled=False)})
        task = json.loads(path.read_text())["tasks"]["restart"]
        self.assertNotEqual(task["script"], "operation.sh")
        self.assertEqual(len(task["input"]), 1)

    def test_includes_and_slash_names_preserve_queue_and_make_distinct_launchers(self):
        (self.root / "included.json").write_text(json.dumps({"tasks": {
            "blue-green/status": self.task(enabled=True), "blue-green-status": self.task(enabled=True)}}))
        path = self.compile({}, include=["included.json"])
        scripts = [t["script"] for t in json.loads(path.read_text())["tasks"].values()]
        self.assertEqual(len(set(scripts)), 2)
        with self.assertRaises(ValueError):
            self.compile({"blue-green/status": self.task(enabled=True)}, include=["included.json"])

    def test_bad_metadata_and_traversal_are_rejected(self):
        for options in [{"enabled": "true"}, {"enabled": True, "database": "private"},
                        {"enabled": True, "when": {"unknown": "x"}},
                        {"enabled": True, "timeout": "0s"}]:
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.compile({"restart": self.task(**options)})
        task = self.task(enabled=True)
        task["script"] = "../not-a-task.sh"
        with self.assertRaises(ValueError):
            self.compile({"restart": task})
        with self.assertRaises(ValueError):
            self.compile({}, include=["../outside.json"])

    def test_symlink_main_resolves_includes_in_configured_directory(self):
        physical = self.root / "physical"
        physical.mkdir()
        target = physical / "main.json"
        target.write_text(json.dumps({"include": ["included.json"]}))
        main = self.root / "main.json"
        main.symlink_to(target)
        (self.root / "included.json").write_text(json.dumps({"tasks": {"restart": self.task(enabled=True)}}))
        compiled = config.compile_config(main, self.tasks, self.root / "out", LIB)
        self.assertIn("restart", json.loads(compiled.read_text())["tasks"])

    def test_conflicting_name_mapping_is_rejected(self):
        task = self.task(enabled=True)
        task["input"].append({"name": "job_name", "env": "OTHER", "type": "string"})
        with self.assertRaises(ValueError):
            self.compile({"restart": task})

    def test_yaml_merge_overrides_and_string_tokens_keep_aqsh_semantics(self):
        source = self.root / "anchored.yaml"
        source.write_text('''report: &report
  enabled: true
  name: default-name
tasks:
  on:
    script: operation.sh
    job_report:
      <<: *report
      name: custom-name
    input:
      - name: mode
        env: MODE
        type: string
        enum: [ON, OFF]
''')
        path = config.compile_config(source, self.tasks, self.root / "out", LIB)
        task = json.loads(path.read_text())["tasks"]["on"]
        self.assertEqual(task["input"][0]["enum"], ["ON", "OFF"])
        settings = json.loads(next(p for p in path.parent.glob('*.json') if p != path).read_text())
        self.assertEqual(settings['name'], 'custom-name')
        source.write_text('tasks:\n  status: {}\n  status: {}\n')
        with self.assertRaises(ValueError):
            config.read_document(source)

    def test_repository_yaml_compiles_and_keeps_existing_runtime_contract(self):
        path = config.compile_config(ROOT / "aqsh-tasks/task-mariadb.yaml",
                                     ROOT / "aqsh-tasks/scripts", self.root / "out", LIB)
        tasks = json.loads(path.read_text())["tasks"]
        inputs = [i["name"] for i in tasks["set-runtime-param"]["input"]]
        self.assertEqual(inputs, ["namespace", "param", "value", "scope", "mdb",
                                  "dry_run", "confirm", "job_name"])
        self.assertEqual(tasks["backup"]["input"], [{"name": "namespace", "env": "DB_NAMESPACE",
                          "required": True, "type": "string", "pattern": "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"}])
        mongo = ROOT / "aqsh-tasks/task-mongodb.yaml"
        self.assertEqual(config.compile_config(mongo, ROOT / "aqsh-tasks/scripts", self.root / "mongo", LIB), mongo)

    def test_entrypoint_preserves_aqsh_arguments_and_debug_coverage(self):
        source = self.root / "startup.json"
        source.write_text(json.dumps({"tasks": {"restart": self.task(enabled=True)}}))
        binary = self.tasks / "aqsh"
        binary.write_text('''#!/usr/bin/env python3
import json,os,sys
print(json.dumps({'config':json.load(open(os.environ['AQSH_TASKS_CONFIG'])),
                  'args':sys.argv[1:],'coverage':os.environ.get('GOCOVERDIR')}))
''')
        binary.chmod(0o755)
        result = subprocess.run(['bash', str(ROOT / 'aqsh-tasks/scripts/aqsh-entrypoint.sh'), '--version'],
                                env={**os.environ, 'PATH':str(self.tasks)+os.pathsep+os.environ['PATH'],
                                     'AQSH_TASKS_CONFIG':str(source), 'AQSH_TASKS_DIR':str(self.tasks),
                                     'AQSH_LIB_DIR':str(LIB), 'AQSH_DEBUG':'true', 'TMPDIR':str(self.root)},
                                capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        self.assertEqual(data['args'], ['--version'])
        self.assertEqual(data['coverage'], '/coverage')
        self.assertNotIn('job_report', data['config']['tasks']['restart'])


class RunnerTests(Fixture):
    def setUp(self):
        super().setUp()
        self.helpers = self.root / "lib"
        self.helpers.mkdir()
        self.report = self.helpers / "job-report-task.sh"
        self.report.write_text('''#!/usr/bin/env bash
set -eu
[[ -f "$TEST_DONE" ]]
[[ ! -e "$TEST_PUBLIC_RESULT" ]]
[[ ! -s "$TEST_PUBLIC_STDOUT" ]]
printf '%s\\n%s\\n%s\\n' "$1" "$2" "$JOB_REPORT_NAME" > "$TEST_REPORT"
if [[ "${TEST_HANG:-}" == true ]]; then
  (trap '' TERM; echo "$BASHPID" > "$TEST_ORPHAN"; while true; do sleep 1; done) &
  sleep 30
fi
exit "${TEST_REPORT_CODE:-0}"
''')
        self.script.write_text('''#!/usr/bin/env bash
set -eu
[[ "$JOB_REPORT_WRAPPED" == true ]]
trap 'printf cleaned > "$TEST_CLEANUP"' EXIT
printf '%s' "$TEST_RESULT" > "$AQSH_RESULT_FILE"
printf 'original stdout\\n'
touch "$TEST_DONE"
exit "$TEST_CODE"
''')
        self.env = {**os.environ, "AQSH_RESULT_FILE": str(self.root / "public-result"),
                    "TEST_PUBLIC_RESULT": str(self.root / "public-result"),
                    "TEST_PUBLIC_STDOUT": str(self.root / "public-stdout"),
                    "TEST_DONE": str(self.root / "done"), "TEST_REPORT": str(self.root / "report"),
                    "TEST_CLEANUP": str(self.root / "cleanup"), "TEST_ORPHAN": str(self.root / "orphan"),
                    "TEST_RESULT": '{ "status": "CHANGED", "summary": "done" }\n', "TEST_CODE": "0"}
        self.options = {"enabled": True, "name": "restart", "timeout": 2,
                        "when": {}, "dry_run_env": "DRY_RUN", "script": str(self.script),
                        "lib_dir": str(self.helpers)}

    def execute(self, **env):
        settings = self.root / "settings.json"
        settings.write_text(json.dumps(self.options))
        with (self.root / "public-stdout").open("wb") as out:
            result = subprocess.run([sys.executable, str(LIB / "job-report-runner.py"), str(settings)],
                                    env={**self.env, **env}, stdout=out, stderr=subprocess.PIPE, timeout=10)
        self.assertEqual((self.root / "public-result").read_text(), env.get("TEST_RESULT", self.env["TEST_RESULT"]))
        self.assertEqual((self.root / "public-stdout").read_text(), "original stdout\n")
        self.assertEqual((self.root / "cleanup").read_text(), "cleaned")
        return result

    def test_success_runs_once_after_operation_before_both_results(self):
        result = self.execute(JOB_REPORT_NAME="incident-custom")
        self.assertEqual(result.returncode, 0)
        self.assertEqual((self.root / "report").read_text(), "success\ndone\nincident-custom\n")

    def test_yaml_name_is_fallback_for_empty_input(self):
        self.execute(JOB_REPORT_NAME="")
        self.assertEqual((self.root / "report").read_text().splitlines()[-1], "restart")

    def test_blocked_partial_missing_and_error_results_are_not_success(self):
        for payload, code in [('{"status":"BLOCKED"}', "0"),
                              ('{"status":"success","data":{"state":"FAILED"}}', "0"),
                              ('{"status":"ERROR","partial":true}', "1"),
                              ('not json', "7")]:
            with self.subTest(payload=payload):
                (self.root / "public-result").unlink(missing_ok=True)
                result = self.execute(TEST_RESULT=payload, TEST_CODE=code)
                self.assertEqual(result.returncode, int(code))
                self.assertEqual((self.root / "report").read_text().splitlines()[0], "failure")

    def test_dry_runs_filters_and_disabled_metadata_do_not_report(self):
        for options, env in [(self.options, {"DRY_RUN": "true"}),
                             ({**self.options, "enabled": False}, {}),
                             ({**self.options, "when": {"RUNTIME_PARAM": "max_connections"}},
                              {"RUNTIME_PARAM": "slow_query_log"}),
                             (self.options, {"TEST_RESULT": '{"status":"success","data":{"dryRun":true}}'})]:
            self.options = options
            (self.root / "public-result").unlink(missing_ok=True)
            self.assertEqual(self.execute(**env).returncode, 0)
            self.assertFalse((self.root / "report").exists())

    def test_report_error_preserves_result_and_exit_status(self):
        result = self.execute(TEST_REPORT_CODE="1", TEST_CODE="7")
        self.assertEqual(result.returncode, 7)
        self.assertIn(b"task result is unchanged", result.stderr)

    def test_total_timeout_kills_report_descendants_and_preserves_success(self):
        self.options["timeout"] = .7
        start = time.monotonic()
        result = self.execute(TEST_HANG="true")
        self.assertEqual(result.returncode, 0)
        self.assertLess(time.monotonic() - start, 5)
        self.assertIn(b"task result is unchanged", result.stderr)
        pid = int((self.root / "orphan").read_text())
        # A Linux zombie is dead even though kill(pid, 0) succeeds until reaped.
        proc = Path(f"/proc/{pid}/stat")
        if proc.exists():
            self.assertEqual(proc.read_text().split()[2], "Z")
        else:
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_termination_stops_task_group_without_publishing_success(self):
        self.script.write_text('''#!/usr/bin/env bash
trap '' TERM
printf '%s' "$BASHPID" > "$TEST_DONE"
while true; do sleep 1; done
''')
        settings = self.root / "settings.json"
        settings.write_text(json.dumps(self.options))
        process = subprocess.Popen([sys.executable, str(LIB / 'job-report-runner.py'), str(settings)],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not (self.root / 'done').exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue((self.root / 'done').exists())
            pid = int((self.root / 'done').read_text())
            process.send_signal(signal.SIGTERM)
            output, _ = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143)
            self.assertEqual(output, b'')
            self.assertFalse((self.root / 'public-result').exists())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        finally:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=5)

    @unittest.skipUnless(sys.platform == 'linux', 'Linux aqsh executor lifetime contract')
    def test_linux_executor_kill_stops_original_task(self):
        self.script.write_text('''#!/usr/bin/env bash
printf '%s' "$BASHPID" > "$TEST_DONE"
while true; do printf x >> "$TEST_CLEANUP"; sleep .05; done
''')
        settings = self.root / "settings.json"
        settings.write_text(json.dumps(self.options))
        process = subprocess.Popen([sys.executable, str(LIB / 'job-report-runner.py'), str(settings)],
                                   env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pid = None
        try:
            deadline = time.monotonic() + 5
            while not (self.root / 'done').exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue((self.root / 'done').exists())
            pid = int((self.root / 'done').read_text())
            process.kill()  # Same mechanism as Go exec.CommandContext timeout.
            process.wait(timeout=5)
            time.sleep(.2)
            before = (self.root / 'cleanup').read_bytes()
            time.sleep(.2)
            self.assertEqual((self.root / 'cleanup').read_bytes(), before)
            proc = Path(f'/proc/{pid}/stat')
            if proc.exists():
                self.assertEqual(proc.read_text().split()[2], 'Z')
            self.assertFalse((self.root / 'public-result').exists())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            if pid is not None:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


class DestinationFixture(Fixture):
    def setUp(self):
        super().setUp()
        mock = self.tasks / "kubectl"
        mock.write_text('''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]; text=' '.join(args)
if '-e' in args:
 q=args[args.index('-e')+1]
 with open(os.environ['TEST_SQL'],'a') as out: out.write(json.dumps({'query':q,'pod':args[args.index('exec')+1], 'public':os.path.exists(os.environ.get('TEST_PUBLIC_RESULT','/no-result'))})+'\\n')
 if 'information_schema.COLUMNS' in q: print('80 80 255 16')
 elif 'INSERT INTO' in q: print('2026-01-02 03:04:05')
 elif 'SYSTEM_VARIABLES' in q: print('NO')
 elif q.startswith('SET GLOBAL'): print('')
 elif q.startswith('SELECT @@GLOBAL.'): print('500')
 else: print('1')
elif 'printenv' in args: print('testpass')
elif '.spec.replicas' in text: print(os.environ.get('TEST_REPLICAS','2'))
elif 'get pods' in text:
 print(json.dumps({'items':[{'metadata':{'name':'mariadb-'+str(i),'ownerReferences':[{'kind':'StatefulSet','name':'mariadb'}]}} for i in range(int(os.environ.get('TEST_REPLICAS','2')))]}))
elif 'currentPrimary' in text: print(os.environ.get('TEST_PRIMARY','mariadb-1'))
else: sys.exit(1)
''')
        mock.chmod(0o755)
        self.env = {**os.environ, "PATH": str(self.tasks) + os.pathsep + os.environ["PATH"],
                    "LIB_DIR": str(LIB), "JOB_REPORT_CONFIG_FILE": str(self.root / "absent.env"),
                    "JOB_REPORT_DATABASE": "operations", "JOB_REPORT_TABLE": "executions",
                    "DB_NAMESPACE": "mariadb-1", "MARIADB_NAME": "mariadb", "JOB_REPORT_NAME": "backup",
                    "K8S_CONTEXT": "kind-cluster-a", "TEST_SQL": str(self.root / "sql")}

    def execute(self, **env):
        return subprocess.run(['bash', str(LIB / 'job-report-task.sh'), 'success', 'done'],
                              env={**self.env, **env}, capture_output=True, timeout=10)


class DestinationTests(DestinationFixture):
    def test_shared_resolution_writes_on_actual_primary(self):
        self.assertEqual(self.execute().returncode, 0)
        rows = [json.loads(s) for s in (self.root / "sql").read_text().splitlines()]
        self.assertEqual(len(rows), 3)
        self.assertTrue(all(row["pod"] == "mariadb-1" for row in rows))
        self.assertIn("status='Finish',flag=1", rows[-1]["query"])

    def test_unknown_multi_member_primary_skips_without_guessing(self):
        result = self.execute(TEST_PRIMARY="")
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"job-report:", result.stderr)
        self.assertFalse((self.root / "sql").exists())

    def test_single_member_fallback_and_unconfigured_destination(self):
        self.assertEqual(self.execute(TEST_PRIMARY="", TEST_REPLICAS="1").returncode, 0)
        self.assertIn('mariadb-0', (self.root / "sql").read_text())
        (self.root / "sql").unlink()
        self.assertEqual(self.execute(JOB_REPORT_DATABASE="", JOB_REPORT_TABLE="").returncode, 0)
        self.assertFalse((self.root / "sql").exists())


class IntegrationTests(DestinationFixture):
    def run_runtime(self, enabled=True, **env):
        document = config.load_config((ROOT / 'aqsh-tasks/task-mariadb.yaml').resolve())
        task = document['tasks']['set-runtime-param']
        task['job_report']['enabled'] = enabled
        task['script'] = str(ROOT / 'aqsh-tasks/scripts/mariadb/set-runtime-param.sh')
        source = self.root / 'runtime.json'
        source.write_text(json.dumps({'tasks':{'set-runtime-param':task}}))
        compiled = config.compile_config(source, ROOT / 'aqsh-tasks/scripts', self.root / 'out', LIB)
        launcher = json.loads(compiled.read_text())['tasks']['set-runtime-param']['script']
        public = self.root / 'public-result'
        with (self.root / 'stdout').open('wb') as stdout:
            result = subprocess.run([launcher], env={**self.env, 'AQSH_RESULT_FILE':str(public),
                            'TEST_PUBLIC_RESULT':str(public), 'DRY_RUN':'false', 'CONFIRM':'true',
                            'RUNTIME_PARAM':'max_connections', 'RUNTIME_VALUE':'500', **env},
                            stdout=stdout, stderr=subprocess.PIPE, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(public.read_text())['reason_code'], 'SRP_APPLIED')
        return [json.loads(s) for s in (self.root / 'sql').read_text().splitlines()]

    def test_compiled_runtime_reports_exactly_once_after_mutation_before_result(self):
        rows = self.run_runtime()
        self.assertEqual(sum('INSERT INTO' in row['query'] for row in rows), 1)
        self.assertEqual(sum('UPDATE' in row['query'] for row in rows), 1)
        metadata = next(i for i, row in enumerate(rows) if 'information_schema.COLUMNS' in row['query'])
        self.assertEqual(sum(row['query'].startswith('SET GLOBAL') for row in rows[:metadata]), 2)
        self.assertEqual(sum(row['query'].startswith('SELECT @@GLOBAL') for row in rows[:metadata]), 2)
        self.assertTrue(all(not row['public'] for row in rows))

    def test_disabled_yaml_does_not_fall_back_to_legacy_native_reporting(self):
        rows = self.run_runtime(enabled=False)
        self.assertFalse(any('INSERT INTO' in row['query'] for row in rows))

    def test_nonmatching_runtime_parameter_does_not_report(self):
        rows = self.run_runtime(RUNTIME_PARAM='max_statement_time')
        self.assertFalse(any('INSERT INTO' in row['query'] for row in rows))


if __name__ == "__main__":
    unittest.main()
