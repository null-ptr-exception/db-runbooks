#!/usr/bin/env python3
"""Verify direct grants without putting SHOW GRANTS credential hashes in argv."""

import json
import re
import sys


def canonical(value):
    value = " ".join(value.upper().split())
    return "BINLOG MONITOR" if value == "REPLICATION CLIENT" else value


def recreate_safe(lines):
    """Only direct grants are removed by REVOKE ALL PRIVILEGES, GRANT OPTION."""
    if not lines:
        return False
    # Ignore quoted identifiers and strings: a role name containing ON/TO must
    # not be mistaken for a direct grant. Keep PROXY distinct from privileges.
    tokens = re.compile(
        r"`(?:``|[^`])*`|'(?:''|\\.|[^'\\])*'|\"(?:\"\"|\\.|[^\"\\])*\""
        r"|\b(?:GRANT|PROXY|ON|TO)\b", re.IGNORECASE
    )
    for line in lines:
        if not re.match(r"^GRANT\s", line, re.IGNORECASE):
            return False
        keywords = [token.upper() for token in tokens.findall(line)
                    if token[0] not in "`'\""]
        if keywords[:3] != ["GRANT", "ON", "TO"]:
            return False
    return True


def matches(expected, supported, lines):
    if not lines:
        return False
    desired = {}
    for grant in expected:
        desired.setdefault(grant["scope"], set()).update(map(canonical, grant["privileges"]))
    actual = {}
    database_privileges = set()
    global_privileges = set()
    for line in supported.splitlines():
        fields = line.split("\t")
        if len(fields) < 2:
            continue
        privilege = canonical(fields[0])
        if privilege in {"USAGE", "GRANT OPTION", "PROXY"}:
            continue
        global_privileges.add(privilege)
        # SHOW PRIVILEGES' Context is descriptive, not an exhaustive list of
        # grant levels (e.g. EXECUTE says Functions,Procedures).
        if privilege in {
            "SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP",
            "REFERENCES", "INDEX", "ALTER", "CREATE TEMPORARY TABLES",
            "LOCK TABLES", "EXECUTE", "CREATE VIEW", "SHOW VIEW",
            "CREATE ROUTINE", "ALTER ROUTINE", "EVENT", "TRIGGER",
            "DELETE HISTORY", "SHOW CREATE ROUTINE",
        }:
            database_privileges.add(privilege)
    for line in lines:
        # Role grants, table grants and other unexpected forms fail verification.
        match = re.match(r"^GRANT (.*?) ON (\*\.\*|`(?:``|[^`])+`\.\*) TO ", line)
        if not match:
            return False
        clause, scope = match.groups()
        privileges = set(map(canonical, clause.split(",")))
        if privileges == {"ALL PRIVILEGES"}:
            privileges = global_privileges if scope == "*.*" else database_privileges
            if not privileges:
                return False
        else:
            privileges.discard("USAGE")
        if re.search(r"\bWITH GRANT OPTION\b", line):
            privileges = privileges | {"GRANT OPTION"}
        actual.setdefault(scope, set()).update(privileges)
    for privileges in desired.values():
        privileges.discard("USAGE")
    # Every account has implicit global USAGE; it is not an extra data grant.
    actual.setdefault("*.*", set())
    desired.setdefault("*.*", set())
    return actual == desired


if __name__ == "__main__":
    lines = sys.stdin.read().splitlines()
    if sys.argv[1:] == ["--recreate-safe"]:
        sys.exit(0 if recreate_safe(lines) else 1)
    sys.exit(0 if matches(json.loads(sys.argv[1]), sys.argv[2], lines) else 1)
