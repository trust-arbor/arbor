defmodule Arbor.Trust.CapabilityGrantOwnerJSONFileSecurityRegressionTest do
  use ExUnit.Case, async: false
  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Trust.TestSupport.GrantOwnerJSONPeer, as: Peer
  @moduletag :integration
  @moduletag :security_regression
  @moduletag timeout: 120_000

  test "security regression: real grant owner persists a target-signed JIT grant in authenticated JSONFile" do
    root =
      Path.join(
        System.tmp_dir!(),
        "trust-grant-owner-json-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    :ok = File.mkdir(root)
    :ok = File.chmod(root, 0o700)
    {:ok, root} = SafePath.resolve_real(root)
    peer = Peer.start!(root)
    on_exit(fn -> Peer.stop(peer) end)
    # State stays under this test's private TMPDIR for the owning QA failure receipt.
    assert :ok = Peer.call(peer, Peer, :boot!, [root])
    outcome = Peer.call(peer, Peer, :exercise, [])
    assert outcome.owner_principal_stable

    assert Enum.all?(outcome.provenance, fn {_key, value} -> value == true end),
           "expected genuine canonical Trust owner/app/PID and strict durable Core configuration"

    # This assertion must be RED on the unchanged DateTime-producing owner.
    assert {:ok, %Capability{} = cap} = outcome.grant_result
    assert cap.principal_id == outcome.target_id
    assert cap.resource_uri == outcome.resource
    assert cap.session_id == outcome.session
    assert is_binary(cap.issuer_signature)
    assert byte_size(cap.issuer_signature) == 64
    assert %DateTime{} = cap.granted_at
    timestamp = Map.get(cap.metadata, :granted_at) || Map.get(cap.metadata, "granted_at")
    assert is_binary(timestamp)
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(timestamp)

    # Public list/authorize are HOT behavior controls, not independent physical readback.
    assert %Capability{id: id} = outcome.controls.hot_capability
    assert id == cap.id
    hot_metadata = outcome.controls.hot_capability.metadata

    assert (Map.get(hot_metadata, :granted_at) || Map.get(hot_metadata, "granted_at")) ==
             timestamp

    assert outcome.controls.authorization == {:ok, :authorized}
    assert match?({:error, _}, outcome.controls.wrong_session)
    assert outcome.controls.replay == {:error, :capability_grant_request_replayed}
    assert outcome.controls.count_after == outcome.controls.count_before + 1
  end
end
