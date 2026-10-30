defmodule CapabilitiesStandaloneConsumer.PeerProof do
  @moduledoc false
  alias Arbor.Security
  alias Arbor.Security.Config
  alias Arbor.Security.Identity.ReplayPeers

  def run_owned!(request_factory) do
    ensure(not Node.alive?(), "peer proof did not start in a fresh nondistributed VM")
    ensure(System.fetch_env!("ERL_EPMD_PORT") != "4369", "peer proof selected the operator EPMD")

    ensure(
      System.get_env("ERL_EPMD_ADDRESS") == "127.0.0.1",
      "peer proof is not loopback confined"
    )

    # A fresh qualification VM creates one controller atom and three owned peer atoms.
    name =
      String.to_atom(
        "capabilities_cold_controller_#{System.unique_integer([:positive])}@localhost"
      )

    {:ok, _} = :net_kernel.start([name, :shortnames])

    try do
      with_peer(
        "foreign",
        fn peer ->
          ensure(
            Enum.all?(
              [:arbor_security, :arbor_capabilities],
              &(&1 not in peer_applications(peer))
            ),
            "foreign peer ran authority"
          )
        end,
        fn node ->
          await_classification!(node, :foreign)
          ensure(not ReplayPeers.peers_present?(), "affirmatively foreign peer was refused")
          {:ok, signed} = request_factory.()

          ensure(
            match?({:ok, _}, Security.verify_signed_request_authenticity(signed)),
            "foreign peer blocked valid signed request"
          )
        end
      )

      with_peer("new_core", &install_new_core!/1, fn node ->
        refuse!(node, request_factory)
      end)

      legacy =
        System.fetch_env!("CAPABILITIES_QA_LEGACY_MANIFEST") |> File.read!() |> Jason.decode!()

      with_peer("legacy", fn peer -> install_legacy!(peer, legacy) end, fn node ->
        refuse!(node, request_factory)
      end)

      ensure(
        ReplayPeers.classification(:unseen_capabilities_probe@nowhere) == :replay_peer,
        "unknown peer classification became permissive"
      )

      %{
        "checks" => [
          "actual package-only authority peer refuses public signed requests",
          "actual provenance-bound legacy Security authority peer refuses public signed requests",
          "affirmatively foreign peer permits public signed requests",
          "local-possession acquisition still works while authority peers are connected",
          "unknown peer classification stays conservative"
        ]
      }
    after
      Node.stop()
    end
  end

  defp refuse!(node, request_factory) do
    ensure(
      ReplayPeers.peers_present?(),
      "authority peer was not discovered by the public replay gate"
    )

    await_classification!(node, :replay_peer)
    # The factory acquires a fresh stored-key owner-bound authority here,
    # proving local possession remains available while this authority peer is up.
    {:ok, signed} = request_factory.()

    ensure(
      Security.verify_signed_request_authenticity(signed) ==
        {:error, :cluster_replay_protection_unavailable},
      "authority peer did not refuse a public signed request"
    )

    ensure(
      ReplayPeers.classification(node) == :replay_peer,
      "authority peer was classified foreign"
    )
  end

  defp install_new_core!(peer) do
    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()], 5_000)
    state = Path.join(System.fetch_env!("CAPABILITIES_COLD_STATE_ROOT"), "new-peer")

    for directory <- [
          state,
          Path.join(state, "authority"),
          Path.join(state, "independent-revocations")
        ] do
      File.mkdir_p!(directory)
      File.chmod!(directory, 0o700)
    end

    :ok = :peer.call(peer, System, :put_env, ["CAPABILITIES_COLD_STATE_ROOT", state], 5_000)

    for {key, value} <- Application.get_all_env(:arbor_capabilities) do
      :ok = :peer.call(peer, Application, :put_env, [:arbor_capabilities, key, value], 5_000)
    end

    {:ok, roles} = Config.signing_key_owner_roles()

    for {key, value} <- [
          authority_state_root: Path.join(state, "authority"),
          master_key_path: Path.join(state, "authority/master.key"),
          storage_backend: Arbor.Security.Store.JSONFile,
          revocation_ledger_path: Path.join(state, "independent-revocations/ledger.json"),
          signing_key_owner_roles: roles
        ] do
      :ok = :peer.call(peer, Application, :put_env, [:arbor_capabilities, key, value], 5_000)
    end

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:arbor_capabilities], 30_000)

    ensure(
      :arbor_security not in peer_applications(peer),
      "new peer accidentally relied on the legacy host app"
    )

    ensure(
      :peer.call(peer, :application, :get_application, [Security], 5_000) ==
        {:ok, :arbor_capabilities},
      "new authority code belongs to the wrong application"
    )

    actual_owners!(peer, :arbor_capabilities)
  end

  defp install_legacy!(peer, manifest) do
    ensure(
      manifest["schema"] == "arbor.capabilities.legacy-build.v1",
      "invalid legacy manifest schema"
    )

    ensure(
      manifest["head"] == "3fbe6596fa2da06480fbdd75c3b516815d79a9d3",
      "legacy baseline head differs"
    )

    build_root = Path.expand(manifest["build_root"])

    ebins =
      manifest["files"]
      |> Map.keys()
      |> Enum.filter(&String.ends_with?(&1, ".app"))
      |> Enum.map(&(Path.dirname(Path.join(build_root, &1)) |> String.to_charlist()))
      |> Enum.uniq()

    ensure(ebins != [], "legacy manifest has no application code paths")
    :ok = :peer.call(peer, :code, :add_paths, [system_paths() ++ ebins], 5_000)
    {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir], 10_000)
    bytes = File.read!(manifest["peer_env_path"])
    ensure(hash(bytes) == manifest["peer_env_sha256"], "legacy peer configuration changed")
    {:ok, [configuration]} = :file.consult(String.to_charlist(manifest["peer_env_path"]))
    ensure(is_list(configuration), "legacy peer configuration is not data")
    security_configuration = Keyword.fetch!(configuration, :arbor_security)

    for key <- [:authority_state_root, :master_key_path, :revocation_ledger_path] do
      path = Keyword.fetch!(security_configuration, key)

      ensure(
        is_binary(path) and Path.type(path) == :absolute,
        "legacy peer omitted an explicit private state path"
      )

      ensure(
        not String.starts_with?(Path.expand(path) <> "/", Path.expand("~/.arbor") <> "/"),
        "legacy peer would use operator authority state"
      )
    end

    ensure(
      Keyword.fetch!(security_configuration, :authority_state_root) !=
        Path.join(System.fetch_env!("CAPABILITIES_COLD_STATE_ROOT"), "authority"),
      "legacy peer would share the candidate authority root"
    )

    for {application, values} <- configuration, {key, value} <- values do
      :ok = :peer.call(peer, Application, :put_env, [application, key, value], 5_000)
    end

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:arbor_security], 30_000)

    ensure(
      :arbor_capabilities not in peer_applications(peer),
      "legacy peer accidentally loaded new Core"
    )

    ensure(
      :peer.call(peer, :application, :get_application, [Security], 5_000) ==
        {:ok, :arbor_security},
      "legacy peer did not use actual old Security ownership"
    )

    beam = :peer.call(peer, :code, :which, [Security], 5_000) |> List.to_string() |> Path.expand()
    relative = Path.relative_to(beam, build_root)

    ensure(
      not String.starts_with?(relative, "../") and Map.has_key?(manifest["files"], relative),
      "legacy authority loaded outside the recorded build"
    )

    {:ok, actual_bytes} = :peer.call(peer, :file, :read_file, [String.to_charlist(beam)], 5_000)

    ensure(
      hash(actual_bytes) == manifest["files"][relative],
      "legacy authority BEAM differs from recorded baseline"
    )

    actual_owners!(peer, :arbor_security)
  end

  defp system_paths do
    roots = [
      System.fetch_env!("CAPABILITIES_COLD_ERLANG_ROOT"),
      System.fetch_env!("CAPABILITIES_COLD_ELIXIR_ROOT")
    ]

    Enum.filter(:code.get_path(), fn path ->
      absolute = Path.expand(List.to_string(path)) <> "/"
      Enum.any?(roots, &String.starts_with?(absolute, Path.expand(&1) <> "/"))
    end)
  end

  defp actual_owners!(peer, application) do
    ensure(
      match?(
        {:ok, {Arbor.Security.Application, _}},
        :peer.call(peer, :application, :get_key, [application, :mod], 5_000)
      ),
      "authority peer application callback was not the actual authority tree"
    )

    supervisor = :peer.call(peer, Process, :whereis, [Arbor.Security.Supervisor], 5_000)

    ensure(
      is_pid(supervisor) and
        :peer.call(peer, :application, :get_application, [supervisor], 5_000) ==
          {:ok, application},
      "authority supervisor belongs to the wrong application"
    )

    for owner <- [
          Arbor.Security.CapabilityStore,
          Arbor.Security.Identity.Registry,
          Arbor.Security.SystemAuthority,
          Arbor.Security.Identity.ReplayPeers
        ] do
      ensure(
        is_pid(:peer.call(peer, Process, :whereis, [owner], 5_000)),
        "authority peer lacked a real owner"
      )
    end
  end

  defp with_peer(label, initialize, operation) do
    # The three labels above are fixed; this never converts external input to atoms.
    name = String.to_atom("capabilities_cold_#{label}_#{System.unique_integer([:positive])}")

    {:ok, peer, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"localhost",
        connection: :standard_io,
        args: peer_cookie_args!()
      })

    try do
      initialize.(peer)

      ensure(
        node not in Node.list(:connected),
        "peer setup connected distribution before discovery"
      )

      ensure(Node.connect(node), "owned peer did not connect")
      assert_peer_cookie!(node)
      operation.(node)
    after
      :peer.stop(peer)
      await_disconnected!(node, 100)
    end
  end

  defp peer_cookie_args! do
    cookie = Node.get_cookie() |> Atom.to_charlist()

    ensure(
      hash(List.to_string(cookie)) == System.fetch_env!("CAPABILITIES_COLD_COOKIE_SHA256"),
      "parent cookie differs from the pinned synthetic cookie"
    )

    for key <- ["ERL_AFLAGS", "ERL_ZFLAGS"] do
      ensure(
        not Regex.match?(~r/(?:^|\s)-setcookie(?:\s|$)/, System.get_env(key, "")),
        "competing inherited peer cookie flags are not permitted"
      )
    end

    case Regex.scan(~r/(?:^|\s)-setcookie(?:\s|$)/, System.get_env("ERL_FLAGS", "")) do
      [] -> [~c"-setcookie", cookie]
      [_one] -> []
      _ -> raise("duplicate inherited peer cookie flags are not permitted")
    end
  end

  defp assert_peer_cookie!(node) do
    cookie = Node.get_cookie() |> Atom.to_charlist()

    matched? =
      case :erpc.call(node, :init, :get_argument, [:setcookie], 5_000) do
        {:ok, [[^cookie]]} -> true
        _ -> false
      end

    ensure(matched?, "owned peer must receive exactly one current synthetic cookie")
  end

  defp await_classification!(node, expected) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_classification!(node, expected, deadline)
  end

  defp await_classification!(node, expected, deadline) do
    ensure(node in Node.list(:connected), "owned peer disconnected before discovery")

    if ReplayPeers.classification(node) == expected do
      :ok
    else
      ensure(
        System.monotonic_time(:millisecond) < deadline,
        "production peer discovery did not become ready"
      )

      receive do
      after
        10 -> await_classification!(node, expected, deadline)
      end
    end
  end

  defp await_disconnected!(node, remaining) do
    if node in Node.list(:connected) do
      ensure(remaining > 0, "owned peer stayed connected after stop")

      receive do
      after
        10 -> await_disconnected!(node, remaining - 1)
      end
    else
      :ok
    end
  end

  defp peer_applications(peer),
    do: :peer.call(peer, :application, :which_applications, [], 5_000) |> Enum.map(&elem(&1, 0))

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("Capabilities peer qualification failed: " <> label)
end
