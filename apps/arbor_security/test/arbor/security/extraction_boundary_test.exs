defmodule Arbor.Security.ExtractionBoundaryTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  @root Path.expand("../../../../../", __DIR__)

  @forbidden_kernel_modules [
    [:Arbor, :Trust],
    [:Arbor, :Actions],
    [:Arbor, :Agent],
    [:Arbor, :AI],
    [:Arbor, :Commands],
    [:Arbor, :Comms],
    [:Arbor, :Consensus],
    [:Arbor, :Dashboard],
    [:Arbor, :Gateway],
    [:Arbor, :Historian],
    [:Arbor, :LLM],
    [:Arbor, :Memory],
    [:Arbor, :Monitor],
    [:Arbor, :Orchestrator],
    [:Arbor, :Sandbox],
    [:Arbor, :Scheduler],
    [:Arbor, :Shell],
    [:Arbor, :Security, :ApprovalGuard],
    [:Arbor, :Security, :PolicyEnforcer]
  ]

  test "B9 security regression: security kernel has no policy or upper-ring module references" do
    violations =
      security_lib_files()
      |> Enum.flat_map(fn path ->
        path
        |> module_references()
        |> Enum.filter(&forbidden_policy_reference?/1)
        |> Enum.map(fn parts -> "#{relative(path)} references #{format_module(parts)}" end)
      end)

    assert violations == []
  end

  test "B9 security regression: security kernel does not depend on arbor_trust" do
    mix_exs = File.read!(Path.join(@root, "apps/arbor_security/mix.exs"))

    refute mix_exs =~ ":arbor_trust"
  end

  defp security_lib_files do
    @root
    |> Path.join("apps/arbor_security/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp module_references(path) do
    {:ok, ast} =
      path
      |> File.read!()
      |> Code.string_to_quoted(file: path)

    {_ast, refs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:__aliases__, _meta, parts} = node, refs ->
          {node, MapSet.put(refs, parts)}

        node, refs ->
          {node, refs}
      end)

    MapSet.to_list(refs)
  end

  defp forbidden_policy_reference?(parts) do
    Enum.any?(@forbidden_kernel_modules, &starts_with?(parts, &1))
  end

  defp starts_with?(parts, prefix), do: Enum.take(parts, length(prefix)) == prefix

  defp relative(path), do: Path.relative_to(path, @root)
  defp format_module(parts), do: Enum.join(parts, ".")
end
