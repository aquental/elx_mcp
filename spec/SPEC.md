# SPEC — ElxMCP: Servidor MCP de Status de Projeto

> **Status:** v0.2 — decisões fechadas (respostas do §7 v0.1 incorporadas)  
> **App:** `elx_mcp` (Phoenix 1.8 + Ecto + PostgreSQL)  
> **Banco de dados:** PostgreSQL em host `hermes` (dev e prod)  
> **Biblioteca MCP:** `anubis_mcp` ~> 1.14

---

## 1. Visão geral

### 1.1 Objetivo

Expor, via **Model Context Protocol (MCP)**, o **status do projeto** (épicos, user stories, tickets e artefatos relacionados) para clientes MCP (Claude Desktop, Cursor, Grok, etc.), de forma que um agente de IA consulte o andamento do trabalho sem acessar o banco diretamente.

A aplicação é **multi-tenant**: vários projetos no mesmo banco; cada **API Key** autentica acesso a **um** projeto.

### 1.2 Escopo (MVP)

| Dentro do escopo | Fora do escopo |
| ---------------- | -------------- |
| Multi-tenant: tabela `projects` + isolamento por API Key | OAuth / SSO |
| Modelo Jira-like: épicos, stories, tickets, sub-tasks, sprints, boards, components, comments, attachments, time tracking, changelog | Sync bidirecional com Jira Cloud/Server real |
| Servidor MCP (`anubis_mcp`) na mesma app Phoenix | App/OTP separado só para MCP |
| Tools + Resources de **somente leitura** | Tools de escrita (`create` / `update`) |
| Auth via `X-API-Key` (32 bytes, SHA-256) | Expiração automática de chaves |
| Criação de API keys via **mix task** | LiveView/admin UI completo de gestão |
| Telemetry nos tools MCP | OpenTelemetry exporter full (pode vir depois; hooks Telemetry sim) |
| CORS habilitado para clientes browser-based | Transporte stdio |

### 1.3 Princípios

1. **Read-only no MVP:** MCP só lê; mutações ficam para versão posterior.
2. **Hierarquia:** `Project → Epic → User Story → Ticket` (+ sub-task via `parent_ticket_id`).
3. **Regras de vínculo:** story **pode** existir sem épico; ticket **deve** ter user story.
4. **API Key = projeto + e-mail:** chave de 32 bytes, hash SHA-256, múltiplas chaves por e-mail, sem expiração default (rotação manual).
5. **Visibilidade:** a chave enxerga o **projeto inteiro** (não filtra por assignee).
6. **Mesma app Phoenix** serve UI (futura) + MCP em Streamable HTTP.
7. **Idioma bilíngue** nas tools/resources MCP (nomes/descrições PT + EN).

---

## 2. Decisões congeladas (origem: perguntas v0.1)

| # | Tema | Decisão |
| - | ---- | -------- |
| 1 | Multi-tenant | Vários `projects`; API Key **por projeto**; nome/identidade do projeto na `api_keys` (FK) |
| 2 | Keys de issues | Contador estilo Jira: `{PROJECT_KEY}-{N}` |
| 3 | Hierarquia solta | Story sem epic **permitida**; ticket sem story **proibido** |
| 4 | Sub-tasks | Sim, via `parent_ticket_id` |
| 5 | MCP MVP | Somente leitura (`project:read`) |
| 6 | Superfície | **Tools e Resources** |
| 7 | `project_status` | Contagens + lista dos **N** itens mais recentes (e bloqueados quando aplicável) |
| 8 | Escopo da key | Vê o **projeto inteiro** |
| 9 | Header | **`X-API-Key`** |
| 10 | Chaves / e-mail | **Múltiplas** chaves por e-mail |
| 11 | Expiração | **Não** expiram por default; usuário pode **rotacionar/revogar** |
| 12 | Hash | **SHA-256** simples (sem pepper obrigatório) |
| 13 | Tamanho da key | **32 bytes** (`:crypto.strong_rand_bytes(32)`) |
| 14 | Transporte | **Streamable HTTP** apenas (`/mcp`) |
| 15 | CORS | **Sim** |
| 16 | Deploy | **Mesma** app Phoenix (UI + MCP) |
| 17 | Status | Alinhados ao **Jira** (ver §4.8) |
| 18 | Campos extras MVP | Sprint, board, components, comments, attachments, time tracking |
| 19 | Histórico | **Comments** + **changelog** no modelo MVP |
| 20 | Idioma MCP | **Bilíngue** (PT/EN) |
| 21 | Criar API keys | **`mix` task** |
| 22 | Host DB | **`hermes`** em dev e prod |
| 23 | Observabilidade | **Telemetry** nos tools MCP |

---

## 3. Biblioteca MCP

### 3.1 Dependência

```elixir
# mix.exs
{:anubis_mcp, "~> 1.14.0"}
```

**Por quê:** manutenção ativa (fork do Hermes), client + server, integração Phoenix (`StreamableHTTP.Plug`), components tipados (`tool` / `resource` / `prompt`).

Não confundir **`anubis_mcp` / Hermes MCP (lib)** com o hostname Postgres **`hermes`**.

### 3.2 Integração

```elixir
# lib/elx_mcp/mcp/server.ex
defmodule ElxMcp.MCP.Server do
  use Anubis.Server,
    name: "ElxMCP Project Status",
    version: "0.2.0",
    capabilities: [:tools, :resources]

  component ElxMcp.MCP.Tools.ProjectStatus
  component ElxMcp.MCP.Tools.ListEpics
  component ElxMcp.MCP.Tools.GetEpic
  component ElxMcp.MCP.Tools.ListUserStories
  component ElxMcp.MCP.Tools.GetUserStory
  component ElxMcp.MCP.Tools.ListTickets
  component ElxMcp.MCP.Tools.GetTicket
  component ElxMcp.MCP.Tools.SearchWorkItems
  # resources registrados conforme Anubis (component type: :resource)

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end
```

```elixir
# router — auth por X-API-Key no pipeline :mcp
pipeline :mcp do
  plug :accepts, ["json"]
  plug ElxMcpWeb.Plugs.MCPAuth
  plug CORSPlug   # ou config CORS do endpoint; ver §7
end

scope "/mcp" do
  pipe_through :mcp
  forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: ElxMcp.MCP.Server
end
```

```elixir
# application.ex
{ElxMcp.MCP.Server, transport: :streamable_http}
```

O plug `MCPAuth` lê `X-API-Key`, valida hash, carrega `project_id` + `email` no `conn.assigns` (e propaga ao frame MCP conforme suporte Anubis / assigns).

---

## 4. Modelo de dados

Todas as tabelas no PostgreSQL host **`hermes`**, via `ElxMcp.Repo`. IDs primários: **UUID** (`:binary_id`), salvo onde indicado.

### 4.1 Diagrama

```text
┌──────────────┐
│   projects   │
└──────┬───────┘
       │ 1:N
       ├──────────────────┬──────────────────┬─────────────────┬──────────────┐
       ▼                  ▼                  ▼                 ▼              ▼
┌─────────────┐   ┌──────────────┐   ┌─────────────┐   ┌────────────┐  ┌──────────┐
│   epics     │   │    boards    │   │   sprints   │   │ components │  │ api_keys │
└──────┬──────┘   └──────┬───────┘   └──────┬──────┘   └─────┬──────┘  └──────────┘
       │ 0..N stories    │                  │                │
       ▼                 │                  │                │
┌────────────────┐       │                  │                │
│  user_stories  │◄──────┼──────────────────┼────────────────┘ (M:N opcional)
└──────┬─────────┘       │                  │
       │ 1:N (obrig.)    │                  │
       ▼                 ▼                  ▼
┌─────────────┐     (board_issues / sprint membership via FKs ou join tables)
│   tickets   │◄──── parent_ticket_id (sub-tasks)
└──────┬──────┘
       │
       ├──── comments (polimórfico: epic | story | ticket)
       ├──── attachments (polimórfico)
       ├──── worklogs (time tracking em tickets)
       └──── changelogs (histórico de mudanças)
```

### 4.2 Tabela `projects`

| Coluna | Tipo | Constraints | Descrição |
| ------ | ---- | ----------- | --------- |
| `id` | `:binary_id` | PK | |
| `key` | `:string` | unique, not null | Prefixo Jira, ex.: `PROJ` (2–10 chars, uppercase) |
| `name` | `:string` | not null | Nome legível |
| `description` | `:string` | | |
| `issue_counter` | `:integer` | not null, default `0` | Sequencial para keys `{key}-{N}` |
| `metadata` | `:map` | default `%{}` | |
| `inserted_at` / `updated_at` | `:utc_datetime_usec` | not null | |

**Índices:** unique `key`.

**Geração de issue key:** em transação, incrementar `issue_counter` e emitir `#{project.key}-#{n}` para epics, stories e tickets (mesmo contador global do projeto, estilo Jira).

### 4.3 Tabela `epics`

| Coluna | Tipo | Constraints | Descrição |
| ------ | ---- | ----------- | --------- |
| `id` | `:binary_id` | PK | |
| `project_id` | `:binary_id` | FK → `projects`, not null, on_delete: `:delete_all` | |
| `key` | `:string` | unique, not null | Ex.: `PROJ-1` |
| `title` | `:string` | not null | |
| `description` | `:string` | | |
| `status` | `:string` | not null, default `"to_do"` | §4.8 |
| `priority` | `:string` | default `"medium"` | §4.8 |
| `owner_email` | `:string` | | |
| `starts_on` | `:date` | | |
| `due_on` | `:date` | | |
| `metadata` | `:map` | default `%{}` | |
| timestamps | | | |

**Índices:** unique `key`; `(project_id, status)`.

### 4.4 Tabela `user_stories`

| Coluna | Tipo | Constraints | Descrição |
| ------ | ---- | ----------- | --------- |
| `id` | `:binary_id` | PK | |
| `project_id` | `:binary_id` | FK → `projects`, not null, on_delete: `:delete_all` | |
| `epic_id` | `:binary_id` | FK → `epics`, **nullable**, on_delete: `:nilify_all` | Story **sem** epic permitida |
| `board_id` | `:binary_id` | FK → `boards`, nullable | |
| `sprint_id` | `:binary_id` | FK → `sprints`, nullable | |
| `key` | `:string` | unique, not null | |
| `title` | `:string` | not null | |
| `description` | `:string` | | Critérios de aceite (markdown) |
| `status` | `:string` | not null, default `"to_do"` | |
| `priority` | `:string` | default `"medium"` | |
| `story_points` | `:integer` | | |
| `assignee_email` | `:string` | | |
| `reporter_email` | `:string` | | |
| `labels` | `{:array, :string}` | default `[]` | |
| `metadata` | `:map` | default `%{}` | |
| timestamps | | | |

**Índices:** unique `key`; `project_id`; `epic_id`; `status`; `sprint_id`.

### 4.5 Tabela `tickets`

| Coluna | Tipo | Constraints | Descrição |
| ------ | ---- | ----------- | --------- |
| `id` | `:binary_id` | PK | |
| `project_id` | `:binary_id` | FK → `projects`, not null, on_delete: `:delete_all` | |
| `user_story_id` | `:binary_id` | FK → `user_stories`, **not null**, on_delete: `:delete_all` | Ticket **sempre** sob uma story |
| `parent_ticket_id` | `:binary_id` | FK → `tickets`, nullable, on_delete: `:nilify_all` | Sub-task |
| `board_id` | `:binary_id` | FK → `boards`, nullable | |
| `sprint_id` | `:binary_id` | FK → `sprints`, nullable | |
| `key` | `:string` | unique, not null | |
| `title` | `:string` | not null | |
| `description` | `:string` | | |
| `type` | `:string` | not null, default `"task"` | `task` \| `bug` \| `subtask` \| `spike` \| `chore` |
| `status` | `:string` | not null, default `"to_do"` | |
| `priority` | `:string` | default `"medium"` | |
| `assignee_email` | `:string` | | |
| `reporter_email` | `:string` | | |
| `original_estimate_seconds` | `:integer` | | Time tracking |
| `remaining_estimate_seconds` | `:integer` | | |
| `time_spent_seconds` | `:integer` | default `0` | Agregado dos worklogs |
| `labels` | `{:array, :string}` | default `[]` | |
| `metadata` | `:map` | default `%{}` | |
| timestamps | | | |

**Índices:** unique `key`; `project_id`; `user_story_id`; `parent_ticket_id`; `status`; `type`.

**Regras de domínio:**

- `user_story_id` **obrigatório**.
- Se `type == "subtask"`, `parent_ticket_id` obrigatório; caso contrário, preferencialmente nulo.
- `parent_ticket_id` e o ticket pai devem pertencer ao **mesmo** `project_id` e, preferencialmente, à mesma `user_story_id`.
- Ciclos em `parent_ticket_id` proibidos (validação na aplicação).

### 4.6 Tabela `boards`

| Coluna | Tipo | Constraints | Descrição |
| ------ | ---- | ----------- | --------- |
| `id` | `:binary_id` | PK | |
| `project_id` | `:binary_id` | FK, not null, on_delete: `:delete_all` | |
| `name` | `:string` | not null | |
| `type` | `:string` | not null, default `"scrum"` | `scrum` \| `kanban` |
| `metadata` | `:map` | default `%{}` | |
| timestamps | | | |

**Índices:** `(project_id, name)` unique opcional.

### 4.7 Tabela `sprints`

| Coluna | Tipo | Constraints | Descrição |
| ------ | ---- | ----------- | --------- |
| `id` | `:binary_id` | PK | |
| `project_id` | `:binary_id` | FK, not null, on_delete: `:delete_all` | |
| `board_id` | `:binary_id` | FK → `boards`, nullable | |
| `name` | `:string` | not null | Ex.: `Sprint 14` |
| `goal` | `:string` | | |
| `status` | `:string` | not null, default `"future"` | `future` \| `active` \| `closed` |
| `start_on` | `:date` | | |
| `end_on` | `:date` | | |
| `metadata` | `:map` | default `%{}` | |
| timestamps | | | |

### 4.8 Status e prioridades (estilo Jira)

**Status de issues** (epics, user_stories, tickets) — strings validadas no changeset:

| Valor (DB) | Label EN | Label PT |
| ---------- | -------- | -------- |
| `backlog` | Backlog | Backlog |
| `to_do` | To Do | A Fazer |
| `in_progress` | In Progress | Em Andamento |
| `in_review` | In Review | Em Revisão |
| `done` | Done | Concluído |
| `cancelled` | Cancelled | Cancelado |

> Alinhado a fluxos comuns de Jira Software (Backlog → To Do → In Progress → In Review → Done). `cancelled` cobre cancelamento explícito.

**Prioridades (Jira):**

| Valor | Label |
| ----- | ----- |
| `lowest` | Lowest |
| `low` | Low |
| `medium` | Medium |
| `high` | High |
| `highest` | Highest |

### 4.9 Tabela `components`

| Coluna | Tipo | Constraints | Descrição |
| ------ | ---- | ----------- | --------- |
| `id` | `:binary_id` | PK | |
| `project_id` | `:binary_id` | FK, not null, on_delete: `:delete_all` | |
| `name` | `:string` | not null | |
| `description` | `:string` | | |
| `lead_email` | `:string` | | |
| timestamps | | | |

**Unique:** `(project_id, name)`.

### 4.10 Join `component_links` (M:N componente ↔ work item)

| Coluna | Tipo | Constraints |
| ------ | ---- | ----------- |
| `id` | `:binary_id` | PK |
| `component_id` | `:binary_id` | FK, not null, on_delete: `:delete_all` |
| `linkable_type` | `:string` | not null — `epic` \| `user_story` \| `ticket` |
| `linkable_id` | `:binary_id` | not null |
| timestamps | | |

**Unique:** `(component_id, linkable_type, linkable_id)`.

### 4.11 Tabela `comments`

| Coluna | Tipo | Constraints | Descrição |
| ------ | ---- | ----------- | --------- |
| `id` | `:binary_id` | PK | |
| `project_id` | `:binary_id` | FK, not null | denormalizado p/ isolamento |
| `commentable_type` | `:string` | not null | `epic` \| `user_story` \| `ticket` |
| `commentable_id` | `:binary_id` | not null | |
| `author_email` | `:string` | not null | |
| `body` | `:string` | not null | markdown |
| timestamps | | | |

**Índices:** `(commentable_type, commentable_id)`; `project_id`.

### 4.12 Tabela `attachments`

| Coluna | Tipo | Constraints | Descrição |
| ------ | ---- | ----------- | --------- |
| `id` | `:binary_id` | PK | |
| `project_id` | `:binary_id` | FK, not null | |
| `attachable_type` | `:string` | not null | `epic` \| `user_story` \| `ticket` |
| `attachable_id` | `:binary_id` | not null | |
| `filename` | `:string` | not null | |
| `content_type` | `:string` | | |
| `byte_size` | `:integer` | | |
| `storage_path` | `:string` | not null | path local ou URI objeto |
| `uploaded_by_email` | `:string` | | |
| timestamps | | | |

> MVP: metadados + path; upload HTTP/LiveView pode ser fase posterior. MCP só **lista** attachments (não faz upload).

### 4.13 Tabela `worklogs` (time tracking)

| Coluna | Tipo | Constraints | Descrição |
| ------ | ---- | ----------- | --------- |
| `id` | `:binary_id` | PK | |
| `project_id` | `:binary_id` | FK, not null | |
| `ticket_id` | `:binary_id` | FK → `tickets`, not null, on_delete: `:delete_all` | |
| `author_email` | `:string` | not null | |
| `time_spent_seconds` | `:integer` | not null, `> 0` | |
| `started_at` | `:utc_datetime_usec` | | |
| `note` | `:string` | | |
| timestamps | | | |

Atualizar `tickets.time_spent_seconds` ao inserir/remover worklogs (context ou trigger app-level).

### 4.14 Tabela `changelogs` (histórico)

| Coluna | Tipo | Constraints | Descrição |
| ------ | ---- | ----------- | --------- |
| `id` | `:binary_id` | PK | |
| `project_id` | `:binary_id` | FK, not null | |
| `entity_type` | `:string` | not null | `epic` \| `user_story` \| `ticket` \| `sprint` | … |
| `entity_id` | `:binary_id` | not null | |
| `actor_email` | `:string` | | |
| `field` | `:string` | not null | ex.: `status`, `assignee_email` |
| `old_value` | `:string` | | serializado |
| `new_value` | `:string` | | serializado |
| `inserted_at` | `:utc_datetime_usec` | not null | só insert (append-only) |

**Índices:** `(entity_type, entity_id)`; `project_id`.

### 4.15 Tabela `api_keys`

| Coluna | Tipo | Constraints | Descrição |
| ------ | ---- | ----------- | --------- |
| `id` | `:binary_id` | PK | |
| `project_id` | `:binary_id` | FK → `projects`, **not null**, on_delete: `:delete_all` | Uma key → um projeto |
| `email` | `:string` | not null | Titular |
| `key_hash` | `:binary` | unique, not null | SHA-256 do raw (32 bytes) |
| `key_prefix` | `:string` | not null | Prefixo para listagem (ex. 8 hex chars) |
| `name` | `:string` | | Rótulo (“Cursor — Alice”) |
| `last_used_at` | `:utc_datetime_usec` | | |
| `revoked_at` | `:utc_datetime_usec` | | Soft-revoke / rotação |
| `scopes` | `{:array, :string}` | default `["project:read"]` | MVP: só read |
| `metadata` | `:map` | default `%{}` | |
| timestamps | | | |

> **Sem** `expires_at` obrigatório no MVP (chaves não expiram). Campo pode existir nullable para uso futuro; default `null`.

**Índices:** unique `key_hash`; `(project_id, email)`; parciais em ativas (`revoked_at IS NULL`).

#### Geração da API Key

```elixir
raw = :crypto.strong_rand_bytes(32)                    # 32 bytes
prefix = Base.encode16(binary_part(raw, 0, 4), case: :lower)
hash = :crypto.hash(:sha256, raw)
plaintext = Base.encode16(raw, case: :lower)          # 64 hex chars — mostrar 1x
```

| Item | Spec |
| ---- | ---- |
| Entropia | 32 bytes |
| Encoding cliente | hex lowercase (64 chars) |
| Persistência | `key_hash` + `key_prefix` apenas |
| Associação | `project_id` + `email` |
| Múltiplas keys | Sim, mesmo e-mail / mesmo projeto |
| Expiração | Não (default) |
| Rotação | Revogar (`revoked_at`) + criar nova via mix task |

#### Mix task (criação)

```text
mix elx_mcp.gen_api_key --project PROJ --email alice@example.com --name "Cursor"
```

Imprime a key plaintext **uma vez** e grava hash no banco.

---

## 5. Contextos Phoenix

```text
ElxMcp.Tenancy          # projects, issue key generation
ElxMcp.Projects         # epics, user_stories, tickets, boards, sprints, components
ElxMcp.Collaboration    # comments, attachments, worklogs, changelogs
ElxMcp.Auth             # api_keys (gerar, revogar, authenticate/2)
ElxMcp.MCP              # server, tools, resources, auth bridge
```

Todas as queries de leitura do MCP **obrigam** `project_id` resolvido pela API Key (nunca confiar em `project_id` vindo do cliente sem cruzar com a key).

---

## 6. Superfície MCP (somente leitura)

Auth em todas as operações: header **`X-API-Key`**. Scope: `project:read`. Visão: **projeto inteiro** ligado à key.

Descrições de tools/resources em **bilíngue** (EN primary name estável + description EN/PT ou description com ambos).

### 6.1 Tools

| Tool | Descrição (EN / PT) | Params principais |
| ---- | ------------------- | ----------------- |
| `project_status` | Project status summary / Resumo do status do projeto | `recent_limit` (default 10): contagens por status + N itens recentes + bloqueados/in_review se houver |
| `list_epics` | List epics / Listar épicos | `status`, `priority`, `limit`, `offset` |
| `get_epic` | Get epic detail / Detalhe do épico | `key` ou `id` — inclui stories resumidas |
| `list_user_stories` | List user stories / Listar user stories | `epic_key`, `status`, `sprint_id`, `assignee_email`, paginação |
| `get_user_story` | Get user story / Detalhe da story | `key` — inclui tickets resumidos |
| `list_tickets` | List tickets / Listar tickets | `story_key`, `status`, `type`, `sprint_id`, `assignee_email`, paginação |
| `get_ticket` | Get ticket / Detalhe do ticket | `key` — sub-tasks, worklogs resumidos, components |
| `search_work_items` | Search / Buscar | `q` em key/title/description (epics+stories+tickets) |
| `list_sprints` | List sprints / Listar sprints | `status` |
| `list_boards` | List boards / Listar boards | |
| `list_comments` | List comments / Listar comentários | `entity_type`, `entity_key` |
| `list_changelog` | List changelog / Histórico de mudanças | `entity_type`, `entity_key`, `limit` |

**Não incluídos no MVP:** tools de escrita (`create_*`, `update_*`).

### 6.2 Resources

| URI | Conteúdo |
| --- | -------- |
| `project://status` | Snapshot JSON do projeto da API Key |
| `project://epics/{key}` | Épico + resumo de stories |
| `project://stories/{key}` | Story + resumo de tickets |
| `project://tickets/{key}` | Ticket completo (metadados leitura) |
| `project://sprints/{id_or_name}` | Sprint |

### 6.3 Prompts (opcional MVP+)

| Prompt | Uso |
| ------ | --- |
| `standup_summary` | Daily a partir de `project_status` + recentes |
| `blocked_items` | Foco em itens não `done` em risco / `in_review` longo |

### 6.4 Telemetry

Emitir eventos `:telemetry` por tool, por exemplo:

```elixir
[:elx_mcp, :mcp, :tool, :stop]
# metadata: %{tool: "project_status", project_id: ..., result: :ok | :error, duration_ms: ...}
```

Integrar com `ElxMcpWeb.Telemetry` / LiveDashboard quando possível.

---

## 7. Autenticação, CORS e segurança

1. Header obrigatório: **`X-API-Key: <hex_64_chars>`**.
2. `ElxMcpWeb.Plugs.MCPAuth`:
   - hash SHA-256 da key;
   - lookup por `key_hash` com `revoked_at IS NULL`;
   - `assign(:current_project, project)`, `assign(:api_key, key)`, `assign(:actor_email, email)`;
   - atualizar `last_used_at` (async ou throttle).
3. 401 se ausente/inválida/revogada.
4. Nunca logar plaintext; logs só com `key_prefix` + `project.key`.
5. **CORS:** permitir origens configuráveis (`config :elx_mcp, :mcp_cors_origins`) para clientes browser; em dev pode ser `*`.
6. Isolamento: **toda** query MCP filtra por `project_id` da key.

---

## 8. Critérios de aceite (MVP)

- [ ] Migrações: `projects`, `epics`, `user_stories`, `tickets`, `boards`, `sprints`, `components`, `component_links`, `comments`, `attachments`, `worklogs`, `changelogs`, `api_keys` no Postgres `hermes`.
- [ ] Contador Jira em `projects.issue_counter` gera keys `{KEY}-{N}` sem colisão.
- [ ] Story sem epic OK; ticket sem story rejeitado no changeset.
- [ ] Sub-tasks via `parent_ticket_id` com validação de ciclo.
- [ ] API key: 32 bytes, SHA-256, associada a `project_id` + `email`; mix task `elx_mcp.gen_api_key`.
- [ ] Múltiplas keys por e-mail; revogação sem expiração default.
- [ ] Servidor `anubis_mcp` em `/mcp` (Streamable HTTP) na mesma app.
- [ ] Tools de leitura + resources listados em §6; auth `X-API-Key`.
- [ ] `project_status` retorna contagens + N recentes.
- [ ] Key enxerga projeto inteiro.
- [ ] Descrições MCP bilíngues (PT/EN).
- [ ] CORS configurável habilitado.
- [ ] Telemetry nos tools.
- [ ] Seeds: 1 projeto, 1 board, 1 sprint, 1 epic, 2 stories, 4 tickets, comments/changelog de exemplo, 1 API key de demo (só dev).
- [ ] Testes: schemas, gen key, auth plug, contador de keys, isolamento multi-tenant.
- [ ] `mix precommit` limpo.

---

## 9. Plano de implementação

1. Migrações + schemas Ecto + contexts (`Tenancy`, `Projects`, `Collaboration`, `Auth`).
2. Mix task de API key + seeds.
3. Dependência `anubis_mcp` + `ElxMcp.MCP.Server` + tools/resources de leitura.
4. Plug `MCPAuth` + pipeline `/mcp` + CORS.
5. Telemetry + testes + `mix precommit`.

Ordem sugerida de PRs/commits lógicos: **schema → auth/keys → MCP read surface → polish**.

---

## 10. Fora do MVP (backlog)

- Tools de escrita (`create_ticket`, `update_status`, …) com scope `project:write`
- Transporte stdio
- UI LiveView de gestão
- Upload real de attachments + storage S3
- Expiração automática / pepper HMAC nas keys
- OpenTelemetry export
- Sync Jira real
- OAuth

---

## 11. Referências

- [Model Context Protocol](https://spec.modelcontextprotocol.io/)
- [anubis_mcp](https://hex.pm/packages/anubis_mcp) — [docs](https://hexdocs.pm/anubis_mcp)
- Config local: `hostname: "hermes"` em `config/dev.exs` (e prod)
- Histórico: decisões derivadas das respostas no §7 da SPEC v0.1

---

## Apêndice A — Changelog do SPEC

| Versão | Data | Notas |
| ------ | ---- | ----- |
| v0.1 | 2026-08-01 | Rascunho + perguntas abertas |
| v0.2 | 2026-08-01 | Respostas incorporadas: multi-tenant, Jira keys, hierarchy rules, extras Jira (sprint/board/components/comments/attachments/time/changelog), auth X-API-Key, read-only MCP, bilingual, mix task, telemetry, CORS, status Jira-like |
