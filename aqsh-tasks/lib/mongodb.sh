#!/usr/bin/env bash
# =============================================================================
# scripts/lib/mongodb.sh
# MongoDB helper functions using mongosh.
#
# ── Connection modes ──────────────────────────────────────────────────────────
#
# MODE 1 – URI  (default)
#   Set MONGO_URI to a full connection string.
#   Special characters in the password MUST be percent-encoded manually, OR
#   use mongo_build_uri to let the library encode them for you.
#
#     MONGO_URI="mongodb://localhost:27017"
#     MONGO_URI=$(mongo_build_uri "host" 27017 "alice" 'p@ss#w0rd!')
#
# MODE 2 – Split credentials  (avoids URI-encoding completely)
#   When MONGO_HOST is non-empty the library uses --host/--port/--username/
#   --password flags so no percent-encoding of the password is needed.
#
#     MONGO_HOST="10.0.0.5"
#     MONGO_PORT=27017
#     MONGO_USER="alice"
#     MONGO_PASS='p@ss#w0rd!'   # ← special chars are fine here
#     MONGO_AUTHDB="admin"      # authentication database (default: admin)
#
# Common settings (apply to both modes):
#   MONGO_TLS=""            # "--tls" if TLS is required, else empty
#   MONGO_EXTRA_ARGS=""     # any additional mongosh flags
#   MONGO_TIMEOUT=10000     # server selection timeout in ms (default 10s)
#
# Every public function prints a JSON string (via response_ok / response_err).
# =============================================================================

[[ -n "${_MONGODB_LIB_LOADED:-}" ]] && return 0
_MONGODB_LIB_LOADED=1

# ── Mode 1: URI settings ─────────────────────────────────────────────────────
MONGO_URI="${MONGO_URI:-mongodb://localhost:27017}"

# ── Mode 2: Split-credential settings ────────────────────────────────────────
# When MONGO_HOST is set these take priority over MONGO_URI.
MONGO_HOST="${MONGO_HOST:-}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_USER="${MONGO_USER:-}"
MONGO_PASS="${MONGO_PASS:-}"
MONGO_AUTHDB="${MONGO_AUTHDB:-admin}"

# ── Common settings ───────────────────────────────────────────────────────────
MONGO_TLS="${MONGO_TLS:-}"
MONGO_EXTRA_ARGS="${MONGO_EXTRA_ARGS:-}"
MONGO_TIMEOUT="${MONGO_TIMEOUT:-10000}"

# ---------------------------------------------------------------------------
# _mongo_uri_percent_encode <string>
# Percent-encode a string so it is safe to embed in a MongoDB URI component
# (username, password, or database name).
# Encodes all chars except unreserved: A-Z a-z 0-9 - _ . ~
# ---------------------------------------------------------------------------
_mongo_uri_percent_encode() {
  local string="$1"
  local encoded=""
  local i char hex
  for (( i=0; i<${#string}; i++ )); do
    char="${string:$i:1}"
    case "$char" in
      [A-Za-z0-9\-_.~]) encoded+="$char" ;;
      *)
        # printf %02X gives uppercase hex; URI spec is case-insensitive
        printf -v hex '%02X' "'$char"
        encoded+="%${hex}"
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# ---------------------------------------------------------------------------
# mongo_build_uri <host> <port> [username] [password] [authdb]
# Build a properly percent-encoded MongoDB URI.
# Useful when the password contains special characters like @ # ! / ? % etc.
# The result is stored in MONGO_URI and also printed to stdout.
#
# Example:
#   MONGO_URI=$(mongo_build_uri "10.0.0.5" 27017 "alice" 'p@ss#w0rd!')
# ---------------------------------------------------------------------------
mongo_build_uri() {
  local host="${1:?host is required}"
  local port="${2:-27017}"
  local username="${3:-}"
  local password="${4:-}"
  local authdb="${5:-}"

  local uri="mongodb://"
  if [[ -n "$username" ]]; then
    local enc_user enc_pass
    enc_user=$(_mongo_uri_percent_encode "$username")
    enc_pass=$(_mongo_uri_percent_encode "$password")
    uri+="${enc_user}:${enc_pass}@"
  fi
  uri+="${host}:${port}"
  if [[ -n "$authdb" ]]; then
    uri+="/${authdb}"
  fi

  MONGO_URI="$uri"
  printf '%s' "$uri"
}

# ---------------------------------------------------------------------------
# _mongosh_eval <database> <js_expression>
# Run a JavaScript expression against a database and capture the output.
#
# Connection dispatch:
#   • MONGO_HOST is set → split-credential mode (no URI encoding needed)
#   • Otherwise         → URI mode (MONGO_URI must be properly encoded)
# ---------------------------------------------------------------------------
_mongosh_eval() {
  local database="$1"
  local js="$2"

  local -a conn_args=()

  if [[ -n "$MONGO_HOST" ]]; then
    # ── Split-credential mode — build URI so we can add query params ──────
    local enc_user enc_pass uri
    enc_user=$(_mongo_uri_percent_encode "${MONGO_USER:-}")
    enc_pass=$(_mongo_uri_percent_encode "${MONGO_PASS:-}")
    if [[ -n "$MONGO_USER" ]]; then
      uri="mongodb://${enc_user}:${enc_pass}@${MONGO_HOST}:${MONGO_PORT}/${database}?authSource=${MONGO_AUTHDB:-admin}&serverSelectionTimeoutMS=${MONGO_TIMEOUT}"
    else
      uri="mongodb://${MONGO_HOST}:${MONGO_PORT}/${database}?serverSelectionTimeoutMS=${MONGO_TIMEOUT}"
    fi
    conn_args+=("$uri")
  else
    # ── URI mode ──────────────────────────────────────────────────────────
    local base_uri="${MONGO_URI%/}"
    # Append timeout as a query parameter; handle existing ? gracefully.
    if [[ "$base_uri" == *'?'* ]]; then
      uri="${base_uri}/${database}?serverSelectionTimeoutMS=${MONGO_TIMEOUT}"
    else
      uri="${base_uri}/${database}?serverSelectionTimeoutMS=${MONGO_TIMEOUT}"
    fi
    conn_args+=("$uri")
  fi

  # shellcheck disable=SC2086
  mongosh "${conn_args[@]}" \
    --quiet \
    --norc \
    $MONGO_TLS \
    $MONGO_EXTRA_ARGS \
    --eval "$js" 2>&1
}

# ---------------------------------------------------------------------------
# _escape_js_string <string>
# Escape a string so it is safe to embed inside a JavaScript single-quoted
# string literal.  Replaces: backslash, single-quote, newline, tab.
# ---------------------------------------------------------------------------
_escape_js_string() {
  local s="$1"
  s="${s//\\/\\\\}"    # backslash first
  s="${s//\'/\\\'}"    # single-quote
  s="${s//$'\n'/\\n}"  # newline
  s="${s//$'\t'/\\t}"  # tab
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# _mongo_conn_label
# Return a display label for the current connection (for log messages).
# ---------------------------------------------------------------------------
_mongo_conn_label() {
  if [[ -n "$MONGO_HOST" ]]; then
    if [[ -n "$MONGO_USER" ]]; then
      printf '%s@%s:%s' "$MONGO_USER" "$MONGO_HOST" "$MONGO_PORT"
    else
      printf '%s:%s' "$MONGO_HOST" "$MONGO_PORT"
    fi
  else
    # Mask user:password portion so credentials never appear in logs or responses
    printf '%s' "$MONGO_URI" | sed 's|//[^@]*@|//***:***@|'
  fi
}

# ---------------------------------------------------------------------------
# mongo_check
# Verify that mongosh is installed and a connection can be established.
# Returns: JSON response
# ---------------------------------------------------------------------------
mongo_check() {
  local op="mongo_check"
  local conn_label
  conn_label=$(_mongo_conn_label)
  log_info "$op" "Checking mongosh connectivity to $conn_label"

  if ! command -v mongosh &>/dev/null; then
    log_error "$op" "mongosh not found in PATH"
    response_err "$op" "mongosh not found in PATH" '{}' 127
    return 1
  fi

  local out
  if ! out=$(_mongosh_eval "admin" "db.adminCommand({ping:1})" 2>&1); then
    log_error "$op" "Cannot connect to MongoDB: $out"
    response_err "$op" "Cannot connect to MongoDB" "{\"connection\":\"$conn_label\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "MongoDB connection successful"
  response_ok "$op" "MongoDB connection successful" "{\"connection\":\"$conn_label\"}"
}

# ---------------------------------------------------------------------------
# mongo_list_databases
# List all databases visible to the current user.
# Returns: JSON response with array of database info objects.
# ---------------------------------------------------------------------------
mongo_list_databases() {
  local op="mongo_list_databases"
  log_info "$op" "Listing databases"

  local out
  if ! out=$(_mongosh_eval "admin" "JSON.stringify(db.adminCommand({listDatabases:1}))" 2>&1); then
    log_error "$op" "Failed to list databases: $out"
    response_err "$op" "Failed to list databases" "{\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Databases listed"
  response_ok "$op" "Databases listed" "$out"
}

# ---------------------------------------------------------------------------
# mongo_list_collections <database>
# List all collections in the given database.
# Returns: JSON response with array of collection names.
# ---------------------------------------------------------------------------
mongo_list_collections() {
  local database="${1:?database is required}"
  local op="mongo_list_collections"
  log_info "$op" "Listing collections in database '$database'"

  local out
  if ! out=$(_mongosh_eval "$database" "JSON.stringify(db.getCollectionNames())" 2>&1); then
    log_error "$op" "Failed to list collections in '$database': $out"
    response_err "$op" "Failed to list collections" "{\"database\":\"$database\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Collections listed for '$database'"
  response_ok "$op" "Collections listed" "{\"database\":\"$database\",\"collections\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_create_collection <database> <collection>
# Create a collection (and database, implicitly) if it does not exist.
# Returns: JSON response
# ---------------------------------------------------------------------------
mongo_create_collection() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local op="mongo_create_collection"
  log_info "$op" "Creating collection '$collection' in database '$database'"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="db.createCollection('${esc_col}'); JSON.stringify({ok:1})"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to create collection '$collection': $out"
    response_err "$op" "Failed to create collection" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Collection '$collection' created in '$database'"
  response_ok "$op" "Collection created" "{\"database\":\"$database\",\"collection\":\"$collection\"}"
}

# ---------------------------------------------------------------------------
# mongo_drop_collection <database> <collection>
# Drop a collection from the given database.
# Returns: JSON response
# ---------------------------------------------------------------------------
mongo_drop_collection() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local op="mongo_drop_collection"
  log_info "$op" "Dropping collection '$collection' from database '$database'"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.getCollection('${esc_col}').drop())"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to drop collection '$collection': $out"
    response_err "$op" "Failed to drop collection" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Collection '$collection' dropped from '$database'"
  response_ok "$op" "Collection dropped" "{\"database\":\"$database\",\"collection\":\"$collection\",\"result\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_drop_database <database>
# Drop an entire database.
# Returns: JSON response
# ---------------------------------------------------------------------------
mongo_drop_database() {
  local database="${1:?database is required}"
  local op="mongo_drop_database"
  log_info "$op" "Dropping database '$database'"

  local js="JSON.stringify(db.dropDatabase())"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to drop database '$database': $out"
    response_err "$op" "Failed to drop database" "{\"database\":\"$database\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Database '$database' dropped"
  response_ok "$op" "Database dropped" "{\"database\":\"$database\",\"result\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_insert_one <database> <collection> <json_document>
# Insert a single document.
# json_document: valid JSON object string, e.g. '{"name":"Alice","age":30}'
# Returns: JSON response with insertedId.
# ---------------------------------------------------------------------------
mongo_insert_one() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local document="${3:?json_document is required}"
  local op="mongo_insert_one"
  log_info "$op" "Inserting document into '$database.$collection'"
  log_debug "$op" "Document: $document"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.getCollection('${esc_col}').insertOne(${document}))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to insert document into '$database.$collection': $out"
    response_err "$op" "Insert failed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Document inserted into '$database.$collection'"
  response_ok "$op" "Document inserted" "{\"database\":\"$database\",\"collection\":\"$collection\",\"result\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_insert_many <database> <collection> <json_array>
# Insert multiple documents.
# json_array: valid JSON array string, e.g. '[{"a":1},{"a":2}]'
# Returns: JSON response with insertedCount.
# ---------------------------------------------------------------------------
mongo_insert_many() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local documents="${3:?json_array is required}"
  local op="mongo_insert_many"
  log_info "$op" "Inserting multiple documents into '$database.$collection'"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.getCollection('${esc_col}').insertMany(${documents}))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to insert documents into '$database.$collection': $out"
    response_err "$op" "InsertMany failed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Documents inserted into '$database.$collection'"
  response_ok "$op" "Documents inserted" "{\"database\":\"$database\",\"collection\":\"$collection\",\"result\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_find <database> <collection> [filter_json] [projection_json] [limit]
# Find documents in a collection.
#   filter_json     : optional filter, default {}
#   projection_json : optional projection, default {}
#   limit           : max documents to return, default 50
# Returns: JSON response with documents array.
# ---------------------------------------------------------------------------
mongo_find() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local filter="${3:-{}}"
  local projection="${4:-{}}"
  local limit="${5:-50}"
  local op="mongo_find"
  log_info "$op" "Finding documents in '$database.$collection' filter=$filter limit=$limit"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.getCollection('${esc_col}').find(${filter},${projection}).limit(${limit}).toArray())"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Find failed in '$database.$collection': $out"
    response_err "$op" "Find failed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Find completed in '$database.$collection'"
  response_ok "$op" "Documents found" "{\"database\":\"$database\",\"collection\":\"$collection\",\"filter\":${filter},\"limit\":${limit},\"documents\":${out}}"
}

# ---------------------------------------------------------------------------
# mongo_find_one <database> <collection> [filter_json]
# Find a single document.
# Returns: JSON response with one document (or null).
# ---------------------------------------------------------------------------
mongo_find_one() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local filter="${3:-{}}"
  local op="mongo_find_one"
  log_info "$op" "Finding one document in '$database.$collection' filter=$filter"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.getCollection('${esc_col}').findOne(${filter}))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "FindOne failed in '$database.$collection': $out"
    response_err "$op" "FindOne failed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "FindOne completed in '$database.$collection'"
  response_ok "$op" "Document found" "{\"database\":\"$database\",\"collection\":\"$collection\",\"document\":${out}}"
}

# ---------------------------------------------------------------------------
# mongo_count <database> <collection> [filter_json]
# Count documents matching a filter.
# Returns: JSON response with count integer.
# ---------------------------------------------------------------------------
mongo_count() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local filter="${3:-{}}"
  local op="mongo_count"
  log_info "$op" "Counting documents in '$database.$collection' filter=$filter"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify({count: db.getCollection('${esc_col}').countDocuments(${filter})})"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Count failed in '$database.$collection': $out"
    response_err "$op" "Count failed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Count completed in '$database.$collection'"
  response_ok "$op" "Count completed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"filter\":${filter},\"result\":${out}}"
}

# ---------------------------------------------------------------------------
# mongo_update_one <database> <collection> <filter_json> <update_json>
# Update a single matching document.
# update_json example: '{"$set":{"status":"active"}}'
# Returns: JSON response with matchedCount / modifiedCount.
# ---------------------------------------------------------------------------
mongo_update_one() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local filter="${3:?filter_json is required}"
  local update="${4:?update_json is required}"
  local op="mongo_update_one"
  log_info "$op" "Updating one document in '$database.$collection'"
  log_debug "$op" "Filter: $filter  Update: $update"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.getCollection('${esc_col}').updateOne(${filter},${update}))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "UpdateOne failed in '$database.$collection': $out"
    response_err "$op" "UpdateOne failed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "UpdateOne completed in '$database.$collection'"
  response_ok "$op" "Document updated" "{\"database\":\"$database\",\"collection\":\"$collection\",\"result\":${out}}"
}

# ---------------------------------------------------------------------------
# mongo_update_many <database> <collection> <filter_json> <update_json>
# Update all matching documents.
# Returns: JSON response with matchedCount / modifiedCount.
# ---------------------------------------------------------------------------
mongo_update_many() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local filter="${3:?filter_json is required}"
  local update="${4:?update_json is required}"
  local op="mongo_update_many"
  log_info "$op" "Updating many documents in '$database.$collection'"
  log_debug "$op" "Filter: $filter  Update: $update"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.getCollection('${esc_col}').updateMany(${filter},${update}))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "UpdateMany failed in '$database.$collection': $out"
    response_err "$op" "UpdateMany failed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "UpdateMany completed in '$database.$collection'"
  response_ok "$op" "Documents updated" "{\"database\":\"$database\",\"collection\":\"$collection\",\"result\":${out}}"
}

# ---------------------------------------------------------------------------
# mongo_upsert_one <database> <collection> <filter_json> <update_json>
# Update or insert (upsert) a single document.
# Returns: JSON response
# ---------------------------------------------------------------------------
mongo_upsert_one() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local filter="${3:?filter_json is required}"
  local update="${4:?update_json is required}"
  local op="mongo_upsert_one"
  log_info "$op" "Upserting document in '$database.$collection'"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.getCollection('${esc_col}').updateOne(${filter},${update},{upsert:true}))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Upsert failed in '$database.$collection': $out"
    response_err "$op" "Upsert failed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Upsert completed in '$database.$collection'"
  response_ok "$op" "Document upserted" "{\"database\":\"$database\",\"collection\":\"$collection\",\"result\":${out}}"
}

# ---------------------------------------------------------------------------
# mongo_delete_one <database> <collection> <filter_json>
# Delete a single matching document.
# Returns: JSON response with deletedCount.
# ---------------------------------------------------------------------------
mongo_delete_one() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local filter="${3:?filter_json is required}"
  local op="mongo_delete_one"
  log_info "$op" "Deleting one document from '$database.$collection' filter=$filter"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.getCollection('${esc_col}').deleteOne(${filter}))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "DeleteOne failed in '$database.$collection': $out"
    response_err "$op" "DeleteOne failed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "DeleteOne completed in '$database.$collection'"
  response_ok "$op" "Document deleted" "{\"database\":\"$database\",\"collection\":\"$collection\",\"result\":${out}}"
}

# ---------------------------------------------------------------------------
# mongo_delete_many <database> <collection> <filter_json>
# Delete all documents matching the filter.
# Returns: JSON response with deletedCount.
# ---------------------------------------------------------------------------
mongo_delete_many() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local filter="${3:?filter_json is required}"
  local op="mongo_delete_many"
  log_info "$op" "Deleting many documents from '$database.$collection' filter=$filter"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.getCollection('${esc_col}').deleteMany(${filter}))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "DeleteMany failed in '$database.$collection': $out"
    response_err "$op" "DeleteMany failed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "DeleteMany completed in '$database.$collection'"
  response_ok "$op" "Documents deleted" "{\"database\":\"$database\",\"collection\":\"$collection\",\"result\":${out}}"
}

# ---------------------------------------------------------------------------
# mongo_aggregate <database> <collection> <pipeline_json>
# Run an aggregation pipeline.
# pipeline_json: JSON array, e.g. '[{"$match":{"status":"A"}},{"$group":{"_id":"$cust_id"}}]'
# Returns: JSON response with result array.
# ---------------------------------------------------------------------------
mongo_aggregate() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local pipeline="${3:?pipeline_json is required}"
  local op="mongo_aggregate"
  log_info "$op" "Running aggregation on '$database.$collection'"
  log_debug "$op" "Pipeline: $pipeline"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.getCollection('${esc_col}').aggregate(${pipeline}).toArray())"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Aggregation failed on '$database.$collection': $out"
    response_err "$op" "Aggregation failed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Aggregation completed on '$database.$collection'"
  response_ok "$op" "Aggregation completed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"result\":${out}}"
}

# ---------------------------------------------------------------------------
# mongo_create_index <database> <collection> <keys_json> [options_json]
# Create an index on a collection.
# keys_json: e.g. '{"email":1}'
# options_json: e.g. '{"unique":true,"background":true}'
# Returns: JSON response with index name.
# ---------------------------------------------------------------------------
mongo_create_index() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local keys="${3:?keys_json is required}"
  local options="${4:-{}}"
  local op="mongo_create_index"
  log_info "$op" "Creating index on '$database.$collection' keys=$keys"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify({indexName: db.getCollection('${esc_col}').createIndex(${keys},${options})})"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to create index on '$database.$collection': $out"
    response_err "$op" "Index creation failed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Index created on '$database.$collection'"
  response_ok "$op" "Index created" "{\"database\":\"$database\",\"collection\":\"$collection\",\"keys\":${keys},\"result\":${out}}"
}

# ---------------------------------------------------------------------------
# mongo_list_indexes <database> <collection>
# List all indexes on a collection.
# Returns: JSON response with indexes array.
# ---------------------------------------------------------------------------
mongo_list_indexes() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local op="mongo_list_indexes"
  log_info "$op" "Listing indexes on '$database.$collection'"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.getCollection('${esc_col}').getIndexes())"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to list indexes on '$database.$collection': $out"
    response_err "$op" "List indexes failed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Indexes listed for '$database.$collection'"
  response_ok "$op" "Indexes listed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"indexes\":${out}}"
}

# ---------------------------------------------------------------------------
# mongo_drop_index <database> <collection> <index_name>
# Drop an index by name.
# Returns: JSON response
# ---------------------------------------------------------------------------
mongo_drop_index() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local index_name="${3:?index_name is required}"
  local op="mongo_drop_index"
  log_info "$op" "Dropping index '$index_name' on '$database.$collection'"

  local esc_col esc_idx
  esc_col=$(_escape_js_string "$collection")
  esc_idx=$(_escape_js_string "$index_name")
  local js="JSON.stringify(db.getCollection('${esc_col}').dropIndex('${esc_idx}'))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to drop index '$index_name' on '$database.$collection': $out"
    response_err "$op" "Drop index failed" "{\"database\":\"$database\",\"collection\":\"$collection\",\"index\":\"$index_name\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Index '$index_name' dropped on '$database.$collection'"
  response_ok "$op" "Index dropped" "{\"database\":\"$database\",\"collection\":\"$collection\",\"index\":\"$index_name\",\"result\":${out}}"
}

# ---------------------------------------------------------------------------
# mongo_server_status
# Retrieve server status (uptime, connections, memory, etc.).
# Returns: JSON response with full serverStatus document.
# ---------------------------------------------------------------------------
mongo_server_status() {
  local op="mongo_server_status"
  log_info "$op" "Retrieving server status"

  local js="JSON.stringify(db.adminCommand({serverStatus:1}))"
  local out
  if ! out=$(_mongosh_eval "admin" "$js" 2>&1); then
    log_error "$op" "Failed to retrieve server status: $out"
    response_err "$op" "Failed to retrieve server status" "{\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Server status retrieved"
  response_ok "$op" "Server status retrieved" "$out"
}

# ---------------------------------------------------------------------------
# mongo_rs_status
# Retrieve replica set status (rs.status()).
# Returns: JSON response with replica set member states.
# ---------------------------------------------------------------------------
mongo_rs_status() {
  local op="mongo_rs_status"
  log_info "$op" "Retrieving replica set status"

  local js="JSON.stringify(rs.status())"
  local out
  if ! out=$(_mongosh_eval "admin" "$js" 2>&1); then
    log_error "$op" "Failed to retrieve replica set status: $out"
    response_err "$op" "Failed to retrieve replica set status" "{\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Replica set status retrieved"
  response_ok "$op" "Replica set status retrieved" "$out"
}

# ---------------------------------------------------------------------------
# mongo_rs_config
# Retrieve replica set configuration (rs.conf()).
# Returns: JSON response
# ---------------------------------------------------------------------------
mongo_rs_config() {
  local op="mongo_rs_config"
  log_info "$op" "Retrieving replica set configuration"

  local js="JSON.stringify(rs.conf())"
  local out
  if ! out=$(_mongosh_eval "admin" "$js" 2>&1); then
    log_error "$op" "Failed to retrieve replica set config: $out"
    response_err "$op" "Failed to retrieve replica set config" "{\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Replica set config retrieved"
  response_ok "$op" "Replica set config retrieved" "$out"
}

# ---------------------------------------------------------------------------
# mongo_rs_is_primary
# Check whether the current node is the replica set primary.
# Returns: JSON response; data.isPrimary = true|false
# ---------------------------------------------------------------------------
mongo_rs_is_primary() {
  local op="mongo_rs_is_primary"
  log_info "$op" "Checking if node is primary"

  local js="JSON.stringify(db.adminCommand({hello:1}))"
  local out
  if ! out=$(_mongosh_eval "admin" "$js" 2>&1); then
    log_error "$op" "hello check failed: $out"
    response_err "$op" "hello check failed" "{\"detail\":\"$out\"}" 1
    return 1
  fi

  local is_primary
  is_primary=$(echo "$out" | grep -o '"isWritablePrimary":[^,}]*\|"ismaster":[^,}]*' | head -1 | awk -F':' '{print $2}' | tr -d ' ')
  log_info "$op" "isPrimary=$is_primary"
  response_ok "$op" "Node role checked" "{\"isPrimary\":${is_primary:-false},\"raw\":${out}}"
}

# ---------------------------------------------------------------------------
# mongo_current_op [max_time_ms]
# List currently running operations.
# max_time_ms: optional filter – only show ops running longer than this value.
# Returns: JSON response with inprog array.
# ---------------------------------------------------------------------------
mongo_current_op() {
  local max_time_ms="${1:-0}"
  local op="mongo_current_op"
  log_info "$op" "Listing current operations (running > ${max_time_ms}ms)"

  local filter="{}"
  if (( max_time_ms > 0 )); then
    filter="{\"secs_running\":{\"\$gte\":$(( max_time_ms / 1000 ))}}"
  fi

  local js="JSON.stringify(db.currentOp(${filter}))"
  local out
  if ! out=$(_mongosh_eval "admin" "$js" 2>&1); then
    log_error "$op" "currentOp failed: $out"
    response_err "$op" "currentOp failed" "{\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Current operations retrieved"
  response_ok "$op" "Current operations retrieved" "$out"
}

# ---------------------------------------------------------------------------
# mongo_kill_op <op_id>
# Kill a running MongoDB operation by its opId.
# Returns: JSON response
# ---------------------------------------------------------------------------
mongo_kill_op() {
  local op_id="${1:?op_id is required}"
  local op="mongo_kill_op"
  log_info "$op" "Killing operation opId=$op_id"

  local js="JSON.stringify(db.adminCommand({killOp:1,op:${op_id}}))"
  local out
  if ! out=$(_mongosh_eval "admin" "$js" 2>&1); then
    log_error "$op" "killOp failed for opId=$op_id: $out"
    response_err "$op" "killOp failed" "{\"opId\":$op_id,\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Operation $op_id killed"
  response_ok "$op" "Operation killed" "{\"opId\":$op_id,\"result\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_create_user <database> <username> <password> [roles_json]
# Create a MongoDB user.
# roles_json example: '[{"role":"readWrite","db":"mydb"}]'
# If omitted, defaults to readWrite on the target database.
# Returns: JSON response
# ---------------------------------------------------------------------------
mongo_create_user() {
  local database="${1:?database is required}"
  local username="${2:?username is required}"
  local password="${3:?password is required}"
  local roles="${4:-[{\"role\":\"readWrite\",\"db\":\"${database}\"}]}"
  local op="mongo_create_user"
  log_info "$op" "Creating user '$username' in database '$database'"

  local safe_user safe_pass
  safe_user=$(_escape_js_string "$username")
  safe_pass=$(_escape_js_string "$password")

  local js="db.createUser({user:'${safe_user}',pwd:'${safe_pass}',roles:${roles}}); JSON.stringify({ok:1})"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to create user '$username': $out"
    response_err "$op" "Failed to create user" "{\"database\":\"$database\",\"username\":\"$username\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "User '$username' created in '$database'"
  response_ok "$op" "User created" "{\"database\":\"$database\",\"username\":\"$username\"}"
}

# ---------------------------------------------------------------------------
# mongo_drop_user <database> <username>
# Drop a MongoDB user.
# Returns: JSON response
# ---------------------------------------------------------------------------
mongo_drop_user() {
  local database="${1:?database is required}"
  local username="${2:?username is required}"
  local op="mongo_drop_user"
  log_info "$op" "Dropping user '$username' from database '$database'"

  local esc_user; esc_user=$(_escape_js_string "$username")
  local js="JSON.stringify(db.dropUser('${esc_user}'))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to drop user '$username': $out"
    response_err "$op" "Failed to drop user" "{\"database\":\"$database\",\"username\":\"$username\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "User '$username' dropped from '$database'"
  response_ok "$op" "User dropped" "{\"database\":\"$database\",\"username\":\"$username\",\"result\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_list_users <database>
# List all users in the given database.
# Returns: JSON response with users array.
# ---------------------------------------------------------------------------
mongo_list_users() {
  local database="${1:?database is required}"
  local op="mongo_list_users"
  log_info "$op" "Listing users in database '$database'"

  local js="JSON.stringify(db.getUsers())"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to list users in '$database': $out"
    response_err "$op" "Failed to list users" "{\"database\":\"$database\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Users listed for '$database'"
  response_ok "$op" "Users listed" "{\"database\":\"$database\",\"users\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_update_user_password <database> <username> <new_password>
# Change the password for an existing MongoDB user.
# Returns: JSON response
# ---------------------------------------------------------------------------
mongo_update_user_password() {
  local database="${1:?database is required}"
  local username="${2:?username is required}"
  local new_password="${3:?new_password is required}"
  local op="mongo_update_user_password"
  log_info "$op" "Updating password for user '$username' in database '$database'"

  local safe_user safe_pass
  safe_user=$(_escape_js_string "$username")
  safe_pass=$(_escape_js_string "$new_password")

  local js="db.updateUser('${safe_user}',{pwd:'${safe_pass}'}); JSON.stringify({ok:1})"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to update password for '$username': $out"
    response_err "$op" "Failed to update user password" "{\"database\":\"$database\",\"username\":\"$username\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Password updated for '$username'"
  response_ok "$op" "User password updated" "{\"database\":\"$database\",\"username\":\"$username\"}"
}

# ---------------------------------------------------------------------------
# mongo_collection_stats <database> <collection>
# Get storage and document statistics for a collection.
# Returns: JSON response with collStats document.
# ---------------------------------------------------------------------------
mongo_collection_stats() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local op="mongo_collection_stats"
  log_info "$op" "Getting stats for '$database.$collection'"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.command({collStats:'${esc_col}',scale:1024}))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to get stats for '$database.$collection': $out"
    response_err "$op" "Failed to get collection stats" "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Stats retrieved for '$database.$collection'"
  response_ok "$op" "Collection stats retrieved" "{\"database\":\"$database\",\"collection\":\"$collection\",\"stats\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_eval_js <database> <js_expression>
# Execute arbitrary JavaScript in the given database context.
# The JS expression MUST produce a value serialisable by JSON.stringify.
# The result is wrapped in the standard response envelope.
# WARNING: use with caution – validate input before passing user data.
# Returns: JSON response
# ---------------------------------------------------------------------------
mongo_eval_js() {
  local database="${1:?database is required}"
  local js="${2:?js_expression is required}"
  local op="mongo_eval_js"
  log_debug "$op" "Evaluating JS in database '$database'"

  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "JS eval failed in '$database': $out"
    response_err "$op" "JS evaluation failed" "{\"database\":\"$database\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "JS eval completed in '$database'"
  response_ok "$op" "JS evaluated" "{\"database\":\"$database\",\"result\":${out}}"
}

# ---------------------------------------------------------------------------
# mongo_db_stats <database>
# Return storage and document statistics for an entire database.
# Returns: JSON response with dbStats document.
# ---------------------------------------------------------------------------
mongo_db_stats() {
  local database="${1:?database is required}"
  local op="mongo_db_stats"
  log_info "$op" "Getting stats for database '$database'"

  local js="JSON.stringify(db.stats(1024))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to get stats for '$database': $out"
    response_err "$op" "Failed to get database stats" "{\"database\":\"$database\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Database stats retrieved for '$database'"
  response_ok "$op" "Database stats retrieved" "{\"database\":\"$database\",\"stats\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_rename_collection <database> <from_collection> <to_collection>
# Rename a collection within the same database.
# Returns: JSON response
# ---------------------------------------------------------------------------
mongo_rename_collection() {
  local database="${1:?database is required}"
  local from_col="${2:?from_collection is required}"
  local to_col="${3:?to_collection is required}"
  local op="mongo_rename_collection"
  log_info "$op" "Renaming '$database.$from_col' → '$database.$to_col'"

  local esc_from esc_to
  esc_from=$(_escape_js_string "$from_col")
  esc_to=$(_escape_js_string "$to_col")
  # adminCommand renameCollection requires fully-qualified namespace
  local esc_db; esc_db=$(_escape_js_string "$database")
  local js="JSON.stringify(db.adminCommand({renameCollection:'${esc_db}.${esc_from}',to:'${esc_db}.${esc_to}',dropTarget:false}))"
  local out
  if ! out=$(_mongosh_eval "admin" "$js" 2>&1); then
    log_error "$op" "Failed to rename '$from_col' → '$to_col' in '$database': $out"
    response_err "$op" "Rename collection failed" \
      "{\"database\":\"$database\",\"from\":\"$from_col\",\"to\":\"$to_col\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Collection renamed: '$from_col' → '$to_col' in '$database'"
  response_ok "$op" "Collection renamed" \
    "{\"database\":\"$database\",\"from\":\"$from_col\",\"to\":\"$to_col\",\"result\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_validate_collection <database> <collection>
# Run a full validation of a collection.
# Returns: JSON response with validation results (valid, errors, warnings).
# ---------------------------------------------------------------------------
mongo_validate_collection() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local op="mongo_validate_collection"
  log_info "$op" "Validating collection '$database.$collection'"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.command({validate:'${esc_col}',full:true}))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Validation failed for '$database.$collection': $out"
    response_err "$op" "Validation failed" \
      "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Validation completed for '$database.$collection'"
  response_ok "$op" "Collection validated" \
    "{\"database\":\"$database\",\"collection\":\"$collection\",\"result\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_oplog_status
# Report the oplog size, used size, earliest and latest timestamps, and the
# retention window expressed in hours and days.
# Only meaningful on replica set members (returns error on standalones).
# Returns: JSON response with sizeMB, usedMB, windowHours, windowDays.
# ---------------------------------------------------------------------------
mongo_oplog_status() {
  local op="mongo_oplog_status"
  log_info "$op" "Retrieving oplog status"

  local js
  # rs.printReplicationInfo() is user-facing; use the raw stats instead
  js=$(cat <<'JSEOF'
(function(){
  var s = db.adminCommand({replSetGetStatus:1});
  if (s.ok !== 1) { return JSON.stringify({error:"not a replica set member"}); }
  var ol = db.getSiblingDB("local").oplog.rs;
  var stats = ol.stats(1024*1024);
  var first = ol.find().sort({$natural:1}).limit(1).toArray()[0];
  var last  = ol.find().sort({$natural:-1}).limit(1).toArray()[0];
  var windowSec = 0;
  if (first && last) {
    var ts1 = first.ts.t !== undefined ? first.ts.t : 0;
    var ts2 = last.ts.t  !== undefined ? last.ts.t  : 0;
    windowSec = ts2 - ts1;
  }
  return JSON.stringify({
    sizeMB: Math.round(stats.maxSize / 1024 / 1024 * 100) / 100,
    usedMB: Math.round(stats.size / 1024 / 1024 * 100) / 100,
    windowSeconds: windowSec,
    windowHours:   Math.round(windowSec / 3600 * 100) / 100,
    windowDays:    Math.round(windowSec / 86400 * 100) / 100
  });
})()
JSEOF
)
  local out
  if ! out=$(_mongosh_eval "local" "$js" 2>&1); then
    log_error "$op" "Failed to retrieve oplog status: $out"
    response_err "$op" "Failed to retrieve oplog status" "{\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Oplog status retrieved"
  response_ok "$op" "Oplog status retrieved" "$out"
}

# ---------------------------------------------------------------------------
# mongo_rs_lag
# Report per-member replication lag in seconds relative to the primary's
# optime.  Only meaningful on replica set members.
# Returns: JSON response with array of {member, state, lagSeconds}.
# ---------------------------------------------------------------------------
mongo_rs_lag() {
  local op="mongo_rs_lag"
  log_info "$op" "Retrieving replication lag"

  local js
  js=$(cat <<'JSEOF'
(function(){
  var s = db.adminCommand({replSetGetStatus:1});
  if (s.ok !== 1) { return JSON.stringify({error:"not a replica set member",members:[]}); }
  var primaryOptime = 0;
  s.members.forEach(function(m){ if (m.state === 1) { primaryOptime = m.optime.ts.t; } });
  var result = s.members.map(function(m){
    var lag = (primaryOptime > 0 && m.optime && m.optime.ts)
              ? primaryOptime - m.optime.ts.t : null;
    return {member: m.name, stateStr: m.stateStr, lagSeconds: lag};
  });
  return JSON.stringify({members: result});
})()
JSEOF
)
  local out
  if ! out=$(_mongosh_eval "admin" "$js" 2>&1); then
    log_error "$op" "Failed to retrieve replication lag: $out"
    response_err "$op" "Failed to retrieve replication lag" "{\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Replication lag retrieved"
  response_ok "$op" "Replication lag retrieved" "$out"
}

# ---------------------------------------------------------------------------
# mongo_get_profiling <database>
# Get the current query profiler level and slowms threshold.
# Returns: JSON response with level (0=off,1=slow,2=all) and slowms.
# ---------------------------------------------------------------------------
mongo_get_profiling() {
  local database="${1:?database is required}"
  local op="mongo_get_profiling"
  log_info "$op" "Getting profiling config for database '$database'"

  local js="JSON.stringify(db.getProfilingStatus())"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to get profiling status for '$database': $out"
    response_err "$op" "Failed to get profiling status" "{\"database\":\"$database\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Profiling status retrieved for '$database'"
  response_ok "$op" "Profiling status retrieved" "{\"database\":\"$database\",\"profiling\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_set_profiling <database> <level> [slowms]
# Set the query profiler level.
#   level 0 = off, 1 = slow queries only, 2 = all operations
#   slowms  = threshold in ms (default: 100); only used when level=1
# Returns: JSON response
# ---------------------------------------------------------------------------
mongo_set_profiling() {
  local database="${1:?database is required}"
  local level="${2:?level is required (0, 1, or 2)}"
  local slowms="${3:-100}"
  local op="mongo_set_profiling"
  log_info "$op" "Setting profiling level=$level slowms=$slowms in database '$database'"

  local js="JSON.stringify(db.setProfilingLevel(${level},${slowms}))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Failed to set profiling in '$database': $out"
    response_err "$op" "Failed to set profiling" \
      "{\"database\":\"$database\",\"level\":$level,\"slowms\":$slowms,\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Profiling set: level=$level slowms=$slowms in '$database'"
  response_ok "$op" "Profiling level set" \
    "{\"database\":\"$database\",\"level\":$level,\"slowms\":$slowms,\"result\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_explain <database> <collection> <filter_json> [verbosity]
# Explain the winning plan for a find query.
# verbosity: "queryPlanner" (default) | "executionStats" | "allPlansExecution"
# Returns: JSON response with explain output.
# ---------------------------------------------------------------------------
mongo_explain() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local filter="${3:?filter_json is required}"
  local verbosity="${4:-queryPlanner}"
  local op="mongo_explain"
  log_info "$op" "Explaining query on '$database.$collection' filter=$filter"

  local esc_col esc_v
  esc_col=$(_escape_js_string "$collection")
  esc_v=$(_escape_js_string "$verbosity")
  local js="JSON.stringify(db.getCollection('${esc_col}').explain('${esc_v}').find(${filter}))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Explain failed on '$database.$collection': $out"
    response_err "$op" "Explain failed" \
      "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Explain completed for '$database.$collection'"
  response_ok "$op" "Explain completed" \
    "{\"database\":\"$database\",\"collection\":\"$collection\",\"verbosity\":\"$verbosity\",\"plan\":$out}"
}

# ---------------------------------------------------------------------------
# mongo_bulk_write <database> <collection> <operations_json>
# Execute a bulk write operation.
# operations_json: JSON array of bulk write operation objects, e.g.:
#   '[{"insertOne":{"document":{"x":1}}},{"deleteOne":{"filter":{"x":1}}}]'
# Returns: JSON response with bulk write result.
# ---------------------------------------------------------------------------
mongo_bulk_write() {
  local database="${1:?database is required}"
  local collection="${2:?collection is required}"
  local operations="${3:?operations_json is required}"
  local op="mongo_bulk_write"
  log_info "$op" "Running bulk write on '$database.$collection'"

  local esc_col; esc_col=$(_escape_js_string "$collection")
  local js="JSON.stringify(db.getCollection('${esc_col}').bulkWrite(${operations}))"
  local out
  if ! out=$(_mongosh_eval "$database" "$js" 2>&1); then
    log_error "$op" "Bulk write failed on '$database.$collection': $out"
    response_err "$op" "Bulk write failed" \
      "{\"database\":\"$database\",\"collection\":\"$collection\",\"detail\":\"$out\"}" 1
    return 1
  fi

  log_info "$op" "Bulk write completed on '$database.$collection'"
  response_ok "$op" "Bulk write completed" \
    "{\"database\":\"$database\",\"collection\":\"$collection\",\"result\":$out}"
}

# ---------------------------------------------------------------------------
# check_mongo_connectivity
# Layer 2 of the MongoDB sanity check: verify mongosh can connect and ping.
#
# Requires (from calling environment):
#   _sc_pass / _sc_fail / _sc_section  — check result helpers
# ---------------------------------------------------------------------------
check_mongo_connectivity() {
  _sc_section "Layer 2: MongoDB Connectivity"

  local r
  r=$(mongo_check 2>/dev/null)
  if [[ "$(_json_status "$r")" == "success" ]]; then
    _sc_pass "MongoDB: connection successful"
    return 0
  else
    _sc_fail "MongoDB: cannot connect" "$(_json_field "$r" "message")"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# check_mongo_internals
# Layer 3 of the MongoDB sanity check: RS health, replication lag, oplog
# window, WiredTiger cache, connection utilisation, lock queue, and
# long-running operations.
#
# Requires (from calling environment):
#   _sc_pass / _sc_warn / _sc_fail / _sc_section  — check result helpers
#   LAG_WARN_SECONDS, LAG_CRIT_SECONDS
#   OPLOG_WARN_DAYS, OPLOG_CRIT_DAYS
#   WT_CACHE_WARN_PERCENT, WT_CACHE_CRIT_PERCENT
#   CONN_WARN_PERCENT, CONN_CRIT_PERCENT
#   LOCK_QUEUE_WARN, LOCK_QUEUE_FAIL
#   MAX_LONG_OP_SECONDS
#   STANDALONE_OK
# ---------------------------------------------------------------------------
check_mongo_internals() {
  _sc_section "Layer 3: MongoDB Internals"

  # Collect serverStatus once (used by multiple sub-checks)
  local srv_r srv_ok
  srv_r=$(mongo_server_status 2>/dev/null)
  srv_ok=false
  [[ "$(_json_status "$srv_r")" == "success" ]] && srv_ok=true

  # 3a. Is this a replica set? ─────────────────────────────────────────────
  local rs_r is_rs
  rs_r=$(mongo_rs_status 2>/dev/null)
  local rs_out_ok
  rs_out_ok=$(echo "$rs_r" | grep -o '"ok":[0-9]*' | head -1 | cut -d':' -f2 || echo "0")
  if [[ "${rs_out_ok}" == "1" ]]; then
    is_rs="true"
  else
    is_rs="false"
  fi

  # 3b. Replica set member health ──────────────────────────────────────────
  if [[ "$is_rs" == "true" ]]; then
    _sc_section "Layer 3a: Replica Set Health"

    if [[ "$(_json_status "$rs_r")" == "success" ]]; then
      local failed_members transitional_members
      failed_members=$(echo "$rs_r" | \
        grep -o '"stateStr":"[^"]*"' | \
        grep -v '"PRIMARY"\|"SECONDARY"\|"ARBITER"\|"RECOVERING"\|"STARTUP2"' | wc -l || echo "0")
      failed_members="${failed_members//[[:space:]]/}"
      transitional_members=$(echo "$rs_r" | \
        grep -o '"stateStr":"[^"]*"' | \
        grep '"RECOVERING"\|"STARTUP2"' | wc -l || echo "0")
      transitional_members="${transitional_members//[[:space:]]/}"

      if [[ "$failed_members" -gt 0 ]]; then
        _sc_fail "Replica set: $failed_members member(s) in error state" \
          "Check rs.status() for details"
      elif [[ "$transitional_members" -gt 0 ]]; then
        _sc_warn "Replica set: $transitional_members member(s) in transitional state (RECOVERING/STARTUP2)" \
          "Members may be catching up; monitor for progression"
      else
        _sc_pass "Replica set: all members in healthy state (PRIMARY/SECONDARY/ARBITER)"
      fi

      local member_states
      member_states=$(echo "$rs_r" | \
        grep -o '"name":"[^"]*","stateStr":"[^"]*"' | \
        sed 's/"name":"\([^"]*\)","stateStr":"\([^"]*\)"/  \1 → \2/' || true)
      if [[ -n "$member_states" ]]; then
        printf '           Members:\n'
        echo "$member_states" | while IFS= read -r line; do
          [[ -n "$line" ]] && printf '           %s\n' "$line"
        done
      fi
    else
      _sc_fail "Replica set status: could not retrieve"
    fi

    # 3c. Replication lag ────────────────────────────────────────────────────
    _sc_section "Layer 3b: Replication Lag"
    printf '           Reference thresholds: WARN ≥ %ds  |  CRIT ≥ %ds\n' \
      "$LAG_WARN_SECONDS" "$LAG_CRIT_SECONDS"
    printf '           (MongoDB Atlas default alert: 10 s warn / 60 s crit)\n'

    local lag_r
    lag_r=$(mongo_rs_lag 2>/dev/null)
    if [[ "$(_json_status "$lag_r")" == "success" ]]; then
      local lag_vals member_names state_strs
      lag_vals=$(echo "$lag_r" | grep -o '"lagSeconds":[^,}]*' | cut -d':' -f2 | tr -d ' ' || true)
      member_names=$(echo "$lag_r" | grep -o '"member":"[^"]*"' | cut -d'"' -f4 || true)
      state_strs=$(echo "$lag_r" | grep -o '"stateStr":"[^"]*"' | cut -d'"' -f4 || true)

      local any_lag_fail=false any_lag_warn=false max_lag=0 max_lag_member=""
      local members_arr=() states_arr=() lags_arr=()
      while IFS= read -r m; do members_arr+=("$m"); done <<< "$member_names"
      while IFS= read -r s; do states_arr+=("$s"); done <<< "$state_strs"
      while IFS= read -r l; do lags_arr+=("$l"); done <<< "$lag_vals"

      local idx=0
      for lv in "${lags_arr[@]:-}"; do
        local mem="${members_arr[$idx]:-unknown}" st="${states_arr[$idx]:-?}"
        idx=$(( idx + 1 ))
        [[ "$lv" == "null" || -z "$lv" ]] && continue
        if (( lv > max_lag )); then
          max_lag=$lv; max_lag_member="$mem"
        fi
        local lag_label
        if (( lv >= LAG_CRIT_SECONDS )); then
          lag_label="⚠⚠ CRITICAL"; any_lag_fail=true
        elif (( lv >= LAG_WARN_SECONDS )); then
          lag_label="⚠ WARNING"; any_lag_warn=true
        else
          lag_label="OK"
        fi
        printf '           %-30s  [%s]  lag: %ds  %s\n' "$mem" "$st" "$lv" "$lag_label"
      done

      if $any_lag_fail; then
        _sc_fail "Replication lag: max ${max_lag}s on '${max_lag_member}' (critical >= ${LAG_CRIT_SECONDS}s)" \
          "Secondary is severely behind; risk of oplog rollover and stale reads"
      elif $any_lag_warn; then
        _sc_warn "Replication lag: max ${max_lag}s on '${max_lag_member}' (warn >= ${LAG_WARN_SECONDS}s)" \
          "Secondary is falling behind; investigate replication throughput"
      else
        _sc_pass "Replication lag: all members within acceptable range (< ${LAG_WARN_SECONDS}s)"
      fi
    else
      _sc_warn "Replication lag: could not retrieve"
    fi

    # 3d. Oplog window ────────────────────────────────────────────────────────
    _sc_section "Layer 3c: Oplog Window"
    printf '           Reference thresholds: WARN < %sd  |  CRIT < %sd\n' \
      "$OPLOG_WARN_DAYS" "$OPLOG_CRIT_DAYS"
    printf '           (MongoDB recommendation: oplog window ≥ 72 h / 3 days)\n'

    local oplog_r
    oplog_r=$(mongo_oplog_status 2>/dev/null)
    if [[ "$(_json_status "$oplog_r")" == "success" ]]; then
      local window_days size_mb used_mb
      window_days=$(_json_field "$oplog_r" "windowDays")
      size_mb=$(_json_field "$oplog_r" "sizeMB")
      used_mb=$(_json_field "$oplog_r" "usedMB")
      window_days="${window_days:-0}"
      printf '           Oplog size: %sMB  |  Used: %sMB  |  Window: %s days\n' \
        "$size_mb" "$used_mb" "$window_days"

      local below_crit below_warn
      below_crit=$(awk "BEGIN{print ($window_days < $OPLOG_CRIT_DAYS) ? 1 : 0}" 2>/dev/null || echo "0")
      below_warn=$(awk  "BEGIN{print ($window_days < $OPLOG_WARN_DAYS) ? 1 : 0}" 2>/dev/null || echo "0")
      if [[ "$below_crit" == "1" ]]; then
        _sc_fail "Oplog window: ${window_days} days — BELOW critical minimum ${OPLOG_CRIT_DAYS} day(s)" \
          "Point-in-time recovery and backup windows are severely impacted"
      elif [[ "$below_warn" == "1" ]]; then
        _sc_warn "Oplog window: ${window_days} days — below recommended ${OPLOG_WARN_DAYS} days ⚠" \
          "Increase oplog size: replSetResizeOplog or deploy larger storage"
      else
        _sc_pass "Oplog window: ${window_days} days (>= ${OPLOG_WARN_DAYS} days recommended)"
      fi
    else
      _sc_warn "Oplog status: could not retrieve (may not be a replica set)"
    fi

  else
    if [[ "$STANDALONE_OK" == "1" ]]; then
      _sc_warn "Standalone mode: RS checks (member health, lag, oplog) skipped (STANDALONE_OK=1)"
    else
      _sc_warn "RS checks skipped: node is not a replica set member" \
        "Set STANDALONE_OK=1 to suppress this warning"
    fi
  fi

  # 3e. WiredTiger cache ───────────────────────────────────────────────────────
  _sc_section "Layer 3d: WiredTiger Cache"
  printf '           Reference thresholds: WARN ≥ %d%%  dirty  |  CRIT ≥ %d%%  dirty\n' \
    "$WT_CACHE_WARN_PERCENT" "$WT_CACHE_CRIT_PERCENT"

  if $srv_ok; then
    local wt_js
    wt_js=$(cat <<'JSEOF'
(function(){
  var s = db.adminCommand({serverStatus:1, wiredTiger:1, repl:0, metrics:0, locks:0});
  if (!s.wiredTiger) return JSON.stringify({error:"wiredTiger not available"});
  var cache = s.wiredTiger.cache;
  var max   = cache["maximum bytes configured"] || 0;
  var inUse = cache["bytes currently in the cache"] || 0;
  var dirty = cache["tracked dirty bytes in the cache"] || 0;
  var usePct   = max > 0 ? Math.round(inUse / max * 100) : 0;
  var dirtyPct = max > 0 ? Math.round(dirty / max * 100) : 0;
  return JSON.stringify({
    maxMB:    Math.round(max   / 1024 / 1024),
    inUseMB:  Math.round(inUse / 1024 / 1024),
    dirtyMB:  Math.round(dirty / 1024 / 1024),
    usePct:   usePct,
    dirtyPct: dirtyPct
  });
})()
JSEOF
)
    local wt_out
    wt_out=$(_mongosh_eval "admin" "$wt_js" 2>/dev/null) || wt_out=""
    if [[ -n "$wt_out" && "$wt_out" != *'"error"'* ]]; then
      local wt_max wt_in_use wt_dirty wt_use_pct wt_dirty_pct
      wt_max=$(echo "$wt_out" | grep -o '"maxMB":[0-9]*' | cut -d':' -f2)
      wt_in_use=$(echo "$wt_out" | grep -o '"inUseMB":[0-9]*' | cut -d':' -f2)
      wt_dirty=$(echo "$wt_out" | grep -o '"dirtyMB":[0-9]*' | cut -d':' -f2)
      wt_use_pct=$(echo "$wt_out" | grep -o '"usePct":[0-9]*' | cut -d':' -f2)
      wt_dirty_pct=$(echo "$wt_out" | grep -o '"dirtyPct":[0-9]*' | cut -d':' -f2)
      wt_use_pct="${wt_use_pct:-0}"; wt_dirty_pct="${wt_dirty_pct:-0}"
      printf '           Cache: total %sMB  |  in-use %sMB (%s%%)  |  dirty %sMB (%s%%)\n' \
        "${wt_max:-?}" "${wt_in_use:-?}" "$wt_use_pct" "${wt_dirty:-?}" "$wt_dirty_pct"
      if (( wt_dirty_pct >= WT_CACHE_CRIT_PERCENT )); then
        _sc_fail "WiredTiger cache: ${wt_dirty_pct}% dirty (critical >= ${WT_CACHE_CRIT_PERCENT}%)" \
          "High dirty cache causes eviction pressure and write stalls"
      elif (( wt_dirty_pct >= WT_CACHE_WARN_PERCENT )); then
        _sc_warn "WiredTiger cache: ${wt_dirty_pct}% dirty (warn >= ${WT_CACHE_WARN_PERCENT}%)" \
          "Consider increasing cache size (wiredTigerCacheSizeGB)"
      else
        _sc_pass "WiredTiger cache: ${wt_dirty_pct}% dirty pages (OK < ${WT_CACHE_WARN_PERCENT}%)"
      fi
    else
      _sc_warn "WiredTiger cache: could not retrieve stats"
    fi
  else
    _sc_warn "WiredTiger cache: serverStatus unavailable"
  fi

  # 3f. Connection utilisation ─────────────────────────────────────────────────
  _sc_section "Layer 3e: Connection Utilisation"
  printf '           Reference thresholds: WARN ≥ %d%%  |  CRIT ≥ %d%% of available connections\n' \
    "$CONN_WARN_PERCENT" "$CONN_CRIT_PERCENT"

  if $srv_ok; then
    local conn_current conn_available
    conn_current=$(echo "$srv_r" | grep -o '"current":[0-9]*' | head -1 | cut -d':' -f2)
    conn_available=$(echo "$srv_r" | grep -o '"available":[0-9]*' | head -1 | cut -d':' -f2)
    conn_current="${conn_current:-0}"; conn_available="${conn_available:-0}"
    local conn_total=$(( conn_current + conn_available ))
    local conn_pct=0
    if (( conn_total > 0 )); then
      conn_pct=$(( conn_current * 100 / conn_total ))
    fi
    printf '           Connections: current %s  |  available %s  |  total capacity %s  |  utilisation %s%%\n' \
      "$conn_current" "$conn_available" "$conn_total" "$conn_pct"
    if (( conn_pct >= CONN_CRIT_PERCENT )); then
      _sc_fail "Connection utilisation: ${conn_pct}% (critical >= ${CONN_CRIT_PERCENT}%)" \
        "New connections may be refused; check connection pool settings"
    elif (( conn_pct >= CONN_WARN_PERCENT )); then
      _sc_warn "Connection utilisation: ${conn_pct}% (warn >= ${CONN_WARN_PERCENT}%)" \
        "Consider increasing maxIncomingConnections or reducing pool size"
    else
      _sc_pass "Connection utilisation: ${conn_pct}% (${conn_current}/${conn_total}) OK"
    fi
  else
    _sc_warn "Connection utilisation: serverStatus unavailable"
  fi

  # 3g. Global lock queue ──────────────────────────────────────────────────────
  _sc_section "Layer 3f: Global Lock Queue"

  if $srv_ok; then
    local lock_queue_total
    lock_queue_total=$(echo "$srv_r" | \
      grep -o '"currentQueue":{[^}]*}' | head -1 | \
      grep -o '"total":[0-9]*' | head -1 | cut -d':' -f2)
    lock_queue_total="${lock_queue_total:-0}"
    if (( lock_queue_total > LOCK_QUEUE_FAIL )); then
      _sc_fail "Global lock queue depth: ${lock_queue_total} operations waiting (crit > ${LOCK_QUEUE_FAIL})" \
        "Severe lock contention; check for long-running write operations"
    elif (( lock_queue_total > LOCK_QUEUE_WARN )); then
      _sc_warn "Global lock queue depth: ${lock_queue_total} operations waiting (warn > ${LOCK_QUEUE_WARN})" \
        "Some lock contention detected; monitor long-running operations"
    else
      _sc_pass "Global lock queue depth: ${lock_queue_total} (OK, threshold warn>${LOCK_QUEUE_WARN} fail>${LOCK_QUEUE_FAIL})"
    fi
  else
    _sc_warn "Global lock queue: serverStatus unavailable"
  fi

  # 3h. Long-running operations ────────────────────────────────────────────────
  _sc_section "Layer 3g: Long-Running Operations"
  printf '           Threshold: operations running > %ds\n' "$MAX_LONG_OP_SECONDS"

  local op_r
  op_r=$(mongo_current_op $(( MAX_LONG_OP_SECONDS * 1000 )) 2>/dev/null)
  if [[ "$(_json_status "$op_r")" == "success" ]]; then
    local long_op_count
    long_op_count=$(echo "$op_r" | grep -o '"opid"' | wc -l || echo "0")
    long_op_count="${long_op_count//[[:space:]]/}"
    if [[ "$long_op_count" -gt 0 ]]; then
      _sc_warn "Long-running operations: $long_op_count op(s) running > ${MAX_LONG_OP_SECONDS}s" \
        "Consider killing with db.killOp(opid) if blocking"
    else
      _sc_pass "Long-running operations: none running > ${MAX_LONG_OP_SECONDS}s"
    fi
  else
    _sc_warn "Long-running operations: could not retrieve"
  fi
}

# =============================================================================
# mongo_resolve_primary
#
# Given any reachable MongoDB FQDN (host:port), return the primary's host and
# port via the isMaster response.
#
# Usage:
#   mongo_resolve_primary <seed_host> <seed_port> <user> <pass> <authdb>
#
# Outputs (to stdout, one per line):
#   <primary_host>
#   <primary_port>
#
# If the node is standalone (no RS / isMaster.primary is null), the seed host
# and port are echoed back unchanged.
# Returns 1 on connection failure.
# =============================================================================
mongo_resolve_primary() {
  local seed_host="${1:?seed_host required}"
  local seed_port="${2:-27017}"
  local user="${3:-}"
  local pass="${4:-}"
  local authdb="${5:-admin}"

  local uri
  if [[ -n "$user" && -n "$pass" ]]; then
    uri="mongodb://${user}:${pass}@${seed_host}:${seed_port}/${authdb}?authSource=${authdb}&connectTimeoutMS=5000&serverSelectionTimeoutMS=5000"
  else
    uri="mongodb://${seed_host}:${seed_port}/${authdb}?connectTimeoutMS=5000&serverSelectionTimeoutMS=5000"
  fi

  local raw
  raw=$(mongosh --quiet --norc --eval \
    'JSON.stringify(db.adminCommand({isMaster:1}))' \
    "$uri" 2>/dev/null) || return 1

  # Extract the "primary" field: "host:port" or absent/null on standalone
  local primary
  primary=$(printf '%s' "$raw" | grep -o '"primary":"[^"]*"' | head -1 | sed 's/"primary":"//;s/"//')

  if [[ -z "$primary" || "$primary" == "null" ]]; then
    # Standalone — return seed values unchanged
    printf '%s\n%s\n' "$seed_host" "$seed_port"
    return 0
  fi

  # primary is "host:port"
  local p_host p_port
  p_host="${primary%:*}"
  p_port="${primary##*:}"
  printf '%s\n%s\n' "$p_host" "${p_port:-27017}"
}
