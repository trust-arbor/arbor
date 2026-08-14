defmodule Arbor.Signals.K1FSourceGuardTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "production Signals lib names no Security modules" do
    root = find_root(__DIR__)

    refute File.exists?(
             Path.join(
               root,
               "apps/arbor_signals/lib/arbor/signals/adapters/security_authorizer.ex"
             )
           )

    files = Path.wildcard(Path.join(root, "apps/arbor_signals/lib/**/*.ex"))
    assert files != []

    Enum.each(files, fn path ->
      contents = File.read!(path)
      relative = Path.relative_to(path, root)

      refute contents =~ "Arbor.Security", "#{relative} names Arbor.Security"
      refute contents =~ "Elixir.Arbor.Security", "#{relative} names Elixir.Arbor.Security"

      refute(
        Regex.match?(~r/Module\.concat[^\n]*Security/, contents),
        "#{relative} hides Security via Module.concat"
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
