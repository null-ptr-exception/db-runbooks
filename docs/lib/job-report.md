# Optional MariaDB job reporting

`lib/job-report.sh` records task execution in an existing table on the target
MariaDB primary. The first consumer is `set-runtime-param` for
`max_connections`. No schema migration or table creation is performed.

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
| start_time | datetime | DB `NOW()` at start |
| end_time | nullable datetime | DB `NOW()` at completion |
| status | varchar (at least 6 characters) | `Start`, `Finish`, `Failed` |
| flag | int | `2`, `1`, `4`, respectively |
| host | varchar | Actual primary pod name captured at start |
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
block the task indefinitely. A timeout only means the helper stopped waiting; it
does not prove the statement did not commit on the server.

## Task integration

Source this library after `mariadb.sh`. Each task opts in explicitly; leaving out
`job_report_enable` disables reporting even when the deployment is configured.
The name argument is optional (defaults to the script filename). Tasks may expose an optional `job_name` input that overrides it; `set-runtime-param` falls back to the parameter name.

```bash
source "${LIB_DIR}/job-report.sh"
job_report_enable "example_task"
# After resolving the actual primary and root password; before doing real work:
job_report_start "$CURRENT_PRIMARY" "$ROOT_PW"
# On semantic success:
job_report_finish success "Operation completed and verified"
# Or on failure/blocked operation:
# job_report_finish failure "Operation could not be completed"
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
Once credentials are resolved, invalid values or missing confirmation can be
recorded as Failed even when the task returns exit code 0. Failures before target
or credential resolution cannot be reported. Unknown primary on a multi-pod
instance skips reporting; a single member is treated as its primary. Reporting
never changes which pods receive the original parameter operation.

## Identity and incomplete records

No ID column is required. The deployment must serialize operations in each
namespace and keep records in that target database. Completion matches the saved
`job_name + host + start_time` (case-sensitive identities) and only transitions
an unfinished `flag=2` row. Completed rows are not overwritten by a later run in
the same second. An unfinished collision in the same DB second skips the new
record with a warning instead of updating the previous attempt. This is not a
cross-process locking mechanism and does not support concurrent identical jobs.

Start and Finish use the database session's clock/timezone, not the task host.
The original primary pod remains the destination for that execution. Failover,
SIGKILL, container loss, or a lost SQL response can leave `Start` with NULL
`end_time`; this helper does not reconcile such records or retry ambiguous writes.
Inspect the original task result/logs before interpreting an unfinished record
as a failed database operation.
