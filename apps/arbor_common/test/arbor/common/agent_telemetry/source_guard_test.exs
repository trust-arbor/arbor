defmodule Arbor.Common.AgentTelemetry.SourceGuardTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  @forbidden [
    {~r/Arbor\.Persistence/, "Arbor.Persistence"},
    {~r/Ecto\./, "Ecto."},
    {~r/Schemas\.TelemetryEvent/, "Schemas.TelemetryEvent"},
    {~r/Code\.ensure_loaded\?/, "Code.ensure_loaded?"},
    {~r/Module\.concat/, "Module.concat"},
    {~r/\bapply\(/, "apply("}
  ]

  test "production telemetry code names no Persistence, Ecto, schemas, or hide mechanisms" do
    root = find_root(__DIR__)
    dir = Path.join(root, "apps/arbor_common/lib/arbor/common/agent_telemetry")

    files =
      dir
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)

    assert files != [], "expected production telemetry files under #{dir}"

    for path <- files do
      contents = File.read!(path)

      for {regex, label} <- @forbidden do
        refute Regex.match?(regex, contents), "#{Path.relative_to(path, root)} names #{label}"
      end
    end
  end

  defp find_root(dir) do
    cond do
      File.exists?(Path.join([dir, "apps", "arbor_contracts", "mix.exs"])) ->
        dir

      Path.dirname(dir) == dir ->
        flunk("umbrella root not found from #{__DIR__}")

      true ->
        find_root(Path.dirname(dir))
    end
  end
end
