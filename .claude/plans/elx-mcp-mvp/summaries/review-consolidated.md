# Consolidated Summary

**Strategy**: Index (under 8k tokens; full unique BLOCKER/WARNING retention)
**Input**: 5 files, ~6.5k tokens
**Output**: ~3.2k tokens (~50% reduction via SUGGESTION compression + dedupe)
**Sources**: `elixir.md`, `iron-laws.md`, `requirements.md`, `security.md`, `testing.md`

## Overall verdict

**REQUIRES CHANGES** — not Iron-Law **BLOCKED**.

| Gate | Result |
|------|--------|
| Iron Laws | **PASS** (0 violations) |
| Requirements | **13 MET**, **1 PARTIAL** (sprints resource), **0 UNMET**, **1 UNCLEAR** (`mix precommit` not re-run) |
| Elixir/Phoenix review | Changes requested (0 BLOCKER, 8 WARNING) |
| Security | No read-path tenant escape; **do not ship public multi-tenant prod** until rate limit / secret-in-context / CORS / Scope writes |
| Testing | **REQUIRES CHANGES** — 5 coverage BLOCKERs (public API / MCP / E2E / auth scopes / collaboration) |

Ship-ready only after: (1) critical test surface filled, (2) P0 security (rate limit + key-in-headers handling), (3) optional PARTIAL sprints resource if SPEC-strict.

---

## Requirements summary

| Status | Count | Detail |
|--------|------:|--------|
| MET | 13 | Migrations, issue keys, story/ticket rules, subtasks+cycle, API keys+mix task, multi-key revoke, Anubis `/mcp`, project_status, whole-project key scope, bilingual, CORS, telemetry, seeds, core tests |
| PARTIAL | 1 | **#8** Read tools/resources: 12 tools + 4 resources present; **missing** `project://sprints/{id_or_name}` |
| UNMET | 0 | — |
| UNCLEAR | 1 | **#16** `mix precommit` alias exists (`mix.exs`); review did not re-run |

---

## Iron Laws

**0 violations** (critical/high/medium). N/A: LiveView #1–3/#11/#17, Oban #7–9b. Clean: money ints, pinned `^`, preload not JOIN, no `to_atom`/`raw`, Mix `app.config`+`ensure_all_started`, supervised children only.

Informational (not violations): MCP `{:error, _}` is not changeset swallow; `Scope.has_scope?/2` unused (read-only MVP).

---

## BLOCKERs (testing — REQUIRES CHANGES triggers)

These are **coverage BLOCKERs**, not Iron Law BLOCKED.

1. **Projects public API largely untested** (`lib/elx_mcp/projects.ex`) — boards/sprints/components/epics get/list, ticket filters, `search_work_items`, parent **cycle** path. *Source: testing*
2. **MCP tools/resources almost untested** — only ProjectStatus + ListEpics + empty-frame unauth; **10/12 tools** + **0/4 resources** + not-found/filters. *Source: testing* (echoed as SUGGESTION in elixir)
3. **No authenticated E2E `/mcp` ConnCase** — plug tests 401s or isolated `call/2`; never full StreamableHTTP with valid key → tool. *Source: testing*
4. **Auth scope gate untested** — key without `"project:read"`; non-binary verify; `get_api_key!`; `last_used_at` touch. *Source: testing*
5. **Collaboration gaps** — no `create_attachment` tests; no cross-tenant isolation for comments/changelog/worklog; multi-worklog time accumulation untested. *Source: testing*

---

## WARNINGs (KEEP ALL unique; iron-law-judge wins on same code — N/A overlap)

### Multi-tenant integrity & writes

| # | Finding | Location | Sources |
|---|---------|----------|---------|
| W1 | No same-tenant checks on association FKs (story/ticket/sprint creates); DB FK ≠ project match | `projects.ex`, migration, schemas | elixir #3, security |
| W2 | Write/context APIs take bare `project_id` without `%Scope{}`; castable tenant fields | `projects.ex` create_*, `collaboration.ex`, `auth` cast | elixir #6, security, testing |
| W3 | Isolation tests incomplete (lists/search/status/collaboration under foreign scope; same-key multi-tenant) | `projects_test`, `tenancy_test` | testing |
| W4 | Tenancy concurrency / API surface thin (`FOR UPDATE` uniqueness, list/get_by_key, duplicate key) | `tenancy_test` | testing |

### MCP encoding & API behavior

| # | Finding | Location | Sources |
|---|---------|----------|---------|
| W5 | `encode_struct/1` drops preloaded associations → nested data never returned; wasted preloads | `mcp/helpers.ex:52-67` | elixir #1 |
| W6 | Invalid `story_key`/`epic_key` → random UUID filter → silent `[]` not not-found | `list_tickets`, `list_user_stories` | elixir #2 |
| W7 | Unbounded `list_sprints` / `list_boards` / `list_comments` (no limit) | `projects.ex`, `collaboration.ex` | elixir #5 |
| W8 | Helpers rebuild Scope; ignore `current_scope`; **default scopes to `["project:read"]` if missing** | `helpers.ex:7-21` | elixir #8, security |

### Auth / security ops

| # | Finding | Location | Sources |
|---|---------|----------|---------|
| W9 | **Plaintext API key in Anubis `frame.context.headers`** | Anubis streamable_http plug + session | security (High) |
| W10 | **No rate limiting** on `/mcp`; every verify hits DB; valid keys `update_all last_used_at` (DoS amp) | router, `mcp_auth`, `auth.ex:90-94` | security (High); elixir #4 related to write amp |
| W11 | Body parsed (`Plug.Parsers`) before API-key auth | `endpoint.ex` then `:mcp` | security |
| W12 | CORS `*` default non-prod; prod `MCP_CORS_ORIGINS=*` footgun with `x-api-key` | config, `cors.ex`, runtime | security |
| W13 | Scopes not allowlisted; tools never re-check `has_scope?` | `api_key` cast, `auth.ex`, tools | elixir #7, security, iron-laws note |
| W14 | Auth timing / last-used side channel (low–med) | `auth.ex` | security |
| W15 | Session assigns tenant ids without crypto bind; no `serialize_assigns/1` | Anubis session, `mcp/server.ex` | security |

### Concurrency / correctness

| # | Finding | Location | Sources |
|---|---------|----------|---------|
| W16 | Non-atomic `time_spent_seconds` (read-modify-write, no lock/`inc`) | `collaboration.ex:46-52` | elixir #4 |
| W17 | Plug edge cases untested (OPTIONS, malformed Bearer, full assign assert) | `mcp_auth_test` | testing |
| W18 | `validation_matrix_test` weak mega-smoke; claims V01–V17 loosely | `validation_matrix_test.exs` | testing |
| W19 | Subtask happy path only in matrix; cycle not dedicated | tests | testing |

---

## SUGGESTIONs (compressed groups)

| Group | Items (merged) | Sources |
|-------|----------------|---------|
| **Keys / counters** | Issue key gaps on failed insert; no key expiry/rotation; mix/seeds print plaintext once (ops hygiene) | elixir, security |
| **Query cost** | Search three-query bias; `status_summary` fan-out; debounce `touch_last_used` (also security P0) | elixir, security |
| **Scope hygiene** | Prefer `Scope.has_scope?/2` in tools when scopes expand | elixir, iron-laws |
| **Test structure** | `describe` per entity; factories; stronger JSON tool asserts; `async: true` on validation matrix; property tests (keys, hash, LIKE escape) | testing, elixir |
| **Prod ops** | Enable Repo SSL; SSE `subscriber_metadata` with `project_id`; body size limits pre-auth; Anubis `serialize_assigns` | security |
| **Positive** | Mix task `app.config` (not `app.start`) correct | security, iron-laws, elixir |

---

## Security priority stack (from security.md)

1. **P0**: Rate-limit `/mcp` + debounce `touch_last_used`
2. **P0**: Treat `frame.context.headers` API key as secret; scrub/no log frames
3. **P1**: Allowlist scopes; fail closed on missing scopes; plan per-tool `has_scope?`
4. **P1**: Refuse CORS `*` in prod
5. **P1**: Scope mutations + association tenancy before write tools
6. **P2**: Expiry, SSE metadata, DB SSL, body limits, `serialize_assigns`

**Positive controls (do not regress):** CSPRNG+SHA-256 keys, project-forced create, re-auth every MCP request, tenant `where: project_id == ^…`, OPTIONS/CORS before auth, prod CORS default deny, Mix safe boot.

---

## Coverage

| File | Represented | Key items |
|------|-------------|-----------|
| `elixir.md` | Yes | 8 WARNINGs, 6 SUGGESTIONs → groups |
| `iron-laws.md` | Yes | 0 violations, N/A table, notes |
| `requirements.md` | Yes | 13/1/0/1 matrix + PARTIAL sprints |
| `security.md` | Yes | High/Med WARNINGs, posture, recs |
| `testing.md` | Yes | 5 BLOCKERs, 6 WARNINGs, SUGGESTION groups |

## Coverage Gaps

None.
