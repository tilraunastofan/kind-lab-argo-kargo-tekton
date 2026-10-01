#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Adds a "Cluster logs" source to the ClickStack (HyperDX) UI pointing at our
# custom logs.logs table, so Search shows the cluster's logs. The image
# hard-codes sources for its own OpenTelemetry tables (default.otel_logs,
# empty here) and ignores any env override, so this writes the source into the
# UI's MongoDB directly, copying the structure of the built-in "Logs" source.
# Idempotent: does nothing if the source already exists. Needs the UI's first
# account to exist (that is what creates the team the source belongs to) —
# otherwise it skips with a notice; re-run it after registering.
#
# logs.logs columns: timestamp, namespace, pod, container, node, stream,
# message, labels (Map), fields (Map: top-level keys of JSON log lines).

CONTAINER="clickhouse-logs"

main() {
  require_cmd docker

  docker inspect "${CONTAINER}" >/dev/null 2>&1 || die "container ${CONTAINER} not found — run: task logs-db:up"

  local out
  out="$(docker exec -i "${CONTAINER}" mongo --quiet mongodb://db:27017/hyperdx --eval '
    var cfg = {
      from: { databaseName: "logs", tableName: "logs" },
      timestampValueExpression: "timestamp",
      displayedTimestampValueExpression: "timestamp",
      implicitColumnExpression: "message",
      bodyExpression: "message",
      serviceNameExpression: "container",
      // JSON log lines carry their own level; everything else is "info".
      // \x27 = a real single quote (ClickHouse reads double quotes as column names).
      severityTextExpression: "if(fields[\x27level\x27] != \x27\x27, fields[\x27level\x27], \x27info\x27)",
      resourceAttributesExpression: "labels",
      eventAttributesExpression: "fields",
      defaultTableSelectExpression: "timestamp, namespace, pod, container, message"
    };
    var existing = db.sources.findOne({name: "Cluster logs", kind: "log"});
    if (existing) {
      db.sources.updateOne({_id: existing._id}, {$set: Object.assign({updatedAt: new Date()}, cfg)});
      print("EXISTS");
    } else {
      var base = db.sources.findOne({kind: "log", "from.tableName": "otel_logs"});
      if (!base) { print("NO_TEAM"); }
      else {
        var now = new Date();
        db.sources.insertOne(Object.assign({
          kind: "log", name: "Cluster logs", team: base.team, connection: base.connection,
          disabled: false, querySettings: [], materializedViews: [],
          highlightedRowAttributeExpressions: [], highlightedTraceAttributeExpressions: [],
          createdAt: now, updatedAt: now, __v: 0
        }, cfg));
        print("CREATED");
      }
    }')"

  case "${out##*$'\n'}" in
    EXISTS)  log "ClickStack source 'Cluster logs' already exists (settings re-applied)" ;;
    CREATED) log "added ClickStack source 'Cluster logs' (logs.logs) — reload http://localhost:8080 and pick it in Search" ;;
    NO_TEAM) warn "ClickStack has no account yet: open http://localhost:8080, create an account, then re-run scripts/clickstack-source-up.sh" ;;
    *)       die "unexpected response from MongoDB: ${out}" ;;
  esac
}

main "$@"
