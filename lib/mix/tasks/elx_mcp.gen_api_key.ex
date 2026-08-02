defmodule Mix.Tasks.ElxMcp.GenApiKey do
  @shortdoc "Generate an API key for a project"

  @moduledoc """
  Generates a 32-byte API key for a project.

      mix elx_mcp.gen_api_key --project PROJ --email alice@example.com --name "Cursor"

  Prints the plaintext key **once**. Only the SHA-256 hash is stored.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [project: :string, email: :string, name: :string]
      )

    project_key = Keyword.get(opts, :project)
    email = Keyword.get(opts, :email)
    name = Keyword.get(opts, :name)

    if is_nil(project_key) or is_nil(email) do
      Mix.raise(
        "Usage: mix elx_mcp.gen_api_key --project KEY --email user@example.com [--name LABEL]"
      )
    end

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:elx_mcp)

    case ElxMcp.Tenancy.get_project_by_key(project_key) do
      nil ->
        Mix.raise("Project not found: #{project_key}")

      project ->
        attrs = if name, do: %{name: name}, else: %{}

        case ElxMcp.Auth.create_api_key(project.id, email, attrs) do
          {:ok, api_key, plaintext} ->
            Mix.shell().info("""
            API key created (store securely — shown once):
              project: #{project.key} (#{project.name})
              email:   #{api_key.email}
              prefix:  #{api_key.key_prefix}
              key:     #{plaintext}
            """)

          {:error, changeset} ->
            Mix.raise("Failed to create API key: #{inspect(changeset.errors)}")
        end
    end
  end
end
