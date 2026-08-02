# Consolidated Summary

**Strategy**: Index (under 8k; BLOCKER/WARNING kept in full per priority)
**Input**: 5 files, ~5.3k tokens
**Output**: ~2.8k tokens (~47% reduction)
**Sources**: `elixir.md`, `iron-laws.md`, `requirements.md`, `security.md`, `testing.md`

## Overall verdict

| Reviewer | Verdict |
|---|---|
| elixir-reviewer | ⚠️ Changes requested — 1 BLOCKER, 4 WARNING, 3 SUGGESTION |
| iron-law-judge | Clean on focus laws; 1 medium SUGGESTION only |
| security | Medium residual risk; 0 critical; several WARNINGs |
| testing | PASS WITH WARNINGS — suite green but soft-gates / gaps |
| requirements | **28 MET · 3 PARTIAL · 0 UNMET · 1 UNCLEAR** |

---

## BLOCKER findings (KEEP ALL)

1. **Hardcoded EXECUTE grant to `elx_mcp_dev` only**  
   - **Files**: `priv/repo/migrations/20260802171043_rls_bypassrls_owner.exs:35-36,274`  
   - **Issue**: `GRANT EXECUTE … TO elx_mcp_dev` only. Plan W1 / `spec/DB_SEC.md` expect portable app role (`elx_mcp_app`). Clusters where migrator/runtime ≠ `elx_mcp_dev` lose SECDEF callability after ownership transfer (owner `elx_mcp_secdef`; PUBLIC revoked).  
   - **Fix**: `@app_role` from env / grant `CURRENT_USER` inside `SET LOCAL ROLE` / configurable role list; never re-grant PUBLIC.  
   - **Found by**: elixir-reviewer (BLOCKER), security (WARNING — same issue; elevating to elixir BLOCKER)

---

## WARNING findings (KEEP ALL)

### Repo / tenant GUC (`lib/elx_mcp/repo.ex`)

1. **Nested different-tenant restore still runs SQL in `after`** (`repo.ex:64-77`)  
   Cross-tenant nest restores via `set_tenant_guc!(prev)` in `after`. If `fun` aborts the TX, restore SQL can raise/mask original error (narrower B1 class). Prefer safe restore or skip when TX unusable.  
   - **Found by**: elixir-reviewer

2. **`safe_clear_tenant_guc` not reached on re-raise** (`repo.ex:46-57`)  
   `Repo.transaction/1` re-raises; clear only on success/`{:error, rollback}`. Sandbox savepoints often hide this. Prefer `try/after` so depth-0 clear always attempts.  
   - **Found by**: elixir-reviewer

3. **Bare `rescue _ -> :ok` in `safe_clear_tenant_guc/0`** (`repo.ex:100-110`)  
   Swallows all exceptions. Narrow to `Postgrex.Error` / `DBConnection.Error` (or aborted-tx messages).  
   - **Found by**: elixir-reviewer

### Security / migration privilege

4. **App role membership of BYPASSRLS secdef**  
   - **Files**: `…_rls_bypassrls_owner.exs:67-68,86-91,271`; `create_elx_mcp_secdef_role.sql:9`  
   - **Issue**: `GRANT elx_mcp_secdef TO elx_mcp_dev` persists. With `NOINHERIT`, session can still `SET ROLE elx_mcp_secdef` → **BYPASSRLS** + `SELECT/UPDATE` all `api_keys` (incl. `key_hash`) + `SELECT` all projects.  
   - **Fix**: After OWNER TO + EXECUTE grants, **`REVOKE elx_mcp_secdef FROM <app_role>`** if runtime reown unnecessary.  
   - **Found by**: security

5. **Hardcoded EXECUTE target `elx_mcp_dev`** (same as BLOCKER; security severity Medium)  
   - **Found by**: security (see BLOCKER for fix)

6. **`down/0` restores client-settable bypass hatch**  
   - **Files**: `…_rls_bypassrls_owner.exs:45-49,302-358`  
   - Rollback reintroduces `app.bypass_rls` in policies — full tenant bypass if client can `set_config`. Intentional for W7; dangerous on shared/prod. Document “do not down in prod” or make irreversible.  
   - **Found by**: security

7. **Permanent `CREATE` on `public` for secdef**  
   - **Files**: migration `:101`; `create_elx_mcp_secdef_role.sql:13`  
   - `GRANT USAGE, CREATE ON SCHEMA public` left after ownership. Combined with SET ROLE, secdef can create objects in `public`.  
   - **Fix**: After transfer, `REVOKE CREATE ON SCHEMA public FROM elx_mcp_secdef`.  
   - **Found by**: security

### Tests

8. **SECDEF-in-TX soft-skip when role missing** (`rls_test.exs:154-170`)  
   `if secdef_bypassrls_role? … else :ok` green-passes without B3. Prefer `@tag :requires_secdef` + CI gate or `flunk/1`.  
   - **Found by**: elixir-reviewer, testing (deduped)

9. **W8 missing-project → unauthorized untested** (`auth_test.exs`)  
   Doc claims behavior; zero coverage for key whose `project_id` no longer resolves.  
   - **Found by**: testing

10. **Search rank order only partially asserted** (`projects_test.exs:126-144`)  
    Claims exact > prefix > title; only asserts `hd == exact`. Strengthen relative order of prefix vs title-only.  
    - **Found by**: testing

11. **B1 not covered for raised SQL abort** (`rls_test.exs:172-180` vs WITH CHECK cases)  
    Rollback+changeset covered; post-raise GUC/process hygiene not asserted after `assert_raise`.  
    - **Found by**: testing

12. **List limit clamps (W9) untested**  
    `list_comments` / `list_changelog` `1..200` — no tests for `0`, negative, `>200`.  
    - **Found by**: testing

---

## SUGGESTION findings (compressed groups)

### G1 — Migration archaeology / operator docs
- Intermediate `GRANT EXECUTE TO PUBLIC` in `20260802170000` (superseded); document full migrate.  
- Intermediate `down/0` is `:ok` on `20260802170100` — note “not reversible alone”.  
- **Found by**: elixir-reviewer

### G2 — Nested `with_tenant` / double wrap
- MCP + context double `with_tenant` pays depth twice (same-project short-circuit OK) — document ownership.  
- Nested restore when `prev == nil` may leave residual GUC — clear to empty.  
- **Found by**: elixir-reviewer, security

### G3 — Attachment / cast consistency
- Drop `:uploaded_by_email` from cast (mirror Comment); current `put_change` path safe.  
- **Found by**: security

### G4 — SECDEF bootstrap surface (by design)
- Auth/tenancy SECDEF list/get remain cross-tenant admin; keep mix-only; optional redact `key_hash`.  
- **Found by**: security (also elixir pre-existing notes)

### G5 — Iron law #19: triage IDs in source comments  
- **Prefer iron-law-judge over general style notes**  
- Production: `repo.ex:43-45` `(B1)`, `tenancy.ex:75-77` `(B1)`, `projects.ex:334-335` `(W3)`, `attachment.ex:36` `(W4)` — keep durable text, drop issue tags.  
- Tests referencing B1/B2/… lower priority.  
- **Found by**: iron-law-judge

### G6 — Test polish
- Update stale B3 else-branch comment (hatch model removed post-B2).  
- `record_changelog` foreign-entity symmetry; split `ensure_entity` describes; raw SQL inside nested same-tenant; list_attachments API later.  
- **Found by**: testing

---

## Iron laws (focus) — clean

Pinned queries, no `String.to_atom` on input, no `raw/1`, no money float, no LiveView `handle_event` auth gap, bare `{:error,_}` not swallowing changesets on paths reviewed.  
**Found by**: iron-law-judge

---

## Requirements coverage summary

| Bucket | Count | Notes |
|---|---|---|
| **MET** | 28 | B1–B5; W1–W11, W13–W14; most P0–P4 tasks |
| **PARTIAL** | 3 | **W12** — no direct `Projects.increment_time_spent` → `:not_found` / insert-rollback unit; **P2-T2** — cluster apply/ACL smoke not verifiable from diff; **P3-T2** — inherits W12 partial |
| **UNMET** | 0 | — |
| **UNCLEAR** | 1 | **P4-T1** — claimed 94 tests; no compile/test log in DIFF_FILES |

Cross-review tension: requirements mark **W1 MET** (GRANT to `elx_mcp_dev` present) while elixir/security flag hardcoded grantee as **BLOCKER / WARNING** for portability — treat W1 implementation as present but incomplete for prod role portability.

---

## Priority fix order (merged)

1. **BLOCKER**: Portable EXECUTE grantee(s) (`CURRENT_USER` / env / `elx_mcp_app`).  
2. **Security**: Evaluate `REVOKE elx_mcp_secdef FROM app` + `REVOKE CREATE ON SCHEMA public FROM secdef` post-migrate.  
3. **Repo WARNINGs**: Nested different-tenant restore; always-clear on depth 0 re-raise; narrow rescue.  
4. **Ops**: Never `down` this migration on shared/prod (or make irreversible).  
5. **Tests**: Fail/tag missing secdef for B3; add W8 missing-project; rank order; raise-path B1 hygiene; W9 limit clamps.  
6. **Hygiene**: Drop `(B1)`/`(W*)` tags from lib comments (iron-law #19).

---

## Coverage

| File | Represented | Key items |
|---|---|---|
| elixir.md | Yes | 1 BLOCKER, 4 WARNING, G1–G2 SUGGESTION groups |
| iron-laws.md | Yes | Clean focus laws; G5 comment-tag SUGGESTION |
| requirements.md | Yes | 28 MET / 3 PARTIAL / 0 UNMET / 1 UNCLEAR |
| security.md | Yes | 4 WARNING (priv/grants/down/CREATE), G3–G4 SUGGESTIONS |
| testing.md | Yes | 5 WARNING (soft-skip, W8, rank, B1 raise, W9), G6 |

## Coverage Gaps

_None — all 5 input files represented._
