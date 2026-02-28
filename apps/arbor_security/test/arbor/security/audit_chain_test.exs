# credo:disable-for-this-file Credo.Check.Refactor.Apply
defmodule Arbor.Security.AuditChainTest do
  @moduledoc """
  Tests for the cryptographic audit chain — delegation chain verification,
  trace_id correlation, and signature persistence in the audit trail.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Security
  alias Arbor.Security.Events
  alias Arbor.Security.Identity.Registry

  setup do
    # Start EventLog ETS backend for event queries
    name = :security_events
    backend = Arbor.Persistence.EventLog.ETS

    case apply(backend, :start_link, [[name: name]]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Generate identities
    {:ok, parent} = Identity.generate(name: "human-parent")
    {:ok, agent} = Identity.generate(name: "child-agent")

    :ok = Registry.register(parent)
    :ok = Registry.register(agent)

    on_exit(fn ->
      try do
        if Process.whereis(name), do: GenServer.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, parent: parent, agent: agent}
  end

  # ======================================================================
  # Gap 3: Delegation Chain Verification on Authorization
  # ======================================================================

  describe "delegation chain verification" do
    test "authorization succeeds with valid delegation chain", %{parent: parent, agent: agent} do
      # Grant parent a capability and delegate to agent
      {:ok, _cap} =
        Security.grant(
          principal: parent.agent_id,
          resource: "arbor://audit/chain/valid",
          delegation_depth: 3
        )

      {:ok, [delegated]} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          delegator_private_key: parent.private_key,
          resources: ["arbor://audit/chain/valid"]
        )

      assert length(delegated.delegation_chain) == 1

      # Agent should be authorized (chain verification passes)
      assert {:ok, :authorized} =
               Security.authorize(agent.agent_id, "arbor://audit/chain/valid")
    end

    test "authorization fails with broken delegation chain (tampered signature)", %{
      parent: parent,
      agent: agent
    } do
      {:ok, _cap} =
        Security.grant(
          principal: parent.agent_id,
          resource: "arbor://audit/chain/tampered",
          delegation_depth: 3
        )

      {:ok, [delegated]} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          delegator_private_key: parent.private_key,
          resources: ["arbor://audit/chain/tampered"]
        )

      # Revoke the valid delegated cap, then store a tampered version
      :ok = Security.revoke(delegated.id)

      [record] = delegated.delegation_chain
      tampered_record = %{record | delegator_signature: :crypto.strong_rand_bytes(64)}
      tampered_cap = %{delegated | delegation_chain: [tampered_record]}

      {:ok, :stored} = Arbor.Security.CapabilityStore.put(tampered_cap)

      # Authorization fails — the store filters out caps with broken chains
      # during find_authorizing (defense-in-depth: auth-level check would
      # also catch it if store-level check is bypassed)
      assert {:error, :unauthorized} =
               Security.authorize(agent.agent_id, "arbor://audit/chain/tampered")
    end

    test "verify_delegation_chain directly catches tampered signatures", %{
      parent: parent,
      agent: agent
    } do
      # Verify the Signer-level check directly (the auth path uses this)
      {:ok, _cap} =
        Security.grant(
          principal: parent.agent_id,
          resource: "arbor://audit/chain/direct-verify",
          delegation_depth: 3
        )

      {:ok, [delegated]} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          delegator_private_key: parent.private_key,
          resources: ["arbor://audit/chain/direct-verify"]
        )

      # Valid chain passes
      key_lookup_fn = fn id -> Arbor.Security.Identity.Registry.lookup(id) end
      assert :ok = Arbor.Security.Capability.Signer.verify_delegation_chain(delegated, key_lookup_fn)

      # Tampered chain fails
      [record] = delegated.delegation_chain
      tampered_record = %{record | delegator_signature: :crypto.strong_rand_bytes(64)}
      tampered_cap = %{delegated | delegation_chain: [tampered_record]}

      assert {:error, :broken_delegation_chain} =
               Arbor.Security.Capability.Signer.verify_delegation_chain(tampered_cap, key_lookup_fn)
    end

    test "empty delegation chain passes verification", %{parent: parent} do
      {:ok, _cap} =
        Security.grant(
          principal: parent.agent_id,
          resource: "arbor://audit/chain/direct",
          delegation_depth: 3
        )

      # Direct grant (no delegation) should authorize fine
      assert {:ok, :authorized} =
               Security.authorize(parent.agent_id, "arbor://audit/chain/direct")
    end

    test "config toggle disables auth-level chain verification", %{parent: parent, agent: agent} do
      {:ok, _cap} =
        Security.grant(
          principal: parent.agent_id,
          resource: "arbor://audit/chain/toggle",
          delegation_depth: 3
        )

      {:ok, [_delegated]} =
        Security.delegate_to_agent(parent.agent_id, agent.agent_id,
          delegator_private_key: parent.private_key,
          resources: ["arbor://audit/chain/toggle"]
        )

      # Valid delegation — verify the config toggle doesn't break valid chains
      # (When disabled, maybe_verify_delegation_chain returns :ok immediately)
      prev = Application.get_env(:arbor_security, :delegation_chain_verification_enabled, true)
      Application.put_env(:arbor_security, :delegation_chain_verification_enabled, false)

      try do
        assert {:ok, :authorized} =
                 Security.authorize(agent.agent_id, "arbor://audit/chain/toggle")
      after
        Application.put_env(:arbor_security, :delegation_chain_verification_enabled, prev)
      end

      # Also verify it works when enabled (default)
      assert {:ok, :authorized} =
               Security.authorize(agent.agent_id, "arbor://audit/chain/toggle")
    end
  end

  # ======================================================================
  # Gap 4: trace_id Correlation
  # ======================================================================

  describe "trace_id correlation" do
    test "generate_trace_id returns unique values" do
      id1 = Security.generate_trace_id()
      id2 = Security.generate_trace_id()

      assert String.starts_with?(id1, "trace_")
      assert String.starts_with?(id2, "trace_")
      assert id1 != id2
      # 8 bytes = 16 hex chars + "trace_" prefix
      assert byte_size(id1) == 22
    end

    test "trace_id propagates through authorization events", %{parent: parent} do
      {:ok, _cap} =
        Security.grant(
          principal: parent.agent_id,
          resource: "arbor://audit/trace/auth",
          delegation_depth: 3
        )

      trace_id = Security.generate_trace_id()

      {:ok, :authorized} =
        Security.authorize(parent.agent_id, "arbor://audit/trace/auth", nil,
          trace_id: trace_id
        )

      {:ok, events} = Events.get_by_type(:authorization_granted)

      matching =
        Enum.find(events, fn e ->
          e.data.trace_id == trace_id
        end)

      assert matching != nil
      assert matching.data.principal_id == parent.agent_id
    end
  end

  # ======================================================================
  # Gap 5: Signature Persistence in Audit Trail
  # ======================================================================

  describe "signature persistence" do
    test "verification event includes signature proof", %{parent: parent} do
      # Create a signed request
      payload = "arbor://audit/sig/test"
      {:ok, signed} = SignedRequest.sign(payload, parent.agent_id, parent.private_key)

      # Verify it (this records the event)
      {:ok, _agent_id} = Security.verify_request(signed)

      {:ok, events} = Events.get_by_type(:identity_verification_succeeded)

      matching =
        Enum.find(events, fn e ->
          e.data.agent_id == parent.agent_id and e.data.signature != nil
        end)

      assert matching != nil
      assert is_binary(matching.data.signature)
      assert is_binary(matching.data.payload_hash)
      assert is_binary(matching.data.nonce)
      assert is_binary(matching.data.signed_at)
    end

    test "failed verification event includes nonce metadata", %{parent: parent} do
      # Create a signed request from parent but use agent's ID (will fail if IDs mismatch,
      # but let's create a request with wrong key to fail verification)
      payload = "arbor://audit/sig/fail"
      {:ok, signed} = SignedRequest.sign(payload, parent.agent_id, parent.private_key)

      # Tamper with signature to cause failure
      tampered = %{signed | signature: :crypto.strong_rand_bytes(64)}
      {:error, _reason} = Security.verify_request(tampered)

      {:ok, events} = Events.get_by_type(:identity_verification_failed)

      matching =
        Enum.find(events, fn e ->
          e.data.agent_id == parent.agent_id and e.data.nonce != nil
        end)

      assert matching != nil
      assert is_binary(matching.data.nonce)
      assert is_binary(matching.data.signed_at)
    end
  end
end
