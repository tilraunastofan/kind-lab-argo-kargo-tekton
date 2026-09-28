-- Applied by scripts/clickhouse-logs-up.sh through `envsubst` (only the one
-- variable below is substituted) on EVERY run, so everything here must be
-- idempotent.

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

-- Vector's identity: it can append rows to logs.logs and do nothing else.
-- CREATE USER IF NOT EXISTS + ALTER USER together give "create it, and keep
-- the password in sync with ~/.tokens if that ever changes".
CREATE USER IF NOT EXISTS vector IDENTIFIED WITH sha256_password BY '${CLICKHOUSE_LOGS_VECTOR_PASSWORD}';
ALTER USER vector IDENTIFIED WITH sha256_password BY '${CLICKHOUSE_LOGS_VECTOR_PASSWORD}';
GRANT INSERT ON logs.logs TO vector;
