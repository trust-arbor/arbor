defmodule Mix.Tasks.Arbor.Template do
  @moduledoc """
  Manage agent templates.

  Templates are JSON files in `.arbor/templates/` that define agent
  personalities, capabilities, and configuration. They can be edited
  with any text editor.

  ## Usage

      mix arbor.template                    # list all templates
      mix arbor.template list               # same as above
      mix arbor.template show <name>        # show template details
      mix arbor.template create <name>      # create a new (minimal) template
      mix arbor.template edit <name>        # open in $EDITOR
      mix arbor.template delete <name>      # delete (refuses builtins)
      mix arbor.template reload             # reload all from disk
      mix arbor.template path               # print templates directory path

  Builtin templates ship as `.md` files in `priv/templates/` — there is no
  longer a `seed` command or a module-cloning option.

  ## Options

    * `--json` - Output as raw JSON (with show)
  """

  use Mix.Task

  @shortdoc "Manage agent templates"

  @switches [
    json: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, args, _} = OptionParser.parse(args, strict: @switches)

    # Ensure the app is compiled so modules are available
    Mix.Task.run("compile", [])

    case args do
      [] -> list_templates()
      ["list"] -> list_templates()
      ["show", name] -> show_template(name, opts)
      ["create", name] -> create_template(name, opts)
      ["edit", name] -> edit_template(name)
      ["delete", name] -> delete_template(name)
      ["reload"] -> reload_templates()
      ["path"] -> print_path()
      _ -> Mix.shell().error("Unknown command. Run `mix help arbor.template` for usage.")
    end
  end

  defp list_templates do
    ensure_store()
    templates = Arbor.Agent.TemplateStore.list()

    if templates == [] do
      Mix.shell().info("No templates found. Run `mix arbor.template seed` to create builtins.")
    else
      Mix.shell().info("Templates (#{length(templates)}):\n")

      header =
        String.pad_trailing("NAME", 20) <>
          String.pad_trailing("SOURCE", 10) <> "DESCRIPTION"

      Mix.shell().info(header)
      Mix.shell().info(String.duplicate("-", 80))

      for t <- templates do
        name = String.pad_trailing(t["name"] || "?", 20)
        source = String.pad_trailing(t["source"] || "?", 10)
        desc = truncate(t["description"] || "", 36)
        Mix.shell().info("#{name}#{source}#{desc}")
      end
    end
  end

  defp show_template(name, opts) do
    ensure_store()

    case Arbor.Agent.TemplateStore.get(name) do
      {:ok, data} ->
        if opts[:json] do
          {:ok, json} = Jason.encode(data, pretty: true)
          Mix.shell().info(json)
        else
          Mix.shell().info("Template: #{data["name"]}")
          Mix.shell().info("Source: #{data["source"]}")
          Mix.shell().info("Version: #{data["version"]}")
          Mix.shell().info("Description: #{data["description"]}")
          Mix.shell().info("Nature: #{data["nature"]}")

          if char = data["character"] do
            Mix.shell().info("\nCharacter:")
            Mix.shell().info("  Name: #{char["name"]}")
            Mix.shell().info("  Role: #{char["role"]}")
            Mix.shell().info("  Tone: #{char["tone"]}")

            if traits = char["traits"] do
              trait_str =
                Enum.map_join(traits, ", ", fn t ->
                  "#{t["name"]}(#{t["intensity"]})"
                end)

              Mix.shell().info("  Traits: #{trait_str}")
            end
          end

          if goals = data["initial_goals"], do: Mix.shell().info("\nGoals: #{length(goals)}")

          if caps = data["required_capabilities"],
            do: Mix.shell().info("Capabilities: #{length(caps)}")

          Mix.shell().info("\nCreated: #{data["created_at"]}")
          Mix.shell().info("Updated: #{data["updated_at"]}")
          Mix.shell().info("\nFile: #{Arbor.Agent.TemplateStore.templates_dir()}/#{name}.json")
        end

      {:error, :not_found} ->
        Mix.shell().error("Template '#{name}' not found.")
    end
  end

  defp create_template(name, _opts) do
    ensure_store()

    if Arbor.Agent.TemplateStore.exists?(name) do
      Mix.shell().error("Template '#{name}' already exists.")
    else
      result =
        Arbor.Agent.TemplateStore.create_from_opts(name,
          description: "Custom template"
        )

      case result do
        :ok ->
          path = Path.join(Arbor.Agent.TemplateStore.templates_dir(), "#{name}.json")
          Mix.shell().info("Created template '#{name}' at #{path}")
          Mix.shell().info("Edit with: mix arbor.template edit #{name}")

        {:error, reason} ->
          Mix.shell().error("Failed to create template: #{inspect(reason)}")
      end
    end
  end

  defp edit_template(name) do
    ensure_store()
    path = Path.join(Arbor.Agent.TemplateStore.templates_dir(), "#{name}.json")

    unless File.exists?(path) do
      Mix.shell().error("Template file not found: #{path}")
      System.halt(1)
    end

    editor = System.get_env("VISUAL") || System.get_env("EDITOR") || "vi"
    port = Port.open({:spawn, "#{editor} #{path}"}, [:binary, :nouse_stdio])

    receive do
      {^port, {:exit_status, 0}} ->
        # Validate and reload
        case Arbor.Agent.TemplateStore.reload(name) do
          {:ok, _} ->
            Mix.shell().info("Template '#{name}' reloaded successfully.")

          {:error, reason} ->
            Mix.shell().error("Error reloading template: #{inspect(reason)}")

            if Mix.shell().yes?("Re-edit?") do
              edit_template(name)
            end
        end

      {^port, {:exit_status, _code}} ->
        Mix.shell().error("Editor exited with error.")
    end
  end

  defp delete_template(name) do
    ensure_store()

    case Arbor.Agent.TemplateStore.delete(name) do
      :ok ->
        Mix.shell().info("Deleted template '#{name}'.")

      {:error, :builtin_protected} ->
        Mix.shell().error("Cannot delete builtin template '#{name}'.")
    end
  end

  defp reload_templates do
    ensure_store()
    Arbor.Agent.TemplateStore.reload()
    Mix.shell().info("Templates reloaded from disk.")
    list_templates()
  end

  defp print_path do
    ensure_store()
    Mix.shell().info(Arbor.Agent.TemplateStore.templates_dir())
  end

  defp ensure_store do
    Arbor.Agent.TemplateStore.ensure_table()
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."
end
