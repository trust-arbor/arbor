defmodule Mix.Tasks.Arbor.Templates.Codegen do
  @moduledoc """
  Generate the canonical Markdown+frontmatter template data files from the
  builtin template modules.

  Writes one `<name>.md` file per builtin template into
  `apps/arbor_agent/priv/templates/`, computed from
  `Arbor.Agent.TemplateStore.from_module/1` and rendered with
  `Arbor.Agent.Template.File.serialize/1`.

  This is part of the data-first template migration (Phase A): it converts the
  built-in templates to data files. It is purely additive — it does not change
  any runtime behavior or template resolution.

  ## Usage

      mix arbor.templates.codegen          # write all builtin templates
      mix arbor.templates.codegen --check  # verify files are up to date (CI)
  """

  use Mix.Task

  alias Arbor.Agent.Template.File, as: TemplateFile
  alias Arbor.Agent.TemplateStore

  @shortdoc "Generate Markdown template data files from builtin modules"

  @switches [check: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _args, _} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("app.config")

    dir = priv_templates_dir()
    File.mkdir_p!(dir)

    results =
      builtin_modules()
      |> Enum.map(fn module ->
        Code.ensure_loaded!(module)
        name = TemplateStore.module_to_name(module)
        data = TemplateStore.from_module(module)
        markdown = TemplateFile.serialize(data)
        path = Path.join(dir, "#{name}.md")
        {name, path, markdown}
      end)

    if opts[:check] do
      check(results)
    else
      Enum.each(results, fn {name, path, markdown} ->
        File.write!(path, markdown)
        Mix.shell().info("wrote #{name} -> #{path}")
      end)

      Mix.shell().info("Generated #{length(results)} template data files.")
    end
  end

  defp check(results) do
    stale =
      Enum.filter(results, fn {_name, path, markdown} ->
        case File.read(path) do
          {:ok, current} -> current != markdown
          _ -> true
        end
      end)

    case stale do
      [] ->
        Mix.shell().info("All #{length(results)} template data files are up to date.")

      list ->
        names = Enum.map_join(list, ", ", fn {name, _, _} -> name end)
        Mix.raise("Stale template data files: #{names}. Run `mix arbor.templates.codegen`.")
    end
  end

  # The 11 builtin template modules. The 10 mapped in
  # `TemplateStore.@builtin_modules` plus `ClaudeCode` (which `module_to_name/1`
  # slugs to "claude_code"). Kept here so codegen covers all shipped templates
  # without modifying `TemplateStore`.
  defp builtin_modules do
    [
      Arbor.Agent.Templates.CliAgent,
      Arbor.Agent.Templates.Scout,
      Arbor.Agent.Templates.Researcher,
      Arbor.Agent.Templates.CodeReviewer,
      Arbor.Agent.Templates.Monitor,
      Arbor.Agent.Templates.Diagnostician,
      Arbor.Agent.Templates.Conversationalist,
      Arbor.Agent.Templates.InterviewAgent,
      Arbor.Agent.Templates.ApiAgent,
      Arbor.Agent.Templates.CouncilEvaluator,
      Arbor.Agent.Templates.ClaudeCode
    ]
  end

  defp priv_templates_dir do
    Path.join(Application.app_dir(:arbor_agent, "priv"), "templates")
  end
end
