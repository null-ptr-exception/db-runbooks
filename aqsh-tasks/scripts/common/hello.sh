#!/bin/bash
set -e
echo "Hello, $NAME!"
echo "Task ID: $AQSH_TASK_ID"
echo "Current time: $(date)"
sleep 2
echo "Done!"
jq -n \
  --arg greeted "$NAME" \
  --arg timestamp "$(date -Iseconds)" \
  '{greeted: $greeted, timestamp: $timestamp}' > "$AQSH_RESULT_FILE"
