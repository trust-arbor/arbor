defmodule Arbor.Signals.K1FSourceGuardTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "production Signals lib names no Security modules" do
    root = find_root(__DIR__)

    refute File.exists?(
             Path.join(
               root,
               "apps/arbor_kernel_runtime/lib/arbor/signals/adapters/security_authorizer.ex"
             )
           )

    signals_root = Path.join(root, "apps/arbor_kernel_runtime/lib/arbor/signals")

    files =
      [
        Path.join(root, "apps/arbor_kernel_runtime/lib/arbor/signals.ex")
        | Path.wildcard(Path.join(signals_root, "**/*.ex"))
      ]
      |> Enum.filter(&File.regular?/1)

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
      File.exists?(Path.join([dir, "apps", "arbor_kernel", "mix.exs"])) ->
        dir

      Path.dirname(dir) == dir ->
        flunk("umbrella root not found from #{__DIR__}")

      true ->
        find_root(Path.dirname(dir))
    end
  end
end
