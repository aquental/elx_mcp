defmodule Mix.Tasks.ElxMcp.Env.Encrypt do
  @shortdoc "Encrypt .env → .env.gpg with GPG symmetric (AES256)"

  @moduledoc """
  Encrypts the local `.env` file to `.env.gpg` using **GPG symmetric** encryption
  with strong parameters (AES-256 + iterated+salted S2K / SHA-512).

      mix elx_mcp.env.encrypt
      mix elx_mcp.env.encrypt --input .env --output .env.gpg
      mix elx_mcp.env.encrypt --force

  ## Passphrase

  1. Interactive: Mix prompts twice (does **not** open `/dev/tty` — works in IDEs)
  2. Non-interactive: `export ELX_MCP_GPG_PASSPHRASE='...'`

  ## Algorithms

  - Cipher: `AES256`
  - S2K mode: `3` (iterated and salted)
  - S2K digest: `SHA512`
  - S2K count: `65011712` (high work factor)

  Requires `gpg` on `PATH` (GnuPG 2.x).
  """

  use Mix.Task

  alias Mix.Tasks.ElxMcp.EnvGpg

  @default_input ".env"
  @default_output ".env.gpg"

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

    Mix.shell().info("Encrypting #{input} → #{output} (AES256 / S2K SHA512)…")

    gpg_args = [
      "--symmetric",
      "--cipher-algo",
      "AES256",
      "--s2k-mode",
      "3",
      "--s2k-digest-algo",
      "SHA512",
      "--s2k-count",
      "65011712",
      "--compress-algo",
      "none",
      "--output",
      output,
      input
    ]

    case EnvGpg.run!(gpg_args, confirm: true) do
      {:ok, out} ->
        if out != "", do: Mix.shell().info(String.trim(out))
        Mix.shell().info("OK: wrote #{output}")
        :ok

      {:error, status, out} ->
        Mix.raise("gpg encrypt failed (exit #{status}):\n#{out}")
    end
  end
end
