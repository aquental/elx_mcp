defmodule Mix.Tasks.ElxMcp.EnvGpg do
  @moduledoc false

  # Shared GPG helpers for env encrypt/decrypt tasks.
  # Never relies on /dev/tty (breaks in IDE/agent terminals).

  @doc """
  Runs gpg with passphrase on stdin (--passphrase-fd 0).

  Passphrase resolution order:
  1. `ELX_MCP_GPG_PASSPHRASE` env
  2. Interactive `Mix.shell().prompt/1`
  """
  def run!(gpg_args, opts \\ []) do
    ensure_gpg!()
    confirm? = Keyword.get(opts, :confirm, false)
    passphrase = resolve_passphrase!(confirm?)

    # Order: batch/passphrase flags before operation flags.
    args =
      [
        "--batch",
        "--yes",
        "--pinentry-mode",
        "loopback",
        "--passphrase-fd",
        "0"
      ] ++ gpg_args

    case gpg_cmd(args, passphrase) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, status, out}
    end
  end

  def ensure_gpg! do
    case System.find_executable("gpg") do
      nil -> Mix.raise("gpg not found on PATH. Install GnuPG 2.x.")
      _ -> :ok
    end
  end

  # System.cmd/3 has no :input on all Elixir versions — use Port for stdin.
  defp gpg_cmd(args, passphrase) do
    gpg = System.find_executable("gpg")

    port =
      Port.open(
        {:spawn_executable, gpg},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          {:args, args},
          {:parallelism, true}
        ]
      )

    # Passphrase line for --passphrase-fd 0; close stdin after write.
    true = Port.command(port, passphrase <> "\n")
    # Closing stdin: send eof by closing the port's input — Port.command with eof
    # is not available; gpg reads one line and continues. Sending nothing more is OK.

    collect_port(port, [])
  end

  defp collect_port(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_port(port, [acc, data])

      {^port, {:exit_status, status}} ->
        {IO.iodata_to_binary(acc), status}
    after
      120_000 ->
        Port.close(port)
        {"gpg timed out after 120s", 1}
    end
  end

  defp resolve_passphrase!(confirm?) do
    case System.get_env("ELX_MCP_GPG_PASSPHRASE") do
      passphrase when is_binary(passphrase) and byte_size(passphrase) > 0 ->
        Mix.shell().info("Using passphrase from ELX_MCP_GPG_PASSPHRASE.")
        passphrase

      _ ->
        prompt_passphrase!(confirm?)
    end
  end

  defp prompt_passphrase!(confirm?) do
    pass1 =
      case Mix.shell().prompt("GPG passphrase:") do
        :eof -> Mix.raise("No passphrase provided (EOF).")
        p when is_binary(p) -> String.trim_trailing(p, "\n")
      end

    if pass1 == "" do
      Mix.raise("Passphrase cannot be empty.")
    end

    if confirm? do
      pass2 =
        case Mix.shell().prompt("Repeat passphrase:") do
          :eof -> Mix.raise("No passphrase provided (EOF).")
          p when is_binary(p) -> String.trim_trailing(p, "\n")
        end

      if pass1 != pass2 do
        Mix.raise("Passphrases do not match.")
      end
    end

    pass1
  end
end
