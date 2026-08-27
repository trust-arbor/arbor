defmodule Arbor.AI.AcpSession.HandlerUngrantedToolNoWaitTest do
  @moduledoc """
  Regression (2026-08-27, ombp quickstart): an ACP agent with **no**
  `arbor://acp/tool/*` capability asked for a tool, the trust policy answered
  `:gated`, and the handler escalated to the InteractionRouter and waited the
  full `permission_timeout_ms` (60 s) for an operator who was never shown the
  request — three times inside one chat turn (205 s). "Not granted" must be an
  immediate deny; only an agent that *holds* a capability for the tool is
  worth asking a human about.

  These tests fail on the pre-fix handler (it escalates and blocks) and pass
  on the fix.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.AI.AcpSession.Handler

  defmodule GatedTrustPolicy do
    @moduledoc false
    def confirmation_mode(_agent_id, _resource_uri), do: :gated
  end

  defmodule NoCapabilitiesSecurity do
    @moduledoc false
    def authorize(_agent_id, _uri, _action, _opts), do: {:error, :unauthorized}
    def list_capabilities(_agent_id, _opts), do: {:ok, []}
    def capability_authorizes?(_cap, _uri, _opts), do: false
  end

  defmodule HoldsToolSecurity do
    @moduledoc false
    def authorize(_agent_id, _uri, _action, _opts), do: {:ok, :authorized}
    def list_capabilities(_agent_id, _opts), do: {:ok, [%{resource_uri: "arbor://acp/tool/Read"}]}

    def capability_authorizes?(%{resource_uri: held}, uri, _opts),
      do: held == uri or String.starts_with?(uri, held <> "/")
  end

  defmodule LegacySecurity do
    @moduledoc false
    # No enumeration API: the handler must keep escalating (historical behaviour).
    def authorize(_agent_id, _uri, _action, _opts), do: {:ok, :authorized}
  end

  setup do
    original = %{
      security: Application.get_env(:arbor_ai, :security_module),
      trust: Application.get_env(:arbor_ai, :trust_policy_module)
    }

    Application.put_env(:arbor_ai, :trust_policy_module, GatedTrustPolicy)

    on_exit(fn ->
      restore(:security_module, original.security)
      restore(:trust_policy_module, original.trust)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_ai, key)
  defp restore(key, value), do: Application.put_env(:arbor_ai, key, value)

  defp state(timeout_ms) do
    {:ok, state} =
      Handler.init(
        session_pid: self(),
        agent_id: "agent_test_ungranted",
        provider: :claude,
        permission_timeout_ms: timeout_ms
      )

    state
  end

  defp request(state, tool) do
    tool_call = %{"tool_name" => tool, "kind" => "execute"}

    options = [
      %{"optionId" => "allow_once", "kind" => "allow_once"},
      %{"optionId" => "reject_once", "kind" => "reject_once"}
    ]

    Handler.handle_permission_request("s1", tool_call, options, state)
  end

  test "security regression: ungranted tool under a gated policy is denied immediately, without waiting" do
    Application.put_env(:arbor_ai, :security_module, NoCapabilitiesSecurity)
    state = state(5_000)

    {elapsed_us, {:ok, outcome, _state}} = :timer.tc(fn -> request(state, "Bash") end)

    assert %{"outcome" => %{"outcome" => "selected", "optionId" => "reject_once"}} = outcome

    assert elapsed_us < 1_000_000,
           "denial took #{div(elapsed_us, 1000)} ms — the handler waited for an operator"
  end

  test "a held tool under a gated policy still reaches escalation (not the not-granted deny)" do
    Application.put_env(:arbor_ai, :security_module, HoldsToolSecurity)
    state = state(50)

    {:ok, outcome, _state} = request(state, "Read")

    # With no InteractionRouter/operator in this test the escalation fails or
    # times out, which is a denial — but never the "tool not granted" one.
    assert %{"outcome" => %{"outcome" => "selected", "optionId" => "reject_once"}} = outcome
    refute Handler.holds_capability?("agent_test_ungranted", "arbor://acp/tool/Bash")
    assert Handler.holds_capability?("agent_test_ungranted", "arbor://acp/tool/Read")
  end

  test "a security module without capability enumeration keeps the escalating behaviour" do
    Application.put_env(:arbor_ai, :security_module, LegacySecurity)
    assert Handler.holds_capability?("agent_test_ungranted", "arbor://acp/tool/Bash")
  end
end
