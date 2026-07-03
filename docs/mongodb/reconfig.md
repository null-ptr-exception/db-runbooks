# MongoDB Reconfig Gateway (aqsh-mongodb)

Gated `rs.reconfig()` for replica-set topology changes (votes, priorities,
member add/remove), plus an independent break-glass path (`force-dr`) for
site-loss disasters. Callers never submit a raw replica-set config document
— they submit **intent ops**, and the gateway reads the live `rs.conf()`,
projects the change, risk-checks it against live cluster facts (MongoDB
health + Kubernetes topology), and executes it step by step.

Naming/credential conventions (`sts_name`, `credential_secret`, …) are
**not** task inputs — same auto-detect tier as `recovery/*` (see CLAUDE.md
"Configuration Layers").

---

## Table of Contents

1. [When To Use What (Decision Table)](#when-to-use-what-decision-table)
2. [Architecture: What Happens On This Deployment](#architecture-what-happens-on-this-deployment)
3. [How It Works](#how-it-works)
4. [API Reference](#api-reference)
5. [Intent Ops Reference](#intent-ops-reference)
6. [Check Catalogue](#check-catalogue)
7. [Usage Scenarios](#usage-scenarios)
8. [force-dr: Break-Glass DR](#force-dr-break-glass-dr)
9. [Deployment Settings (Internal Config)](#deployment-settings-internal-config)
10. [Common vs Uncommon Operations](#common-vs-uncommon-operations)
11. [RBAC Requirements](#rbac-requirements)
12. [Relationship to recovery/fix-no-primary](#relationship-to-recoveryfix-no-primary)

---

## When To Use What (Decision Table)

| Situation | Use | Do NOT use |
|---|---|---|
| Preview any topology change, "what would happen if" | `reconfig/plan` (read-only, always safe) | — |
| Change votes/priority, add/remove a member, hide a member | `reconfig/plan` → `reconfig/apply` | manual `rs.reconfig()` in mongosh |
| Big sale / holiday — no changes allowed for a while | `reconfig/freeze enabled=true` | — |
| A whole site/zone is down, **no primary can be elected** | `reconfig/force-dr` (dry_run → confirm) | `reconfig/apply` (will refuse: NO_PRIMARY) |
| No primary but **all members are reachable** (election stuck) | `recovery/fix-no-primary` (diagnose → unfreeze) | `force-dr` (will refuse: nothing unreachable) |
| A pod's data is corrupted / stuck in initial sync | `recovery/wipe` / `recovery/recover` | reconfig tasks (wrong tool) |
| Lost site has come back, members rejoined with votes:0 | `reconfig/plan` → `apply` (restore votes one by one) | `force-dr` again (never force on a healthy set) |

---

## Architecture: What Happens On This Deployment

The sandbox `mongo-1` namespace runs a 3-member RS (`mongodb-0/1/2`, member
0 has priority 2 → deterministic primary). Concretely, on this architecture:

```
Operator / test-client (cluster-b)
     │  POST /tasks/reconfig%2Fplan      {namespace, ops_json}
     ▼
aqsh (mongo-core, cluster-a)
     │ 1. auto-detect: STS name (namespace has exactly 1 STS → "mongodb"),
     │    credentials (fallback: secret "mongodb-credentials")
     │ 2. kubectl exec mongodb-N → mongosh: rs.conf() + rs.status()   (facts)
     │ 3. kubectl get pods/nodes → zone map        (fails soft: Kind has no
     │                                              zone labels → check=skip)
     │ 4. project ops onto live members → run check catalogue
     ▼
report {risk_level, checks[], diff, projected_members, plan_hash}
```

- `plan` **changes nothing**, ever. It executes only reads (`rs.conf`,
  `rs.status`, `kubectl get`).
- `apply` executes **one `rs.reconfig()` per op** on the current primary.
  On this 3-member set a votes/priority change commits in <1s per step and
  no pod restarts — `rs.reconfig` is a config change, not a rollout.
- `freeze` patches **one annotation** on the StatefulSet
  (`reconfig.db-runbooks/freeze`). Nothing restarts; it only makes
  `plan` report `change_window: block` and `apply` refuse.
- `force-dr confirm` runs `rs.reconfig({force:true})` **from the surviving
  member with the freshest oplog** and sets `reconfig.db-runbooks/dr-active`
  on the StatefulSet. On this deployment, losing 2 of 3 members leaves
  mongodb-0 as a read-only SECONDARY; force-dr strips votes from the two
  lost members (never deletes them) so mongodb-0 elects itself with 1/1
  votes and becomes writable again.
- Every `apply`/`force-dr`/`freeze` writes an audit entry (pre/post config
  snapshots, who, why) into the `mongodb-reconfig-audit` ConfigMap in the
  target namespace (ring buffer, newest 20 entries).

---

## How It Works

### Intent ops instead of raw config

The classic failure mode of manual `rs.reconfig()` is the hand-built config
document: stale `version`, dropped `settings.*` fields, `_id` collisions,
typo'd hosts. The gateway makes those unrepresentable: the caller only says
*what to change*; the server reads the live config and owns version
handling, `_id` allocation, and field preservation.

### plan_hash: stateless CAS instead of tokens

`plan` returns a `plan_hash` = hash(namespace, sts, canonical ops, live
`configVersion`, election `term`). `apply` recomputes the same hash from
the **live** world; a mismatch means the ops differ from what was planned
or someone changed the config in between → refused with `PLAN_STALE`,
re-run `plan`. There is no stored token and no TTL — the guard is
compare-and-swap on reality, which catches a config change after 30 seconds
just as reliably as after 30 minutes.

### One reconfig step per op

MongoDB 4.4+ "safe reconfig" only allows one voting change per
`rs.reconfig()` call and waits for majority commitment. `apply` doesn't ask
the operator to split the change — it always executes op-by-op, re-reading
the config and re-verifying the version before each step. If a step fails,
the response reports exactly which steps completed.

### block vs warn

- **block** findings can never be overridden — not with any flag, not by
  any role. Fix the finding or don't apply.
- **warn** findings require `override_reason` (recorded in the audit log).

---

## API Reference

All endpoints under `http://aqsh-mongodb.kind-a.test:30080/tasks/`,
task names URL-encoded (`reconfig%2Fplan`).

### `reconfig/plan` — read-only risk report

| Input | Required | Meaning / effect of changing it |
|---|---|---|
| `namespace` | yes | Which namespace's replica set to inspect. Wrong value → detection finds no/wrong STS. |
| `ops_json` | yes | JSON array of [intent ops](#intent-ops-reference). This is *the change you are proposing*; plan never executes it. |

Returns `{risk_level, checks[], diff, projected_members, current_version,
term, steps, plan_hash, health}`. Always completes (block findings are data
in the report, not a task failure); fails only when ops are malformed or
the replica set is unreadable.

### `reconfig/apply` — execute a planned change

| Input | Required | Meaning / effect of changing it |
|---|---|---|
| `namespace` | yes | Same as plan. |
| `ops_json` | yes | Must be the **same ops** you planned — any difference changes the hash → `PLAN_STALE`. |
| `plan_hash` | yes | The hash from plan's report. Proves you ran plan against the current config; guards against concurrent changes. Never construct one by hand. |
| `override_reason` | warn-level only | Free text, written to the audit log. Required when plan was `warn`; ignored when `pass`; useless when `block` (block is not overridable). |
| `requested_by` / `request_id` | no | Audit fields (free text). Set them from your ticketing system; they change nothing functionally. |

Failure codes: `PLAN_STALE`, `BLOCKED`, `OVERRIDE_REQUIRED`, `NO_PRIMARY`,
`RECONFIG_FAILED`, `PRIMARY_LOST_MID_APPLY` (each includes
`completed_steps` so you know how far it got).

### `reconfig/force-dr` — break-glass, site-loss only

| Input | Required | Meaning / effect of changing it |
|---|---|---|
| `namespace` | yes | Same as plan. |
| `incident_id` | yes | Incident reference recorded in annotations + audit. The gateway does NOT verify it against a ticketing system — that is the calling platform's job. Never invent one; if you have no incident, you have no business calling this. |
| `dry_run` | default `true` | `true`: evaluate preconditions + return the suggested config and `plan_hash`. Changes nothing. |
| `confirm` | default `false` | `true` (with `dry_run=false`): re-verify everything and execute `rs.reconfig({force:true})`. This is the point of no return. |
| `plan_hash` | confirm only | From the dry_run. If the cluster state moved between dry_run and confirm, the hash mismatches and confirm refuses. |
| `requested_by` | no | Audit field. |

### `reconfig/freeze` — change window control

| Input | Required | Meaning / effect of changing it |
|---|---|---|
| `namespace` | yes | Same as plan. |
| `enabled` | yes | `true` blocks all `apply` (block-level, non-overridable). `false` lifts it. Does NOT affect `force-dr` — a DR does not wait for a change window. |
| `reason` | when enabling | Free text shown in every blocked plan report ("frozen until after 11.11 sale"). |

---

## Intent Ops Reference

`ops_json` is a JSON array; each element is one op. `member` selectors
accept a pod name (`"mongodb-2"`), a full `host:port`, or a host without
port — the selector must match exactly one member.

| Op | Fields | What it does | Frequency |
|---|---|---|---|
| `set_priority` | `member`, `priority` (0–1000) | Changes election preference. `priority > 0` on the highest member makes it take over primary within seconds — that IS an election. `0` = never primary. | **Common** |
| `set_votes` | `member`, `votes` (0 or 1) | Grants/removes a vote. `votes:0` automatically forces `priority:0` (MongoDB requirement). This changes quorum math — always read the plan's `vote_parity` and `zone_quorum` checks. | **Common** |
| `add_member` | `host`, optional `votes`/`priority`/`hidden` | Adds a member (port defaults to `:27017`, `_id` auto-allocated). For a local host the backing pod must already exist and be Ready (block otherwise) — scale the StatefulSet first, then add. | Occasional |
| `set_hidden` | `member`, `hidden` (bool) | `true` hides a member from clients and forces `priority:0` (member keeps replicating). This is the correct first step when re-integrating a stale member. | Occasional |
| `remove_member` | `member` | Removes the member from the config entirely. **Uncommon — 不建議動**: prefer `set_votes 0` + `set_hidden true` unless the host is permanently gone; a removed member's data drifts irreversibly and re-adding later means full initial sync. | **Uncommon** |

---

## Check Catalogue

| Check id | Level | Trigger |
|---|---|---|
| `member_resolution` | block | An op references a member that doesn't exist / is ambiguous / already exists (add). |
| `projected_structure` | block | Result would have 0 voting members, >7 voting members, or no electable member (all priority 0). |
| `k8s_member_check` | block / warn | block: `add_member` host matches this StatefulSet's naming but the pod doesn't exist. warn: host not locally verifiable (cross-cluster member), or an existing member has no backing pod (drift). |
| `change_window` | block | Freeze annotation is set. |
| `dr_state` | warn | `dr-active` annotation set — you should be doing the post-DR restore flow. |
| `vote_parity` | warn | Even total votes. Note: the fix for a 2-site 3+3 is a **third-site** witness (2+2+1), not an arbiter inside one of the two existing sites. |
| `psa_arbiter` | warn | An arbiter exists (PSA rollback/write-concern hazards). |
| `member_health` | warn | Any member `health != 1` or replication lag above the deployment threshold (default 60s). Changing config on an unstable set amplifies risk. |
| `primary_impact` | warn | The change removes or de-votes/de-prioritizes the current primary → expect a stepdown. |
| `zone_quorum` / `zone_quorum_<zone>_down` | warn / skip | Per-zone loss simulation using **live** pod→node→zone mapping and only counting *healthy* surviving votes. `skip` when zone labels are absent (never guesses). `warn` when all voters share one zone, or when losing a zone leaves the survivors below majority. |

---

## Usage Scenarios

### 1. Preview only ("would this be safe?") — anytime, zero risk

```json
POST /tasks/reconfig%2Fplan
{"namespace": "mongo-1",
 "ops_json": "[{\"action\":\"set_votes\",\"member\":\"mongodb-2\",\"votes\":0}]"}
```

Read `risk_level` and `checks`. Nothing was executed; run it as often as
you like. This is also the drift detector: an empty-diff plan with warn
findings tells you the *current* topology has problems.

### 2. Routine change (e.g. shift primary preference)

1. `plan` with `[{"action":"set_priority","member":"mongodb-1","priority":3}]`
2. risk `pass` → `apply` with the returned `plan_hash`.
3. Note: raising a priority above the current primary's **causes a
   takeover election** within seconds. That is usually the intent; the
   plan's `primary_impact`/report tells you.

### 3. Change freeze during a business-critical window

`freeze enabled=true reason="..."` before the window; `apply` is
impossible (even with override) until `freeze enabled=false`. `force-dr`
still works — DR is exempt from freezes by design.

### 4. Site loss (no primary, half the members unreachable)

See [force-dr](#force-dr-break-glass-dr). Do **not** try `apply`
(it refuses with `NO_PRIMARY`) and do not hand-craft a force reconfig.

### 5. Post-DR restore (the step everyone forgets)

When the lost site returns, its members rejoin automatically as
non-voting (`votes:0, priority:0` — force-dr set that). **Do not just
flip votes back**:

1. If they were down long enough to exceed the oplog window, run
   `recovery/recover` on them first (initial sync).
2. Optionally `set_hidden true` while they catch up.
3. Watch `plan`'s `member_health` — when lag ≈ 0, restore one member at a
   time: `set_votes 1`, then `set_priority`.
4. The successful gated `apply` clears the `dr-active` annotation
   automatically — DR state ends when config management is back on the
   normal path.

---

## force-dr: Break-Glass DR

Three machine-checked preconditions, all evaluated **live** (never cached),
all must pass:

| # | Precondition | Why |
|---|---|---|
| P1 `no_primary` | No healthy PRIMARY visible anywhere in the set | If a primary exists, quorum is intact — whatever your problem is, force is the wrong tool. |
| P2 `quorum_lost` | Healthy surviving votes < majority | If the survivors can still elect, wait for the election or use `recovery/fix-no-primary`. |
| P3 `unreachable_age` | Every unreachable **voting** member unheard-of for ≥ `RECONFIG_DR_MIN_UNREACHABLE_SECONDS` (from the survivors' `rs.status().lastHeartbeatRecv` — no external monitoring needed) | Network blips must not be decapitations. |

Flow:

```
dry_run (default)        → preconditions + suggested config + plan_hash
  ↓ human reviews the suggested members (lost site → votes:0 priority:0)
confirm=true dry_run=false plan_hash=<from dry_run>
  → re-verify P1–P3, CAS on hash, rs.reconfig({force:true}) from the
    freshest-optime survivor, wait for election, set dr-active annotation,
    write audit entry
```

What force-dr will NOT do:

- It never deletes members — a lost site keeps its slots (`votes:0`).
- It never runs when a primary exists, no matter what you pass.
- It is not automated end-to-end by design: a human reviews the dry_run
  output before confirm. Keep it that way.
- Dual-person approval is not enforced here — aqsh has no 4-eyes
  primitive. Enforce it in the layer that calls this task (separate
  `allowed_groups` on this endpoint + your approval workflow).

---

## Deployment Settings (Internal Config)

Set in `/etc/aqsh/config/mongodb.env` (deploy-time ConfigMap). These are
per-deployment **policy**, deliberately not task inputs.

| Key | Default | Meaning / effect of changing it | Touch it? |
|---|---|---|---|
| `RECONFIG_DR_MIN_UNREACHABLE_SECONDS_DEFAULT` | 300 | How long a site must be silent before force-dr may fire. Lower = faster DR but network blips can qualify (this sandbox uses 45 for tests). Raise for flaky networks. | Review with on-call team; don't change casually |
| `RECONFIG_LAG_WARN_SECONDS_DEFAULT` | 60 | Replication lag above this marks a member unhealthy in `member_health` and in quorum simulation. Lower = stricter plans. | Rarely — **不建議動** unless your workload's normal lag differs |
| `RECONFIG_AUDIT_CONFIGMAP_DEFAULT` | `mongodb-reconfig-audit` | Audit ConfigMap name. Must match the RBAC `resourceNames` pin (chart value `mongodb.reconfigAuditConfigmap`) — change both together or audit writes get denied. | **不建議動** |
| `RECONFIG_AUDIT_MAX_ENTRIES_DEFAULT` | 20 | Ring buffer depth. Bigger keeps more history but a ConfigMap caps at ~1 MiB. | **不建議動** |

Annotations the gateway owns on the StatefulSet (do not set by hand;
`freeze`/`force-dr`/`apply` manage their lifecycle):
`reconfig.db-runbooks/freeze`, `…/freeze-reason`, `…/dr-active`,
`…/dr-incident`.

---

## Common vs Uncommon Operations

| Operation | Rating | Guidance |
|---|---|---|
| `plan` (any ops) | Daily driver | Run freely — read-only. |
| `apply` set_priority / set_votes | Common | The normal path for topology tuning. |
| `freeze` on/off | Common (per calendar) | Tie to your change-management calendar. |
| `apply` add_member / set_hidden | Occasional | Scaling and re-integration flows. |
| `apply` remove_member | **Uncommon — 不建議動** | Prefer votes:0 + hidden. Only remove when the host is permanently decommissioned. |
| `force-dr` dry_run | Occasional (drills) | Safe to run in game-days; changes nothing. |
| `force-dr` confirm | **Break-glass only — 不建議動** | Real incidents with an incident_id only. Every use should end in a postmortem reading the audit entry. |
| Editing `RECONFIG_*` internal config | **Uncommon — 不建議動** | Per-deployment policy; involve the on-call team (see table above). |
| Hand-editing the gateway annotations / audit ConfigMap | **Never** | You would be lying to your own safety system. |

---

## RBAC Requirements

Everything the recovery tasks already use, plus the audit ConfigMap pin
(`tests/chart/templates/mongodb-rbac.yaml`):

- `statefulsets` get/patch (pinned name) — freeze/DR annotations
- `pods` get/list, `pods/exec` create — facts via mongosh
- `nodes` get/list (cluster role) — zone labels for quorum simulation
- `configmaps` get/patch pinned to `mongodb-recovery-config` **and**
  `mongodb-reconfig-audit`; namespace-wide `create` (create can't be
  name-pinned in Kubernetes RBAC)
- `secrets` get (pinned name) — credentials

---

## Relationship to recovery/fix-no-primary

`recovery/fix-no-primary level=reconfig|force-primary` also executes forced
reconfigs, with **none** of the gates above. It predates this gateway and
targets a different failure (all members reachable but stuck SECONDARY —
E1+E5), where the unreachable-age precondition can never be satisfied. It
remains unchanged for now; treat it as the tool for *"everyone is alive but
no one is primary"*, and `force-dr` as the tool for *"a site is gone"*.
Longer term the fix-no-primary force levels should converge onto this
gateway's audit + precondition machinery.
