defmodule ElxMcp.MCP.Helpers do
  @moduledoc false

  require Logger

  alias Anubis.Server.Response
  alias ElxMcp.Auth.Scope

  @drop_always ~w(__meta__)a
  @drop_parents ~w(project parent_ticket)a

  def scope_from_frame(frame) do
    cond do
      match?(%Scope{}, frame.assigns[:current_scope]) ->
        scope = frame.assigns.current_scope

        if Scope.has_scope?(scope, "project:read") do
          scope
        else
          nil
        end

      match?(
        %{project_id: pid, api_key_email: _, api_key_id: _, scopes: scopes}
        when not is_nil(pid) and is_list(scopes),
        frame.assigns
      ) ->
        assigns = frame.assigns

        scope = %Scope{
          project_id: assigns.project_id,
          actor_email: assigns.api_key_email,
          api_key_id: assigns.api_key_id,
          scopes: assigns.scopes,
          key_prefix: Map.get(assigns, :key_prefix)
        }

        if Scope.has_scope?(scope, "project:read"), do: scope, else: nil

      true ->
        nil
    end
  end

  def with_scope(frame, fun) do
    case scope_from_frame(frame) do
      %Scope{} = scope ->
        fun.(scope)

      nil ->
        log_tool("?", nil, nil, %{}, :unauthorized, 0)
        {:reply, Response.error(Response.tool(), "Unauthorized / Não autorizado"), frame}
    end
  end

  def json_reply(frame, data) do
    {:reply, Response.json(Response.tool(), data), frame}
  end

  def error_reply(frame, message) when is_binary(message) do
    {:reply, Response.error(Response.tool(), message), frame}
  end

  @doc """
  Emit telemetry and (in dev) console log after a tool finishes.
  """
  def emit_tool(tool, scope_or_project_id, start_ms, result, params \\ %{})

  def emit_tool(tool, %Scope{} = scope, start_ms, result, params) do
    duration = System.monotonic_time(:millisecond) - start_ms

    :telemetry.execute(
      [:elx_mcp, :mcp, :tool, :stop],
      %{duration_ms: duration},
      %{
        tool: tool,
        project_id: scope.project_id,
        email: scope.actor_email,
        result: result,
        params: params
      }
    )

    log_tool(tool, scope.project_id, scope.actor_email, params, result, duration)
  end

  def emit_tool(tool, project_id, start_ms, result, params) do
    duration = System.monotonic_time(:millisecond) - start_ms

    :telemetry.execute(
      [:elx_mcp, :mcp, :tool, :stop],
      %{duration_ms: duration},
      %{tool: tool, project_id: project_id, result: result, params: params}
    )

    log_tool(tool, project_id, nil, params, result, duration)
  end

  defp log_tool(tool, project_id, email, params, result, duration_ms) do
    if Application.get_env(:elx_mcp, :log_mcp_tools, false) do
      Logger.info(fn ->
        "[MCP tool] #{tool} result=#{inspect(result)} " <>
          "duration_ms=#{duration_ms} project_id=#{inspect(project_id)} " <>
          "email=#{inspect(email)} params=#{inspect(params || %{}, limit: 40)}"
      end)
    end
  end

  def encode_struct(struct) when is_struct(struct) do
    struct
    |> Map.from_struct()
    |> Map.drop(@drop_always ++ @drop_parents)
    |> Enum.reject(fn {_k, v} -> match?(%Ecto.Association.NotLoaded{}, v) end)
    |> Map.new(fn {k, v} -> {k, encode_value(v)} end)
  end

  def encode_struct(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, encode_value(v)} end)
  def encode_struct(list) when is_list(list), do: Enum.map(list, &encode_struct/1)
  def encode_struct(other), do: other

  defp encode_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_value(%Date{} = d), do: Date.to_iso8601(d)
  defp encode_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp encode_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp encode_value(list) when is_list(list), do: Enum.map(list, &encode_value/1)
  defp encode_value(%Ecto.Association.NotLoaded{}), do: nil
  defp encode_value(v) when is_struct(v), do: encode_struct(v)
  defp encode_value(v) when is_map(v), do: Map.new(v, fn {k, val} -> {k, encode_value(val)} end)
  defp encode_value(v), do: v
end
