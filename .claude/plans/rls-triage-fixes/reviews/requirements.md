## Requirements Coverage (from Plan rls-triage-fixes)

### Blockers (B1–B5)

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| B1 | `with_tenant/2` clear after failed DB ops → `{:error, changeset}` contract | MET | No clear after `fun` inside nested TX `lib/elx_mcp/repo.ex:43-57`; clear outside via `safe_clear_tenant_guc` `:100-110`; regression `test/elx_mcp/rls_test.exs:172-179` |
| B2 | Remove client-settable `app.bypass_rls` from policies; SECDEF owned by BYPASSRLS role | MET | UUID-only policies `priv/repo/migrations/20260802171043_rls_bypassrls_owner.exs:109-150`; SECDEF without set_config bypass `:153-168`; OWNER TO `elx_mcp_secdef` `:252`; no `bypass_rls` in `lib/` |
| B3 | SECDEF SET LOCAL leak for outer TX fixed (no policy hatch) + regression | MET | Fixed via B2 (no hatch) migration `:3-7,:154`; regression `test/elx_mcp/rls_test.exs:154-169` (gated on `elx_mcp_secdef` BYPASSRLS) |
| B4 | Nested `with_tenant` tests (same + different tenant) | MET | Same `test/elx_mcp/rls_test.exs:119-132`; different `:134-152`; impl nest `lib/elx_mcp/repo.ex:59-78` |
| B5 | Collab boundary tests for attachment / worklog / changelog | MET | Write gates `test/elx_mcp/collaboration_test.exs:135-160`; foreign entity `:185-227`; attachment path+isolation `:72-122` |

### Warnings (W1–W14)

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| W1 | REVOKE EXECUTE from PUBLIC; GRANT to app role only | MET | `20260802171043_rls_bypassrls_owner.exs:271-275` REVOKE ALL FROM PUBLIC + GRANT EXECUTE TO `elx_mcp_dev` |
| W2 | Pool `after_connect` GUC hygiene (`app.project_id`) | MET | `lib/elx_mcp/repo.ex:27-29`; wired `config/runtime.exs:277-278` |
| W3 | Unscoped APIs: `@doc false` on `increment_time_spent`; document Auth/Tenancy admin | MET | `@doc false` `lib/elx_mcp/projects.ex:11-12,335-337`; Auth admin notes `auth.ex:9-10,25`; Tenancy SECDEF notes `tenancy.ex:5-6,15-17` |
| W4 | Attachment `storage_path` not cast from client; server-side path | MET | cast omits path `lib/elx_mcp/collaboration/attachment.ex:26-36`; server path `collaboration.ex:65-72`; test ignores client path `collaboration_test.exs:78-91` |
| W5 | Clear process-dict tenant key on TX failure (`after` depth 0) | MET | `lib/elx_mcp/repo.ex:80-85` `Process.delete(@project_key)` in `after` when depth==0 |
| W6 | Load schemas via `Repo.load` for API key + project structs | MET | `lib/elx_mcp/auth.ex:204-214`; `lib/elx_mcp/tenancy.ex:110-119` |
| W7 | Real `down/0` or document irreversible | MET | Implementable `down/0` restores bypass shape `20260802171043_rls_bypassrls_owner.exs:45-49,302+` |
| W8 | `verify_api_key` → `{:error, :unauthorized}` when project missing | MET | `lib/elx_mcp/auth.ex:80,93-94` (`%Project{} = project <- get_project` else unauthorized) |
| W9 | Align limit clamps `list_comments` / `list_changelog` | MET | Both `min(200) \|> max(1)` `collaboration.ex:42,137` |
| W10 | Search rank + `escape_like` tests | MET | Rank `test/elx_mcp/projects_test.exs:126-144`; escape `%`/`_` `:146-166`; SQL ESCAPE `projects.ex:491-536,698-703` |
| W11 | Direct `ensure_entity_in_project` unit tests (negatives) | MET | `test/elx_mcp/projects_test.exs:184-215` |
| W12 | `increment_time_spent` not_found + Multi rollback tests | PARTIAL | Missing-ticket gate + no orphan `collaboration_test.exs:229-254`; Multi path `collaboration.ex:85-109`; **no** direct `Projects.increment_time_spent` → `:not_found` or insert-then-rollback unit test |
| W13 | Attachment row isolation under wrong GUC | MET | `test/elx_mcp/collaboration_test.exs:114-122` |
| W14 | Expand RLS sample (WITH CHECK / second surface) | MET | WITH CHECK mismatched comment insert `test/elx_mcp/rls_test.exs:182-202` |

### Plan tasks (P0–P4)

| # | Requirement | Status | Evidence |
|---|-------------|--------|----------|
| P0-T1 | Spike CREATE ROLE / BYPASSRLS path (b) manual SQL | MET | `priv/repo/manual/create_elx_mcp_secdef_role.sql:1-20`; migration prerequisite docs `:9-15` |
| P1-T1 | Fix `with_tenant` post-fun clear + process-dict (B1, W5) | MET | `lib/elx_mcp/repo.ex:37-110` |
| P1-T2 | `after_connect` + runtime wiring (W2) | MET | `repo.ex:27-29`; `config/runtime.exs:277-278` |
| P1-T3 | Harden unscoped mutator docs (W3) | MET | `projects.ex:335-337`; `auth.ex:1-10`; `tenancy.ex:1-8` |
| P1-T4 | Attachment path + list limit clamps (W4, W9) | MET | `attachment.ex:26-36`; `collaboration.ex:42,65-72,137` |
| P1-T5 | Auth/tenancy Repo.load + missing project + empty scopes (W6, W8) | MET | load helpers above; empty scopes `auth.ex:37-39` + test `auth_test.exs:84-87` |
| P2-T1 | Migration: drop bypass GUC; SECDEF ownership + grants (B2, B3, W1, W7) | MET | `priv/repo/migrations/20260802171043_rls_bypassrls_owner.exs` full up/down |
| P2-T2 | Apply migration on hermes + CI and smoke-check | PARTIAL | Artifacts present (migration + manual SQL + `spec/DB_SEC.md:428-449`); actual cluster apply / ACL smoke not verifiable from diff alone |
| P3-T1 | Nested with_tenant + SECDEF-in-TX + WITH CHECK (B4, B3, W14) | MET | `test/elx_mcp/rls_test.exs:119-202` |
| P3-T2 | Collab boundaries + worklog rollback + attachment isolation (B5, W12, W13) | PARTIAL | B5/W13 MET; W12 only partial (see above) |
| P3-T3 | Search rank/escape + ensure_entity cases (W10, W11) | MET | `test/elx_mcp/projects_test.exs:126-215`; ESCAPE SQL `projects.ex:478-536` |
| P4-T1 | Full verification (`mix compile` / format / test) | UNCLEAR | Claimed 94 passed in plan; no compile/test log in DIFF_FILES — cannot verify from code alone |
| P4-T2 | Update `spec/DB_SEC.md` history v1.10 + residual notes | MET | `spec/DB_SEC.md:408,428-449,469` |

**Summary**: 28 MET · 3 PARTIAL · 0 UNMET · 1 UNCLEAR
