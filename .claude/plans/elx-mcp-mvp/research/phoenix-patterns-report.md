# Codebase Analysis — ElxMCP (Phoenix Patterns)

**Analyzed:** 2026-08-01  
**App path:** `/Users/aquental/projects/ai/CECI/elx_mcp`  
**SPEC:** `spec/SPEC.md` v0.2  
**Ash Framework:** **Not present** — classic Phoenix contexts apply.

---

## Project Structure

| Area | Location / convention |
|------|------------------------|
| OTP app | `:elx_mcp` |
| Business logic root | `ElxMcp` (`lib/elx_mcp.ex` — empty placeholder) |
| Domain modules | `lib/elx_mcp/` (currently: `application.ex`, `repo.ex`, `mailer.ex` only) |
| Web root | `ElxMcpWeb` (`lib/elx_mcp_web.ex`) |
| Web modules | `lib/elx_mcp_web/` (router, endpoint, telemetry, controllers, components) |
| Migrations | `priv/repo/migrations/` (**empty**) |
| Seeds | `priv/repo/seeds.exs` |
| Tests | `test/elx_mcp_web/`, `test/support/{conn_case,data_case}.ex` |
| HTTP client | **Req** (`:req`) — project guideline; no Tesla/HTTPoison |
| Adapter | **Bandit** (`Bandit.PhoenixAdapter`) |

### Module naming

- Domain: `ElxMcp.{Context}` and schemas under `ElxMcp.{Context}.{Schema}`
- Web: `ElxMcpWeb.{Router,Endpoint,Plugs.*,Controller,Live,...}`
- Mix tasks: `Mix.Tasks.ElxMcp.*` → CLI `mix elx_mcp.*`
- PubSub: `ElxMcp.PubSub` (already supervised)
- Repo: `ElxMcp.Repo` (Postgres)

### Greenfield state

This is a **stock `phx.new` skeleton** with:

- One HTML home route (`PageController`)
- No contexts, schemas, or migrations
- No authentication (no `Accounts`, no `%Scope{}`, no session auth)
- No `anubis_mcp` dependency yet
- No LiveViews beyond layout infrastructure
- No factories (ExMachina not installed)

---

## Phoenix Version & Modern Patterns

| Item | Status |
|------|--------|
| **Phoenix** | `~> 1.8.9` |
| **Ecto / Ecto SQL** | `~> 3.13` |
| **LiveView** | `~> 1.2.0` |
| **Elixir** | `~> 1.17` |
| **Scopes (`%Scope{}`)** | **Not generated** — Agents.md / layouts mention `current_scope`, but no Scope module or auth generators ran |
| **Verified routes** | Yes — `helpers: false`, `~p` via `Phoenix.VerifiedRoutes` |
| **FallbackController** | No |
| **PubSub in contexts** | N/A (no contexts yet); `ElxMcp.PubSub` is supervised |
| **JSON API** | Commented `:api` pipeline only |
| **CORS** | Not configured |
| **Primary key generators** | Config has `generators: [timestamp_type: :utc_datetime]` only — **must add `binary_id: true`** to match SPEC UUIDs |

### Config highlights

- **Dev DB:** Postgres via `.env` / `DB_*` (see `config/runtime.exs`), SSL configurable — aligns with SPEC.
- **Test DB:** `localhost` / `postgres` / `elx_mcp_test` + SQL Sandbox.
- **Prod:** `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`; `force_ssl` with x-forwarded-proto.
- **Timestamps:** generator prefers `:utc_datetime`; SPEC wants `:utc_datetime_usec` — prefer explicit schema timestamps matching SPEC.
- **precommit:** `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`.

### Supervision tree (`ElxMcp.Application`)

```text
ElxMcpWeb.Telemetry
ElxMcp.Repo
DNSCluster
{Phoenix.PubSub, name: ElxMcp.PubSub}
ElxMcpWeb.Endpoint
```

**To add for MCP:** `{ElxMcp.MCP.Server, transport: :streamable_http}` (per SPEC / anubis_mcp) before or alongside Endpoint.

---

## Contexts Identified

| Context | Purpose | Status |
|---------|---------|--------|
| *(none)* | Greenfield | Empty |

### Recommended context boundaries (aligned with SPEC §5)

| Context | Module | Owns | Schemas (lib path) |
|---------|--------|------|--------------------|
| **Tenancy** | `ElxMcp.Tenancy` | Projects as tenants; issue key sequence | `Project` → `lib/elx_mcp/tenancy/project.ex` |
| **Projects** | `ElxMcp.Projects` | Jira-like work items & planning | `Epic`, `UserStory`, `Ticket`, `Board`, `Sprint`, `Component`, `ComponentLink` |
| **Collaboration** | `ElxMcp.Collaboration` | Activity & evidence on work items | `Comment`, `Attachment`, `Worklog`, `Changelog` |
| **Auth** | `ElxMcp.Auth` | API keys (not user/password sessions) | `ApiKey` |
| **MCP** | `ElxMcp.MCP` | Protocol surface only — **no Repo queries of other schemas** | `Server`, `Tools.*`, `Resources.*` |

#### Boundary rules

1. **Tenancy owns `projects` and `issue_counter`.**  
   `next_issue_key(project_id)` (or similar) runs in a transaction: lock/update counter → return `"#{key}-#{n}"`. Projects/Collaboration call this; they do not touch `issue_counter` directly.

2. **Projects owns hierarchy & planning.**  
   Cross-schema rules live here: story may omit epic; ticket **must** have story; subtask/`parent_ticket_id` same project (+ cycle checks). Prefer keeping boards/sprints/components here (shared project vocabulary; frequent co-use with tickets/stories).

3. **Collaboration owns side tables.**  
   Always denormalize/filter by `project_id`. Do not join Tenancy/Projects schemas from Collaboration except by **IDs** passed in; resolve entity existence via Projects public API when needed.

4. **Auth owns keys only.**  
   `authenticate_api_key(raw) → {:ok, %{project_id, email, api_key, scopes}} | {:error, :unauthorized}`. Hashing (SHA-256), revoke, gen, last_used_at. Does **not** own project CRUD.

5. **MCP is an adapter, not a data context.**  
   Tools/resources call `Auth` (or receive pre-resolved scope from plug/frame) + `Projects` / `Collaboration` / `Tenancy` public APIs. Never `Repo` other contexts’ schemas.

#### Optional Scope struct (recommended even without session auth)

Phoenix 1.8 “scope as first param” still applies for multi-tenant isolation. Introduce a lightweight struct (not full phx.gen.auth):

```elixir
defmodule ElxMcp.Auth.Scope do
  @type t :: %__MODULE__{
          project_id: Ecto.UUID.t(),
          actor_email: String.t(),
          api_key_id: Ecto.UUID.t() | nil,
          scopes: [String.t()]
        }
  defstruct [:project_id, :actor_email, :api_key_id, scopes: []]
end
```

**Convention for all tenant-scoped reads:**

```elixir
def list_epics(%Auth.Scope{} = scope, filters \\ %{}) do
  from(e in Epic, where: e.project_id == ^scope.project_id, ...)
  |> Repo.all()
end
```

- Scope **first** argument on every Projects/Collaboration/Tenancy read used by MCP.
- Never trust client-supplied `project_id`; only `scope.project_id` from authenticated key.
- Future LiveView UI can map `current_scope` assign to the same struct.

#### Why not merge Tenancy + Projects?

- `issue_counter` and project identity are tenancy concerns; work-item graph is large and will grow (write tools later).
- Keeps `Projects` under ~god-context risk as write surface expands.
- Auth stays separate so key lifecycle never couples to issue schemas.

#### Why not put ApiKey under Tenancy?

- Auth is security-sensitive (hashing, revoke, logging rules). Mix task + plug should depend on `Auth` only.
- Tenancy remains pure “what is a project.”

---

## Patterns in Use (current) & Patterns to Establish

### Context API style (target)

```elixir
# Auth
Auth.authenticate_api_key(raw_key) :: {:ok, %Auth.Scope{}} | {:error, :unauthorized}
Auth.create_api_key(project_id, email, attrs) :: {:ok, {plaintext, %ApiKey{}}} | {:error, changeset}
Auth.revoke_api_key(id) :: {:ok, %ApiKey{}} | {:error, _}

# Tenancy
Tenancy.get_project!(%Scope{}, id_or_key)
Tenancy.next_issue_key(%Scope{} | project_id)  # transactional

# Projects (all take %Scope{} first)
Projects.list_epics(scope, filters)
Projects.get_epic_by_key(scope, key)
Projects.project_status(scope, recent_limit)

# Collaboration
Collaboration.list_comments(scope, entity_type, entity_id_or_key)
```

- Return `{:ok, _}` / `{:error, %Ecto.Changeset{}}` for writes; bang only for internal “must exist.”
- MVP MCP is **read-only**; still design write APIs for seeds/mix and later tools.
- PubSub optional for MVP (no UI live updates yet).

### Router / pipeline patterns for `/mcp`

**Current router:**

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {ElxMcpWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
end

pipeline :api do
  plug :accepts, ["json"]
end
```

**Recommended addition (do not reuse `:browser` — no CSRF/session for MCP):**

```elixir
pipeline :mcp do
  plug :accepts, ["json"]
  # Optional: skip session/CSRF entirely (already not in this pipeline)
  plug ElxMcpWeb.Plugs.CORS, origins: Application.fetch_env!(:elx_mcp, :mcp_cors_origins)
  plug ElxMcpWeb.Plugs.MCPAuth
end

scope "/mcp" do
  pipe_through :mcp
  forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: ElxMcp.MCP.Server
end
```

Implementation notes:

1. **Place `/mcp` outside `scope "/", ElxMcpWeb`** so `forward` is not double-aliased under `ElxMcpWeb`.
2. **`MCPAuth`** (module plug under `lib/elx_mcp_web/plugs/mcp_auth.ex`):
   - Read `X-API-Key` (also tolerate common variants only if SPEC expands; stick to `X-API-Key`).
   - Decode hex → 32 bytes; invalid format → 401 (constant-time fail path).
   - `:crypto.hash(:sha256, raw)` → lookup `key_hash` where `revoked_at IS NULL`.
   - Build `%Auth.Scope{}` + assign `:current_scope`, `:current_project` (preload project if needed), `:api_key`, `:actor_email`.
   - Propagate scope into Anubis frame/assigns per library support (research anubis_mcp Plug options).
   - Update `last_used_at` via Task / throttled update (not on critical path if possible).
3. **CORS:** config key `:mcp_cors_origins`; handle `OPTIONS` preflight in plug or dedicated CORS plug before auth (preflight often has no API key — **auth must not reject OPTIONS**, or CORS plug answers first).
4. **Body parsing:** Endpoint already has `Plug.Parsers` with JSON — verify Streamable HTTP / SSE does not conflict (chunked responses, content types). May need parser pass-through for MCP content-types.
5. **No `protect_from_forgery`** on MCP.
6. **Rate limiting** out of MVP but note as hardening.

### Schema patterns (to establish)

| Concern | Recommendation |
|---------|----------------|
| Primary keys | `:binary_id` / UUID everywhere (SPEC) |
| FKs | `:binary_id` |
| Timestamps | `:utc_datetime_usec` (SPEC) |
| Soft delete | Only `api_keys.revoked_at` in MVP |
| Polymorphic | `commentable_type` / `attachable_type` as **string allowlists** in changesets — never `String.to_atom/1` on user input |
| Money | N/A; time as **integer seconds** (not float) |
| Associations | Preload only what tools return; separate queries for `has_many` |
| Status/priority | Ecto validation against fixed lists (SPEC §4.8) |

Config change:

```elixir
config :elx_mcp,
  ecto_repos: [ElxMcp.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true]
```

### LiveView patterns

- Layouts already expect optional `current_scope` and use `<Layouts.app>`.
- MVP has **no admin LiveView** (keys via mix task). When UI arrives: authenticated `live_session` + pass `current_scope`.
- Streams for lists; `assign_async` / `connected?` for DB in mount (Iron Laws).

### Testing patterns

| Item | Current / target |
|------|------------------|
| Case templates | `ElxMcp.DataCase`, `ElxMcpWeb.ConnCase` |
| Factory | None — add simple helpers in `test/support/factory.ex` or context fixtures (no ExMachina required) |
| Mocking | None — prefer Repo + sandbox for Auth/MCPAuth |
| Async | `async: true` OK for Postgres sandbox isolation tests |
| Critical tests | Key gen/hash, MCPAuth 401/200, **cross-tenant isolation** (key A cannot read project B), issue counter uniqueness, hierarchy validations |

---

## Anti-patterns Found

None in application domain code (skeleton only). **Avoid introducing:**

| Anti-pattern | Why |
|--------------|-----|
| Service objects under `lib/elx_mcp/services/` | Put functions on contexts |
| MCP tools calling `Repo` on other schemas | Breaks context ownership |
| Trusting `project_id` from tool params | Tenant escape |
| Logging full API keys | Use `key_prefix` only |
| `String.to_atom` on `entity_type` / query filters | Atom exhaustion |
| God context `ElxMcp.Projects` > ~400–500 LOC without split | Split Collaboration already mitigates |
| Float for estimates | Use integer seconds |
| Session/CSRF pipeline on `/mcp` | Breaks machine clients |
| Authenticating only at mount for future LiveView writes | Authorize every `handle_event` |

---

## Iron Law Concerns — Multi-tenant API Key Auth

| Priority | Law / risk | Application to ElxMCP |
|----------|------------|------------------------|
| **P1** | Scope filtering on every query | Every Projects/Collaboration query **must** `where: project_id == ^scope.project_id`. Tools that accept `key`/`id` must still constrain by scope. Add multi-tenant isolation tests as acceptance criteria. |
| **P1** | Authorize every operation | Plug auth is necessary but not sufficient if tools can be invoked without frame scope. Ensure Anubis handlers **require** scope from frame/assigns; reject missing scope. |
| **P1** | `String.to_atom/1` on user input | Filters (`status`, `entity_type`, `type`) → allowlists + `String.to_existing_atom` only if needed, prefer string comparisons. |
| **P1** | Unpinned query values | Always `^` pin; never fragment-interpolate client strings into SQL. Search `q` uses parameterized `ilike`. |
| **P1** | Timing / enumeration | Invalid vs revoked key both 401 with same body; constant-time compare not strictly needed if only hash lookup, but avoid “project not found” vs “bad key” distinctions that leak tenancy. |
| **P1** | XSS / `raw/1` | MCP returns JSON/text; if markdown bodies are returned, do not mark HTML-safe for browser clients without escaping. |
| **P2** | last_used_at write amplification | Throttle updates; don’t fail request if update fails. |
| **P2** | Async last_used_at | If using `Task`, ensure no bare unsupervised process leaks under load — `Task.Supervisor` preferred. |
| **P2** | Mix task boot | `mix elx_mcp.gen_api_key`: use `Mix.Task.run("app.config")` + `Application.ensure_all_started(:elx_mcp)` carefully — avoid full `app.start` if it binds Endpoint/MCP in awkward ways; document preferred pattern. |
| **P2** | CORS + credentials | Prefer explicit origin list in prod; `*` only in dev. |
| **P2** | SHA-256 without pepper | Acceptable per SPEC; document compromise model (DB leak of hashes + offline brute of 256-bit keys is infeasible; prefix still not secret). Rotation = revoke + new key. |
| **P3** | Polymorphic preloads | Prefer explicit type branches over dynamic schema modules from user strings. |

### Auth data flow (recommended)

```text
Client → X-API-Key
  → MCPAuth plug
    → Auth.authenticate_api_key/1
      → %Scope{project_id, actor_email, scopes}
    → conn.assigns.current_scope
  → Anubis StreamableHTTP
    → Tool handle(scope from frame)
      → Projects.*/Collaboration.* (scope first)
```

---

## Conventions to Follow

1. **Contexts own data** — no cross-context `Repo` on foreign schemas.
2. **`%Auth.Scope{}` first** on tenant-scoped functions.
3. **UUIDs + usec timestamps** per SPEC (update generators).
4. **HTTP via Req** if any outbound calls appear later.
5. **Verified routes (`~p`)** for any browser UI.
6. **Layouts.app + current_scope** for future LiveViews.
7. **Icons via `<.icon>`**, Tailwind v4 import syntax, no daisyUI components per Agents.md (deps may include daisyui assets — prefer custom Tailwind).
8. **Finish with `mix precommit`.**
9. **Telemetry:** `[:elx_mcp, :mcp, :tool, :stop]` with tool name, project_id, result, duration — wire into `ElxMcpWeb.Telemetry`.
10. **Bilingual** tool descriptions (EN stable names + EN/PT descriptions).

---

## Quick Reference for New Features

### Schema location

| Domain | Path |
|--------|------|
| Project tenant | `lib/elx_mcp/tenancy/` |
| Work items | `lib/elx_mcp/projects/` |
| Comments/changelog/etc. | `lib/elx_mcp/collaboration/` |
| API keys | `lib/elx_mcp/auth/` |
| MCP server/tools | `lib/elx_mcp/mcp/` |
| Web plugs | `lib/elx_mcp_web/plugs/` |

### Context pattern

- Scope as first param: **yes** (`%ElxMcp.Auth.Scope{}`)
- PubSub on mutations: optional MVP
- Return tuples: `{:ok, _}` / `{:error, _}`
- MCP tools: thin; all DB via contexts

### Router pattern for MCP

- New pipeline `:mcp` (json + CORS + MCPAuth)
- `scope "/mcp"` + `forward` to Anubis StreamableHTTP Plug
- Application child for `ElxMcp.MCP.Server`

### Testing pattern

- `DataCase` for contexts; `ConnCase` for plug + `/mcp` integration
- Fixtures: insert project → api key → work items under same `project_id`
- Always assert tenant isolation with a second project/key
- `async: true` for pure context tests

### Answers to planning questions

1. **Schema location:** under context dirs above; start with Tenancy + Auth + Projects core tables.
2. **Domain owners:** Tenancy=`projects`; Projects=hierarchy; Collaboration=side tables; Auth=keys; MCP=protocol.
3. **Similar functionality:** none yet — greenfield.
4. **Testing:** ExUnit + SQL Sandbox; add fixtures; isolation tests mandatory.
5. **Reusable components:** CoreComponents/Layouts for future UI only.
6. **Phoenix 1.8 scopes:** not stock-generated; **introduce custom Auth.Scope** for API keys.
7. **Errors:** MCP → protocol errors / HTTP 401 at plug; no FallbackController needed for MCP.
8. **PubSub:** `ElxMcp.PubSub` available; no domain topics yet.

---

## Implementation order (pattern-consistent)

1. Config generators (`binary_id`, timestamps) + migrations/schemas.
2. `Auth` + `Tenancy` + `Projects` + `Collaboration` contexts with Scope-first APIs.
3. Mix task `elx_mcp.gen_api_key` + seeds.
4. Add `anubis_mcp`, supervise server, router pipeline, `MCPAuth`, CORS.
5. Read-only tools/resources + telemetry + isolation tests + `mix precommit`.
