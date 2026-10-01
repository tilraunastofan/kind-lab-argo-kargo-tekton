-- Applied by scripts/clickhouse-logs-up.sh on EVERY run, so everything here
-- must be idempotent.

CREATE DATABASE IF NOT EXISTS logs;

CREATE TABLE IF NOT EXISTS logs.logs
(
    timestamp DateTime64(3, 'UTC'),
    namespace LowCardinality(String),
    pod       String,
    container LowCardinality(String),
    node      LowCardinality(String),
    stream    LowCardinality(String),
    message   String,
    labels    Map(String, String),
    -- Top-level keys of the log line when it is a JSON object, values
    -- stringified (nested objects/arrays as JSON text). Empty otherwise.
    fields    Map(String, String)
)
ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (namespace, pod, timestamp)
TTL toDateTime(timestamp) + INTERVAL 14 DAY;

-- Users (admin, vector, and the locked-down bundled api/worker) are defined in
-- scripts/clickhouse-logs/users.xml.tmpl, not here: the ClickStack image's
-- `default` user is localhost-only and cannot CREATE USER.
