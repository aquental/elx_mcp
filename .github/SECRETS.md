# GitHub Actions Secrets (Option C)

Configure under **Settings → Secrets and variables → Actions** (or via `gh`).

## Required

| Secret | Used by | Description |
|--------|---------|-------------|
| `DB_PASSWORD` | `.github/workflows/ci.yml` | Password for the CI Postgres **service container** user `elx_mcp_dev`. **Not** the hermes production password. |

## Optional

| Secret | Description |
|--------|-------------|
| `SECRET_KEY_BASE` | Not required for `mix test` today (`config/test.exs` sets the endpoint key). Reserve for future release/deploy jobs. |
| `ELX_MCP_BACKUP_PASSPHRASE` | Future jobs that run encrypted backups. |

## Create secrets (CLI)

```bash
# Generate a CI-only DB password (do not reuse hermes prod password)
openssl rand -base64 24 | tr -d '/+=' | gh secret set DB_PASSWORD

# Optional prod-like key for future deploy workflows
mix phx.gen.secret | gh secret set SECRET_KEY_BASE
```

List:

```bash
gh secret list
```

## Design notes

- CI uses **Postgres 16 in Docker** on the runner (`localhost:5432`), with `DB_SSL=false`.
- **hermes** stays out of CI (IP allowlist / no public exposure). Production secrets never need to be the same as `DB_PASSWORD` in Actions.
- The app already loads config from env via `config/runtime.exs` — no SDK required.

## Local parity (optional)

```bash
export DB_USER=elx_mcp_dev
export DB_PASSWORD='your-ci-style-password'
export DB_HOST=localhost
export DB_PORT=5432
export DB_NAME_TEST=elx_mcp_test
export DB_SSL=false
export MIX_ENV=test
# docker run ... postgres with matching user/password
mix test
```
