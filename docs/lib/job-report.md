# Optional MariaDB job reporting

`lib/job-report.sh` records task execution in an existing table on the target
MariaDB primary. The first consumer is `set-runtime-param` for
`max_connections`. No schema migration or table creation is performed.

The runbook image also supports deploy-time `job_report` metadata in task YAML.
This lets an existing task use the common reporting wrapper without editing its
script. The destination must be a resolvable MariaDB in the request's namespace;
this is not a MongoDB reporting backend.

## Deployment

Set just these two values in the private deployment's existing
`/etc/aqsh/config/mariadb.env` ConfigMap entry:

```bash
# Illustrative names only; supply your own existing database and table.
JOB_REPORT_DATABASE=operations
JOB_REPORT_TABLE=job_history
```

Both absent means reporting is off. Partial/invalid configuration logs a warning
and skips reporting. Identifiers accept ASCII letters, digits, and underscores.
Use the existing `create-account` root credential resolution and primary SQL
execution path; no additional credential or connection inputs are required.
The config template is not baked into the image: mount the real config in the
deployment. Keep environment-specific names and credentials out of public files.

The table must have this contract (additional columns need defaults):

| Column | Type | Meaning |
|---|---|---|
| job_name | varchar | Caller-selected name |
| start_time | datetime | DB `NOW()` when the report row is created |
| end_time | nullable datetime | DB `NOW()` when the report outcome is written |
| status | varchar (at least 6 characters) | `Start`, `Finish`, `Failed` |
| flag | int | `2`, `1`, `4`, respectively |
| host | varchar | Actual primary pod resolved for the request |
| message | varchar | Result summary, initially empty |

Use the exact `status` spelling. A differently named existing column must be
aligned by the deployment owner before enabling this feature.
The helper reads varchar lengths, refuses to truncate identity fields, and
truncates messages to their column length. SQL values use hex literals, including
names and messages containing quotes, newlines, or backslashes. The session uses
strict SQL mode so incompatible schemas fail visibly rather than storing a
truncated identity or status. Query/lock waits have session limits. In addition,
job-report applies its own bounded wall-clock timeout per SQL hop (default 8s,
overridable via `JOB_REPORT_SQL_TIMEOUT`) so a hung kubectl/transport path cannot
block the task indefinitely. On timeout the helper snapshots the SQL hop's
descendant PID tree before signaling, then reaps that saved tree (TERM then KILL)
so TERM-ignoring children cannot escape by reparenting to PID 1. A timeout only
means the helper stopped waiting; it does not prove the statement did not commit
on the server.

## YAML integration

Keep the original task's `script`, inputs, authorization, queue, retry and timeout
settings, and add this block alongside them:

```yaml
tasks:
  restart:
    script: mariadb/restart.sh
    job_report:
      enabled: true
      name: mariadb-restart
      timeout: 30s
    # Keep this task's existing input/allowed_groups/timeout fields here.
```

`enabled` defaults to false. `name` defaults to the YAML task key. `timeout`
defaults to `30s` and bounds the **whole reporting phase**, including target and
credential resolution, SQL and process cleanup (allow a small cleanup overhead).
It accepts positive durations in `ms`, `s` or `m`. The original task timeout must
leave room for this phase. These fields are deployment configuration, not public
task inputs. Database/table names stay in `mariadb.env`.

An enabled task automatically gets the optional string input `job_name`, mapped
to `JOB_REPORT_NAME`. An existing compatible declaration is reused, never
duplicated. A nonempty per-call name overrides the YAML name; omitted/empty names
fall back to it. If the existing input has a nonempty `default`, aqsh supplies
that value and it takes precedence too; prefer `job_report.name` for the static
fallback and leave the input default empty. This is caller intent (e.g. different incident/change labels
within the same deployment), rather than a deployment location or credential.

Optional `when` filters match declared input names against **string** values:

```yaml
job_report:
  enabled: true
  name: max_connections
  when:
    param: max_connections
  timeout: 30s
```

This is the `set-runtime-param` configuration shipped in this image. Listing and
other parameters do not report. The wrapper also skips declared `dry_run=true`
requests and results with top-level/nested `dry_run` or `dryRun` set to true.
Rejected real requests can still report Failed, including exit-code-zero BLOCKED
results. `enabled: false` disables even this task's legacy native reporting when
invoked through the compiled wrapper.

At startup, `aqsh-entrypoint.sh` compiles `AQSH_TASKS_CONFIG` and its relative
includes into a private temporary configuration. It generates launchers for
tasks with `job_report` metadata, removes that metadata before aqsh reads it, and
keeps unrelated definitions/defaults intact. The source ConfigMap is never
rewritten. A malformed definition stops startup with an error; the compiler does
not guess a script or destination. Configuration changes require restarting the
aqsh process to compile them again.

This requires the updated **runbook image**, whose entrypoint and `python3-yaml`
dependency are included here; stock aqsh 0.5.0 alone cannot interpret the block.
If a deployment overrides the image entrypoint, explicitly run
`python3 /tasks/lib/job-report-config.py "$AQSH_TASKS_CONFIG" "$AQSH_TASKS_DIR" <private-output-dir>`
and set `AQSH_TASKS_CONFIG` to the path it prints before starting aqsh.

The wrapper runs the original executable as a child process, preserving its EXIT
cleanup and exit status. It holds stdout and `AQSH_RESULT_FILE` until the bounded
reporting attempt ends; stderr remains live. Exact result bytes and stdout are
then published unchanged, including missing or malformed results. Stdout progress
logs are consequently delayed and occupy temporary disk space during execution.

Reporting runs **after** the task and cleanup, so it never adds database reads or
writes ahead of a break-glass mutation. It resolves the current primary with the
shared MariaDB helpers; an unknown multi-member primary skips reporting rather
than selecting an arbitrary pod. Unlike the direct integration below, the YAML
wrapper resolves the reporting primary after the task, so a failover during the
task may change the reported host/destination.

Nonzero exits and explicit ERROR/FAILED/BLOCK/BLOCKED/CRITICAL/PARTIAL results
report Failed. Known success statuses (success/CHANGED/OK/READY/PASS/WARN/COMPLETED)
report Finish; WARN means the diagnostic task completed with warnings. Nested
failure state, partial results, false success or nonzero result codes override
success. Missing/unrecognized JSON does not become success solely because the
process exited zero. Reports use only the result summary/message, never the full
data object that can contain a password or secret. Resolution/write failures and
report timeouts warn and preserve the original operation result.

TERM/INT stops the task/report process group and its descendants. On Linux, a
parent-death signal also kills the child task/report leader if aqsh kills the
wrapper at its executor deadline, so the original task cannot continue its
workflow after the wrapper dies. SIGKILL or container loss can still interrupt
cleanup/reporting and leave descendant calls in flight; this is not a durable
exactly-once audit service. The serialization and incomplete-record limitations
below still apply.

## Direct script integration (legacy/custom callers)

Source this library after `mariadb.sh`. Each task opts in explicitly; leaving out
`job_report_enable` disables reporting even when the deployment is configured.
The name argument is optional (defaults to the script filename). Tasks may expose an optional `job_name` input that overrides it; `set-runtime-param` falls back to the parameter name.

```bash
source "${LIB_DIR}/job-report.sh"
job_report_enable "example_task"
# After resolving the actual primary/password and completing or rejecting work:
job_report_start "$CURRENT_PRIMARY" "$ROOT_PW"
# On semantic success:
job_report_finish success "Operation completed and verified"
# Or on failure/blocked operation:
# job_report_finish failure "Operation could not be completed"
# Emit the original task result after the bounded reporting attempts.
```

Invoke these functions in the parent shell, not command substitutions. Integrate
`job_report_exit "$?"` into the caller's EXIT trap alongside existing cleanup.
The library installs no traps. An unexpected exit after Start records Failed,
even for exit code 0: only an explicit semantic success records Finish. Repeated
finish calls do not write again, and reporting SQL output is kept out of task
JSON. SQL failures produce a generic warning without credentials or query text;
they do not change the task's original result or retry its operation.

`set-runtime-param` opts in for real `max_connections` requests (including
decreases). The recorded `job_name` is optional input `job_name` /
`JOB_REPORT_NAME`, or the parameter name when omitted. Listing, dry-run, and
other parameters do not report.
It defers both Start and Finish until the parameter operation and its read-back
attempts have completed, or the request has been rejected. No report SQL runs
before the mutation or between its per-pod apply/read-back steps. Once credentials are
resolved, invalid values or missing confirmation can be recorded as Failed even
when the task returns exit code 0. Failures before target or credential resolution
cannot be reported. Unknown primary on a multi-pod instance skips reporting; a
single member is treated as its primary. Reporting never changes which pods
receive the original parameter operation.

The bounded reporting attempts finish before either stdout JSON or
`AQSH_RESULT_FILE` is published, including when a report write fails or times out.
With the default timeout, the three SQL hops can add approximately 24 seconds
plus process cleanup overhead to the final response, after the database operation
has completed. Reporting failure still preserves the original result and exit
status. `start_time` and `end_time` cover this reporting phase, not the duration of
the parameter operation.

Direct invocations retain this behavior. Under the YAML wrapper,
`JOB_REPORT_WRAPPED=true` suppresses the script's native reporting to avoid a
second row; the common wrapper owns the reporting phase and result publication.

## Identity and incomplete records

No ID column is required. The deployment must serialize operations in each
namespace and keep records in that target database. Completion matches the saved
`job_name + host + start_time` (case-sensitive identities) and only transitions
an unfinished `flag=2` row. Completed rows are not overwritten by a later run in
the same second. An unfinished collision in the same DB second skips the new
record with a warning instead of updating the previous attempt. This is not a
cross-process locking mechanism and does not support concurrent identical jobs.

Start and Finish use the database session's clock/timezone, not the task host.
Because `set-runtime-param` reports after the outcome is known, interruption
before reporting can leave no row even if some or all parameter changes landed.
The original primary pod remains the destination for that execution. Failover,
SIGKILL, container loss, or a lost SQL response can leave `Start` with NULL
`end_time`; this helper does not reconcile such records or retry ambiguous writes.
Inspect the original task result/logs before interpreting an unfinished record
as a failed database operation.
