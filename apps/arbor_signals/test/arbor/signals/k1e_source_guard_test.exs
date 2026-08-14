defmodule Arbor.Signals.K1ESourceGuardTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "production Signals lib names no Persistence or Historian modules" do
    root = find_root(__DIR__)
    files = Path.wildcard(Path.join(root, "apps/arbor_signals/lib/**/*.ex"))
    assert files != []

    Enum.each(files, fn path ->
      contents = File.read!(path)
      relative = Path.relative_to(path, root)

      refute contents =~ "Arbor.Persistence", "#{relative} names Arbor.Persistence"
      refute contents =~ "Arbor.Historian", "#{relative} names Arbor.Historian"
      refute contents =~ "Elixir.Arbor.Persistence", "#{relative} names Elixir.Arbor.Persistence"
      refute contents =~ "Elixir.Arbor.Historian", "#{relative} names Elixir.Arbor.Historian"

      refute(
        Regex.match?(~r/Module\.concat[^\n]*(Persistence|Historian)/, contents),
        "#{relative} hides Persistence or Historian via Module.concat"
      )
    end)
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
