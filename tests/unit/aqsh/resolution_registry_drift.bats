#!/usr/bin/env bats

# Keeps docs/internal/resolution-tiers.md's per-family registry honest.
#
# CLAUDE.md's "Maintaining this file" rule says a list of "which tasks are in
# category X" is a registry, it will drift, and it belongs somewhere a test can
# check it. This is that test.
#
# The check is exact set equality with NO exemption list, deliberately: an
# allowlist is itself a registry and would drift the same way. A family that
# genuinely resolves nothing (common/hello) earns a row saying so rather than
# an entry in a skip list.

setup_file() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
  export REPO_ROOT
}

# Namespaced task families declared across both gateways, as "<family>/*".
# Task keys use two-space indentation in the AQSH config; a key containing "/"
# is a namespaced task, and its first path segment is the family.
families_from_tasks() {
  awk '/^  [A-Za-z0-9_\/-]+:$/ {
         gsub(/^  |:$/, "")
         if (index($0, "/") > 0) { split($0, a, "/"); print a[1] "/*" }
       }' \
    "${REPO_ROOT}/aqsh-tasks/tasks-mariadb.yaml" \
    "${REPO_ROOT}/aqsh-tasks/tasks-mongodb.yaml" \
    | sort -u
}

# First column of the registry table. Only rows whose first cell is a
# backticked "<family>/*" count — the prose rows ("MongoDB account tasks",
# "MariaDB object storage") describe cross-cutting resolution orders rather
# than a namespaced family, and are intentionally not part of the comparison.
families_from_registry() {
  grep -E '^\| `[A-Za-z0-9_-]+/\*` ' \
    "${REPO_ROOT}/docs/internal/resolution-tiers.md" \
    | sed 's/^| `//; s/`.*//' \
    | sort -u
}

@test "resolution-tiers registry lists exactly the namespaced task families" {
  run bash -c "$(declare -f families_from_tasks families_from_registry); \
    diff <(families_from_tasks) <(families_from_registry)"

  if [ "$status" -ne 0 ]; then
    echo "resolution-tiers.md registry is out of sync with tasks-*.yaml." >&2
    echo "  '<' = declared in tasks-*.yaml, missing a row in the registry" >&2
    echo "  '>' = has a registry row, but no such family in tasks-*.yaml" >&2
    echo "$output" >&2
  fi

  [ "$status" -eq 0 ]
}

# Guards the check itself: if either extractor silently stops matching — a
# rename, a reformat of the table, an awk change — both sides go empty and the
# diff above passes while checking nothing.
@test "both registry extractors return a non-empty set" {
  run families_from_tasks
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 0 ]

  run families_from_registry
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 0 ]
}
