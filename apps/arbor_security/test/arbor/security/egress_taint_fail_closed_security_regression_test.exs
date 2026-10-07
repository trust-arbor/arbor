defmodule Arbor.Security.EgressTaintFailClosedSecurityRegressionTest do
  @moduledoc """
  Security regression (Imp review D3, 2026-09-27): the egress gate's taint
  conjunct — the fail-closed part of the egress ceiling — read a missing,
  misspelled, nil, string-valued, or otherwise unrecognized `:egress_taint` as
  "no taint". That skipped both the `:hostile` and `:untrusted` hard-block
  branches and fell through to the policy check alone, so a caller that
  dropped or mistyped the option could send data to an external destination
  under nothing but an `:allow` standing.

  Post-fix, anything the gate cannot read as a known level is decided as
  `:untrusted` (same posture as `TaintEnvelope.missing_fallback/0`). Callers
  whose model means "no label = clean" must pass `:trusted` explicitly.

  Asserted through the public `Arbor.Security.authorize_egress/3` and
  `Arbor.Security.authorize/4` APIs with enforcement on and an explicit
  `egress_mode: :allow` standing, so the only thing that can deny is the taint
  conjunct. Pre-fix every "denied" case below returned `:allow`/`{:ok, _}`.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.{Capability, Taint}
  alias Arbor.Security.CapabilityStore

  @moduletag :fast

  @resource "arbor://ai/generate"

  setup do
    prev = Application.get_env(:arbor_security, :egress_gate_enforcing)
    Application.put_env(:arbor_security, :egress_gate_enforcing, true)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:arbor_security, :egress_gate_enforcing),
        else: Application.put_env(:arbor_security, :egress_gate_enforcing, prev)
    end)

    %{agent_id: "agent_d3_#{System.unique_integer([:positive])}"}
  end

  defp egress(agent, tier, opts), do: Arbor.Security.authorize_egress(agent, tier, opts)

  describe "security regression: unreadable egress taint is :untrusted, not absent" do
    test "omitted :egress_taint blocks external egress despite an :allow standing",
         %{agent_id: agent} do
      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               egress(agent, :external_provider, egress_mode: :allow)
    end

    test "misspelled key carrying :hostile is not silently dropped", %{agent_id: agent} do
      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               egress(agent, :external_provider, egress_tain: :hostile, egress_mode: :allow)
    end

    test "explicit nil taint blocks", %{agent_id: agent} do
      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               egress(agent, :external_provider, egress_taint: nil, egress_mode: :allow)
    end

    test "string-valued levels are read, not ignored", %{agent_id: agent} do
      assert {:error, {:egress_blocked, :external_provider, :hostile}} =
               egress(agent, :external_provider, egress_taint: "hostile", egress_mode: :allow)

      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               egress(agent, :external_provider, egress_taint: "untrusted", egress_mode: :allow)
    end

    test "unknown atoms and strings block as :untrusted", %{agent_id: agent} do
      for taint <- [:clean, :safe, "safe", "TRUSTED", 0, %{}] do
        assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
                 egress(agent, :external_provider, egress_taint: taint, egress_mode: :allow),
               "expected #{inspect(taint)} to block as :untrusted"
      end
    end

    test "a bare multi-key taint map (no :level) cannot hide a hostile entry",
         %{agent_id: agent} do
      context_taint_map = %{"prompt" => %Taint{level: :hostile}}

      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               egress(agent, :external_provider,
                 egress_taint: context_taint_map,
                 egress_mode: :allow
               )
    end

    test "Taint struct/map with an unknown level blocks", %{agent_id: agent} do
      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               egress(agent, :external_provider,
                 egress_taint: %{level: :bogus},
                 egress_mode: :allow
               )
    end

    test "the advisory external_peer tier is still covered by the taint conjunct",
         %{agent_id: agent} do
      assert {:error, {:egress_blocked, :external_peer, :untrusted}} =
               egress(agent, :external_peer, [])
    end
  end

  describe "explicit clean taint still egresses (behavior-preserving for wired callers)" do
    test "atom, string, struct, and string-keyed map forms of :trusted", %{agent_id: agent} do
      for taint <- [:trusted, "trusted", %Taint{level: :trusted}, %{"level" => "trusted"}] do
        assert egress(agent, :external_provider, egress_taint: taint, egress_mode: :allow) ==
                 :allow,
               "expected #{inspect(taint)} to allow"
      end
    end

    test ":derived is not blocked by the taint conjunct", %{agent_id: agent} do
      assert egress(agent, :external_provider, egress_taint: :derived, egress_mode: :allow) ==
               :allow
    end

    test "non-external tiers are unaffected by a missing taint", %{agent_id: agent} do
      assert egress(agent, :on_host, []) == :allow
      assert egress(agent, :none, []) == :allow
    end
  end

  describe "security regression: capability action path (authorize/4)" do
    setup %{agent_id: agent} do
      {:ok, cap} =
        Capability.new(
          resource_uri: @resource,
          principal_id: agent,
          delegation_depth: 0,
          constraints: %{},
          metadata: %{test: true}
        )

      CapabilityStore.put_fixture(cap)
      :ok
    end

    test "external egress with no taint is hard-blocked, not waved through by :allow",
         %{agent_id: agent} do
      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               Arbor.Security.authorize(agent, @resource, :execute,
                 egress_tier: :external_provider,
                 egress_mode: :allow,
                 verify_identity: false
               )
    end

    test "external egress with explicit :trusted taint and :allow standing authorizes",
         %{agent_id: agent} do
      assert {:ok, :authorized} =
               Arbor.Security.authorize(agent, @resource, :execute,
                 egress_tier: :external_provider,
                 egress_taint: :trusted,
                 egress_mode: :allow,
                 verify_identity: false
               )
    end
  end
end
