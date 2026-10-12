defmodule Arbor.Security.InvocationReceiptSecurityRegressionTest do
  @moduledoc """
  Security regression (2026-09-28): with `invocation_receipts_enabled`, a
  receipt field that `InvocationReceipt.signing_payload/1` cannot encode raised
  INSIDE the `SystemAuthority` GenServer — the trust root. The crash:

  - exited the `Security.authorize/4` caller (`maybe_emit_receipt/6` only
    rescued, and `GenServer.call` exits rather than raises);
  - spent the arbor_security supervisor's restart intensity on caller data;
  - in `:ephemeral` mode minted a new authority key on restart, so every
    capability signed before the crash stopped verifying.

  Two triggers, both through the public facade:

  - a non-atom action (the MCP bridges passed `%{action: :execute}` until
    `arbor_gateway`'s own regression test);
  - ANY capability obtained by delegation, because every delegation record
    carries `constraints: map()` and the chain encoder interpolated it.

  The fix: `SystemAuthority` replies `{:error, :invalid_receipt}` instead of
  raising, `InvocationReceipt.new/1` rejects non-atom actions, the chain
  encoder canonicalizes map values, and `maybe_emit_receipt/6` also catches
  exits from an unavailable authority.

  Security regression (2026-10-01): the signed chain text had no unambiguous
  boundaries, so a holder of a signed receipt could re-shape its delegation
  chain under the same authority signature. Fixed by receipt payload v2
  (`.arbor/decisions/2026-10-01-invocation-receipt-payload-v2.md`).

  Ported to main 2026-10-11 from `claude/lucid-mestorf-7d16c0`. On main the
  public `SystemAuthority.sign_receipt/1` is closed (receipts are signed only
  through `InvocationReceiptBroker`), so the direct-signing cases use the
  `sign_receipt_for_test/1` seam; the authorize/4 cases drive the real broker
  path.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.InvocationReceipt
  alias Arbor.Security
  alias Arbor.Security.SystemAuthority

  setup do
    previous = Application.get_env(:arbor_security, :invocation_receipts_enabled)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:arbor_security, :invocation_receipts_enabled),
        else: Application.put_env(:arbor_security, :invocation_receipts_enabled, previous)
    end)

    authority = Process.whereis(SystemAuthority)
    assert is_pid(authority)

    %{authority: authority, authority_ref: Process.monitor(authority)}
  end

  @tag :fast
  test "security regression: a map action through authorize/4 does not crash SystemAuthority",
       %{authority: authority, authority_ref: authority_ref} do
    agent_id = "agent_receipt_map_action_#{System.unique_integer([:positive])}"
    uri = "arbor://fs/read/receipt_regression/map_action"
    {:ok, _cap} = Security.grant_fixture(principal: agent_id, resource: uri)

    assert {:ok, :authorized} =
             authorize_without_exit(agent_id, uri, %{action: :execute})

    assert_authority_survived(authority, authority_ref)
    # An unencodable action yields no receipt rather than a malformed one.
    refute_received {:receipt, _}
  end

  @tag :fast
  test "security regression: a delegated capability's receipt is signed without crashing SystemAuthority",
       %{authority: authority, authority_ref: authority_ref} do
    {:ok, parent} = Identity.generate(name: "receipt-regression-parent")
    {:ok, agent} = Identity.generate(name: "receipt-regression-agent")
    :ok = Security.register_identity_fixture(parent)
    :ok = Security.register_identity_fixture(agent)

    uri = "arbor://fs/read/receipt_regression/delegated/**"

    {:ok, parent_cap} =
      Security.grant_fixture(principal: parent.agent_id, resource: uri, delegation_depth: 2)

    {:ok, delegated} =
      Security.delegate_fixture(parent_cap.id, agent.agent_id,
        delegator_private_key: parent.private_key
      )

    assert [%{constraints: constraints}] = delegated.delegation_chain
    assert is_map(constraints)

    assert {:ok, :authorized} = authorize_without_exit(agent.agent_id, uri, :read)
    assert_authority_survived(authority, authority_ref)

    assert_received {:receipt, %InvocationReceipt{} = receipt}
    assert receipt.capability_id == delegated.id
    assert length(receipt.delegation_chain) == 1
    assert :ok = InvocationReceipt.verify(receipt, SystemAuthority.public_key())

    # The chain, constraints included, is covered by the signature.
    [record] = receipt.delegation_chain
    tampered_record = %{record | constraints: Map.put(record.constraints, :rate_limit, 1_000)}
    tampered = %{receipt | delegation_chain: [tampered_record]}

    assert {:error, :invalid_receipt_signature} =
             InvocationReceipt.verify(tampered, SystemAuthority.public_key())
  end

  # Security regression (2026-10-01): the unversioned receipt payload joined
  # chain records with ";" and fields with "," without escaping, and a
  # delegator signature is 64 raw bytes. Anyone holding a signed receipt
  # could hide the second delegation inside the first record's signature,
  # and the authority's signature still verified the shorter chain. Payload
  # v2 length-prefixes and type-tags every record, key and value.
  @tag :fast
  test "security regression: a signed receipt cannot be re-presented with a re-shaped delegation chain" do
    {:ok, root} = Identity.generate(name: "receipt-chain-root")
    {:ok, middle} = Identity.generate(name: "receipt-chain-middle")
    {:ok, leaf} = Identity.generate(name: "receipt-chain-leaf")
    Enum.each([root, middle, leaf], &(:ok = Security.register_identity_fixture(&1)))

    uri = "arbor://fs/read/receipt_regression/chain/**"

    {:ok, root_cap} =
      Security.grant_fixture(principal: root.agent_id, resource: uri, delegation_depth: 3)

    {:ok, middle_cap} =
      Security.delegate_fixture(root_cap.id, middle.agent_id,
        delegator_private_key: root.private_key
      )

    {:ok, leaf_cap} =
      Security.delegate_fixture(middle_cap.id, leaf.agent_id,
        delegator_private_key: middle.private_key
      )

    assert length(leaf_cap.delegation_chain) == 2

    # Built and signed the way `maybe_emit_receipt/6` does after a grant,
    # called directly so the test isolates the receipt signer from chain
    # authorization.
    {:ok, unsigned} =
      InvocationReceipt.new(
        capability_id: leaf_cap.id,
        principal_id: leaf.agent_id,
        resource_uri: uri,
        action: :read,
        delegation_chain: leaf_cap.delegation_chain
      )

    {:ok, receipt} = SystemAuthority.sign_receipt_for_test(unsigned)

    public_key = SystemAuthority.public_key()
    assert :ok = InvocationReceipt.verify(receipt, public_key)

    # Present the same signature over a one-record chain whose delegator
    # signature carries the second record in the legacy text encoding.
    [first, second] = receipt.delegation_chain

    merged = %{
      first
      | delegator_signature: first.delegator_signature <> ";" <> legacy_record_text(second)
    }

    assert {:error, :invalid_receipt_signature} =
             InvocationReceipt.verify(%{receipt | delegation_chain: [merged]}, public_key)
  end

  # The same class through the real grant path: a one-hop capability's
  # receipt, re-presented with the record's signature folded into its
  # delegator_id. The record now claims no delegator signature at all.
  @tag :fast
  test "security regression: an authorize/4 receipt cannot be re-presented with a record field absorbed" do
    {:ok, parent} = Identity.generate(name: "receipt-absorb-parent")
    {:ok, agent} = Identity.generate(name: "receipt-absorb-agent")
    :ok = Security.register_identity_fixture(parent)
    :ok = Security.register_identity_fixture(agent)

    uri = "arbor://fs/read/receipt_regression/absorb/**"

    {:ok, parent_cap} =
      Security.grant_fixture(principal: parent.agent_id, resource: uri, delegation_depth: 2)

    {:ok, _delegated} =
      Security.delegate_fixture(parent_cap.id, agent.agent_id,
        delegator_private_key: parent.private_key
      )

    assert {:ok, :authorized} = authorize_without_exit(agent.agent_id, uri, :read)
    assert_received {:receipt, %InvocationReceipt{delegation_chain: [record]} = receipt}

    public_key = SystemAuthority.public_key()
    assert :ok = InvocationReceipt.verify(receipt, public_key)

    absorbed =
      record
      |> Map.delete(:delegator_signature)
      |> Map.put(
        :delegator_id,
        record.delegator_id <> ",delegator_signature=" <> record.delegator_signature
      )

    assert {:error, :invalid_receipt_signature} =
             InvocationReceipt.verify(%{receipt | delegation_chain: [absorbed]}, public_key)
  end

  @tag :fast
  test "security regression: SystemAuthority answers an unencodable receipt with an error",
       %{authority: authority, authority_ref: authority_ref} do
    {:ok, receipt} =
      InvocationReceipt.new(
        capability_id: "cap_receipt_regression",
        principal_id: "agent_receipt_regression",
        resource_uri: "arbor://fs/read/receipt_regression"
      )

    # new/1 now rejects this, so build it the way a direct struct update would.
    unencodable = %{receipt | action: %{action: :execute}}

    assert {:error, :invalid_receipt} = sign_without_exit(unencodable)
    assert_authority_survived(authority, authority_ref)

    # And the authority still signs well-formed receipts afterwards.
    assert {:ok, signed} = SystemAuthority.sign_receipt_for_test(receipt)
    assert :ok = InvocationReceipt.verify(signed, SystemAuthority.public_key())
  end

  # The receipt is signed after the decision via GenServer.call; an authority
  # that cannot answer in time EXITS the caller, which `rescue` never caught.
  # The decision itself also consults the authority (and correctly fails
  # closed if it cannot), so suspend it only once the grant is recorded: the
  # authorization_granted telemetry runs in the caller between the decision
  # and the receipt. Suspend (not stop) so the supervisor is untouched.
  @tag :slow
  test "security regression: an authority that stops answering after the decision does not fail the call",
       %{authority: authority} do
    agent_id = "agent_receipt_authority_timeout_#{System.unique_integer([:positive])}"
    uri = "arbor://fs/read/receipt_regression/authority_timeout"
    {:ok, _cap} = Security.grant_fixture(principal: agent_id, resource: uri)

    handler_id = "receipt-regression-suspend-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:arbor, :security, :authorization_granted],
        fn _event, _measurements, %{data: %{principal_id: principal_id}}, _config ->
          if principal_id == agent_id, do: :sys.suspend(authority)
        end,
        nil
      )

    result =
      try do
        authorize_without_exit(agent_id, uri, :read)
      after
        :telemetry.detach(handler_id)
        :ok = :sys.resume(authority)
      end

    assert {:ok, :authorized} = result
    refute_received {:receipt, _}
  end

  defp authorize_without_exit(principal_id, uri, action) do
    parent = self()

    Security.authorize(principal_id, uri, action,
      receipt_callback: fn receipt -> send(parent, {:receipt, receipt}) end
    )
  catch
    :exit, reason -> {:caller_exited, reason}
  end

  defp sign_without_exit(receipt) do
    SystemAuthority.sign_receipt_for_test(receipt)
  catch
    :exit, reason -> {:caller_exited, reason}
  end

  # How the unversioned (v1) encoder rendered one delegation record: keys
  # sorted, values interpolated, maps as key-sorted JSON pair lists.
  defp legacy_record_text(record) do
    record
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(",", fn
      {key, value} when is_map(value) and not is_struct(value) ->
        "#{key}=#{Jason.encode!(legacy_pairs(value))}"

      {key, value} ->
        "#{key}=#{value}"
    end)
  end

  defp legacy_pairs(map) when is_map(map) and not is_struct(map),
    do: map |> Enum.map(fn {k, v} -> [to_string(k), legacy_pairs(v)] end) |> Enum.sort()

  defp legacy_pairs(other), do: other

  defp assert_authority_survived(authority, authority_ref) do
    refute_received {:DOWN, ^authority_ref, :process, ^authority, _reason}
    assert Process.alive?(authority)
    assert Process.whereis(SystemAuthority) == authority
  end
end
