defmodule Mix.Tasks.ElxMcp.Env.Decrypt do
  @shortdoc "Decrypt .env.gpg → .env with GPG"

  @moduledoc """
  Decrypts `.env.gpg` to `.env` using **GPG** (symmetric passphrase).

      mix elx_mcp.env.decrypt
      mix elx_mcp.env.decrypt --input .env.gpg --output .env
      mix elx_mcp.env.decrypt --force

  ## Passphrase

  1. Interactive: Mix prompts once (does **not** open `/dev/tty`)
  2. Non-interactive: `export ELX_MCP_GPG_PASSPHRASE='...'`

  Requires `gpg` on `PATH` (GnuPG 2.x).
  """

  use Mix.Task

  alias Mix.Tasks.ElxMcp.EnvGpg

  @default_input ".env.gpg"
  @default_output ".env"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [input: :string, output: :string, force: :boolean]
      )

    input = Keyword.get(opts, :input, @default_input)
    output = Keyword.get(opts, :output, @default_output)
    force? = Keyword.get(opts, :force, false)

    unless File.exists?(input) do
      Mix.raise("Input file not found: #{input}")
    end

    if File.exists?(output) and not force? do
      Mix.raise("Output already exists: #{output} (use --force to overwrite)")
    end

    if File.exists?(output) and force? do
      File.rm!(output)
    end

    Mix.shell().info("Decrypting #{input} → #{output}…")

    gpg_args = [
      "--decrypt",
      "--output",
      output,
      input
    ]

    case EnvGpg.run!(gpg_args, confirm: false) do
      {:ok, out} ->
        if out != "", do: Mix.shell().info(String.trim(out))
        File.chmod!(output, 0o600)
        Mix.shell().info("OK: wrote #{output} (mode 0600)")
        :ok

      {:error, status, out} ->
        Mix.raise("gpg decrypt failed (exit #{status}):\n#{out}")
    end
  end
end
