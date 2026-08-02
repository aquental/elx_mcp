# Security Report: MCP API Key Auth (`X-API-Key`)

**App:** `elx_mcp`  
**Scope:** Design-time security analysis for API key auth on Streamable HTTP MCP endpoint (`/mcp`)  
**Status:** Feature not implemented yet (greenfield vs SPEC v0.2)  
**Date:** 2026-08-01  
**OWASP:** API1 (BOLA/IDOR), API2 (broken auth), API4 (unrestricted resource consumption), API8 (misconfig), A07 (auth failures)

---

## Executive Summary

The SPEC’s model is sound for an MVP: 32-byte keys, store only SHA-256 + prefix, soft revoke, tenant = `project_id` bound to the key, read-only `project:read`, plug before Anubis StreamableHTTP. Residual risk is implementation detail, not the high-level design.

**Highest risks if implemented carelessly:**

1. **Cross-tenant data leak (Critical)** — tools/resources that fetch by `id`/`key` without forcing `project_id` from the authenticated key.
2. **Auth bypass / missing assigns propagation (Critical)** — plug authenticates but Anubis frame/tools never receive `project_id`.
3. **CORS misconfiguration (High)** — `*` + credentials or overly broad origins on a bearer-like secret header.
4. **Key material leakage (High)** — logs, exceptions, mix task stdout history, seeds committed with live keys.
5. **Brute-force / DoS on `/mcp` (Medium)** — no rate limit; cheap hash + DB lookup still amplifiable.

**SHA-256 of a 256-bit random key is acceptable** (not a low-entropy password). Prefer lookup-by-hash over “fetch all and compare.” Timing-safe compare is still recommended as defense-in-depth when comparing digests.

---

## Threat Model (STRIDE-lite)

| Threat | Vector | Impact | Mitigation |
| ------ | ------ | ------ | ---------- |
| Spoofing | Stolen `X-API-Key`, leaked seed/mix output | Full project read | Hash-at-rest, one-time display, revoke, TLS only, never log raw key |
| Tampering | Client-supplied `project_id` / entity id in tool args | Cross-tenant read | Ignore client tenant; scope every query by key’s `project_id` |
| Repudiation | No attribution | Audit gap | Assign `actor_email`, `api_key_id`, `key_prefix` in telemetry |
| Info disclosure | Error messages, logs, CORS reflection | Key/prefix/DB shape leak | Uniform 401 body; log prefix only; redact params |
| DoS | Flood `/mcp` auth | DB load | Rate limit by IP then by key; throttle `last_used_at` writes |
| Elevation | Scope creep / future write tools | Write as tenant | Enforce scopes in plug **and** tool layer; MVP refuse non-read |

---

## 1. Plug Implementation Checklist (`ElxMcpWeb.Plugs.MCPAuth`)

Place **before** `Anubis.Server.Transport.StreamableHTTP.Plug`. Fail closed.

### Request path

- [ ] Read header **`x-api-key`** only (Plug normalizes to lowercase). Do **not** accept query-string or body keys (URL/history leakage).
- [ ] Reject missing/empty → **401** immediately with generic body (`{"error":"unauthorized"}`).
- [ ] Validate format **before** DB: `~r/\A[0-9a-f]{64}\z/` (lowercase hex only). Invalid format → same **401** (no distinct error to prevent oracle).
- [ ] Decode: `Base.decode16!(presented, case: :lower)` → 32 bytes; hash: `:crypto.hash(:sha256, raw_bytes)`.
- [ ] Lookup **by hash**, not by prefix:

```elixir
from k in ApiKey,
  where: k.key_hash == ^hash and is_nil(k.revoked_at),
  preload: [:project]
```

- [ ] If no row → **401** (identical response/timing budget as invalid format where practical).
- [ ] Enforce scopes: require `"project:read"` in `scopes` (MVP). Missing scope → **403** (or 401 if you prefer not to distinguish; document choice).
- [ ] Ensure project still exists / not soft-disabled if you add project status later.
- [ ] Assign only trusted data:

  - `:current_project` / `:project_id`
  - `:api_key` (struct **without** any plaintext; prefer assign `api_key_id`, `key_prefix`, `scopes`)
  - `:actor_email`

- [ ] **Propagate assigns into MCP frame** (critical). Confirm Anubis StreamableHTTP path: `conn.assigns` → server `frame` / process dict / opts. Add an integration test that a tool sees `project_id` without client sending it.
- [ ] Update `last_used_at` **async / throttled** (e.g. at most once per N minutes) — never block auth on write failure; never log key.
- [ ] Do **not** put session/CSRF plugs on `:mcp` pipeline (stateless API). Keep browser pipeline separate.
- [ ] Return **401** with `WWW-Authenticate: ApiKey realm="mcp"` optional; avoid echoing presented key.
- [ ] Filter logs: configure `:filter_parameters` / custom telemetry metadata scrubber so `x-api-key` never appears in Plug.Telemetry or Logger metadata.
- [ ] Constant response shape for all auth failures (status + JSON body + no stack traces to client).

### Router sketch (hardened)

```elixir
pipeline :mcp do
  plug :accepts, ["json"]
  # Optional: rate limit by IP before auth (cheap reject)
  # plug ElxMcpWeb.Plugs.MCPRateLimit, by: :ip
  plug ElxMcpWeb.Plugs.MCPAuth
  # Optional: rate limit by api_key_id after auth
  # plug ElxMcpWeb.Plugs.MCPRateLimit, by: :api_key
  # CORS: prefer dedicated plug with explicit origins — see §3
end

scope "/mcp" do
  pipe_through :mcp
  forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: ElxMcp.MCP.Server
end
```

### Auth context API

```elixir
# ElxMcp.Auth
@spec authenticate_api_key(String.t()) ::
        {:ok, %{api_key: ApiKey.t(), project: Project.t()}} | {:error, :unauthorized}

def authenticate_api_key(presented) when is_binary(presented) do
  with {:ok, raw} <- decode_key(presented),
       hash <- :crypto.hash(:sha256, raw),
       %ApiKey{} = key <- fetch_active_by_hash(hash),
       true <- "project:read" in (key.scopes || []) do
    {:ok, %{api_key: key, project: key.project}}
  else
    _ -> {:error, :unauthorized}
  end
end
```

- Schema: `key_hash` as `:binary` (32-byte digest), unique index; partial index `WHERE revoked_at IS NULL` optional.
- Never `cast` `key_hash` / `project_id` from external params on create — set in context only.
- `redact: true` on any field that could hold secrets (if any virtual field holds plaintext, never persist it).

---

## 2. Timing-Safe Comparison

### Do you need it?

| Approach | Timing risk | Recommendation |
| -------- | ----------- | -------------- |
| Hash presented key → `WHERE key_hash = ^hash` (indexed equality) | Low for key guessing (256-bit space); DB/index timing not attacker-useful at this entropy | **Primary design** |
| Load candidate by prefix then compare hashes in Elixir | Medium if prefix narrows candidates | Avoid prefix-only lookup for auth |
| Compare hex strings with `==` | Classic string short-circuit | Use `Plug.Crypto.secure_compare/2` if comparing digests in-process |

**Recommendation:**

1. **Primary:** deterministic hash → unique index lookup (SPEC).
2. **Defense-in-depth:** if you ever compare two digests in Elixir, use:

```elixir
Plug.Crypto.secure_compare(stored_hash, computed_hash)
```

Both sides must be equal-length binaries (SHA-256 digests are). Do **not** `secure_compare` on the raw hex key against DB plaintext (you must not store plaintext).

3. **Dummy work on miss (optional MVP+):** on unknown hash, still run a fixed `secure_compare` against a static dummy digest to normalize process time; limited value vs network/DB variance — prioritize rate limits instead.
4. **Do not** use `String.to_atom/1` on scopes, tool names, or headers — allowlist scopes as strings; use `to_existing_atom` only for fixed internal atoms.

**SHA-256 vs password KDFs:** Argon2/bcrypt are for *low-entropy* secrets. A 32-byte CSPRNG key has ~256 bits entropy; single SHA-256 is appropriate and keeps auth latency low for MCP. Optional MVP+ **pepper** (HMAC-SHA256 with server secret from `runtime.exs`) hardens DB exfiltration — SPEC says pepper not required; document as post-MVP hardening.

---

## 3. CORS Risks

SPEC: configurable origins (`config :elx_mcp, :mcp_cors_origins`); dev may use `*`.

### Risks

| Risk | Why it matters |
| ---- | -------------- |
| `Access-Control-Allow-Origin: *` with credentialed browser calls | Browsers block `*` + `credentials`, but mis-set `Access-Control-Allow-Credentials: true` with reflected Origin is classic break |
| Reflecting arbitrary `Origin` | Any malicious site can call `/mcp` **if** the victim’s browser has the API key (e.g. key in JS, extension, or proxied UI) |
| Exposing `X-API-Key` via `Access-Control-Allow-Headers` to untrusted origins | Enables cross-origin authenticated reads from evil.com when key is available to JS |
| Preflight caching too long | Harder to revoke bad CORS config |
| CORS on entire Endpoint vs `/mcp` only | Over-broad headers on browser UI routes |

### Recommendations

1. **Production: explicit allowlist** — never `*`. Load from env:

   ```elixir
   # runtime.exs
   origins =
     System.get_env("MCP_CORS_ORIGINS", "")
     |> String.split(",", trim: true)

   config :elx_mcp, :mcp_cors_origins, origins
   ```

2. Prefer **CORS only on `/mcp` pipeline**, not global Endpoint, unless UI truly needs it.
3. Allow methods required by Streamable HTTP only (typically `GET`, `POST`, `OPTIONS`, maybe `DELETE` if Anubis session ends — verify Anubis docs).
4. `Access-Control-Allow-Headers: content-type, x-api-key, accept, mcp-session-id` (adjust to actual Anubis headers) — do not mirror request headers blindly.
5. **`Access-Control-Allow-Credentials: false`** for API-key MCP (key is not a cookie). Avoid cookie session coupling on `/mcp`.
6. Dev `*` is OK for local tools; **guard with `config_env() == :dev`**.
7. Document: **browser clients must not embed long-lived API keys in front-end bundles**. Prefer desktop MCP clients (Cursor, Claude Desktop) that store secrets outside page JS. CORS is for controlled web UIs, not public SPAs with secrets.
8. If a future web UI needs MCP, use a **same-origin BFF** that holds the key server-side instead of exposing `X-API-Key` to the browser.

---

## 4. Mix Task Safety (`mix elx_mcp.gen_api_key`)

**Iron Law:** start config/app pieces without booting the full web stack.

```elixir
defmodule Mix.Tasks.ElxMcp.GenApiKey do
  use Mix.Task

  @shortdoc "Generate an API key for a project (prints plaintext once)"

  @impl Mix.Task
  def run(args) do
    # ✅ Correct — config + app deps, no Endpoint/Oban consumer side effects
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:elx_mcp)

    # ❌ Never: Mix.Task.run("app.start")  — boots full supervision (port bind, etc.)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [project: :string, email: :string, name: :string]
      )

    # validate opts, call ElxMcp.Auth.create_api_key/1
    # IO.puts plaintext ONCE; warn it will not be shown again
  end
end
```

### Checklist

- [ ] `Mix.Task.run("app.config")` + `Application.ensure_all_started(:elx_mcp)` only.
- [ ] Require `--project` (key or id) and `--email`; validate email format; project must exist.
- [ ] Generate with `:crypto.strong_rand_bytes(32)` only — never user-supplied key material.
- [ ] Persist **hash + prefix + project_id + email + scopes**; never write plaintext.
- [ ] Print plaintext to **stdout once**; print prefix + id for records; non-zero exit on failure.
- [ ] Do not log plaintext via `Logger` (stdout ≠ Logger; still avoid `Logger.info(key)`).
- [ ] Restrict who can run the task in prod (SSH/ops only); treat shell history as sensitive (`HISTCONTROL`, avoid CI logs capturing stdout).
- [ ] Seeds: demo key **only in dev/test**; never commit production keys; prefer generating at seed time and printing once.

---

## 5. Isolation Tests to Require

These are **acceptance-level** security tests, not optional unit fluff.

### Auth plug / context

1. Missing header → 401, no body leak.
2. Malformed key (wrong length, uppercase, non-hex) → 401.
3. Unknown key → 401.
4. Revoked key (`revoked_at` set) → 401.
5. Valid key → 200/MCP path proceeds; assigns `project_id` + email.
6. Valid key without `project:read` → deny.
7. Logs/telemetry metadata on auth failure **do not** contain full key (assert Logger metadata / captured log).

### Tenant isolation (Critical)

Setup: projects A and B; epic/story/ticket in each; key_A and key_B.

8. **Tool `get_epic` / `get_ticket` / resources** with B’s id/key using key_A → **not found / forbidden**, never B’s payload.
9. **List tools** with key_A return **only** A rows (count + ids).
10. **Search** `q` matching titles in both projects → only A.
11. **Comments / changelog / attachments** by entity id → scoped by project_id from key, not client.
12. Client passes `project_id` of B in tool args (if schema allows extra keys) → **ignored**; still only A.
13. After **revoke** key_A, subsequent MCP call fails even if session/header reused.
14. **Resource URIs** (`project://tickets/{key}`) cannot read cross-tenant keys.
15. Sub-task / parent traversal does not escape project (parent in other project rejected by data rules + query scope).

### Regression helpers

```elixir
# Every MCP context read function should require project_id as first arg (or scope struct)
# Flag any Repo.get!(Schema, id) without project_id in lib/elx_mcp/mcp and lib/elx_mcp/projects
```

- Prefer `ElxMcp.Projects.get_ticket!(project_id, id)` over `get_ticket!(id)`.
- Soft-delete: if projects/keys soft-delete later, auth and lists must exclude them.

### CORS tests (conn)

16. Allowed origin → ACAO reflects that origin (or fixed list behavior).
17. Disallowed origin → no permissive ACAO (or no CORS success headers).
18. OPTIONS preflight does not skip auth in a way that leaks data (preflight may be unauthenticated; must not return entity bodies).

---

## 6. Rate Limiting (Optional MVP, Recommended Soon)

**MVP stance:** optional but **strongly recommended** before public exposure of `/mcp`.

| Layer | Key | Suggested limit | Purpose |
| ----- | --- | --------------- | ------- |
| Pre-auth | Client IP | 60–120 req/min | Brute force / scan |
| Post-auth | `api_key_id` | 300–600 req/min | Runaway agent loops |
| Global | IP burst | 20/sec short window | Syn flood-ish abuse |

Implementation options:

- **Hammer** (ETS in single-node; Redis if multi-node) — see skill patterns.
- **PlugAttack** for IP throttle at pipeline edge.

```elixir
# After auth
Hammer.check_rate("mcp:key:#{api_key_id}", 60_000, 300)
# Before auth
Hammer.check_rate("mcp:ip:#{ip}", 60_000, 60)
```

On deny: **429** + `Retry-After`; same JSON error style; log `key_prefix` + IP not raw key.

**Also throttle** `last_used_at` updates (e.g. skip if updated &lt; 5 min ago) to avoid write amplification.

Defer distributed rate limit complexity if single-node MVP; document single-node ETS limitation.

---

## Critical / High Findings (Design Gates)

### C1 — Tenant isolation is the product security boundary

- **Severity:** Critical (if missed in impl)
- **Issue:** API key auth without mandatory `project_id` on every query is classic BOLA/IDOR.
- **Fix:** Scope struct or forced `project_id` argument on all MCP context APIs; no bare `Repo.get`; tests §5.8–5.14.

### C2 — Assigns must reach tool execution

- **Severity:** Critical
- **Issue:** Plug-only auth is insufficient if Anubis tools resolve tenant from client input or default project.
- **Fix:** Explicit bridge tests; fail tool execution if `project_id` missing in frame.

### H1 — CORS + browser-held keys

- **Severity:** High
- **Issue:** Broad CORS + key in JS ⇒ any origin can read project data.
- **Fix:** Allowlist origins; no credentials; prefer non-browser MCP clients; BFF for web.

### H2 — Key leakage channels

- **Severity:** High
- **Issue:** Logger, exception messages, mix CI logs, seeds, LiveDashboard request logger.
- **Fix:** Scrub `x-api-key`; never `Logger` plaintext; mark demo keys clearly; revoke path documented.

### M1 — No expiry

- **Severity:** Medium (accepted by SPEC)
- **Issue:** Stolen keys work forever until revoke.
- **Fix:** Document rotation runbook; post-MVP `expires_at`; optional last_used monitoring alerts.

### M2 — No rate limit in MVP

- **Severity:** Medium
- **Issue:** Auth endpoint abuse / agent storms.
- **Fix:** §6 before internet-facing deploy.

---

## Security Posture (Target After Impl)

| Area | Target | Notes |
| ---- | ------ | ----- |
| Authentication | ✅ Design OK | Hash lookup + revoke; format gate |
| Authorization / tenancy | ⚠️ Impl-sensitive | Must be query-level, not plug-only |
| Input validation | ✅ | Hex format; changesets on all writes (future); tool params validated |
| SQL injection | ✅ | Ecto `^` only; no fragment interpolation |
| XSS | N/A (JSON MCP) | Still no `raw` if HTML UI added |
| CSRF | ✅ N/A for header API | Do not use cookie auth for MCP |
| Secrets | ✅ | runtime env for DB/SECRET; keys hashed |
| CORS | ⚠️ | Allowlist in prod |
| Rate limit | ⚠️ optional MVP | Required for public deploy |

Checked patterns in current codebase: no MCP auth yet; standard Phoenix browser CSRF present; no `String.to_atom` / `raw` / SQL interpolation issues in app `lib/` for this feature (not implemented).

---

## Recommendations (Priority)

1. **P0** Implement `authenticate` as hash → unique lookup; uniform 401; never log plaintext.
2. **P0** Force `project_id` from key into every MCP tool/resource query; integration isolation tests first-class.
3. **P0** Verify Anubis assign/frame propagation with an automated test.
4. **P1** CORS allowlist from env; dev-only `*`; no credentials on `/mcp`.
5. **P1** Mix task: `app.config` + `ensure_all_started`, never `app.start`.
6. **P1** Parameter/header filtering for logs; telemetry with `key_prefix` only.
7. **P2** Rate limit IP + api_key_id before public exposure.
8. **P2** Throttle `last_used_at`; runbook for revoke/rotation.
9. **P3** Pepper (HMAC) + optional `expires_at` + admin audit list by prefix.

---

## Tools to Run Manually (no Bash in this agent)

```bash
mix sobelow --exit medium
mix deps.audit
mix hex.audit
mix test test/elx_mcp_web/plugs/mcp_auth_test.exs
mix test test/elx_mcp/isolation_test.exs
```

---

## Plug Quick Reference (copy for implementers)

```elixir
defmodule ElxMcpWeb.Plugs.MCPAuth do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    presented = List.first(get_req_header(conn, "x-api-key"))

    case ElxMcp.Auth.authenticate_api_key(presented) do
      {:ok, %{api_key: key, project: project}} ->
        conn
        |> assign(:current_project, project)
        |> assign(:project_id, project.id)
        |> assign(:api_key_id, key.id)
        |> assign(:api_key_prefix, key.key_prefix)
        |> assign(:actor_email, key.email)
        |> assign(:api_key_scopes, key.scopes)

      {:error, _} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, ~s({"error":"unauthorized"}))
        |> halt()
    end
  end
end
```

**Never** include `presented` in assigns, logs, or error bodies.
