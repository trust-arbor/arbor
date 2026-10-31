defmodule Arbor.KernelRuntime.TrustPolicyConfigOwnershipTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @root Path.expand("../../../../..", __DIR__)

  test "product test policy toggles belong to Trust without moving Core verification controls" do
    {:ok, ast} = @root |> Path.join("config/test.exs") |> File.read!() |> Code.string_to_quoted()

    {_ast, settings} =
      Macro.prewalk(ast, %{}, fn
        {:config, _, [owner, values]} = node, acc when is_atom(owner) and is_list(values) ->
          {node, Map.update(acc, owner, values, &Keyword.merge(&1, values))}

        node, acc ->
          {node, acc}
      end)

    trust = Map.fetch!(settings, :arbor_trust)
    core = Map.fetch!(settings, :arbor_capabilities)

    for key <- [:policy_enforcer_enabled, :approval_guard_enabled] do
      assert Keyword.fetch!(trust, key) == false
      refute Keyword.has_key?(core, key)
    end

    assert Keyword.fetch!(core, :identity_verification) == false
    assert Keyword.fetch!(core, :capability_signing_required) == false
    assert Keyword.fetch!(core, :start_children) == false
  end
end
