defmodule Arbor.Trust.CapabilityEnforcementMatrixSourceHostTest do
  use ExUnit.Case, async: true
  @moduletag :fast
  test "no production module outside arbor_trust consults the matrix" do
    umbrella = find_umbrella_root()

    hits =
      Enum.flat_map(["apps", "packages"], fn scope ->
        apps_dir = Path.join(umbrella, scope)

        apps_dir
        |> File.ls!()
        |> Enum.reject(&(&1 == "arbor_trust"))
        |> Enum.flat_map(fn app ->
          lib = Path.join([apps_dir, app, "lib"])
          if File.dir?(lib), do: scan_lib(lib, app), else: []
        end)
      end)

    assert hits == [],
           "K5 matrix must stay audit-only until hard gates exist in their " <>
             "owner apps. Production references outside arbor_trust: #{inspect(hits)}"
  end

  defp scan_lib(lib, app) do
    lib
    |> Path.join("**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      content = File.read!(file)

      if String.contains?(content, "CapabilityEnforcementMatrix") or
           String.contains?(content, "capability_enforcement_rows") or
           String.contains?(content, "capability_enforcement_for") do
        [{app, Path.relative_to(file, lib)}]
      else
        []
      end
    end)
  end

  defp find_umbrella_root(path \\ Path.expand(__DIR__)) do
    cond do
      File.dir?(Path.join(path, "apps")) and File.exists?(Path.join(path, "mix.exs")) ->
        path

      path == Path.dirname(path) ->
        flunk("could not find umbrella root from #{__DIR__}")

      true ->
        find_umbrella_root(Path.dirname(path))
    end
  end
end
