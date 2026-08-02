defmodule ElxMcp.Auth do
  @moduledoc """
  API key generation, verification, and revocation.

  Tenant-scoped writes use `Repo.with_tenant/2` (transaction-local RLS GUC).
  Pre-tenant lookup uses SECURITY DEFINER functions (`elx_mcp_lookup_api_key`, etc.)
  owned by a BYPASSRLS role — not a tenant-scoped HTTP surface.

  Bootstrap / admin APIs (SECDEF, not tenant-scoped HTTP):
  - `create_api_key/3`, `revoke_api_key/1`, `get_api_key!/1`, `list_api_keys/2`
  """

  import Ecto.Query
  alias ElxMcp.Auth.{ApiKey, Scope}
  alias ElxMcp.Catalog
  alias ElxMcp.Repo
  alias ElxMcp.Tenancy
  alias ElxMcp.Tenancy.Project

  @last_used_debounce_seconds 60

  @doc """
  Generates a 32-byte key. Returns `{:ok, api_key, plaintext_hex}` once.

  Admin/bootstrap API (runs under tenant for INSERT RLS). Rejects empty scopes.
  """
  def create_api_key(project_id, email, attrs \\ %{}) do
    raw = :crypto.strong_rand_bytes(32)
    plaintext = Base.encode16(raw, case: :lower)
    prefix = Base.encode16(binary_part(raw, 0, 4), case: :lower)
    hash = :crypto.hash(:sha256, raw)

    attrs_map = Map.new(attrs)
    scopes = Map.get(attrs_map, :scopes) || Map.get(attrs_map, "scopes") || ["project:read"]
    scopes = List.wrap(scopes)

    cond do
      scopes == [] ->
        {:error, :invalid_scopes}

      not Enum.all?(scopes, &(&1 in Catalog.scopes())) ->
        {:error, :invalid_scopes}

      true ->
        Repo.with_tenant(project_id, fn ->
          %ApiKey{}
          |> ApiKey.changeset(Map.put(attrs_map, :email, email))
          |> Ecto.Changeset.put_change(:project_id, project_id)
          |> Ecto.Changeset.put_change(:key_hash, hash)
          |> Ecto.Changeset.put_change(:key_prefix, prefix)
          |> Ecto.Changeset.put_change(:scopes, scopes)
          |> Ecto.Changeset.validate_required([:project_id, :key_hash, :key_prefix])
          |> Repo.insert()
          |> case do
            {:ok, api_key} -> {:ok, api_key, plaintext}
            error -> error
          end
        end)
    end
  end

  @doc """
  Verifies a hex-encoded API key **and** that it belongs to `email`.

  Lookup uses SECURITY DEFINER (no tenant GUC yet). Returns `{:ok, %Scope{}}`
  or `{:error, :unauthorized}`. Missing project after key lookup is unauthorized.
  """
  def verify_api_key(plaintext, email)
      when is_binary(plaintext) and is_binary(email) do
    normalized_email = normalize_email(email)

    with true <- normalized_email != "",
         true <- valid_hex_key?(plaintext),
         {:ok, raw} <- Base.decode16(plaintext, case: :mixed),
         hash <- :crypto.hash(:sha256, raw),
         %ApiKey{} = key <- fetch_active_key(hash),
         scopes when is_list(scopes) <- List.wrap(key.scopes),
         true <- Enum.member?(scopes, "project:read"),
         true <- emails_match?(key.email, normalized_email),
         %Project{} = project <- Tenancy.get_project(key.project_id) do
      touch_last_used(key)

      scope = %Scope{
        project_id: key.project_id,
        actor_email: key.email,
        api_key_id: key.id,
        scopes: scopes,
        key_prefix: key.key_prefix,
        project: project
      }

      {:ok, scope}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def verify_api_key(_, _), do: {:error, :unauthorized}

  defp normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  defp emails_match?(stored, provided)
       when is_binary(stored) and is_binary(provided) and byte_size(stored) == byte_size(provided) do
    Plug.Crypto.secure_compare(stored, provided)
  end

  defp emails_match?(_, _), do: false

  @doc """
  Requires `project:write` on the scope. Used at mutation boundaries.
  """
  def authorize_write(%Scope{} = scope) do
    if Scope.has_scope?(scope, "project:write"), do: :ok, else: {:error, :forbidden}
  end

  @doc """
  Revokes an API key. Admin/bootstrap (tenant-scoped UPDATE).
  """
  def revoke_api_key(%ApiKey{} = key) do
    Repo.with_tenant(key.project_id, fn ->
      key
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:microsecond))
      |> Repo.update()
    end)
  end

  def get_api_key!(id) do
    case one_from_function("SELECT * FROM elx_mcp_get_api_key($1::uuid)", [uuid_param(id)]) do
      nil -> raise Ecto.NoResultsError, queryable: ApiKey
      map -> load_api_key_struct(map)
    end
  end

  def list_api_keys(project_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50) |> min(200)

    Repo.with_tenant(project_id, fn ->
      Repo.all(
        from k in ApiKey,
          where: k.project_id == ^project_id,
          order_by: [desc: k.inserted_at],
          limit: ^limit
      )
    end)
  end

  defp valid_hex_key?(key), do: Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, key)

  defp fetch_active_key(hash) when is_binary(hash) do
    case one_from_function("SELECT * FROM elx_mcp_lookup_api_key($1)", [hash]) do
      nil -> nil
      map -> load_api_key_struct(map)
    end
  end

  defp touch_last_used(%ApiKey{id: id, last_used_at: last}) do
    now = DateTime.utc_now(:microsecond)

    should_update? =
      cond do
        is_nil(last) ->
          true

        match?(%DateTime{}, last) ->
          DateTime.diff(now, last, :second) >= @last_used_debounce_seconds

        match?(%NaiveDateTime{}, last) ->
          DateTime.diff(now, DateTime.from_naive!(last, "Etc/UTC"), :second) >=
            @last_used_debounce_seconds

        true ->
          true
      end

    if should_update? do
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT elx_mcp_touch_api_key($1::uuid, $2::timestamptz)",
        [uuid_param(id), now]
      )
    end

    :ok
  end

  defp uuid_param(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, bin} -> bin
      :error -> id
    end
  end

  defp one_from_function(sql, params) do
    result = Ecto.Adapters.SQL.query!(Repo, sql, params)

    case result.rows do
      [row] -> Map.new(Enum.zip(result.columns, row))
      _ -> nil
    end
  end

  defp load_api_key_struct(map) when is_map(map) do
    # Repo.load expects dump format for :binary_id (16-byte UUID), not strings.
    normalized =
      map
      |> normalize_row_keys()
      |> Map.update("id", nil, &dump_uuid/1)
      |> Map.update("project_id", nil, &dump_uuid/1)
      |> Map.update("scopes", [], &List.wrap/1)
      |> Map.update("metadata", %{}, fn m -> m || %{} end)

    Repo.load(ApiKey, normalized)
  end

  defp normalize_row_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end

  defp dump_uuid(nil), do: nil

  defp dump_uuid(str) when is_binary(str) and byte_size(str) == 36 do
    case Ecto.UUID.dump(str) do
      {:ok, bin} -> bin
      :error -> str
    end
  end

  defp dump_uuid(bin) when is_binary(bin) and byte_size(bin) == 16, do: bin
  defp dump_uuid(other), do: other
end
