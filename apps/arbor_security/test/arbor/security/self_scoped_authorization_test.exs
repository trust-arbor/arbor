defmodule Arbor.Security.SelfScopedAuthorizationTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security

  # Security regression coverage for `authorize_self_scoped/6` (2026-08-25).
  # A capability on the canonical parent may cover ONLY the principal's own
  # child resource. Every other relaxation here would be a hole.

  setup do
    me = "agent_self_#{:erlang.unique_integer([:positive])}"
    other = "agent_other_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      for id <- [me, other] do
        case Security.list_capabilities(id) do
          {:ok, caps} -> Enum.each(caps, &Security.revoke(&1.id))
          _ -> :ok
        end
      end
    end)

    {:ok, me: me, other: other}
  end

  test "a parent capability covers the principal's OWN scoped child", %{me: me} do
    {:ok, _} = Security.grant(principal: me, resource: "arbor://historian/query")

    assert {:ok, :authorized} =
             Security.authorize_self_scoped(
               me,
               "arbor://historian/query/agent:#{me}",
               me,
               "arbor://historian/query",
               :query,
               verify_identity: false
             )
  end

  test "security regression: a parent capability does NOT cover another subject's child",
       %{me: me, other: other} do
    {:ok, _} = Security.grant(principal: me, resource: "arbor://memory/read")

    assert {:error, _} =
             Security.authorize_self_scoped(
               me,
               "arbor://memory/read/#{other}",
               other,
               "arbor://memory/read",
               :execute,
               verify_identity: false
             )
  end

  test "security regression: self is the principal, not a claimed subject", %{
    me: me,
    other: other
  } do
    # The caller claims subject == principal but the scoped resource belongs to
    # someone else: the descendant check is on the URI, so no relaxation.
    {:ok, _} = Security.grant(principal: me, resource: "arbor://memory/read")

    assert {:error, _} =
             Security.authorize_self_scoped(
               me,
               "arbor://memory/read/#{other}",
               me,
               "arbor://memory/read/#{other}",
               :execute,
               verify_identity: false
             )
  end

  test "security regression: only a strict segment-descendant is covered", %{me: me} do
    {:ok, _} = Security.grant(principal: me, resource: "arbor://memory/read")

    # A sibling namespace that merely shares a string prefix.
    assert {:error, _} =
             Security.authorize_self_scoped(
               me,
               "arbor://memory/reader/#{me}",
               me,
               "arbor://memory/read",
               :execute,
               verify_identity: false
             )
  end

  test "a scoped grant still works on its own (no parent needed)", %{me: me} do
    {:ok, _} = Security.grant(principal: me, resource: "arbor://memory/read/#{me}")

    assert {:ok, :authorized} =
             Security.authorize_self_scoped(
               me,
               "arbor://memory/read/#{me}",
               me,
               "arbor://memory/read",
               :execute,
               verify_identity: false
             )
  end

  test "nothing held → denied even when self-scoped", %{me: me} do
    assert {:error, _} =
             Security.authorize_self_scoped(
               me,
               "arbor://memory/read/#{me}",
               me,
               "arbor://memory/read",
               :execute,
               verify_identity: false
             )
  end
end
