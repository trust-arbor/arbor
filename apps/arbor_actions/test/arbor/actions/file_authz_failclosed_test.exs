defmodule Arbor.Actions.FileAuthzFailClosedTest do
  @moduledoc """
  Security regression: `Arbor.Actions.File.authorize_file_op/3` must FAIL CLOSED
  on any authorization result it doesn't explicitly recognize. Before the
  2026-06-09 fix, its catch-all clause was `_ -> {:ok, path}`, which swallowed
  `{:ok, :pending_approval, _}` (an op that needs human approval and is NOT yet
  authorized) — and any other unexpected shape — into an ALLOW. That is an
  approval bypass.

  These tests inject a security module that returns the pending-approval and
  unexpected shapes and assert denial; they fail on `git checkout HEAD~1` of the
  fix (where the catch-all returns `{:ok, path}`).
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Actions.File, as: FileActions

  defmodule PendingSecurity do
    @moduledoc false
    def authorize(_agent, _uri, _action, _opts), do: {:ok, :pending_approval, "proposal_1"}
  end

  defmodule WeirdSecurity do
    @moduledoc false
    def authorize(_agent, _uri, _action, _opts), do: :totally_unexpected
  end

  defmodule AllowSecurity do
    @moduledoc false
    def authorize(_agent, _uri, _action, _opts), do: {:ok, :authorized}
  end

  setup do
    on_exit(fn -> Application.delete_env(:arbor_actions, :security_module) end)
    :ok
  end

  @ctx %{agent_id: "agent_x"}

  test "denies a pending_approval result instead of allowing it" do
    Application.put_env(:arbor_actions, :security_module, PendingSecurity)

    assert {:error, {:unauthorized, {:requires_approval, "proposal_1"}}} =
             FileActions.authorize_file_op(@ctx, "/ws/secret", :write)
  end

  test "fails closed on an unexpected authorization result" do
    Application.put_env(:arbor_actions, :security_module, WeirdSecurity)

    assert {:error, {:unauthorized, {:unexpected_authz_result, :totally_unexpected}}} =
             FileActions.authorize_file_op(@ctx, "/ws/secret", :write)
  end

  test "still allows a genuinely authorized op (no regression on the happy path)" do
    Application.put_env(:arbor_actions, :security_module, AllowSecurity)
    assert {:ok, "/ws/secret"} = FileActions.authorize_file_op(@ctx, "/ws/secret", :write)
  end

  test "system-level calls (no agent_id) still pass through" do
    assert {:ok, "/ws/secret"} = FileActions.authorize_file_op(%{}, "/ws/secret", :read)
  end
end
