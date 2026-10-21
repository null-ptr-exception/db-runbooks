# MariaDB session diagnostics and remediation

`POST /tasks/sessions` provides one fixed-action interface for one Rundeck job.
It diagnoses the exact selected pod or explicitly interrupts a selected client
statement/connection. It accepts no SQL text and installs no monitoring platform.

## Request

```json
{"namespace":"mariadb-1","target_pod":"mariadb-0","action":"diagnose"}
```

| Input | Default | Caller decision |
|---|---|---|
| `namespace` | required | MariaDB instance namespace. |
| `target_pod` | required | Exact pod to inspect/act on, including replicas. |
| `action` | `diagnose` | `diagnose`, `kill-query`, or `kill-connection`. |
| `connection_id` | empty | Positive decimal process-list ID for termination. |
| `dry_run` | `true` | Preview termination or execute it. |
| `confirm` | `false` | Explicit acknowledgement of execution. |
| `expected_session` | empty | Identity fingerprint returned by termination preview. |

The instance is discovered in the namespace (CR, or native StatefulSet fallback).
Ambiguous instances fail closed. The pod must be a live member of the discovered
StatefulSet and its database container must be running. Neither diagnosis nor
remediation silently selects a primary or another pod. Credentials and container
naming use existing deployment resolution and are not public inputs.

## Diagnosis

The default action is read-only. Result `sections` contains:

- `processlist`: non-Sleep threads ordered by command duration, excluding the
  diagnostic session. Original ID/user/host/database/command/time/state/SQL
  details remain available, plus query IDs.
- `distribution`: non-Sleep threads grouped by user/database/command/state.
- `connection_status`: server/version, global running/connected counts,
  max_connections and current row-lock waits. The diagnostic connection can
  contribute to global counts.
- `transactions`: oldest open InnoDB transactions with process-list details.
  Sleep sessions are included; transaction age differs from command age.
- `lock_waits`: current row-lock waiting/blocking transaction relationships.
  An idle blocker may have null SQL text.

Each section has `collected`, its read-start `collected_at`, `rows`, and
`truncated`. The top-level timestamp is the task collection start. Failed reads return
`rows:null`, not an empty healthy result. `findings` groups **observed** row-lock
blockers from the returned lock rows; a capped list is not an exhaustive census.
The overall result is READY, PARTIAL, or ERROR. A diagnostic result never claims
that high running-thread counts prove CPU, disk or lock contention.

Snapshots are sequential and non-atomic, including the transaction/process-list
join. A disappeared process-list row is possible. The result includes collection
time and exact pod, not a reconstruction of the original alert instant.

## Preview and execute termination

Preview using the same endpoint:

```json
{"namespace":"mariadb-1","target_pod":"mariadb-0","action":"kill-connection","connection_id":"42"}
```

The result is `SESSION_DRY_RUN_READY`, with `before` describing the current
session and a 64-character `before.fingerprint`. For execution, submit the same
target/action/ID, the fingerprint as `expected_session`, `dry_run:"false"`,
and `confirm:"true"`.
`dry_run=true,confirm=true` and `dry_run=false,confirm=false` are rejected.
Missing `expected_session` is `SESSION_EXPECTED_SESSION_REQUIRED`; malformed
values are invalid input. `SESSION_TARGET_CHANGED` means a valid fingerprint
was compared with the inspected session and no longer matched.

The task re-reads the target before execution. Its fingerprint binds the pod UID
and container restart count, selected action, server, connection/user/host, query ID/text and
transaction ID. If these changed since preview, obtain a new preview. The fingerprint
is an identity acknowledgement, not an authentication credential or permission.

Built-in root/system accounts and replication/background commands are protected.
Deployment configuration can add protected accounts. Each inspection uses a
short-lived connection; it is not a persistent session identity guard.
`kill-query` requires a running statement and issues `KILL QUERY ID`
for the inspected query ID, avoiding interruption of a later statement on the
same connection. `kill-connection` issues `KILL CONNECTION` for that connection.

There remains a narrow inspection-to-KILL race, especially for connection
termination. This is not atomic compare-and-swap. Operators still need to review
business impact; a long transaction alone is not a reason to terminate it.

KILL QUERY leaves the connection and potentially its transaction/locks active.
Connection termination rolls back ordinary open transactions; prepared XA
transactions require separate recovery and are outside this interface.

## Outcome evidence

An uncertain attempt is persisted before KILL, then acceptance is persisted
before bounded verification. An interrupted transport must not imply no change. Result states distinguish:

| State/reason | Meaning |
|---|---|
| `NO_ACTION / SESSION_NOT_FOUND` | Target absent before execution; no KILL issued. |
| `NO_ACTION / SESSION_TARGET_ALREADY_GONE` | KILL returned a definite missing-ID error and a bounded post-read confirmed the original target gone; `changed:false`, `command_accepted:false`. |
| `UNKNOWN / SESSION_KILL_ATTEMPTING` | Request attempt recorded; server acknowledgement not yet observed. |
| `ACCEPTED / SESSION_KILL_ACCEPTED` | Server accepted KILL; completion not yet established. |
| `VERIFIED / SESSION_TERMINATION_VERIFIED` | Original query absent, or connection and original InnoDB transaction absent. If the KILL reply was lost, `changed:null` and `command_accepted:null` retain uncertainty about which operation ended it. |
| `PENDING / SESSION_TERMINATION_PENDING` | KILL accepted, but termination/rollback still visible within the verification budget. |
| `UNKNOWN / SESSION_VERIFICATION_UNAVAILABLE` | A post-read failed; the result retains any known acceptance/rejection evidence. |
| `ERROR / SESSION_KILL_FAILED` | KILL failed and post-read still sees the original target. A definite missing-ID error gives `changed:false`; other failures retain `changed:null` and `command_accepted:null`. |

Verification reports remaining original transaction/waiter evidence. VERIFIED
for query termination **does not** mean transaction completion, released locks,
or recovered application health. The original transaction is tracked separately
from connection visibility. No automatic retry is configured by the task defaults.
On KILL failure, verification runs once without repeating the mutation.
Only MariaDB's [missing-ID errors](https://mariadb.com/docs/server/reference/sql-statements/administrative-sql-statements/kill)
1094 (`KILL CONNECTION`) and 1957 (`KILL QUERY ID`) establish a definite rejection;
raw client errors are captured privately and discarded. Transaction IDs are JSON
strings, including the IDs used to bind previews and verify rollback.

## Deployment and one Rundeck job

Import [the job example](../../examples/rundeck/mariadb-sessions.yaml) and deploy
[its companion API client](../../examples/rundeck/run-mariadb-sessions.sh) to
`/opt/db-runbooks/bin/run-mariadb-sessions.sh` on the executor. The client requires
Bash, curl and jq, reads `RD_OPTION_*` environment values, submits only
`/tasks/sessions`, and polls the returned execution ID. Configure `AQSH_URL` and
`AQSH_TOKEN` privately on that executor. Pin the reviewed repository version.
Adapt existing site/pod selectors to these namespace/pod inputs in deployment.
The client retries failed polling GETs within its deadline, never the submission
POST. `AQSH_POLL_TIMEOUT_SECONDS` is executor configuration (1–180, default 180).
Every exit after a submission attempt prints the execution ID when available
and guidance to inspect it before resubmitting termination. `UNKNOWN`, `PENDING`,
`ACCEPTED` and unrecognized results fail the Rundeck job; a green job requires a
completed positive result (`READY`, `PARTIAL`, `NO_ACTION`, `DRY_RUN_READY`, `VERIFIED`).

Use one invocation for diagnosis, another with a termination action for preview,
and another to apply. All remain the same Rundeck job. The UI has fixed actions,
not a free-form SQL field. Restrict both run and output access to operators who
may terminate sessions: action options and preview fingerprints are not an ACL boundary.
The example task permits only `system:serviceaccounts:db-ops`, the sandbox
control-plane namespace. Deployments must set their actual operator group and
restrict Kubernetes exec access to the same audience.
Do not expose this combined endpoint to read-only users.

The executor API token stays in deployment configuration. Raw SQL and client
hosts can contain private application data; keep task/Rundeck outputs within
the authorized operational audience, outside public source/examples.

Deployment policy in `mariadb.env` controls row limit (100, max 1000), SQL text
limit (4096, max 65536), read statement timeout (5 seconds, max 10), verification
attempts (3, max 5, one second apart), and additional protected users. Each list
fetches one extra row to detect truncation. A row cap bounds returned data;
it does not eliminate scanning/sorting cost. No Performance Schema/sys schema
installation is required. SQL/timeouts must be validated against deployment's
MariaDB version and PROCESS/administration privileges.

## Validation

Focused unit tests: `bats tests/unit/mariadb/sessions.bats`.
API-client tests: `bats tests/unit/mariadb/sessions-rundeck.bats`.
Real operator/API tests: `bats tests/mariadb/sessions.bats` (requires the normal
MariaDB suite infrastructure). The integration file covers real competing
transactions, blocking/idle sessions, query interruption, connection rollback
and refused mutation. Run it only in an explicitly authorized sandbox.
