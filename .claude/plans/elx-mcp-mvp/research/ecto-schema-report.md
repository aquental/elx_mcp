# Data Model: ElxMCP MVP (SPEC v0.2)

**Ash check:** No `Ash.Resource` / `ash_postgres` in repo. Pure Ecto + PostgreSQL.

**Existing state:** `ElxMcp.Repo` only; `priv/repo/migrations/` empty. DB host `hermes` (`elx_mcp_dev`).

**App module root:** `ElxMcp` · **IDs:** `:binary_id` (UUID) · **Timestamps:** `:utc_datetime_usec`

---

## Domain Overview

Multi-tenant project-status store for MCP read tools. Tenant boundary is **`projects`**. Every work item and collaboration row carries `project_id` for isolation. Hierarchy:

```
Project 1──* Epic 0..*── UserStory 1──* Ticket 0..*── Ticket (subtask via parent_ticket_id)
         1──* Board, Sprint, Component, ApiKey
         1──* Comment | Attachment | Worklog | Changelog  (polymorphic / ticket-scoped)
```

**Rules (SPEC §4):**

| Rule | Enforcement |
|------|-------------|
| Story may omit epic | `user_stories.epic_id` nullable, `on_delete: :nilify_all` |
| Ticket always under story | `tickets.user_story_id` NOT NULL, `on_delete: :delete_all` |
| Sub-tasks | `parent_ticket_id` self-FK; type `subtask` requires parent |
| Issue keys | Shared `projects.issue_counter` → `{PROJECT_KEY}-{N}` for epic/story/ticket |
| API key = one project | `api_keys.project_id` NOT NULL; auth always scopes by key’s project |

**Polymorphism note (SPEC §4.10–4.14):** SPEC mandates Rails-style `*_type` + `*_id` for `component_links`, `comments`, `attachments`, `changelogs`. True FKs to multiple parents are impossible; we use:

- `Ecto.Enum` (or string check) for `*_type`
- Unique indexes on `(type, id, …)`
- Application validation that the target exists **and** shares `project_id`
- Denormalized `project_id` on collab tables for tenant isolation without join

Do **not** introduce additional polymorphic shapes beyond SPEC.

---

## Migration Order and DDL Outline

Prefer **one migration per table** (or one compound migration for greenfield MVP). Order respects FKs:

| # | Migration | Depends on |
|---|-----------|------------|
| 1 | `create_projects` | — |
| 2 | `create_boards` | projects |
| 3 | `create_sprints` | projects, boards |
| 4 | `create_components` | projects |
| 5 | `create_epics` | projects |
| 6 | `create_user_stories` | projects, epics, boards, sprints |
| 7 | `create_tickets` | projects, user_stories, boards, sprints (+ self-ref) |
| 8 | `create_component_links` | components |
| 9 | `create_comments` | projects |
| 10 | `create_attachments` | projects |
| 11 | `create_worklogs` | projects, tickets |
| 12 | `create_changelogs` | projects |
| 13 | `create_api_keys` | projects |

All tables: `primary_key: false` + `add :id, :binary_id, primary_key: true`; `timestamps(type: :utc_datetime_usec)`.

### 1. `projects`

```elixir
create table(:projects, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :key, :string, null: false
  add :name, :string, null: false
  add :description, :string
  add :issue_counter, :integer, null: false, default: 0
  add :metadata, :map, null: false, default: %{}
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:projects, [:key])
# Optional CHECK: issue_counter >= 0
```

### 2. `boards`

```elixir
create table(:boards, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
  add :name, :string, null: false
  add :type, :string, null: false, default: "scrum"
  add :metadata, :map, null: false, default: %{}
  timestamps(type: :utc_datetime_usec)
end

create index(:boards, [:project_id])
create unique_index(:boards, [:project_id, :name])
```

### 3. `sprints`

```elixir
create table(:sprints, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
  add :board_id, references(:boards, type: :binary_id, on_delete: :nilify_all)
  add :name, :string, null: false
  add :goal, :string
  add :status, :string, null: false, default: "future"
  add :start_on, :date
  add :end_on, :date
  add :metadata, :map, null: false, default: %{}
  timestamps(type: :utc_datetime_usec)
end

create index(:sprints, [:project_id])
create index(:sprints, [:board_id])
create index(:sprints, [:project_id, :status])
```

### 4. `components`

```elixir
create table(:components, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
  add :name, :string, null: false
  add :description, :string
  add :lead_email, :string
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:components, [:project_id, :name])
```

### 5. `epics`

```elixir
create table(:epics, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
  add :key, :string, null: false
  add :title, :string, null: false
  add :description, :string
  add :status, :string, null: false, default: "to_do"
  add :priority, :string, null: false, default: "medium"
  add :owner_email, :string
  add :starts_on, :date
  add :due_on, :date
  add :metadata, :map, null: false, default: %{}
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:epics, [:key])
create index(:epics, [:project_id, :status])
create index(:epics, [:project_id])
```

### 6. `user_stories`

```elixir
create table(:user_stories, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
  add :epic_id, references(:epics, type: :binary_id, on_delete: :nilify_all)
  add :board_id, references(:boards, type: :binary_id, on_delete: :nilify_all)
  add :sprint_id, references(:sprints, type: :binary_id, on_delete: :nilify_all)
  add :key, :string, null: false
  add :title, :string, null: false
  add :description, :string
  add :status, :string, null: false, default: "to_do"
  add :priority, :string, null: false, default: "medium"
  add :story_points, :integer
  add :assignee_email, :string
  add :reporter_email, :string
  add :labels, {:array, :string}, null: false, default: []
  add :metadata, :map, null: false, default: %{}
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:user_stories, [:key])
create index(:user_stories, [:project_id])
create index(:user_stories, [:epic_id])
create index(:user_stories, [:project_id, :status])
create index(:user_stories, [:sprint_id])
create index(:user_stories, [:board_id])
```

### 7. `tickets`

```elixir
create table(:tickets, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
  add :user_story_id, references(:user_stories, type: :binary_id, on_delete: :delete_all), null: false
  add :parent_ticket_id, references(:tickets, type: :binary_id, on_delete: :nilify_all)
  add :board_id, references(:boards, type: :binary_id, on_delete: :nilify_all)
  add :sprint_id, references(:sprints, type: :binary_id, on_delete: :nilify_all)
  add :key, :string, null: false
  add :title, :string, null: false
  add :description, :string
  add :type, :string, null: false, default: "task"
  add :status, :string, null: false, default: "to_do"
  add :priority, :string, null: false, default: "medium"
  add :assignee_email, :string
  add :reporter_email, :string
  add :original_estimate_seconds, :integer
  add :remaining_estimate_seconds, :integer
  add :time_spent_seconds, :integer, null: false, default: 0
  add :labels, {:array, :string}, null: false, default: []
  add :metadata, :map, null: false, default: %{}
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:tickets, [:key])
create index(:tickets, [:project_id])
create index(:tickets, [:user_story_id])
create index(:tickets, [:parent_ticket_id])
create index(:tickets, [:project_id, :status])
create index(:tickets, [:project_id, :type])
create index(:tickets, [:sprint_id])
create index(:tickets, [:board_id])
```

### 8. `component_links`

```elixir
create table(:component_links, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :component_id, references(:components, type: :binary_id, on_delete: :delete_all), null: false
  add :linkable_type, :string, null: false
  add :linkable_id, :binary_id, null: false
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:component_links, [:component_id, :linkable_type, :linkable_id])
create index(:component_links, [:linkable_type, :linkable_id])
```

### 9. `comments`

```elixir
create table(:comments, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
  add :commentable_type, :string, null: false
  add :commentable_id, :binary_id, null: false
  add :author_email, :string, null: false
  add :body, :string, null: false
  timestamps(type: :utc_datetime_usec)
end

create index(:comments, [:project_id])
create index(:comments, [:commentable_type, :commentable_id])
```

### 10. `attachments`

```elixir
create table(:attachments, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
  add :attachable_type, :string, null: false
  add :attachable_id, :binary_id, null: false
  add :filename, :string, null: false
  add :content_type, :string
  add :byte_size, :integer
  add :storage_path, :string, null: false
  add :uploaded_by_email, :string
  timestamps(type: :utc_datetime_usec)
end

create index(:attachments, [:project_id])
create index(:attachments, [:attachable_type, :attachable_id])
```

### 11. `worklogs`

```elixir
create table(:worklogs, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
  add :ticket_id, references(:tickets, type: :binary_id, on_delete: :delete_all), null: false
  add :author_email, :string, null: false
  add :time_spent_seconds, :integer, null: false
  add :started_at, :utc_datetime_usec
  add :note, :string
  timestamps(type: :utc_datetime_usec)
end

create index(:worklogs, [:project_id])
create index(:worklogs, [:ticket_id])
```

### 12. `changelogs` (append-only)

```elixir
create table(:changelogs, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
  add :entity_type, :string, null: false
  add :entity_id, :binary_id, null: false
  add :actor_email, :string
  add :field, :string, null: false
  add :old_value, :string
  add :new_value, :string
  # only inserted_at — no updated_at
  timestamps(type: :utc_datetime_usec, updated_at: false)
end

create index(:changelogs, [:project_id])
create index(:changelogs, [:entity_type, :entity_id])
create index(:changelogs, [:project_id, :inserted_at])
```

### 13. `api_keys`

```elixir
create table(:api_keys, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
  add :email, :string, null: false
  add :key_hash, :binary, null: false
  add :key_prefix, :string, null: false
  add :name, :string
  add :last_used_at, :utc_datetime_usec
  add :revoked_at, :utc_datetime_usec
  add :expires_at, :utc_datetime_usec  # nullable; unused in MVP
  add :scopes, {:array, :string}, null: false, default: ["project:read"]
  add :metadata, :map, null: false, default: %{}
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:api_keys, [:key_hash])
create index(:api_keys, [:project_id, :email])
# Partial index for auth hot path (Postgres):
create index(:api_keys, [:key_hash],
  where: "revoked_at IS NULL",
  name: :api_keys_active_key_hash_index
)
# Note: unique on key_hash already covers lookup; partial helps if many revoked rows
```

**Migration safety (greenfield):** normal indexes OK (no concurrent). On later production tables with data, use `concurrently: true` + `@disable_ddl_transaction true` for new indexes.

---

## Shared Enums

```elixir
# lib/elx_mcp/projects/enums.ex (or per-schema @statuses)
@issue_statuses ~w(backlog to_do in_progress in_review done cancelled)a
@priorities ~w(lowest low medium high highest)a
@ticket_types ~w(task bug subtask spike chore)a
@board_types ~w(scrum kanban)a
@sprint_statuses ~w(future active closed)a
@linkable_types ~w(epic user_story ticket)a
@changelog_entity_types ~w(epic user_story ticket sprint board)a  # extend as needed
```

Use `Ecto.Enum` on schemas; store as strings in DB (default Ecto.Enum dump).

---

## Entities & Schema Modules

**Suggested layout:**

```text
lib/elx_mcp/
  tenancy/project.ex
  projects/{epic,user_story,ticket,board,sprint,component,component_link}.ex
  collaboration/{comment,attachment,worklog,changelog}.ex
  auth/api_key.ex
```

Global schema config (in each schema or via shared macro later):

```elixir
@primary_key {:id, :binary_id, autogenerate: true}
@foreign_key_type :binary_id
@timestamps_opts [type: :utc_datetime_usec]
```

### Project (`ElxMcp.Tenancy.Project`)

**Table:** `projects`

| Field | Type | Constraints | Notes |
|-------|------|-------------|-------|
| id | :binary_id | PK | |
| key | :string | unique, not null | 2–10 uppercase |
| name | :string | not null | |
| description | :string | | |
| issue_counter | :integer | ≥ 0, default 0 | Jira sequence |
| metadata | :map | default %{} | |

**Associations:**

- `has_many :epics` → `on_delete: :delete_all` (DB)
- `has_many :user_stories`, `:tickets`, `:boards`, `:sprints`, `:components`, `:api_keys`, `:comments`, `:attachments`, `:worklogs`, `:changelogs`

**Changesets:**

- `create_changeset/2` — cast `key`, `name`, `description`, `metadata`; validate key format; `unique_constraint(:key)`; never cast `issue_counter` from external input
- `update_changeset/2` — name, description, metadata only (key immutable after create)

```elixir
defmodule ElxMcp.Tenancy.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "projects" do
    field :key, :string
    field :name, :string
    field :description, :string
    field :issue_counter, :integer, default: 0
    field :metadata, :map, default: %{}

    has_many :epics, ElxMcp.Projects.Epic
    has_many :user_stories, ElxMcp.Projects.UserStory
    has_many :tickets, ElxMcp.Projects.Ticket
    has_many :boards, ElxMcp.Projects.Board
    has_many :sprints, ElxMcp.Projects.Sprint
    has_many :components, ElxMcp.Projects.Component
    has_many :api_keys, ElxMcp.Auth.ApiKey

    timestamps()
  end

  @key_regex ~r/^[A-Z][A-Z0-9]{1,9}$/

  def create_changeset(project, attrs) do
    project
    |> cast(attrs, [:key, :name, :description, :metadata])
    |> update_change(:key, &normalize_key/1)
    |> validate_required([:key, :name])
    |> validate_format(:key, @key_regex)
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:key)
  end

  def update_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :description, :metadata])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
  end

  defp normalize_key(nil), do: nil
  defp normalize_key(key) when is_binary(key), do: String.upcase(String.trim(key))
end
```

### Epic (`ElxMcp.Projects.Epic`)

**Table:** `epics`

| Field | Type | Constraints |
|-------|------|-------------|
| project_id | FK | not null, delete_all |
| key | :string | unique, not null — set by issue key gen |
| title | :string | not null |
| status | Ecto.Enum | issue statuses, default `:to_do` |
| priority | Ecto.Enum | priorities, default `:medium` |
| owner_email | :string | |
| starts_on / due_on | :date | |
| metadata | :map | |

**Associations:** `belongs_to :project`; `has_many :user_stories` (`on_delete: :nilify_all` at DB)

**Changesets:** `create_changeset` requires title + project_id (put_change); key via context after counter; status/priority inclusion. `update_changeset` excludes key/project_id.

### UserStory (`ElxMcp.Projects.UserStory`)

**Table:** `user_stories`

| Field | Type | Notes |
|-------|------|-------|
| project_id | FK not null | |
| epic_id | FK nullable | story without epic OK |
| board_id / sprint_id | FK nullable | |
| key, title, status, priority | | same pattern as epic |
| story_points | :integer | ≥ 0 if present |
| assignee_email / reporter_email | :string | |
| labels | {:array, :string} | default [] |

**Associations:** `belongs_to` project, epic, board, sprint; `has_many :tickets` (`delete_all`)

**Validations:** if `epic_id` set, epic must belong to same `project_id` (custom validation / prepare_changes).

### Ticket (`ElxMcp.Projects.Ticket`)

**Table:** `tickets`

| Field | Type | Notes |
|-------|------|-------|
| user_story_id | FK **required** | ticket always under story |
| parent_ticket_id | self FK nullable | sub-tasks |
| type | Ecto.Enum | task/bug/subtask/spike/chore |
| time_*_seconds | :integer | estimates; `time_spent_seconds` aggregated |

**Associations:**

- `belongs_to :project`, `:user_story`, `:board`, `:sprint`
- `belongs_to :parent_ticket, Ticket`
- `has_many :subtasks, Ticket, foreign_key: :parent_ticket_id`
- `has_many :worklogs`

**Key validations (changeset + context):**

1. **`user_story_id` required** — `validate_required` + `foreign_key_constraint`
2. **Subtask parent** — if `type == :subtask`, require `parent_ticket_id`; if parent set, prefer type subtask
3. **Same project / story** — parent’s `project_id` and `user_story_id` match child (custom validation after preload/lookup)
4. **No cycles** — app-level: walk `parent_ticket_id` chain; reject if self or ancestor includes self; max depth guard (e.g. 16)
5. Estimates / time_spent ≥ 0

```elixir
def create_changeset(ticket, attrs) do
  ticket
  |> cast(attrs, [
    :title, :description, :type, :status, :priority,
    :assignee_email, :reporter_email, :labels, :metadata,
    :board_id, :sprint_id, :parent_ticket_id, :user_story_id,
    :original_estimate_seconds, :remaining_estimate_seconds
  ])
  # project_id + key set in context, not cast from client
  |> validate_required([:title, :user_story_id, :type, :status])
  |> validate_subtask_parent()
  |> foreign_key_constraint(:user_story_id)
  |> foreign_key_constraint(:parent_ticket_id)
  |> unique_constraint(:key)
end

defp validate_subtask_parent(changeset) do
  type = get_field(changeset, :type)
  parent = get_field(changeset, :parent_ticket_id)

  cond do
    type == :subtask and is_nil(parent) ->
      add_error(changeset, :parent_ticket_id, "is required for subtasks")

    type != :subtask and not is_nil(parent) ->
      # soft preference: either force type subtask or clear parent — SPEC: prefer null if not subtask
      add_error(changeset, :parent_ticket_id, "only allowed when type is subtask")

    true ->
      changeset
  end
end
```

**Cycle check** lives in context (needs DB reads):

```elixir
defp assert_no_parent_cycle(ticket_id, parent_id) when ticket_id == parent_id,
  do: {:error, :cycle}

defp assert_no_parent_cycle(ticket_id, parent_id) do
  # walk ancestors of parent_id; if ticket_id appears → cycle
end
```

### Board / Sprint / Component

**Board:** `belongs_to :project`; `has_many :sprints`; type enum scrum|kanban; unique `(project_id, name)`.

**Sprint:** `belongs_to :project`, `:board`; status future|active|closed; optional date range validation `end_on >= start_on`.

**Component:** unique `(project_id, name)`; `has_many :component_links`.

### ComponentLink (`ElxMcp.Projects.ComponentLink`)

| Field | Type |
|-------|------|
| component_id | FK |
| linkable_type | Ecto.Enum epic\|user_story\|ticket |
| linkable_id | :binary_id |

No `belongs_to` polymorphic target — query by type+id. Unique triple index.

### Comment / Attachment / Worklog / Changelog

**Comment:** denormalized `project_id`; `commentable_type` + `commentable_id`; author_email + body required.

**Attachment:** metadata-only MVP; storage_path required.

**Worklog:** `belongs_to :ticket`; `time_spent_seconds > 0`; on insert/delete, Multi updates `tickets.time_spent_seconds`.

**Changelog:** append-only; `timestamps(updated_at: false)`; no update changeset.

### ApiKey (`ElxMcp.Auth.ApiKey`)

| Field | Type | Notes |
|-------|------|-------|
| project_id | FK not null | |
| email | :string | not null |
| key_hash | :binary | unique — SHA-256 of 32-byte raw |
| key_prefix | :string | e.g. 8 hex chars (first 4 bytes) |
| name | :string | label |
| last_used_at | :utc_datetime_usec | |
| revoked_at | :utc_datetime_usec | soft revoke |
| expires_at | :utc_datetime_usec | nullable, unused MVP |
| scopes | {:array, :string} | default `["project:read"]` |

**Never** store plaintext. Generation only in Auth context / mix task:

```elixir
raw = :crypto.strong_rand_bytes(32)
prefix = Base.encode16(binary_part(raw, 0, 4), case: :lower)
hash = :crypto.hash(:sha256, raw)
plaintext = Base.encode16(raw, case: :lower)  # show once
```

Auth lookup: `where: [key_hash: ^hash], where: is_nil(revoked_at)`, preload `:project`.

---

## Relationships Diagram

```
projects ─┬─< epics ─< user_stories ─< tickets ─< tickets (parent_ticket_id)
          │              ^                │
          │              │ epic_id?       ├─ board_id?, sprint_id?
          ├─< boards ────┤                └─< worklogs
          ├─< sprints ───┘
          ├─< components ─< component_links (→ epic|story|ticket)
          ├─< api_keys
          ├─< comments     (→ epic|story|ticket)
          ├─< attachments  (→ epic|story|ticket)
          └─< changelogs   (→ entity_type + entity_id)
```

---

## Issue Key Generation (Transactional Counter)

**Invariant:** One global sequence per project for epics, stories, and tickets → `PROJ-1`, `PROJ-2`, …

**Algorithm (inside `Repo.transaction` / `Ecto.Multi`):**

```elixir
defmodule ElxMcp.Tenancy do
  import Ecto.Query

  def next_issue_key(%Project{} = project) do
    # Row lock prevents concurrent duplicate N
    {1, [counter]} =
      from(p in Project,
        where: p.id == ^project.id,
        select: p.issue_counter,
        update: [inc: [issue_counter: 1]]
      )
      |> Repo.update_all([])  # runs in current transaction if wrapped

    # Prefer FOR UPDATE pattern for clarity:
    # project = Project |> where(id: ^id) |> lock("FOR UPDATE") |> Repo.one!
    # n = project.issue_counter + 1
    # project |> change(%{issue_counter: n}) |> Repo.update!
    # key = "#{project.key}-#{n}"

    n = counter + 1  # if using update_all returning old value — adjust to RETURNING
    {:ok, "#{project.key}-#{n}"}
  end
end
```

**Recommended Multi for create epic/story/ticket:**

```elixir
Ecto.Multi.new()
|> Ecto.Multi.one(:project, from(p in Project, where: p.id == ^project_id, lock: "FOR UPDATE"))
|> Ecto.Multi.run(:key, fn _repo, %{project: p} ->
  n = p.issue_counter + 1
  {:ok, {n, "#{p.key}-#{n}"}}
end)
|> Ecto.Multi.update(:bump, fn %{project: p, key: {n, _}} ->
  Ecto.Changeset.change(p, issue_counter: n)
end)
|> Ecto.Multi.insert(:issue, fn %{key: {_n, key}} ->
  attrs
  |> Map.put(:key, key)
  |> Map.put(:project_id, project_id)
  |> then(&Issue.create_changeset(%Issue{}, &1))
end)
|> Repo.transaction()
```

**Notes:**

- Do **not** cast `key` or `issue_counter` from external/API params.
- Unique index on `key` is the safety net if lock is missed.
- Keys are globally unique strings (Jira-style); project prefix already namespaces them.
- Counter never decreases (no reuse on delete).

---

## Indexes for Multi-Tenant Queries

MCP tools always filter by `project_id` from the API key.

| Query pattern | Index |
|---------------|-------|
| Auth by hash | `unique(api_keys.key_hash)` + filter `revoked_at IS NULL` |
| List epics by status | `(epics.project_id, status)` |
| List stories by epic/sprint/status | `epic_id`, `sprint_id`, `(project_id, status)` |
| List tickets by story/type/status | `user_story_id`, `(project_id, status)`, `(project_id, type)` |
| Subtasks of ticket | `parent_ticket_id` |
| Comments on entity | `(commentable_type, commentable_id)` + `project_id` |
| Changelog for entity | `(entity_type, entity_id)`, `(project_id, inserted_at)` |
| Search by key | unique `key` on epics/stories/tickets (exact get) |
| Component links for item | `(linkable_type, linkable_id)` |
| Keys per email | `(api_keys.project_id, email)` |

**Search (`search_work_items`):** MVP can use `ILIKE` on title/description with `project_id` filter. Optional later: `pg_trgm` GIN on title. Not required for initial schema.

**Preload strategy:**

- `belongs_to` (epic, story, project, board, sprint): JOIN or single preload OK
- `has_many` tickets under story, subtasks, comments: **separate queries** (avoid row multiplication)
- MCP list endpoints: paginate (`limit`/`offset` or keyset on `inserted_at`)

---

## Query Patterns

```elixir
defmodule ElxMcp.Projects.TicketQuery do
  import Ecto.Query
  alias ElxMcp.Projects.Ticket

  def base, do: from(t in Ticket, as: :ticket)

  def for_project(q, project_id),
    do: from([ticket: t] in q, where: t.project_id == ^project_id)

  def with_status(q, status) when is_atom(status),
    do: from([ticket: t] in q, where: t.status == ^status)

  def for_story(q, story_id),
    do: from([ticket: t] in q, where: t.user_story_id == ^story_id)

  def roots(q),
    do: from([ticket: t] in q, where: is_nil(t.parent_ticket_id))

  def by_key(q, key),
    do: from([ticket: t] in q, where: t.key == ^key)
end

# MCP isolation — always:
TicketQuery.base()
|> TicketQuery.for_project(conn.assigns.current_project.id)
|> TicketQuery.with_status(:in_progress)
|> Repo.all()
```

```elixir
# Api key authenticate
def authenticate(raw_hex) when is_binary(raw_hex) do
  with {:ok, raw} <- Base.decode16(raw_hex, case: :lower),
       hash <- :crypto.hash(:sha256, raw),
       %ApiKey{} = key <-
         ApiKey
         |> where([k], k.key_hash == ^hash and is_nil(k.revoked_at))
         |> preload(:project)
         |> Repo.one() do
    {:ok, key}
  else
    _ -> {:error, :unauthorized}
  end
end
```

---

## Transaction Requirements

| Operation | Pattern |
|-----------|---------|
| Create epic / story / ticket | Multi: lock project → bump counter → insert with key |
| Create subtask | Same + parent cycle check + same story/project |
| Insert worklog | Multi: insert worklog → recompute/sum `tickets.time_spent_seconds` |
| Revoke API key | Simple update `revoked_at` |
| Record changelog | Insert-only after successful update of entity (same Multi step) |
| Delete project | DB cascade via `on_delete: :delete_all` |

Worklog aggregate example:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:worklog, Worklog.create_changeset(...))
|> Ecto.Multi.run(:refresh_spent, fn repo, %{worklog: w} ->
  total =
    from(wl in Worklog, where: wl.ticket_id == ^w.ticket_id, select: sum(wl.time_spent_seconds))
    |> repo.one() || 0

  from(t in Ticket, where: t.id == ^w.ticket_id)
  |> repo.update_all(set: [time_spent_seconds: total])
  |> then(fn _ -> {:ok, total} end)
end)
|> Repo.transaction()
```

---

## Context Boundaries (SPEC §5)

| Context | Owns |
|---------|------|
| `ElxMcp.Tenancy` | Project CRUD, `next_issue_key` / counter |
| `ElxMcp.Projects` | Epics, stories, tickets, boards, sprints, components, links |
| `ElxMcp.Collaboration` | Comments, attachments, worklogs, changelogs |
| `ElxMcp.Auth` | Generate/revoke/authenticate API keys |
| `ElxMcp.MCP` | Read tools only — always pass `project_id` from auth |

Cross-context: Projects may call Tenancy for keys; Collaboration never accepts untrusted `project_id` without matching parent entity.

---

## Seeds (acceptance §8)

1 project (`DEMO`), 1 board, 1 sprint, 1 epic, 2 stories (one without epic optional), 4 tickets (incl. 1 subtask), sample comments + changelog, 1 API key (print hash only in seeds; document demo key generation in mix task for dev).

---

## Migration Checklist

- [ ] `null: false` explicit on required columns
- [ ] `on_delete` on every FK (`delete_all` / `nilify_all` per SPEC)
- [ ] Indexes co-located with create table migrations
- [ ] UUID PKs + `utc_datetime_usec`
- [ ] No money/float fields
- [ ] `issue_counter` not writable via public changesets
- [ ] Changelog `updated_at: false`
- [ ] `key_hash` as `:binary` (bytea), unique
- [ ] Polymorphic types validated via Ecto.Enum + app existence checks

---

## Performance Considerations

- **Tenant isolation:** leading column of composite indexes is always `project_id` where multi-column.
- **Auth path:** single point lookup by `key_hash` (unique) — O(1); update `last_used_at` async/throttled to avoid write contention.
- **Status dashboards:** `(project_id, status)` supports `project_status` counts via `group_by`.
- **Recent items:** order by `inserted_at desc` + limit; add `(project_id, inserted_at desc)` later if needed.
- **Preloads:** separate queries for has_many collections on `get_*` tools.

---

## Out of Scope (schema)

- Soft-delete on work items
- Full-text search indexes (optional later)
- Attachment blob storage tables
- Write-side optimistic locking (`lock_version`) — optional for post-MVP writes
- Separate issue key sequences per type (SPEC: one counter)

---

## Implementation Notes for Next Step

1. Run `mix ecto.gen.migration create_projects` … (or single `create_elx_mcp_core_schema`) in order above.
2. Implement schemas + changesets under context modules.
3. Implement `ElxMcp.Tenancy.next_issue_key/1` with `FOR UPDATE` before any seed data that creates issues.
4. Tests: counter concurrency (async tasks same project), story without epic, ticket without story fails, subtask cycle rejected, api_key authenticate/revoke, multi-tenant query isolation.

**Repo:** `ElxMcp.Repo` · **Host:** `hermes` · **SPEC:** v0.2
