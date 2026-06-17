defmodule Arbor.Consensus.AuthorizationTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :integration

  alias Arbor.Security

  @caller_id "agent_test_caller"

  setup_all do
    # The consensus facade fails CLOSED when Security is unavailable, so these
    # "delegates ... when security permits" tests must run with a genuinely
    # healthy Security subsystem and a real capability grant — there is no more
    # dev/test permissive fallback to lean on. Start all the processes
    # Security.healthy?() requires (same set + order as authorization_e2e_test).
    security_children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ]

    for {mod, opts} <- security_children do
      unless Process.whereis(mod) do
        case Supervisor.start_child(Arbor.Security.Supervisor, {mod, opts}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> raise "Failed to start #{mod}: #{inspect(reason)}"
        end
      end
    end

    # Don't require capability signatures for these facade delegation tests.
    original_signing = Application.get_env(:arbor_security, :capability_signing_required)
    Application.put_env(:arbor_security, :capability_signing_required, false)

    Process.sleep(20)

    unless Security.healthy?() do
      raise "Security.healthy?() returned false after starting all processes"
    end

    on_exit(fn ->
      if is_nil(original_signing) do
        Application.delete_env(:arbor_security, :capability_signing_required)
      else
        Application.put_env(:arbor_security, :capability_signing_required, original_signing)
      end
    end)

    :ok
  end

  setup do
    # Security is healthy (started in setup_all); grant the consensus
    # capabilities so authorize/2 genuinely PERMITS via a real capability check.
    grant_consensus_capabilities(@caller_id)
    :ok
  end

  describe "authorize_propose/3" do
    test "delegates to propose when security permits" do
      attrs = %{
        proposer: @caller_id,
        topic: :code_modification,
        description: "Test proposal via authorize_propose",
        context: %{}
      }

      assert {:ok, proposal_id} = Arbor.Consensus.authorize_propose(@caller_id, attrs)
      assert is_binary(proposal_id)
    end
  end

  describe "authorize_ask/3" do
    test "delegates to ask when security permits" do
      assert {:ok, proposal_id} =
               Arbor.Consensus.authorize_ask(@caller_id, "Test advisory question")

      assert is_binary(proposal_id)
    end
  end

  describe "authorize_cancel/3" do
    test "delegates to cancel when security permits" do
      {:ok, proposal_id} =
        Arbor.Consensus.propose(%{
          proposer: @caller_id,
          topic: :code_modification,
          description: "Proposal to cancel"
        })

      # The cancel may succeed or fail depending on proposal state,
      # but it should not return {:error, {:unauthorized, _}}
      result = Arbor.Consensus.authorize_cancel(@caller_id, proposal_id)
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "authorize_force_approve/4" do
    test "delegates to force_approve when security permits" do
      {:ok, proposal_id} =
        Arbor.Consensus.propose(%{
          proposer: "agent_1",
          topic: :code_modification,
          description: "Proposal to force approve"
        })

      # Wait briefly for evaluation to complete
      Process.sleep(50)

      result = Arbor.Consensus.authorize_force_approve(@caller_id, proposal_id, "admin")
      # May be authorized, or gated by approval guard (trust-tier dependent).
      # The key invariant: should not fail on capability check itself.
      assert result in [
               :ok,
               {:error, {:unauthorized, :pending_approval}},
               {:error, {:unauthorized, :escalation_disabled}}
             ] or
               not match?({:error, {:unauthorized, :no_capability}}, result)
    end
  end

  describe "authorize_force_reject/4" do
    test "delegates to force_reject when security permits" do
      {:ok, proposal_id} =
        Arbor.Consensus.propose(%{
          proposer: "agent_1",
          topic: :code_modification,
          description: "Proposal to force reject"
        })

      Process.sleep(50)

      result = Arbor.Consensus.authorize_force_reject(@caller_id, proposal_id, "admin")

      assert result in [
               :ok,
               {:error, {:unauthorized, :pending_approval}},
               {:error, {:unauthorized, :escalation_disabled}}
             ] or
               not match?({:error, {:unauthorized, :no_capability}}, result)
    end
  end

  describe "authorize_decide/3" do
    @tag :llm
    test "delegates to decide when security permits" do
      # decide requires LLM — tag as :llm
      result = Arbor.Consensus.authorize_decide(@caller_id, "Should we test?")
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "function signatures" do
    test "all authorize_* functions are exported" do
      exports = Arbor.Consensus.__info__(:functions)

      assert {:authorize_propose, 2} in exports or {:authorize_propose, 3} in exports
      assert {:authorize_ask, 2} in exports or {:authorize_ask, 3} in exports
      assert {:authorize_decide, 2} in exports or {:authorize_decide, 3} in exports
      assert {:authorize_cancel, 2} in exports or {:authorize_cancel, 3} in exports
      assert {:authorize_force_approve, 3} in exports or {:authorize_force_approve, 4} in exports
      assert {:authorize_force_reject, 3} in exports or {:authorize_force_reject, 4} in exports
    end
  end

  # Grant wildcard consensus capabilities. Security is started in setup_all and
  # the facade fails closed when it is unavailable, so this grant is what makes
  # the "...when security permits" delegation paths genuinely PERMIT.
  defp grant_consensus_capabilities(caller_id) do
    if Code.ensure_loaded?(Arbor.Security.CapabilityStore) and
         Process.whereis(Arbor.Security.CapabilityStore) != nil do
      consensus_uris = [
        "arbor://consensus/propose",
        "arbor://consensus/ask",
        "arbor://consensus/cancel",
        "arbor://consensus/force_approve",
        "arbor://consensus/force_reject",
        "arbor://consensus/decide"
      ]

      for uri <- consensus_uris do
        {:ok, cap} =
          Arbor.Contracts.Security.Capability.new(
            resource_uri: uri,
            principal_id: caller_id,
            actions: [:all]
          )

        Arbor.Security.CapabilityStore.put(cap)
      end
    end
  end
end
