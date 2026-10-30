defmodule Arbor.Security.CapabilitiesPackageReplayPeerSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security
  alias Arbor.Security.Config
  alias Arbor.Security.Identity.ReplayPeers

  @moduletag :integration
  @moduletag :security_regression

  test "security regression: a connected Capabilities authority cannot be classified as a foreign replay target" do
    assert Node.list(:connected) == []
    started_here = start_private_distribution!()
    on_exit(fn -> if started_here and Node.alive?(), do: Node.stop() end)

    # Bounded fixture-only atom: one owned peer per test in a private realm.
    name =
      String.to_atom(
        "capabilities_package_peer_#{System.unique_integer([:positive, :monotonic])}"
      )

    {:ok, peer, peer_node} =
      :peer.start_link(%{
        name: name,
        host: ~c"localhost",
        connection: :standard_io,
        args: peer_cookie_args!()
      })

    on_exit(fn -> stop_peer(peer) end)
    assert Node.connect(peer_node)
    assert_peer_cookie!(peer_node)

    candidate? = Application.get_application(Security) == :arbor_capabilities
    install_capabilities_presence!(peer_node, candidate?)
    assert :arbor_capabilities in remote_applications(peer_node)
    :ok = ReplayPeers.forget(peer_node)
    _settled_classification = ReplayPeers.classification(peer_node)

    {:ok, identity} = Identity.generate(name: "package-peer-public-refusal")
    :ok = Security.register_identity_fixture(Identity.public_only(identity))
    on_exit(fn -> Security.deregister_identity_fixture(identity.agent_id) end)

    {:ok, request} =
      SignedRequest.sign("package-peer-refusal", identity.agent_id, identity.private_key)

    # This is the RED oracle on the unchanged legacy Main: its peer probe sees
    # only :arbor_security, calls this peer foreign and accepts the real proof.
    assert {:error, :cluster_replay_protection_unavailable} =
             Security.verify_signed_request_authenticity(request)

    assert ReplayPeers.classification(peer_node) == :replay_peer

    if candidate? do
      assert {:ok, {Arbor.Security.Application, _}} =
               :erpc.call(peer_node, :application, :get_key, [:arbor_capabilities, :mod], 5_000)

      for owner <- [
            Arbor.Security.CapabilityStore,
            Arbor.Security.SystemAuthority,
            Arbor.Security.Identity.Registry,
            ReplayPeers
          ] do
        assert is_pid(:erpc.call(peer_node, Process, :whereis, [owner], 5_000))
      end
    end
  end

  defp install_capabilities_presence!(peer_node, false) do
    # The legacy predecessor has no new package. Its RED case conservatively
    # announces the new application on a real node; candidate GREEN below must
    # run the actual application and cannot satisfy this gate with this stub.
    spec =
      {:application, :arbor_capabilities,
       [
         vsn: ~c"presence-regression",
         applications: [:kernel, :stdlib],
         modules: [],
         registered: []
       ]}

    assert :ok = :erpc.call(peer_node, :application, :load, [spec], 5_000)
    assert :ok = :erpc.call(peer_node, :application, :start, [:arbor_capabilities], 5_000)
  end

  defp install_capabilities_presence!(peer_node, true) do
    :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()], 5_000)

    state =
      Path.join(
        System.tmp_dir!(),
        "capabilities-package-peer-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(state)
    File.chmod!(state, 0o700)
    File.mkdir!(Path.join(state, "authority"))
    File.chmod!(Path.join(state, "authority"), 0o700)
    File.mkdir!(Path.join(state, "independent-revocations"))
    File.chmod!(Path.join(state, "independent-revocations"), 0o700)
    {:ok, canonical} = SafePath.resolve_real(state)
    assert canonical == state

    for {key, value} <- Application.get_all_env(:arbor_capabilities) do
      :ok = :erpc.call(peer_node, Application, :put_env, [:arbor_capabilities, key, value], 5_000)
    end

    {:ok, roles} = Config.signing_key_owner_roles()

    overrides = [
      start_children: true,
      signal_transport: nil,
      distributed_signals: false,
      runtime_host: nil,
      runtime: [start_profile: :full],
      authority_state_root: Path.join(state, "authority"),
      master_key_path: Path.join(state, "authority/master.key"),
      storage_backend: Arbor.Security.Store.JSONFile,
      event_log_adapter: nil,
      revocation_ledger_path: Path.join(state, "independent-revocations/ledger.json"),
      system_authority_mode: :ephemeral,
      session_token_secret: String.duplicate("p", 32),
      signing_key_owner_roles: roles
    ]

    for {key, value} <- overrides do
      :ok = :erpc.call(peer_node, Application, :put_env, [:arbor_capabilities, key, value], 5_000)
    end

    assert {:ok, _started} =
             :erpc.call(
               peer_node,
               Application,
               :ensure_all_started,
               [:arbor_capabilities],
               30_000
             )
  end

  defp start_private_distribution! do
    cookie_argument_present? =
      case :init.get_argument(:setcookie) do
        {:ok, [[_synthetic_cookie]]} -> true
        _ -> false
      end

    assert cookie_argument_present?, "Exactly one pinned synthetic cookie is required"
    port = System.fetch_env!("ERL_EPMD_PORT")
    assert port != "4369"
    assert System.get_env("ERL_EPMD_ADDRESS") == "127.0.0.1"

    if Node.alive?() do
      false
    else
      # At most one controller atom is created by this fixture test.
      name =
        String.to_atom(
          "capabilities_package_regression_#{System.unique_integer([:positive, :monotonic])}@localhost"
        )

      assert {:ok, _} = :net_kernel.start([name, :shortnames])
      true
    end
  end

  defp peer_cookie_args! do
    cookie = Node.get_cookie() |> Atom.to_charlist()
    cookie_hash = :crypto.hash(:sha256, List.to_string(cookie)) |> Base.encode16(case: :lower)
    assert cookie_hash == System.fetch_env!("CUSTODY_QA_COOKIE_SHA256")

    for key <- ["ERL_AFLAGS", "ERL_ZFLAGS"] do
      assert not Regex.match?(~r/(?:^|\s)-setcookie(?:\s|$)/, System.get_env(key, "")),
             "Competing inherited peer cookie flags are not permitted"
    end

    case Regex.scan(~r/(?:^|\s)-setcookie(?:\s|$)/, System.get_env("ERL_FLAGS", "")) do
      [] -> [~c"-setcookie", cookie]
      [_one] -> []
      _ -> flunk("Duplicate inherited peer cookie flags are not permitted")
    end
  end

  defp assert_peer_cookie!(peer_node) do
    cookie = Node.get_cookie() |> Atom.to_charlist()

    matched? =
      case :erpc.call(peer_node, :init, :get_argument, [:setcookie], 5_000) do
        {:ok, [[^cookie]]} -> true
        _ -> false
      end

    assert matched?, "Owned peer must receive exactly one current synthetic cookie"
  end

  defp remote_applications(peer_node),
    do:
      :erpc.call(peer_node, :application, :which_applications, [], 5_000)
      |> Enum.map(&elem(&1, 0))

  defp stop_peer(peer) do
    :peer.stop(peer)
  catch
    :exit, _ -> :ok
  end
end
