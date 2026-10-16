defmodule Arbor.Trust.CapabilityEnforcementMatrixAuditOnlyTest do
  @moduledoc """
  Regression: K5 matrix stays an audit declaration, not an authorize path.

  Conservative choice (2026-10-16): do not force-enforce the table at
  `Arbor.Security.authorize/4`. Hard gates must stay off that decision
  path. See `docs/arbor/K5_ENFORCEMENT_MATRIX.md`.
  """
  use ExUnit.Case, async: true

  alias Arbor.Trust.CapabilityEnforcementMatrix

  @moduletag :fast

  test "matrix API is read-only and does not authorize" do
    exports = CapabilityEnforcementMatrix.__info__(:functions)

    assert Keyword.has_key?(exports, :rows)
    assert Keyword.has_key?(exports, :row_for)
    refute Keyword.has_key?(exports, :authorize)
    refute Keyword.has_key?(exports, :check)
    refute Keyword.has_key?(exports, :enforce)
    refute Keyword.has_key?(exports, :allow)
    refute Keyword.has_key?(exports, :deny)

    rows = Arbor.Trust.capability_enforcement_rows()
    assert rows != []
    assert rows == CapabilityEnforcementMatrix.rows()

    for row <- rows do
      assert is_map(row)
      assert is_map(row.soft_gate)
      assert is_map(row.hard_gate)
      refute row.hard_gate.authorize4_dependent?
    end
  end

  test "no production module outside arbor_trust consults the matrix" do
    umbrella = find_umbrella_root()
    apps_dir = Path.join(umbrella, "apps")

    hits =
      apps_dir
      |> File.ls!()
      |> Enum.reject(&(&1 == "arbor_trust"))
      |> Enum.flat_map(fn app ->
        lib = Path.join([apps_dir, app, "lib"])

        if File.dir?(lib) do
          scan_lib(lib, app)
        else
          []
        end
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
