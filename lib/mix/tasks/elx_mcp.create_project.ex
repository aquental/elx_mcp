defmodule Mix.Tasks.ElxMcp.CreateProject do
  @shortdoc "Create a project and optionally an API key"

  @moduledoc """
  Creates a multi-tenant project and, when `--email` is given, an API key.

      mix elx_mcp.create_project \\
        --key CECI \\
        --name "Projeto CECI" \\
        --description "Projeto CECI" \\
        --email antonio.quental@gmail.com

  Options:

  * `--key` — project key (2–10 chars, uppercase letters/digits; required)
  * `--name` — display name (defaults to key)
  * `--description` — optional text
  * `--email` — if set, generates an API key for this email
  * `--key-name` — label for the API key (optional)

  The API key plaintext is printed **once**.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          key: :string,
          name: :string,
          description: :string,
          email: :string,
          key_name: :string
        ]
      )

    key = Keyword.get(opts, :key)

    if is_nil(key) or String.trim(key) == "" do
      Mix.raise("""
      Usage: mix elx_mcp.create_project --key CECI [--name "..."] [--description "..."] [--email you@example.com]
      """)
    end

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:elx_mcp)

    name = Keyword.get(opts, :name) || key
    description = Keyword.get(opts, :description)
    email = Keyword.get(opts, :email)
    key_name = Keyword.get(opts, :key_name)

    attrs =
      %{key: key, name: name}
      |> then(fn m -> if description, do: Map.put(m, :description, description), else: m end)

    case ElxMcp.Tenancy.get_project_by_key(key) do
      %{} = existing ->
        Mix.shell().info("Project already exists: #{existing.key} (#{existing.name})")
        maybe_create_key(existing, email, key_name)

      nil ->
        case ElxMcp.Tenancy.create_project(attrs) do
          {:ok, project} ->
            Mix.shell().info("""
            Project created:
              key:         #{project.key}
              name:        #{project.name}
              description: #{project.description || "(none)"}
              id:          #{project.id}
            """)

            maybe_create_key(project, email, key_name)

          {:error, changeset} ->
            Mix.raise("Failed to create project: #{inspect(changeset.errors)}")
        end
    end
  end

  defp maybe_create_key(_project, nil, _key_name), do: :ok

  defp maybe_create_key(project, email, key_name) do
    attrs = if key_name, do: %{name: key_name}, else: %{name: "default"}

    case ElxMcp.Auth.create_api_key(project.id, email, attrs) do
      {:ok, api_key, plaintext} ->
        Mix.shell().info("""
        API key created (store securely — shown once):
          project:  #{project.key} (#{project.name})
          email:    #{api_key.email}
          prefix:   #{api_key.key_prefix}
          X-API-Key: #{plaintext}
          X-Email:   #{api_key.email}
        """)

      {:error, changeset} ->
        Mix.raise("Failed to create API key: #{inspect(changeset.errors)}")
    end
  end
end
