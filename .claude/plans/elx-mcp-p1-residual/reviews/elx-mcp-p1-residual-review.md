# Review: ElxMCP P1 Residual

**Date**: 2026-08-02  
**Plan**: `.claude/plans/elx-mcp-p1-residual/plan.md`  
**Verdict**: **PASS WITH WARNINGS** (quick-fix applied for W3/W7/W8)

**Post-review fixes (2026-08-02)**:
1. ETS fail-closed (`require_table!`); session plug tests (`async: false`); changelog limit cap
2. SessionBind 30m TTL + prune; DELETE/GET fail-closed (`verify_owner`); collab entity-in-project; force actor emails from Scope; drop cast of `time_spent_seconds` / ticket_id / inserted_at / author_email
3. **71 tests green**

Agents: elixir-reviewer · security-analyzer · testing-reviewer · iron-law-judge · requirements-verifier  
(Skipped: verification-runner — full suite already green this session: 64 tests, compile --warnings-as-errors, format OK)

---

## Requirements Coverage

| Status | Count |
|--------|-------|
| MET | 15 (+ P6-T1 confirmed in session) |
| PARTIAL | 0 |
| UNMET | 0 |
| UNCLEAR | 0 (P6-T1 resolved: 64 passed) |

**Path A meets P1-T3**: YES — `SessionBind` ETS + `MCPAuth` POST bind / DELETE·GET verify → 403.

All seven audit P1s have completed tasks. See `reviews/requirements.md`.

---

## Summary by severity

| Severity | Count | Notes |
|----------|-------|-------|
| BLOCKER | 0 | After anti-noise filter |
| WARNING | 8 | Lifecycle residual, ETS growth, test gaps, collab integrity |
| SUGGESTION | 5 | Query short-circuit, docs, mass-assign polish |

Testing agent labeled missing DELETE/GET 403 tests as BLOCKER; demoted to **WARNING** (coverage gap, not incorrect production behavior — POST 403 + unit bind tests cover ownership model; DELETE/GET share `verify/3`).

---

## Warnings (actionable)

### W1 — Pre-bind lifecycle window (HIGH consensus: elixir + security)
`SessionBind.verify/3` returns `:ok` when unbound. Between initialize (session id only in **response**) and first POST that binds, any authenticated principal who learns the id can DELETE/GET. Tool data IDOR is not affected.  
**Files**: `session_bind.ex`, `mcp_auth.ex`  
**Mitigation in plan**: documented residual; fail-closed DELETE/GET when unbound is a follow-up.

### W2 — SessionBind ETS no TTL (HIGH consensus)
No prune except DELETE unbind → abandoned sessions grow memory. RateLimit has opportunistic prune; SessionBind does not.  
**Follow-up**: store bound_at + prune, or size cap.

### W3 — ETS create-on-miss reopens ownership risk
`setup!` / `ensure_table!` still create tables from the calling process if missing. Application owns on happy path; crash recovery recreates under request process.  
**Follow-up**: fail closed if table missing outside Application/tests.

### W4 — Collaboration writes lack entity-in-project checks
`create_comment` / attachment / changelog force `project_id` from Scope but do not verify entity id belongs to project (Projects creates do). Latent integrity before write MCP tools.  
**Follow-up**: `ensure_same_project` / resolve-by-scope before insert.

### W5 — Mass-assign residuals
`:time_spent_seconds` still cast on Ticket; actor emails / `storage_path` / changelog `inserted_at` client-settable. Low until write tools ship.

### W6 — Rate limit IP-only behind proxies
Documented single-node / IP pre-auth. Behind LB need trusted remote IP + optional post-auth key (out of original P1 scope).

### W7 — Test coverage gaps for session lifecycle
Missing plug tests: DELETE 403, GET 403, owner unbind. `MCPAuthTest` is `async: true` while touching SessionBind ETS — prefer `async: false` for bind tests.  
No `child_limit` truncation test for P2-T2.

### W8 — `list_changelog` limit not min-capped
Unlike `list_comments`, limit not `min(200)`.

---

## Suggestions

- Short-circuit search after limit filled; optional UNION
- Align search_work_items moduledoc with description opt-in
- Private/Scope-wrap `increment_time_spent`
- Stronger Jason asserts on remaining tools (P5-T3 partial strength)
- SessionBind race branch concurrent test (optional)

---

## Clean areas

| Area | Result |
|------|--------|
| Iron Laws | **0 violations** |
| Scope-first + `authorize_write` | OK |
| No cast `:project_id` / issue `:key` | OK |
| RateLimit Application ownership + survive-exit | OK |
| Search ladder + pg_trgm | OK |
| `get_*_id` + child_limit 50 | OK |
| Resources + 429 tests | OK |
| SQL pinning / no String.to_atom | OK |

---

## Agent artifacts

- `reviews/elixir.md`
- `reviews/security.md`
- `reviews/testing.md`
- `reviews/iron-laws.md`
- `reviews/requirements.md`

---

## Recommended next steps

1. **Ship as-is** if residual warnings are accepted (documented lifecycle window + follow-ups).
2. **Quick fix pass** for W7 (DELETE/GET 403 tests + async:false) + W3 fail-closed ETS — small, high value.
3. Defer W1 fail-closed, W2 TTL, W4 collab entity checks to a P2 plan unless write tools land soon.
