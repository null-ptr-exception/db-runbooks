#!/usr/bin/env python3
"""Compile deploy-time job_report metadata for the unmodified aqsh executor."""
import argparse
import copy
import glob
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import sys


def read_document(path):
    text = path.read_text()
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate YAML/JSON key in {path.name}")
            result[key] = value
        return result
    try:
        document = json.loads(text, object_pairs_hook=unique_pairs)
    except json.JSONDecodeError:
        import yaml  # Installed as python3-yaml in the runbook image.

        class Loader(yaml.SafeLoader):
            pass

        # Match YAML 1.2 / Go yaml.v3: unquoted ON/OFF and yes/no are strings.
        Loader.yaml_implicit_resolvers = {
            key: [(tag, pattern) for tag, pattern in values
                  if tag not in {"tag:yaml.org,2002:bool", "tag:yaml.org,2002:timestamp"}]
            for key, values in Loader.yaml_implicit_resolvers.items()
        }
        Loader.add_implicit_resolver("tag:yaml.org,2002:bool",
                                     re.compile(r"^(?:true|false|True|False|TRUE|FALSE)$"), list("tTfF"))

        def mapping(loader, node):
            # Explicit duplicates are errors, but normal << anchor overrides
            # retain the same semantics as aqsh's YAML loader.
            keys = set()
            for key_node, _ in node.value:
                if key_node.tag == "tag:yaml.org,2002:merge":
                    continue
                key = loader.construct_object(key_node)
                if key in keys:
                    raise ValueError(f"duplicate YAML key in {path.name}")
                keys.add(key)
            loader.flatten_mapping(node)
            result = {}
            for key_node, value_node in node.value:
                key = loader.construct_object(key_node)
                result[key] = loader.construct_object(value_node)
            return result

        Loader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
        document = yaml.load(text, Loader=Loader)
    if not isinstance(document, dict):
        raise ValueError("task configuration must be a mapping")
    return document


def load_config(path):
    document = read_document(path)
    tasks = copy.deepcopy(document.get("tasks") or {})
    if not isinstance(tasks, dict):
        raise ValueError("tasks must be a mapping")
    loaded = set()
    base = path.parent.resolve()
    for pattern in document.get("include") or []:
        if not isinstance(pattern, str) or Path(pattern).is_absolute():
            raise ValueError("include patterns must be relative")
        resolved = (path.parent / pattern).resolve()
        if not resolved.is_relative_to(base):
            raise ValueError("include escapes configuration directory")
        for match in sorted(glob.glob(str(resolved))):
            include = Path(match).resolve()
            if not include.is_relative_to(base):
                raise ValueError("include escapes configuration directory")
            if include in loaded:
                continue
            loaded.add(include)
            included = read_document(include)
            if included.get("include") or included.get("defaults"):
                raise ValueError("included files must not define include/defaults")
            for name, task in (included.get("tasks") or {}).items():
                if name in tasks:
                    raise ValueError(f"duplicate task: {name}")
                tasks[name] = task
    result = copy.deepcopy(document)
    result.pop("include", None)
    result["tasks"] = tasks
    return result


def report_options(name, task):
    options = task.pop("job_report")
    if not isinstance(options, dict) or set(options) - {"enabled", "name", "when", "timeout"}:
        raise ValueError(f"{name}: unsupported job_report configuration")
    enabled = options.get("enabled", False)
    if not isinstance(enabled, bool):
        raise ValueError(f"{name}: job_report.enabled must be a boolean")
    label = options.get("name", name)
    if not isinstance(label, str) or not label:
        raise ValueError(f"{name}: job_report.name must be a nonempty string")
    duration = str(options.get("timeout", "30s"))
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(ms|s|m)", duration)
    if not match:
        raise ValueError(f"{name}: job_report.timeout must use ms, s or m")
    timeout = float(match[1]) * {"ms": .001, "s": 1, "m": 60}[match[2]]
    if timeout <= 0 or not math.isfinite(timeout):
        raise ValueError(f"{name}: job_report.timeout must be positive")
    inputs = task.setdefault("input", [])
    fields = {item["name"]: item for item in inputs}
    when = options.get("when", {})
    if not isinstance(when, dict) or any(
        key not in fields or not isinstance(value, str) for key, value in when.items()
    ):
        raise ValueError(f"{name}: job_report.when must match declared inputs with strings")
    report_inputs = [item for item in inputs if item.get("env") == "JOB_REPORT_NAME"]
    if "job_name" in fields or report_inputs:
        if (len(report_inputs) != 1 or report_inputs[0].get("name") != "job_name"
                or report_inputs[0].get("type", "string") != "string"
                or report_inputs[0].get("required", False)):
            raise ValueError(f"{name}: job_name must be optional string mapped to JOB_REPORT_NAME")
    elif enabled:
        inputs.append({"name": "job_name", "env": "JOB_REPORT_NAME", "type": "string", "required": False})
    return {
        "enabled": enabled,
        "name": label,
        "timeout": timeout,
        "when": {fields[key]["env"]: value for key, value in when.items()},
        "dry_run_env": fields.get("dry_run", {}).get("env"),
    }


def compile_config(source, tasks_dir, output, lib_dir):
    source, tasks_dir, output, lib_dir = map(Path, (source, tasks_dir, output, lib_dir))
    # Resolve includes relative to the configured path, not the physical target
    # of a ConfigMap/symlink-mounted main file (same contract as aqsh).
    source = Path(os.path.abspath(source))
    tasks_dir, lib_dir = tasks_dir.resolve(), lib_dir.resolve()
    config = load_config(source)
    if not any("job_report" in task for task in config["tasks"].values()):
        return source
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    for name, task in config["tasks"].items():
        if "job_report" not in task:
            continue
        options = report_options(name, task)
        script = Path(task["script"])
        script = (script if script.is_absolute() else tasks_dir / script).resolve()
        if not script.is_relative_to(tasks_dir) or not script.is_file() or not os.access(script, os.X_OK):
            raise ValueError(f"{name}: reporting script must be executable within AQSH_TASKS_DIR")
        digest = hashlib.sha256(name.encode()).hexdigest()[:24]
        settings = output / f"{digest}.json"
        settings.write_text(json.dumps({**options, "script": str(script), "lib_dir": str(lib_dir)}))
        settings.chmod(0o600)
        launcher = output / f"{digest}.sh"
        command = ["python3", str(lib_dir / "job-report-runner.py"), str(settings)]
        launcher.write_text("#!/usr/bin/env bash\nexec " + shlex.join(command) + "\n")
        launcher.chmod(0o700)
        task["script"] = str(launcher)
    target = output / "tasks.json"
    target.write_text(json.dumps(config))  # JSON is valid YAML for aqsh's parser.
    target.chmod(0o600)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("tasks_dir")
    parser.add_argument("output")
    parser.add_argument("--lib-dir", default=str(Path(__file__).resolve().parent))
    args = parser.parse_args()
    try:
        print(compile_config(args.source, args.tasks_dir, args.output, args.lib_dir))
    except Exception as error:
        # Do not print input values or task payloads in startup errors.
        detail = str(error) if type(error) is ValueError else type(error).__name__
        print(f"job-report config: {detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
