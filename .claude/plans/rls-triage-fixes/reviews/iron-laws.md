# Iron Law Violations Report

## Summary
- Files scanned: 12 (`repo.ex`, `auth.ex`, `tenancy.ex`, `collaboration.ex`, `projects.ex`, `attachment.ex`, migration `20260802171043_rls_bypassrls_owner.exs`, `rls_test.exs`, `collaboration_test.exs`, `projects_test.exs`, `auth_test.exs`, manual secdef SQL)
- Iron Laws checked: 19 of 26 (LiveView #1–3, #11, #17 N/A — no LiveView; Oban #7–9b N/A; Mix #16 N/A)
- Focus laws: unpinned queries, `String.to_atom`, `raw/1`, handle_event auth, money float, bare `{:error, _}` — **all clean**
- Violations found: 1 (0 critical/BLOCKER, 0 high/WARNING, 1 medium/SUGGESTION)

## Critical Violations (BLOCKER)

_None._

Checked and clean for this diff:
- **#5 Pin values** — Ecto queries use `^`; raw SQL uses `$N` params (`auth`, `tenancy`, `projects.search_ranked`, migration role names are compile-time `@secdef_role` constants, not user input).
- **#10 `String.to_atom`** — no matches under `lib/elx_mcp` for this change set (`Atom.to_string` only).
- **#12 `raw/1`** — no HEEx/LiveView in scope.
- **#4 Money float** — no monetary fields.
- **#11 handle_event auth** — N/A (no LiveView).
- **#17 bare `{:error, _}` swallowing changesets** — `Tenancy.create_project/1` rolls back with `%Ecto.Changeset{}`; collab Multi returns `{:error, reason}` preserving insert changesets; Auth insert path re-exports `error` as-is.

## High Violations (WARNING)

_None._

## Medium Violations (SUGGESTION)

### [#19] Comments aren't commit messages (inline review tags)
- **Files**:
  - `lib/elx_mcp/repo.ex:43-45` — `(B1)` in GUC-clear footgun note
  - `lib/elx_mcp/tenancy.ex:75-77` — `(B1)` on rollback/changeset contract
  - `lib/elx_mcp/projects.ex:334-335` — `(W3)` on `increment_time_spent` surface
  - `lib/elx_mcp/collaboration/attachment.ex:36` — `(W4)` on server-side `storage_path`
- **Code**: durable notes tagged with triage IDs, e.g. `further SQL raises (B1)`
- **Confidence**: REVIEW
- **Fix**: Keep the durable invariant text (aborted-TX clear, server-side path, non-public Multi helper). Drop the `(B1)` / `(W3)` / `(W4)` tags — those belong in the commit/PR, not source.

_Optional (tests only, same law):_ `test/elx_mcp/rls_test.exs` and `collaboration_test.exs` reference B1/B2/B3/W4/W13/W14 in comments — low priority; test narration is less harmful than production tags.
