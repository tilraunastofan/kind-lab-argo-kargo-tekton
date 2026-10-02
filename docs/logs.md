# Cluster logs: ClickHouse + ClickStack

All container logs from the cluster are shipped by Vector (`gitops/apps/vector.yaml`,
namespace `logging`) to a container on the Mac named `clickhouse-logs`. It runs
ClickStack's all-in-one image (`clickhouse/clickstack-all-in-one`): a ClickHouse server,
the ClickStack (HyperDX) web UI, MongoDB for the UI's state, and an OTel collector.
Optional, off by default (`LOGS_ENABLED=true` to opt in; see README). Start or repair it with `task logs-db:up` (run by `task cluster:up` only when enabled).

| What | Where |
|---|---|
| ClickStack UI | **http://localhost:8080** (use `localhost`, not `clickhouse-logs.orb.local`: the UI's login cookies are bound to `localhost`) |
| ClickHouse HTTP | `http://127.0.0.1:8123` (from the Mac), `http://clickhouse-logs:8123` (from pods) |
| Play UI (plain SQL box) | `http://127.0.0.1:8123/play` |
| Logs table | `logs.logs` (14-day TTL) |
| Query as admin | `source ~/.tokens; docker exec -it clickhouse-logs clickhouse-client --user admin --password "$CLICKHOUSE_LOGS_ADMIN_PASSWORD"` |

## ClickHouse users

| User | Password | Can do |
|---|---|---|
| `admin` | `CLICKHOUSE_LOGS_ADMIN_PASSWORD` in `~/.tokens` | everything (from any address) |
| `vector` | `CLICKHOUSE_LOGS_VECTOR_PASSWORD` in `~/.tokens` | `INSERT` into `logs.logs` only |
| `default`, `api`, `worker` | built into the image | **localhost only** (ClickStack's own processes). The image ships `api/api` and `worker/worker` open to any address; `scripts/clickhouse-logs/users.xml.tmpl` pins them to localhost. There is no `default` login for you. |

Users are defined in `scripts/clickhouse-logs/users.xml.tmpl` (rendered to
`~/.local/state/tekton-lab/clickhouse-logs/lab-users.xml` and mounted), not with SQL,
because the bundled `default` user can't `CREATE USER`.

## First use of the ClickStack UI

1. Open http://localhost:8080 and **create an account** (any email/password; it is stored
   only in the local MongoDB volume).
2. Run `scripts/clickstack-source-up.sh` (`task logs-db:up` does it too). It adds a
   **Cluster logs** source for the custom table `logs.logs`; pick it in *Search*. Without
   it, Search queries the UI's built-in `default.otel_logs` table, which stays empty here
   (our logs don't go through the OpenTelemetry collector), so you see no results.
   The image hard-codes its default sources and ignores env overrides, so the script writes
   the source straight into the UI's MongoDB, copying the built-in "Logs" source's
   structure. It needs the account from step 1 (that creates the team the source belongs
   to) and is safe to re-run; it re-applies its settings each time.

   Field mapping: timestamp → `timestamp`, body → `message`, service → `container`,
   resource attributes → `labels` (pod labels), event attributes → `fields` (keys of JSON
   log lines), severity → the JSON `level` field if present, else `info`.

Other ways in, no setup (no UI account needed): `http://127.0.0.1:8123/play` (login `admin`), or
`clickhouse-client` as above.

## Notes

- **Data volumes**: `clickstack-ch-data` (ClickHouse) and `clickstack-mongo-data` (UI state)
  survive `task cluster:down`. The previous plain-ClickHouse volume `clickhouse-logs-data`
  is no longer used but was deliberately not deleted (`docker volume rm clickhouse-logs-data`
  once you don't need its old logs): the image now bundles ClickHouse 26.8 and that data was
  written by 26.9, which ClickHouse can't downgrade.
- **Why `logs.logs` and not `otel_logs`**: Vector writes with a ClickHouse login so
  `cluster:up` needs no manual step. ClickStack's native path (OTLP into the collector)
  needs an ingestion API key that only exists after the first UI account is created.
- Logs written while the container was being replaced are not replayed.
