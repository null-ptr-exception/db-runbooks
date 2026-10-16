#!/usr/bin/env bash
# Fixed read queries for mariadb/sessions.sh. Numeric policy and connection
# values are validated by the caller before interpolation; no SQL is an input.

sessions_query() {
  local section="$1" cap=$((SESSION_ROW_LIMIT + 1)) n="$SESSION_SQL_LIMIT"
  case "$section" in
    processlist)
      cat <<SQL
SELECT /* sessions:processlist */ JSON_OBJECT(
 'connection_id', CAST(ID AS CHAR), 'query_id', CAST(QUERY_ID AS CHAR),
 'user', USER, 'host', HOST, 'database', DB, 'command', COMMAND,
 'command_seconds', TIME, 'state', STATE, 'sql', LEFT(INFO, $n),
 'sql_truncated', COALESCE(CHAR_LENGTH(INFO) > $n, 0))
FROM information_schema.PROCESSLIST
WHERE COMMAND <> 'Sleep' AND ID <> CONNECTION_ID()
ORDER BY TIME DESC, ID LIMIT $cap;
SQL
      ;;
    distribution)
      cat <<SQL
SELECT /* sessions:distribution */ JSON_OBJECT(
 'user', USER, 'database', DB, 'command', COMMAND, 'state', STATE,
 'thread_count', COUNT(*), 'longest_command_seconds', MAX(TIME))
FROM information_schema.PROCESSLIST
WHERE COMMAND <> 'Sleep' AND ID <> CONNECTION_ID()
GROUP BY USER, DB, COMMAND, STATE
ORDER BY COUNT(*) DESC, MAX(TIME) DESC LIMIT $cap;
SQL
      ;;
    connection_status)
      cat <<'SQL'
SELECT /* sessions:connection_status */ JSON_OBJECT(
 'server', @@hostname, 'version', VERSION(),
 'max_connections', @@GLOBAL.max_connections,
 'threads_running', (SELECT CAST(VARIABLE_VALUE AS UNSIGNED)
   FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='THREADS_RUNNING'),
 'threads_connected', (SELECT CAST(VARIABLE_VALUE AS UNSIGNED)
   FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='THREADS_CONNECTED'),
 'row_lock_current_waits', (SELECT CAST(VARIABLE_VALUE AS UNSIGNED)
   FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='INNODB_ROW_LOCK_CURRENT_WAITS'));
SQL
      ;;
    transactions)
      cat <<SQL
SELECT /* sessions:transactions */ JSON_OBJECT(
 'transaction_id', CAST(t.TRX_ID AS CHAR), 'connection_id', CAST(t.TRX_MYSQL_THREAD_ID AS CHAR),
 'user', p.USER, 'host', p.HOST, 'database', p.DB, 'command', p.COMMAND,
 'state', t.TRX_STATE, 'started_at', t.TRX_STARTED,
 'transaction_seconds', TIMESTAMPDIFF(SECOND, t.TRX_STARTED, NOW()),
 'rows_locked', t.TRX_ROWS_LOCKED, 'rows_modified', t.TRX_ROWS_MODIFIED,
 'sql', LEFT(t.TRX_QUERY, $n),
 'sql_truncated', COALESCE(CHAR_LENGTH(t.TRX_QUERY) > $n, 0))
FROM information_schema.INNODB_TRX t
LEFT JOIN information_schema.PROCESSLIST p ON p.ID=t.TRX_MYSQL_THREAD_ID
ORDER BY t.TRX_STARTED, t.TRX_ID LIMIT $cap;
SQL
      ;;
    lock_waits)
      cat <<SQL
SELECT /* sessions:lock_waits */ JSON_OBJECT(
 'waiting_connection_id', CAST(r.TRX_MYSQL_THREAD_ID AS CHAR),
 'waiting_transaction_id', CAST(r.TRX_ID AS CHAR),
 'wait_seconds', TIMESTAMPDIFF(SECOND, r.TRX_WAIT_STARTED, NOW()),
 'waiting_sql', LEFT(r.TRX_QUERY, $n),
 'waiting_sql_truncated', COALESCE(CHAR_LENGTH(r.TRX_QUERY) > $n, 0),
 'blocking_connection_id', CAST(b.TRX_MYSQL_THREAD_ID AS CHAR),
 'blocking_transaction_id', CAST(b.TRX_ID AS CHAR),
 'blocking_transaction_seconds', TIMESTAMPDIFF(SECOND, b.TRX_STARTED, NOW()),
 'blocking_sql', LEFT(b.TRX_QUERY, $n),
 'blocking_sql_truncated', COALESCE(CHAR_LENGTH(b.TRX_QUERY) > $n, 0))
FROM information_schema.INNODB_LOCK_WAITS w
JOIN information_schema.INNODB_TRX r ON r.TRX_ID=w.REQUESTING_TRX_ID
JOIN information_schema.INNODB_TRX b ON b.TRX_ID=w.BLOCKING_TRX_ID
ORDER BY r.TRX_WAIT_STARTED, r.TRX_ID LIMIT $cap;
SQL
      ;;
    inspect)
      cat <<SQL
SELECT /* sessions:inspect */ JSON_OBJECT(
 'connection_id', CAST(p.ID AS CHAR), 'query_id', CAST(p.QUERY_ID AS CHAR),
 'user', p.USER, 'host', p.HOST, 'database', p.DB, 'command', p.COMMAND,
 'command_seconds', p.TIME, 'state', p.STATE, 'sql', LEFT(p.INFO, $n),
 'sql_truncated', COALESCE(CHAR_LENGTH(p.INFO) > $n, 0),
 'transaction_id', CAST(t.TRX_ID AS CHAR), 'rows_modified', t.TRX_ROWS_MODIFIED,
 'fingerprint', SHA2(CONCAT('$POD_EPOCH:$ACTION', JSON_OBJECT(
   'server', @@hostname, 'connection_id', p.ID, 'user', p.USER,
   'host', p.HOST, 'query_id', p.QUERY_ID, 'sql', p.INFO,
   'transaction_id', CAST(t.TRX_ID AS CHAR))), 256))
FROM information_schema.PROCESSLIST p
LEFT JOIN information_schema.INNODB_TRX t ON t.TRX_MYSQL_THREAD_ID=p.ID
WHERE p.ID=$CONNECTION_ID;
SQL
      ;;
    verify)
      cat <<SQL
SELECT /* sessions:verify */ JSON_OBJECT(
 'connection_present', CAST(EXISTS(SELECT 1 FROM information_schema.PROCESSLIST
   WHERE ID=$CONNECTION_ID) AS UNSIGNED),
 'original_query_present', CAST(EXISTS(SELECT 1 FROM information_schema.PROCESSLIST
   WHERE ID=$CONNECTION_ID AND QUERY_ID=$ORIGINAL_QUERY_ID
     AND COMMAND IN ('Query','Execute') AND INFO IS NOT NULL) AS UNSIGNED),
 'original_transaction_present', CAST(EXISTS(SELECT 1 FROM information_schema.INNODB_TRX
   WHERE TRX_ID='$ORIGINAL_TRX_ID') AS UNSIGNED),
 'original_transaction_waiters', (SELECT COUNT(*)
   FROM information_schema.INNODB_LOCK_WAITS WHERE BLOCKING_TRX_ID='$ORIGINAL_TRX_ID'));
SQL
      ;;
    *) return 1 ;;
  esac
}
