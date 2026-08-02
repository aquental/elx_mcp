defmodule ElxMcp.Auth do
  @moduledoc """
  API key generation, verification, and revocation.
  """

  import Ecto.Query
  alias ElxMcp.Auth.{ApiKey, Scope}
  alias ElxMcp.Catalog
  alias ElxMcp.Repo

  @last_used_debounce_seconds 60

  @doc """
  Generates a 32-byte key. Returns `{:ok, api_key, plaintext_hex}` once.
  """
  def create_api_key(project_id, email, attrs \\ %{}) do
    raw = :crypto.strong_rand_bytes(32)
    plaintext = Base.encode16(raw, case: :lower)
    prefix = Base.encode16(binary_part(raw, 0, 4), case: :lower)
    hash = :crypto.hash(:sha256, raw)

    attrs_map = Map.new(attrs)
    scopes = Map.get(attrs_map, :scopes) || Map.get(attrs_map, "scopes") || ["project:read"]

    if not Enum.all?(List.wrap(scopes), &(&1 in Catalog.scopes())) do
      {:error, :invalid_scopes}
    else
      Repo.with_tenant(project_id, fn ->
        %ApiKey{}
        |> ApiKey.changeset(Map.put(attrs_map, :email, email))
        |> Ecto.Changeset.put_change(:project_id, project_id)
        |> Ecto.Changeset.put_change(:key_hash, hash)
        |> Ecto.Changeset.put_change(:key_prefix, prefix)
        |> Ecto.Changeset.put_change(:scopes, List.wrap(scopes))
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

  Uses RLS bypass for the lookup (key is the tenant discovery path), then returns Scope.
  """
  def verify_api_key(plaintext, email)
      when is_binary(plaintext) and is_binary(email) do
    normalized_email = normalize_email(email)

    result =
      Repo.with_bypass(fn ->
        with true <- normalized_email != "",
             true <- valid_hex_key?(plaintext),
             {:ok, raw} <- Base.decode16(plaintext, case: :mixed),
             hash <- :crypto.hash(:sha256, raw),
             %ApiKey{} = key <- fetch_active_key(hash),
             true <- is_list(key.scopes) and "project:read" in key.scopes,
             true <- emails_match?(key.email, normalized_email) do
          touch_last_used(key)

          scope = %Scope{
            project_id: key.project_id,
            actor_email: key.email,
            api_key_id: key.id,
            scopes: key.scopes,
            key_prefix: key.key_prefix,
            project: key.project
          }

          {:ok, scope}
        else
          _ -> {:error, :unauthorized}
        end
      end)

    case result do
      {:ok, {:ok, %Scope{}} = ok} -> ok
      {:ok, {:error, :unauthorized}} -> {:error, :unauthorized}
      {:error, _} -> {:error, :unauthorized}
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

  def revoke_api_key(%ApiKey{} = key) do
    Repo.with_tenant(key.project_id, fn ->
      key
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:microsecond))
      |> Repo.update()
    end)
  end

  def get_api_key!(id) do
    {:ok, key} =
      Repo.with_bypass(fn ->
        Repo.get!(ApiKey, id)
      end)

    key
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

  defp fetch_active_key(hash) do
    Repo.one(
      from k in ApiKey,
        where: k.key_hash == ^hash and is_nil(k.revoked_at),
        preload: [:project]
    )
  end

  defp touch_last_used(%ApiKey{id: id, last_used_at: last}) do
    now = DateTime.utc_now(:microsecond)

    should_update? =
      is_nil(last) or DateTime.diff(now, last, :second) >= @last_used_debounce_seconds

    if should_update? do
      from(k in ApiKey, where: k.id == ^id)
      |> Repo.update_all(set: [last_used_at: now])
    end

    :ok
  end
end
