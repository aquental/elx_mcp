# Code Review: RLS triage fixes

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 8 (1 BLOCKER, 4 WARNING, 3 SUGGESTION)
- **Focus**: NEW code in Repo tenant hygiene, SECDEF re-ownership migrations, attachment path, docs/tests

---

## BLOCKER

1. **`priv/repo/migrations/20260802171043_rls_bypassrls_owner.exs:35-36,274`** — `@app_role` hardcoded to `"elx_mcp_dev"`

   `GRANT EXECUTE … TO elx_mcp_dev` only. Plan (W1) and `spec/DB_SEC.md` describe a future/prod app role (`elx_mcp_app`) and least-privilege EXECUTE for “the app role”. On any cluster where the migrator/runtime role is not literally `elx_mcp_dev`, SECDEF helpers become uncallable after ownership transfer (owner is `elx_mcp_secdef`; PUBLIC revoked).

   ```elixir
   # Suggested
   @app_role System.get_env("DB_APP_ROLE") || System.get_env("DB_USER") || "elx_mcp_dev"
   # or grant EXECUTE TO CURRENT_USER inside the SET LOCAL ROLE block
   EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', sig, current_user);
   ```

   Prefer granting to `CURRENT_USER` (migrator) and/or a configurable role name so CI, hermes, and prod stay portable.

---

## WARNING

1. **`lib/elx_mcp/repo.ex:64-77`** — Nested different-tenant restore still runs SQL in `after`

   Outer (depth 0) correctly clears GUC *outside* the nested TX (B1). Nested path with a **different** `project_id` still calls `set_tenant_guc!(prev)` in `after`. If `fun` aborts the open TX (`Postgrex.Error` / failed query), restore SQL runs against an aborted transaction and can raise/mask the original error — same class as B1, narrower surface (only cross-tenant nesting).

   ```elixir
   # Suggested sketch
   try do
     fun.()
   after
     Process.put(@project_key, prev) # or delete
     # only restore GUC if connection TX is still usable; else rely on outer clear / savepoint rollback
     _ = safe_set_tenant_guc(prev) # rescue DBError
   end
   ```

2. **`lib/elx_mcp/repo.ex:46-57`** — `safe_clear_tenant_guc` not reached on re-raise

   `Repo.transaction/1` re-raises exceptions (does not return `{:error, _}`). On that path, `safe_clear_tenant_guc()` is skipped; only process-dict cleanup in `after` runs. Under Sandbox, savepoint rollback usually undoes `SET LOCAL`, so isolation tests pass — but the intentional Sandbox clear is success/`{:error, rollback}` only. Prefer `try/after` around the transaction so clear always attempts when `depth == 0` (keep bare-ish rescue on clear only).

3. **`lib/elx_mcp/repo.ex:100-110`** — Bare `rescue _ -> :ok` in `safe_clear_tenant_guc/0`

   Intentional B1 hygiene, but swallows all exceptions (including unexpected `DBConnection` / coding errors). Narrow to `Postgrex.Error` / `DBConnection.Error` (or match aborted-tx messages) so real bugs surface.

4. **`test/elx_mcp/rls_test.exs:154-169`** — SECDEF-in-TX isolation soft-skips without `elx_mcp_secdef`

   `if secdef_bypassrls_role?() … else :ok` can green-pass on a cluster that never applied the BYPASSRLS bootstrap. Prefer `flunk/1` or `@tag :requires_secdef` + CI gate so B3 coverage cannot silently disappear.

---

## SUGGESTION

1. **`priv/repo/migrations/20260802170000_rls_harden_local_guc_secdef.exs:249-250`** — Intermediate `GRANT EXECUTE … TO PUBLIC`

   Superseded by `20260802171043`, but any stop between migrations leaves PUBLIC EXECUTE on SECDEF. Acceptable archaeology; document “migrate fully” in ops notes if not already.

2. **`priv/repo/migrations/20260802170100_secdef_row_security_off.exs:21-23`** — `down/0` is `:ok`

   Irreversible intermediate (re-introduces bypass GUC). Final migration’s `down` restores v1.9 shape; fine if intentional — one-line `@moduledoc` “not reversible alone” would help operators.

3. **`lib/elx_mcp/projects.ex:337-345` + MCP `with_scope`** — Double `with_tenant` nesting is fine (same project short-circuit) but every collab/project call under MCP pays depth bookkeeping twice. Optional later: document that contexts own tenant and MCP need not wrap, or vice versa — not a correctness bug.

---

## Pre-existing (out of deep scope)

- `lib/elx_mcp/auth.ex:129` — `get_api_key!/1` SECDEF, no tenant/authz (admin surface).
- `lib/elx_mcp/tenancy.ex:18` — `list_projects/0` SECDEF lists all projects (bootstrap).
- `lib/elx_mcp/collaboration.ex:40` — `list_comments` does not verify entity membership (tenant-only).

---

## Verified OK (no issue)

| Area | Notes |
|------|--------|
| B1 clear outside nested TX | `repo.ex:46-57` — clear after `transaction/1` returns |
| Process dict hygiene | `after` restores depth / deletes project key at depth 0 |
| Policies UUID-only | `20260802171043` drops `app.bypass_rls` hatch |
| SECDEF owner BYPASSRLS | re-own + `SET LOCAL ROLE` for GRANT/REVOKE after OWNER TO |
| Manual role SQL | `priv/repo/manual/create_elx_mcp_secdef_role.sql` + CREATE on schema |
| `storage_path` | removed from cast; server-side path in `Collaboration.create_attachment` |
| `increment_time_spent` | `@doc false`; still tenant-wrapped; collab Multi-safe |
| `create_project` | `Repo.rollback(cs)` preserves `{:error, %Ecto.Changeset{}}` |
| `after_connect` | wired in `runtime.exs:277`; session-level empty GUC |
| Tests | nested same/different tenant, storage_path ignore, B1 duplicate key, WITH CHECK samples |

---

## Priority fix order

1. Make EXECUTE grant role portable (BLOCKER).
2. Harden nested different-tenant GUC restore + optional always-clear on depth 0 (WARNINGs 1–2).
3. Narrow rescue; fail tests when secdef role missing in CI (WARNINGs 3–4).
