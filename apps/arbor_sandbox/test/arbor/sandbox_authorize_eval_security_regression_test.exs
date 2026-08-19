defmodule Arbor.SandboxAuthorizeEvalSecurityRegressionTest do
  @moduledoc """
  Security regression: eval-session last-mile is authorize_eval/4.

  Parent behavior (must fail on checkout of the exact parent):
  `Arbor.Sandbox.authorize_eval/4` does not exist, so agent callers
  can only use the trusted-system `eval_code/3` host API.

  Fixed behavior: `authorize_eval/4` authorizes `arbor://sandbox/eval`
  then calls `ExecSession.eval/3`. Missing or denied caller fails
  closed with `{:error, {:unauthorized, reason}}` and does not evaluate.
  Host `eval_code/3` stays the trusted-system API with no principal.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Sandbox
  alias Arbor.Sandbox.ExecSession

  @eval_resource "arbor://sandbox/eval"

  setup do
    {:ok, _} = Application.ensure_all_started(:arbor_security)

    unless Process.whereis(Arbor.Security.Identity.Registry) do
      start_supervised!({Arbor.Security.Identity.Registry, []})
    end

    unless Process.whereis(Arbor.Security.SystemAuthority) do
      start_supervised!({Arbor.Security.SystemAuthority, []})
    end

    unless Process.whereis(Arbor.Security.CapabilityStore) do
      start_supervised!({Arbor.Security.CapabilityStore, []})
    end

    unique = System.unique_integer([:positive])
    caller_id = "agent_p1d_eval_caller_#{unique}"
    {:ok, session} = ExecSession.start_link(agent_id: "agent_p1d_eval_session_#{unique}")

    on_exit(fn ->
      if Process.whereis(Arbor.Security.CapabilityStore) do
        Arbor.Security.CapabilityStore.revoke_all(caller_id)
      end
    end)

    {:ok, caller_id: caller_id, session: session}
  end

  test "security regression: authorize_eval/4 without a grant is denied and does not eval",
       %{caller_id: caller_id, session: session} do
    assert {:ok, "0"} = Sandbox.eval_code(session, "x = 0")
    assert %{execution_count: 1} = ExecSession.stats(session)

    assert {:error, {:unauthorized, _reason}} =
             Sandbox.authorize_eval(caller_id, session, "x = 1")

    assert %{execution_count: 1} = ExecSession.stats(session)
    assert {:ok, "0"} = Sandbox.eval_code(session, "x")
  end

  test "security regression: authorized authorize_eval/4 evaluates through ExecSession",
       %{caller_id: caller_id, session: session} do
    assert {:ok, _capability} =
             Arbor.Security.grant(principal: caller_id, resource: @eval_resource)

    assert {:ok, "1"} = Sandbox.authorize_eval(caller_id, session, "x = 1")
    assert {:ok, "1"} = Sandbox.eval_code(session, "x")
  end

  test "security regression: host eval_code/3 with no principal still evaluates",
       %{session: session} do
    assert {:ok, "2"} = Sandbox.eval_code(session, "1 + 1")
  end
end
