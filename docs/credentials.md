# Lab credentials

Generated credentials live in `~/.tokens` (mode 600, never committed) and are created on
first use by `ensure_token` in `scripts/lib.sh`. Show one with
`source ~/.tokens; echo "$NAME"`.

| What | Variable | Where it is used | Set up by |
|---|---|---|---|
| ArgoCD `admin` password | `ARGOCD_ADMIN_PASSWORD` | https://argocd.tekton-lab.test, username `admin` | `scripts/argocd-admin-up.sh` |
| Kargo `admin` password | `KARGO_ADMIN_PASSWORD` | https://kargo.tekton-lab.test and `kargo login --admin` | `scripts/kargo-admin-up.sh` |
| ClickHouse logs passwords | `CLICKHOUSE_LOGS_ADMIN_PASSWORD`, `CLICKHOUSE_LOGS_VECTOR_PASSWORD` | host ClickHouse/ClickStack (`clickhouse-logs`), see [logs.md](logs.md) | `scripts/clickhouse-logs-up.sh` |
| ClickStack UI account | (chosen by you on first visit to http://localhost:8080) | ClickStack UI | created in the UI |
| Forgejo token | `FORGEJO_TOKEN` | Forgejo API, `git push forgejo` | created by hand |
| GHCR push token | `GHCR_PUSH_TOKEN` | Tekton pushing images (`ghcr-push` Secret) | created by hand, `scripts/ghcr-push-secret-up.sh` |

The two admin-password scripts keep the cluster in sync with the stored value: re-run them
after a rebuild, or if you change/lose a password, and they re-apply it (ArgoCD picks it up
immediately; for Kargo also run `kubectl -n kargo rollout restart deploy kargo-api`).
`bootstrap.sh` runs both automatically.

The one-shot `argocd-initial-admin-secret` that ArgoCD creates on install is deleted by
`argocd-admin-up.sh` (it would only hold a stale password).
