defmodule ElxMcp.Auth.Scope do
  @moduledoc """
  Tenant scope resolved from an API key. Passed as first argument to
  project-scoped context functions.
  """

  @enforce_keys [:project_id, :actor_email, :api_key_id, :scopes]
  defstruct [:project_id, :actor_email, :api_key_id, :scopes, :key_prefix, :project]

  @type t :: %__MODULE__{
          project_id: Ecto.UUID.t(),
          actor_email: String.t(),
          api_key_id: Ecto.UUID.t(),
          scopes: [String.t()],
          key_prefix: String.t() | nil,
          project: ElxMcp.Tenancy.Project.t() | nil
        }

  def has_scope?(%__MODULE__{scopes: scopes}, scope) when is_binary(scope) do
    scope in scopes
  end
end
