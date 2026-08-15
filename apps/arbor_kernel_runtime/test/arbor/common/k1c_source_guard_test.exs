defmodule Arbor.Common.K1CSourceGuardTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "ActionProvider names no Arbor.Actions or hide mechanisms" do
    contents =
      read_prod!(
        "apps/arbor_kernel_runtime/lib/arbor/common/capability_providers/action_provider.ex"
      )

    refute contents =~ "Arbor.Actions", "ActionProvider names Arbor.Actions"
    refute contents =~ "Code.ensure_loaded?", "ActionProvider names Code.ensure_loaded?"
    refute contents =~ "Module.concat", "ActionProvider names Module.concat"
    refute Regex.match?(~r/\bapply\(/, contents), "ActionProvider names apply("
  end

  test "SkillImporter names no Arbor.Security, Reflex, or hiding variants" do
    contents = read_prod!("apps/arbor_kernel_runtime/lib/arbor/common/skill_importer.ex")

    refute contents =~ "Arbor.Security", "SkillImporter names Arbor.Security"
    refute contents =~ "Elixir.Arbor.Security", "SkillImporter names Elixir.Arbor.Security"
    refute contents =~ "Security.Reflex", "SkillImporter names Security.Reflex"

    refute(
      Regex.match?(~r/Module\.concat[^\n]*(Security|Reflex|Actions)/, contents),
      "SkillImporter hides Security, Reflex, or Actions via Module.concat"
    )
  end

  defp read_prod!(relative) do
    root = find_root(__DIR__)
    path = Path.join(root, relative)
    assert File.regular?(path), "expected production file #{relative}"
    File.read!(path)
  end

  defp find_root(dir) do
    cond do
      File.exists?(Path.join([dir, "apps", "arbor_kernel", "mix.exs"])) ->
        dir

      Path.dirname(dir) == dir ->
        flunk("umbrella root not found from #{__DIR__}")

      true ->
        find_root(Path.dirname(dir))
    end
  end
end
