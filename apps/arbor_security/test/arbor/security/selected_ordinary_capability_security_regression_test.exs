defmodule Arbor.Security.SelectedOrdinaryCapabilitySecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Security
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Supervisor, as: SecuritySupervisor
  alias Arbor.Security.SystemAuthority
  alias Arbor.Security.TestBootstrap

  @moduletag :fast
  @moduletag :security_regression
  @resource "arbor://action/reports/build_morning_digest"
  @parent "arbor://action/reports/**"

  defmodule ApprovalProbe do
    def healthy?, do: true

    def submit(_proposal, _opts \\ []) do
      send(self(), :selected_capability_escalated)
      {:ok, "proposal_selected_capability"}
    end
  end

  setup do
    settings = [
      identity_verification: true,
      strict_identity_mode: true,
      capability_signing_required: false,
      consensus_escalation_enabled: true,
      consensus_module: ApprovalProbe,
      use_interaction_router_for_approval: false
    ]

    previous =
      Enum.map(settings, fn {key, value} ->
        old = Application.fetch_env(:arbor_security, key)
        Application.put_env(:arbor_security, key, value)
        {key, old}
      end)

    on_exit(fn -> Enum.each(previous, fn {key, old} -> restore_env(key, old) end) end)
    %{owner: identity!(), other: identity!()}
  end

  test "source-selected wildcard grant covers a concrete child while exact-resource mode stays exact",
       %{owner: owner} do
    cap = grant!(owner, @parent)

    assert {:error, :missing_signed_request} = Security.authorize(owner.agent_id, @resource)
    assert {:ok, :authorized} = exercise(owner, cap)

    assert {:error, :unauthorized} =
             Security.authorize_source_owned_exact_ordinary_capability(
               owner.agent_id,
               @resource,
               :execute,
               cap.id,
               %{session_id: nil, task_id: nil, principal_scope: nil, expected_egress: nil}
             )
  end

  test "revoked selection never substitutes another live covering grant", %{owner: owner} do
    selected = grant!(owner, @parent)
    other = grant!(owner, "arbor://action/**")
    assert {:ok, :authorized} = exercise(owner, selected)
    assert :ok = Security.revoke(selected.id)

    assert {:ok, :authorized} = exercise(owner, other)
    assert {:error, :unauthorized} = exercise(owner, selected)
  end

  test "a changed signed payload under the same stored id invalidates the original selection", %{
    owner: owner
  } do
    selected = grant!(owner, @parent)
    assert {:ok, :authorized} = exercise(owner, selected)

    # Test-owned hostile-store seam: same id, genuine root signature, changed
    # signed content. The public gate must compare the retained exact digest.
    replacement = signed_store!(%{selected | metadata: %{fixture_revision: 2}})
    assert replacement.id == selected.id
    assert digest(replacement) != digest(selected)
    assert {:ok, :authorized} = exercise(owner, replacement)
    assert {:error, :unauthorized} = exercise(owner, selected)
  end

  test "selection is bound to the stored principal and segment-aware resource coverage", %{
    owner: owner,
    other: other
  } do
    cap = grant!(owner, @parent)
    assert {:error, :unauthorized} = exercise(other, cap)

    assert {:error, :unauthorized} =
             exercise(owner, cap, "arbor://action/reports_extra/build_morning_digest")

    assert {:ok, :authorized} = exercise(owner, cap)
  end

  test "expired and not-yet-valid selections refuse even with another covering grant", %{
    owner: owner
  } do
    cap = grant!(owner, @parent)
    alternative = grant!(owner, "arbor://action/**")

    for attrs <- [
          %{expires_at: DateTime.add(DateTime.utc_now(), -60)},
          %{not_before: DateTime.add(DateTime.utc_now(), 3600)}
        ] do
      invalid = cap |> struct!(attrs) |> signed_store!()
      assert {:ok, :authorized} = exercise(owner, alternative)
      assert {:error, :unauthorized} = exercise(owner, invalid)
    end
  end

  test "scopes, counters, constraints, and delegated shapes cannot enter this stateless lane", %{
    owner: owner
  } do
    cap = grant!(owner, @parent)

    for attrs <- [
          %{session_id: "session_selected"},
          %{task_id: "task_selected"},
          %{principal_scope: "human_selected"},
          %{max_uses: 1},
          %{constraints: %{requires_approval: true}},
          %{constraints: %{"requires_approval" => false}},
          %{constraints: %{rate_limit: %{max_requests: 1, window_seconds: 60}}},
          %{parent_capability_id: "cap_" <> String.duplicate("a", 32)},
          %{delegation_chain: [%{delegator_id: owner.agent_id}]}
        ] do
      unsupported = cap |> struct!(attrs) |> signed_store!()
      assert {:error, :unauthorized} = exercise(owner, unsupported)
      refute_receive :selected_capability_escalated
    end
  end

  test "unsigned, tampered, and agent-signed stored capabilities fail under relaxed signing config",
       %{owner: owner} do
    cap = grant!(owner, @parent)
    assert {:ok, :authorized} = exercise(owner, cap)

    unsigned = %{cap | issuer_signature: nil}
    assert {:ok, :stored} = CapabilityStore.put(unsigned)
    assert {:error, :unauthorized} = exercise(owner, unsigned)

    tampered = %{cap | metadata: %{tampered: true}}
    assert {:ok, :stored} = CapabilityStore.put(tampered)
    assert {:error, :unauthorized} = exercise(owner, tampered)

    self_signed = Signer.sign(%{cap | issuer_id: owner.agent_id}, owner.private_key)
    assert :ok = Signer.verify(self_signed, owner.public_key)
    assert {:ok, :stored} = CapabilityStore.put(self_signed)
    assert {:error, :unauthorized} = exercise(owner, self_signed)
  end

  test "inactive and unknown identities refuse regardless of relaxed ordinary identity config", %{
    owner: owner
  } do
    cap = grant!(owner, @parent)
    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    assert {:ok, :authorized} = exercise(owner, cap)

    assert :ok = Security.suspend_identity(owner.agent_id, reason: "selected-capability fixture")
    assert {:error, :unauthorized} = exercise(owner, cap)
    assert :ok = Security.resume_identity(owner.agent_id)
    assert {:ok, :authorized} = exercise(owner, cap)
    assert :ok = Security.revoke_identity(owner.agent_id, reason: "selected-capability fixture")
    assert {:error, :unauthorized} = exercise(owner, cap)

    {:ok, unknown} = Identity.generate()
    unknown_cap = grant!(unknown, @parent)
    assert {:error, :unauthorized} = exercise(unknown, unknown_cap)
  end

  test "a capability-store outage cannot fall back to another grant", %{owner: owner} do
    cap = grant!(owner, @parent)
    grant!(owner, "arbor://action/**")
    assert {:ok, :authorized} = exercise(owner, cap)
    on_exit(fn -> assert :ok = TestBootstrap.restore_supervised_tree!() end)

    assert :ok = Supervisor.terminate_child(SecuritySupervisor, CapabilityStore)
    assert {:error, :unauthorized} = exercise(owner, cap)
  end

  test "signature-owner outage denies without crashing the capability store", %{owner: owner} do
    cap = grant!(owner, @parent)
    assert {:ok, :authorized} = exercise(owner, cap)
    store = Process.whereis(CapabilityStore)
    on_exit(fn -> assert :ok = TestBootstrap.restore_supervised_tree!() end)

    assert :ok = Supervisor.terminate_child(SecuritySupervisor, SystemAuthority)
    assert {:error, :unauthorized} = exercise(owner, cap)
    assert Process.alive?(store)
    assert Process.whereis(CapabilityStore) == store
  end

  test "implicit FileGuard still rejects a symlink escaping the selected filesystem grant", %{
    owner: owner
  } do
    root =
      Path.join(System.tmp_dir!(), "selected_capability_#{System.unique_integer([:positive])}")

    allowed = Path.join(root, "allowed")
    outside = Path.join(root, "outside.txt")
    File.mkdir_p!(allowed)
    File.write!(outside, "outside")
    File.write!(Path.join(allowed, "safe.txt"), "safe")
    File.ln_s!(outside, Path.join(allowed, "escape.txt"))
    on_exit(fn -> File.rm_rf!(root) end)

    cap = grant!(owner, file_uri(allowed) <> "/**")
    assert {:ok, :authorized} = exercise(owner, cap, file_uri(Path.join(allowed, "safe.txt")))

    assert {:error, :unauthorized} =
             exercise(owner, cap, file_uri(Path.join(allowed, "escape.txt")))

    assert File.read!(outside) == "outside"
  end

  test "malformed selections and wildcard operation requests fail closed", %{owner: owner} do
    cap = grant!(owner, @parent)

    for {uri, action, id, expected} <- [
          {@parent, :execute, cap.id, digest(cap)},
          {@resource, :read, cap.id, digest(cap)},
          {@resource, :execute, "cap_missing", digest(cap)},
          {@resource, :execute, cap.id, String.duplicate("A", 64)},
          {@resource, :execute, cap.id, nil}
        ] do
      assert {:error, :invalid_request} =
               Security.authorize_source_owned_selected_ordinary_capability(
                 owner.agent_id,
                 uri,
                 action,
                 id,
                 expected
               )
    end

    assert {:error, :unauthorized} =
             Security.authorize_source_owned_selected_ordinary_capability(
               owner.agent_id,
               @resource,
               :execute,
               cap.id,
               String.duplicate("0", 64)
             )
  end

  defp identity! do
    assert {:ok, identity} = Identity.generate()
    assert :ok = Security.register_identity(Identity.public_only(identity))
    identity
  end

  defp grant!(owner, resource) do
    assert {:ok, cap} = Security.grant(principal: owner.agent_id, resource: resource)
    on_exit(fn -> Security.revoke(cap.id) end)
    cap
  end

  defp signed_store!(cap) do
    assert {:ok, signed} = SystemAuthority.sign_capability(cap)
    assert {:ok, :stored} = CapabilityStore.put(signed)
    signed
  end

  defp exercise(owner, cap, uri \\ @resource) do
    Security.authorize_source_owned_selected_ordinary_capability(
      owner.agent_id,
      uri,
      :execute,
      cap.id,
      digest(cap)
    )
  end

  defp digest(cap),
    do: :crypto.hash(:sha256, Capability.signing_payload(cap)) |> Base.encode16(case: :lower)

  defp file_uri(path), do: "arbor://fs/read/" <> String.trim_leading(path, "/")
  defp restore_env(key, {:ok, value}), do: Application.put_env(:arbor_security, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:arbor_security, key)
end
