# Library Research: anubis_mcp (~> 1.14) for ElxMCP

## Recommended

### anubis_mcp
- **Hex**: https://hex.pm/packages/anubis_mcp
- **Docs**: https://anubis-mcp.hexdocs.pm/ (v1.14.0)
- **GitHub**: https://github.com/zoedsoupe/anubis-mcp
- **Downloads**: ~307k all-time; ~20k last 7 days
- **Last release**: 1.14.0 (2026-07-30) — actively maintained
- **License**: LGPL-3.0
- **Why**: First-class MCP server + Phoenix Streamable HTTP plug; component DSL for tools/resources; Frame assigns inherit `Plug.Conn.assigns` (ideal for X-API-Key → `project_id`); official recipe for API-key plug in front of MCP; documented unit + Plug.Test integration testing.
- **MCP specs (1.x)**: 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25
- **Note**: Do not confuse package name with Postgres host `hermes`.

---

## 1. Defining `Anubis.Server` and components

### Server module

```elixir
defmodule ElxMcp.MCP.Server do
  use Anubis.Server,
    name: "ElxMCP Project Status",
    version: "0.2.0",
    capabilities: [:tools, :resources]

  # Compile-time registration; name defaults to snake_case of last module segment
  component ElxMcp.MCP.Tools.ProjectStatus
  component ElxMcp.MCP.Tools.ListEpics
  component ElxMcp.MCP.Resources.ProjectOverview
  # component MyMod, name: "custom_name"

  @impl true
  def init(_client_info, frame) do
    # Prefer locking tenant into session assigns once (see §3)
    project_id = frame.assigns[:project_id]
    email = frame.assigns[:api_key_email]

    {:ok, assign(frame, project_id: project_id, api_key_email: email)}
  end
end
```

Alternative (echo example): register tools/resources **dynamically** in `init/2` via `register_tool/3`, `register_resource/3` and implement `handle_tool_call/3` / `handle_resource_read/2` on the server. Prefer **Component modules** for ElxMCP (clearer tests, one file per tool).

### Tool component

```elixir
defmodule ElxMcp.MCP.Tools.ProjectStatus do
  @moduledoc "Returns project status summary / Retorna resumo do status do projeto"

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :limit, :integer, min: 1, max: 50, default: 10,
      description: "Max recent items / Máx. itens recentes"
  end

  @impl true
  def execute(%{limit: limit}, frame) do
    project_id = frame.assigns.project_id
    summary = ElxMcp.Projects.status_summary(project_id, limit: limit)
    {:reply, Response.json(Response.tool(), summary), frame}
  end
end
```

- `@moduledoc` becomes the tool description (or implement `description/0`).
- `schema` builds JSON Schema for clients **and** validates params (atom keys, defaults applied) before `execute/2`.
- Types: `:string`, `:integer`, `:number`, `:boolean`, `:enum` + `values:`, `{:list, type}`, `embeds_one` / `embeds_many`.
- Constraints: `required`, `default`, `min`/`max`, `min_length`/`max_length`, `description`.

### Resource component

```elixir
defmodule ElxMcp.MCP.Resources.ProjectOverview do
  @moduledoc "Project overview JSON / Visão geral do projeto em JSON"

  use Anubis.Server.Component,
    type: :resource,
    uri: "project://current/overview",
    mime_type: "application/json"

  alias Anubis.Server.Response

  @impl true
  def read(_params, frame) do
    data = ElxMcp.Projects.overview(frame.assigns.project_id)
    {:reply, Response.json(Response.resource(), data), frame}
  end
end
```

- Fixed URI via `uri:`; templates via `uri_template:` (RFC 6570) — mutually exclusive.
- Callback is `read/2` (not `execute/2`).

### Prompts

Not needed for MVP (read-only tools + resources). Pattern: `type: :prompt` + `get_messages/2` + `Response.prompt() |> Response.user_message(...)`.

---

## 2. Phoenix router + Streamable HTTP

### Dependency

```elixir
# mix.exs
{:anubis_mcp, "~> 1.14.0"}
```

### Supervision

```elixir
# lib/elx_mcp/application.ex children
children = [
  ElxMcpWeb.Endpoint,
  {ElxMcp.MCP.Server, transport: :streamable_http}
  # optional: session_idle_timeout: to_timeout(minute: 30)
]
```

- Server process and HTTP plug are separate; plug routes into the supervised transport.
- With Phoenix, HTTP transport starts only when the endpoint is serving (like `PHX_SERVER`). Force in tests: `transport: {:streamable_http, start: true}`.
- Env override: `ANUBIS_MCP_SERVER=true`.

### Router

```elixir
# lib/elx_mcp_web/router.ex
pipeline :mcp do
  # event-stream required for GET SSE; json for POST
  plug :accepts, ["json", "event-stream"]
  plug ElxMcpWeb.Plugs.MCPAuth
  # CORS as per SPEC §7
end

scope "/mcp" do
  pipe_through :mcp
  forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: ElxMcp.MCP.Server
end
```

**Plug options:**
| Option | Default | Notes |
|--------|---------|--------|
| `:server` | required | Server module |
| `:session_header` | `"mcp-session-id"` | Session id header |
| `:request_timeout` | `30_000` | ms |
| `:subscriber_metadata` | `fn _ -> %{} end` | Tag SSE subscribers (use remote capture) |

**HTTP methods on `/mcp`:**
- **POST** — JSON-RPC (initialize, tools/call, resources/read, …)
- **GET** — SSE stream (Accept must include `text/event-stream`)
- **DELETE** — close session

---

## 3. Session / auth context → `execute/2` frame

### Official pattern for X-API-Key (matches SPEC)

Anubis OAuth is **not** used for MVP. Recipes doc recommends rejecting bad keys **before** the MCP plug, and scoping tools via `frame.assigns`:

```elixir
defmodule ElxMcpWeb.Plugs.MCPAuth do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with [key] <- get_req_header(conn, "x-api-key"),
         {:ok, api_key} <- ElxMcp.Auth.verify_api_key(key) do
      conn
      |> assign(:project_id, api_key.project_id)
      |> assign(:api_key_email, api_key.email)
      |> assign(:api_key_id, api_key.id)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, ~s({"error":"unauthorized"}))
        |> halt()
    end
  end
end
```

### How assigns reach tools

From StreamableHTTP.Plug source (`build_request_context/2`):

```elixir
%{
  assigns: conn.assigns,   # ← Plug assigns passed through
  type: :http,
  req_headers: conn.req_headers,
  remote_ip: conn.remote_ip,
  auth: auth_claims,       # OAuth only; nil for API-key path
  ...
}
```

`%Anubis.Server.Frame{}`:
- **`frame.assigns`** — session user state; **inherits `Plug.Conn.assigns` on HTTP**.
- **`frame.context`** — read-only per request: `session_id`, `client_info`, `headers` (lowercase string keys), `remote_ip`, `auth`.

**Recommended ElxMCP flow:**
1. `MCPAuth` validates every request and sets `project_id` / email on `conn.assigns`.
2. `init/2` copies them into session assigns (stable for session lifetime).
3. Tools **always** filter with `frame.assigns.project_id` (never trust tool args for tenant).
4. Optional hardening: re-assert `project_id` from headers/assigns on each tool if you fear session fixation across keys (plug already 401s invalid keys).

**Header-based alternative** (no plug assigns):

```elixir
def init(_client_info, frame) do
  key = Map.get(frame.context.headers, "x-api-key")
  {:ok, api_key} = ElxMcp.Auth.verify_api_key!(key)
  {:ok, assign(frame, project_id: api_key.project_id)}
end
```

Prefer the plug for HTTP 401 before MCP protocol noise.

**OAuth note:** built-in `authorization:` + JWT/introspection is available but **out of SPEC scope**. Claims via `Frame.subject/1`, `Frame.scopes/1`, component `scopes: ["…"]`.

**Persistence:** if using session store, implement `serialize_assigns/1` so only JSON-safe keys (`project_id`, email) are persisted — not Ecto structs.

---

## 4. `Anubis.Server.Response` for tools

Fluent builders; return `{:reply, response, frame}` or `{:error, %Anubis.MCP.Error{}, frame}`.

```elixir
# Success — structured JSON as text content (most useful for agents)
{:reply, Response.json(Response.tool(), %{epics: 3, tickets: 12}), frame}

# Plain text
{:reply, Response.text(Response.tool(), "ok"), frame}

# structuredContent + text (pairs with output_schema)
{:reply, Response.structured(Response.tool(), %{count: 3}), frame}

# Domain error visible to the model (isError: true)
{:reply, Response.error(Response.tool(), "Project not found"), frame}

# Protocol-level error
{:error, Anubis.MCP.Error.execution("catalog backend unavailable"), frame}

# Resources
Response.resource() |> Response.text(json_string)
Response.resource() |> Response.blob(binary)
Response.json(Response.resource(), map)
```

Wire shape via `Response.to_protocol/1` → `%{"content" => [...], "isError" => false}`.

Also: `image/4`, `audio/4`, `resource_link/4`, `embedded_resource/3`.

---

## 5. Dependency + supervision checklist

| Item | Value |
|------|--------|
| Dep | `{:anubis_mcp, "~> 1.14.0"}` |
| Child | `{ElxMcp.MCP.Server, transport: :streamable_http}` |
| Route | `forward "/", StreamableHTTP.Plug, server: ElxMcp.MCP.Server` under `/mcp` |
| Pipeline | `:mcp` with `MCPAuth` **before** forward |
| Accepts | `["json", "event-stream"]` |
| CORS | Enable on MCP path (SPEC) |
| Logger (stdio only) | N/A for MVP (HTTP only) |

Transitive deps include Peri (schema), Plug, etc. Optional `:jose` only if using JWT OAuth later.

---

## 6. Testing (documented)

### Unit tests (preferred for tools)

No transport needed. Call `execute/2` / `read/2` with a hand-built frame:

```elixir
alias Anubis.Server.{Frame, Response}

frame = Frame.assign(%Frame{}, %{project_id: project.id})

assert {:reply, %Response{type: :tool, isError: false} = resp, _} =
         ElxMcp.MCP.Tools.ProjectStatus.execute(%{limit: 5}, frame)

assert [%{"type" => "text", "text" => text}] = resp.content
# or Response.to_protocol(resp)
```

Schema contract:

```elixir
schema = ElxMcp.MCP.Tools.ProjectStatus.input_schema()
assert "query" in (schema["required"] || [])
```

Server `init/2`:

```elixir
assert {:ok, frame} = ElxMcp.MCP.Server.init(%{"name" => "test"}, %Frame{assigns: %{project_id: id}})
assert frame.assigns.project_id == id
```

### Integration (Plug.Test)

```elixir
@plug_opts StreamableHTTP.Plug.init(server: ElxMcp.MCP.Server)

setup do
  start_supervised!({ElxMcp.MCP.Server, transport: {:streamable_http, start: true}})
  :ok
end

# POST initialize → read mcp-session-id header
# POST notifications/initialized with session header
# POST tools/call with session header + X-API-Key
```

Accept header must include `application/json` (and `text/event-stream` if testing SSE POST).

Docs: https://anubis-mcp.hexdocs.pm/testing.html  
Reference apps: `examples/echo-elixir` (Phoenix), `examples/upcase` (Plug).

---

## Compatibility Notes

- **Elixir / OTP**: modern Elixir (project Phoenix 1.8); library uses stdlib `JSON` in places.
- **Phoenix**: integrate via `forward` + supervised server; no special LiveView requirement for MCP.
- **Conflicts**: none known with Req/Ecto/Phoenix stack.
- **Anubis 2.x**: drops 2024-11-05 + HTTP+SSE transport; stay on 1.14 for SPEC.
- **Failure modes**: bad API key → HTTP 401 from plug; tool domain errors → `Response.error`; session idle timeout default 30 min; request timeout default 30s.
- **Multi-tenant safety**: always scope Ecto queries with `^frame.assigns.project_id` (recipe “Constrained database queries”).

## Considered but Rejected

### Built-in OAuth (`authorization:` option)
- **Why not**: SPEC freezes X-API-Key only; no OAuth/SSO in MVP.

### STDIO transport
- **Why not**: SPEC Streamable HTTP only; no stdio.

### Runtime-only registration (`register_tool` in init)
- **Why not**: works (echo example) but component modules scale better for many read-only tools + unit tests.

## No Library Needed

- API key hashing/storage: plain Ecto + `:crypto` / SHA-256.
- CORS: existing CORS plug / endpoint config.
- HTTP client: already use Req (not for MCP server path).
