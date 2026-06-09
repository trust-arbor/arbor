defmodule Mix.Tasks.Arbor.Security.UriInventory do
  @shortdoc "Cross-reference arbor:// URI usage against the registry and actions"

  @moduledoc """
  Inventory every `arbor://` URI namespace used in the codebase and cross-
  reference it against the canonical registry and the set of Arbor actions, to
  triage registry gaps.

      mix arbor.security.uri_inventory          # all namespaces
      mix arbor.security.uri_inventory --gaps   # only namespaces with gaps

  Columns: namespace, in registry?, action-backed?, uncovered URI count, and a
  recommendation (register / register sub-path / triage / ok). Does not start the
  application.
  """

  use Mix.Task

  alias Arbor.Actions.Security.UriInventory

  @switches [gaps: :boolean, root: :string]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile")
    {opts, _, _} = OptionParser.parse(argv, switches: @switches)

    rows = UriInventory.build(Keyword.get(opts, :root, "apps"))
    rows = if opts[:gaps], do: Enum.reject(rows, &(&1.uncovered == [])), else: rows

    Mix.shell().info(header())

    Enum.each(rows, fn r ->
      Mix.shell().info(
        "#{pad(r.namespace, 16)} #{yn(r.in_registry)}  #{yn(r.action_backed)}  " <>
          "#{pad(to_string(length(r.uncovered)), 4)}  #{r.recommendation}"
      )
    end)

    gaps = Enum.count(rows, &(&1.uncovered != []))
    Mix.shell().info("\n#{length(rows)} namespaces, #{gaps} with gaps.")
  end

  defp header do
    "#{pad("namespace", 16)} reg act  gap   recommendation\n" <>
      String.duplicate("-", 60)
  end

  defp yn(true), do: " ✓ "
  defp yn(false), do: " · "
  defp pad(s, n), do: String.pad_trailing(s, n)
end
