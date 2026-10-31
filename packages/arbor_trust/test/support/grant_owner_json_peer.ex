defmodule Arbor.Trust.TestSupport.GrantOwnerJSONPeer do
  @moduledoc false
  @first_party ~w(arbor_kernel arbor_custody arbor_support arbor_oauth arbor_capabilities arbor_persistence arbor_trust)a
  @otp_apps ~w(asn1 compiler crypto erts inets kernel os_mon public_key runtime_tools sasl ssl stdlib)a
  alias Arbor.Security.Config, as: SecurityConfig
  alias __MODULE__.{AuditSink, Catalog, Provisioner}

  def start!(root) do
    for child <- ["authority", "independent-revocations", "home", "data", "tmp"] do
      path = Path.join(root, child)
      :ok = File.mkdir(path)
      :ok = File.chmod(path, 0o700)
    end

    env_file = Path.join(root, "empty.env")
    File.write!(env_file, "", [:exclusive])
    inetrc = Path.join(root, "inetrc")

    File.write!(inetrc, "{host, {127,0,0,1}, [\"localhost\"]}.\n{lookup, [file]}.\n", [:exclusive])

    {:ok, reservation} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(reservation)
    :ok = :gen_tcp.close(reservation)
    true = port != 4369
    cookie = "trust_owner_json_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    cookie_hash = :crypto.hash(:sha256, cookie)
    # No :name option: standard_io controls a non-distributed fresh VM.
    # Child-only env overrides prevent an inherited real/duplicate cookie or code path.
    args = [
      ~c"-boot",
      ~c"start_clean",
      ~c"-no_dot_erlang",
      ~c"+S",
      ~c"2:2",
      ~c"-setcookie",
      String.to_charlist(cookie)
    ]

    env = [
      {~c"ERL_FLAGS", ~c""},
      {~c"ERL_AFLAGS", ~c""},
      {~c"ERL_ZFLAGS", ~c""},
      {~c"ELIXIR_ERL_OPTIONS", ~c""},
      {~c"ERL_LIBS", ~c""},
      {~c"ERL_EPMD_PORT", Integer.to_charlist(port)},
      {~c"ERL_EPMD_ADDRESS", ~c"127.0.0.1"},
      {~c"ERL_INETRC", String.to_charlist(inetrc)},
      {~c"ARBOR_HOME", String.to_charlist(Path.join(root, "home"))},
      {~c"ARBOR_DATA_DIR", String.to_charlist(Path.join(root, "data"))},
      {~c"ARBOR_ENV_PATH", String.to_charlist(env_file)},
      {~c"TMPDIR", String.to_charlist(Path.join(root, "tmp"))}
    ]

    case :peer.start_link(%{connection: :standard_io, args: args, env: env, wait_boot: 30_000}) do
      {:ok, peer} -> prepare_owned_code!(peer, cookie_hash)
      {:ok, peer, :nonode@nohost} -> prepare_owned_code!(peer, cookie_hash)
      _other -> raise "strict grant-owner peer failed to start"
    end
  end

  def stop(peer) do
    monitor = Process.monitor(peer)

    try do
      if Process.alive?(peer) do
        try do
          :ok = :peer.stop(peer)
        catch
          :exit, :noproc -> :ok
          :exit, {:noproc, _} -> :ok
        end
      end

      receive do
        {:DOWN, ^monitor, :process, ^peer, _reason} -> :ok
      after
        5_000 -> raise "owned strict peer did not acknowledge shutdown"
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  def call(peer, module, function, args), do: :peer.call(peer, module, function, args, 110_000)

  def boot!(root) do
    false = Node.alive?()
    [] = first_party_started()

    for child <- ["authority", "independent-revocations", "home", "data", "tmp"] do
      {:ok, %{type: :directory, mode: mode}} = File.lstat(Path.join(root, child))
      true = Bitwise.band(mode, 0o077) == 0
    end

    env_file = Path.join(root, "empty.env")
    System.put_env("ARBOR_HOME", Path.join(root, "home"))
    System.put_env("ARBOR_DATA_DIR", Path.join(root, "data"))
    System.put_env("ARBOR_ENV_PATH", env_file)
    System.put_env("TMPDIR", Path.join(root, "tmp"))
    System.put_env("CAPABILITIES_COLD_STATE_ROOT", root)

    # Load genuine generated .app files; never fabricate application specs.
    for app <- @first_party do
      case Application.load(app) do
        :ok -> :ok
        {:error, {:already_loaded, ^app}} -> :ok
      end
    end

    {:ok, :arbor_trust} = :application.get_application(Provisioner)

    internal_role = fn module ->
      %{application: :arbor_capabilities, path: [module], registered_name: module, purposes: []}
    end

    roles = %{
      system_authority: internal_role.(Arbor.Security.SystemAuthority),
      signing_broker: internal_role.(Arbor.Security.SigningAuthorityBroker),
      channel_broker: internal_role.(Arbor.Security.ChannelAuthorityBroker),
      system_lifecycle_owner: %{
        application: :arbor_trust,
        path: [
          Arbor.Trust.Supervisor,
          Arbor.Trust.TestSupport.GrantOwnerJSONPeer.DormantLifecycleOwner
        ],
        registered_name: Arbor.Trust.TestSupport.GrantOwnerJSONPeer.DormantLifecycleOwner,
        purposes: []
      },
      scheduler_owner: %{
        application: :arbor_trust,
        path: [Arbor.Trust.Supervisor, Provisioner],
        registered_name: Provisioner,
        purposes: [:session]
      },
      trust_grant_owner: %{
        application: :arbor_trust,
        path: [Arbor.Trust.Supervisor, Arbor.Trust.CapabilityGrantOwner],
        registered_name: Arbor.Trust.CapabilityGrantOwner,
        purposes: [:trust_capability_grant]
      }
    }

    core = [
      runtime_host: nil,
      runtime: [start_profile: :full],
      start_children: true,
      signal_transport: nil,
      distributed_signals: false,
      authority_state_root: Path.join(root, "authority"),
      master_key_path: Path.join(root, "authority/master.key"),
      revocation_ledger_path: Path.join(root, "independent-revocations/revocations.json"),
      storage_backend: Arbor.Security.Store.JSONFile,
      system_authority_mode: :persistent,
      audit_journal_mode: :durable,
      invocation_audit_mode: :required,
      invocation_audit_sink: AuditSink,
      authority_audit_consumer_name: nil,
      authority_audit_consumer_application: nil,
      identity_verification: true,
      strict_identity_mode: true,
      capability_signing_required: true,
      delegation_chain_verification_enabled: true,
      constraint_enforcement_enabled: true,
      allow_local_human_identity: true,
      oidc: [],
      uri_registry_enforcement: true,
      uri_registration_providers: [Catalog],
      uri_bootstrap_providers: [Catalog],
      session_token_secret: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      approval_receipt_issuer_owner: %{
        application: :arbor_trust,
        path: [Arbor.Trust.Supervisor, Arbor.Trust.ConfirmationTracker],
        registered_name: Arbor.Trust.ConfirmationTracker
      },
      signing_key_owner_roles: roles
    ]

    for {key, value} <- core,
        do: Application.put_env(:arbor_capabilities, key, value, persistent: true)

    for {key, value} <- [
          runtime_host: nil,
          runtime: [start_profile: :full],
          start_children: true,
          profile_store: [mode: :memory],
          profile_sync_transport: nil,
          observation: nil,
          pubsub: nil,
          action_profile_provider: nil,
          policy_enforcer_enabled: true,
          approval_guard_enabled: true
        ] do
      Application.put_env(:arbor_trust, key, value, persistent: true)
    end

    [] = first_party_started()
    {:ok, _} = Application.ensure_all_started(:arbor_capabilities)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)
    {:ok, provisioner} = Supervisor.start_child(Arbor.Trust.Supervisor, {Provisioner, []})
    ^provisioner = Process.whereis(Provisioner)
    :ok
  end

  def exercise, do: GenServer.call(Provisioner, :exercise, 100_000)

  def public_provenance do
    owner = Process.whereis(Arbor.Trust.CapabilityGrantOwner)
    supervisor = Process.whereis(Arbor.Trust.Supervisor)
    root = Process.whereis(Arbor.Trust.ApplicationSupervisor)
    children = Supervisor.which_children(supervisor)

    %{
      canonical_owner:
        is_pid(owner) and
          Enum.any?(children, &match?({Arbor.Trust.CapabilityGrantOwner, ^owner, :worker, _}, &1)),
      canonical_supervisor:
        is_pid(supervisor) and
          Enum.any?(
            Supervisor.which_children(root),
            &match?({Arbor.Trust.Supervisor, ^supervisor, :supervisor, _}, &1)
          ),
      genuine_modules:
        Enum.all?(
          [Arbor.Trust.CapabilityGrantOwner, Provisioner],
          &(:application.get_application(&1) == {:ok, :arbor_trust})
        ),
      genuine_application_callback:
        Application.spec(:arbor_trust, :mod) == {Arbor.Trust.Application, []},
      provisioner_is_distinct: owner != Process.whereis(Provisioner),
      json_file_backend: SecurityConfig.storage_backend() == Arbor.Security.Store.JSONFile,
      persistent_system_authority: SecurityConfig.system_authority_mode() == :persistent,
      durable_audit: Application.fetch_env!(:arbor_capabilities, :audit_journal_mode) == :durable,
      required_invocation_audit: SecurityConfig.invocation_audit_mode() == :required,
      strict_identity: SecurityConfig.strict_identity_mode?(),
      identity_verification: SecurityConfig.identity_verification_enabled?(),
      capability_signing: SecurityConfig.capability_signing_required?(),
      delegation_verification: SecurityConfig.delegation_chain_verification_enabled?(),
      constraints: SecurityConfig.constraint_enforcement_enabled?(),
      non_distributed: not Node.alive?(),
      no_product_apps: Enum.all?(first_party_started(), &(&1 in @first_party))
    }
  end

  defp prepare_owned_code!(peer, cookie_hash) do
    prepare_code!(peer, cookie_hash)
  rescue
    exception ->
      :ok = stop(peer)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      :ok = stop(peer)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp prepare_code!(peer, cookie_hash) do
    paths = collect_paths(@first_party ++ [:elixir, :logger], MapSet.new(), [])
    :ok = :peer.call(peer, :code, :add_paths, [Enum.map(paths, &String.to_charlist/1)])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])
    :ok = :peer.call(peer, __MODULE__, :admit_private_peer!, [cookie_hash])
    peer
  end

  defp collect_paths([], _seen, paths), do: Enum.uniq(paths)

  defp collect_paths([app | rest], seen, paths) do
    if MapSet.member?(seen, app) or app in @otp_apps do
      collect_paths(rest, MapSet.put(seen, app), paths)
    else
      if String.starts_with?(Atom.to_string(app), "arbor_") and app not in @first_party,
        do: raise("undeclared product app in strict peer closure")

      dir = :code.lib_dir(app)
      true = is_list(dir)
      path = Path.join(List.to_string(dir), "ebin")

      {:ok, [{:application, ^app, props}]} =
        :file.consult(String.to_charlist(Path.join(path, "#{app}.app")))

      required =
        (Keyword.get(props, :applications, []) -- Keyword.get(props, :optional_applications, [])) ++
          Keyword.get(props, :included_applications, [])

      collect_paths(required ++ rest, MapSet.put(seen, app), [path | paths])
    end
  end

  def admit_private_peer!(expected_hash) do
    false = Node.alive?()

    actual_hash =
      case :init.get_argument(:setcookie) do
        {:ok, [[cookie]]} when is_list(cookie) -> :crypto.hash(:sha256, List.to_string(cookie))
        _ -> raise "strict peer requires exactly one private initial cookie"
      end

    true = actual_hash == expected_hash
    :ok
  end

  defp first_party_started do
    for {app, _, _} <- Application.started_applications(),
        String.starts_with?(Atom.to_string(app), "arbor_"),
        do: app
  end
end

defmodule Arbor.Trust.TestSupport.GrantOwnerJSONPeer.Catalog do
  @moduledoc false
  def capability_uri_prefixes,
    do: ["arbor://security", "arbor://memory", "arbor://trust", "arbor://approval"]
end

defmodule Arbor.Trust.TestSupport.GrantOwnerJSONPeer.AuditSink do
  @moduledoc false
  # Real fsynced private invocation sink, same public callback as the standalone consumer.
  def persist_security_invocation(event) do
    path = Path.join(System.fetch_env!("CAPABILITIES_COLD_STATE_ROOT"), "invocations.jsonl")

    with {:ok, file} <- :file.open(String.to_charlist(path), [:append, :binary, :raw]) do
      try do
        with :ok <- :file.write(file, Jason.encode!(event) <> "\n"),
             :ok <- :file.sync(file),
             do: {:ok, event["id"]}
      after
        :file.close(file)
      end
    end
  end
end

defmodule Arbor.Trust.TestSupport.GrantOwnerJSONPeer.Provisioner do
  @moduledoc false
  use GenServer
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.OIDC.IdentityStore
  alias Arbor.Trust
  alias Arbor.Trust.CapabilityGrantOwner
  alias Arbor.Trust.TestSupport.GrantOwnerJSONPeer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_) do
    Process.flag(:sensitive, true)
    {:ok, nil}
  end

  def handle_call(:exercise, _from, state), do: {:reply, exercise_owned!(), state}

  defp exercise_owned! do
    true = self() == Process.whereis(__MODULE__)
    {:error, :genesis_unauthorized} = Security.complete_local_genesis(:unproved)
    {:ok, operator, genesis} = prepare_operator_genesis!()
    {:ok, _} = Security.complete_local_genesis(genesis)
    true = match?({:error, _}, Security.complete_local_genesis(genesis))
    operator_authority = authority!(operator.agent_id)
    {:ok, target} = enroll!("grant-owner-json-target", operator_authority)
    target_authority = authority!(target.agent_id)

    try do
      resource = "arbor://memory/read/" <> target.agent_id <> "/grant-owner-json"
      session = "grant-owner-json-" <> target.agent_id

      {:ok, _profile} =
        Trust.ensure_trust_profile(target.agent_id,
          baseline: :block,
          rules: %{resource => :allow}
        )

      :allow = Trust.effective_mode(target.agent_id, resource)
      initial = await_status(:dormant)

      {:ok, _} =
        Security.grant(
          principal: initial.principal_id,
          resource: CapabilityGrantOwner.required_capability_uri(),
          delegation_depth: 0,
          actor_authority: operator_authority
        )

      :ok = Supervisor.terminate_child(Arbor.Trust.Supervisor, CapabilityGrantOwner)
      {:ok, _} = Supervisor.restart_child(Arbor.Trust.Supervisor, CapabilityGrantOwner)
      ready = await_status(:ready)
      true = ready.principal_id == initial.principal_id
      {:error, :unauthorized} = Security.load_signing_key(ready.principal_id)
      provenance = GrantOwnerJSONPeer.public_provenance()
      true = Enum.all?(provenance, fn {_key, value} -> value == true end)
      {:ok, payload} = Trust.build_capability_grant_request(target.agent_id, resource, session)
      {:ok, wrong_signer} = Security.sign_with_authority(operator_authority, payload)
      {:error, :capability_grant_request_denied} = CapabilityGrantOwner.request(wrong_signer)
      {:ok, signed_request} = Security.sign_with_authority(target_authority, payload)
      {:ok, before_caps} = Security.list_capabilities(target.agent_id)
      # Mandatory RED/GREEN oracle: untouched result from the canonical production owner.
      result = CapabilityGrantOwner.request(signed_request)

      controls =
        case result do
          {:ok, capability} ->
            {:ok, hot_caps} = Security.list_capabilities(target.agent_id)
            {:ok, signed} = Security.sign_with_authority(target_authority, resource)

            authorization =
              Trust.authorize(target.agent_id, resource, :read,
                session_id: session,
                signed_request: signed,
                expected_resource: resource
              )

            {:ok, wrong_session_signed} = Security.sign_with_authority(target_authority, resource)

            wrong_session =
              Trust.authorize(target.agent_id, resource, :read,
                session_id: session <> "-wrong",
                signed_request: wrong_session_signed,
                expected_resource: resource
              )

            replay = CapabilityGrantOwner.request(signed_request)
            {:ok, after_caps} = Security.list_capabilities(target.agent_id)

            %{
              hot_capability: Enum.find(hot_caps, &(&1.id == capability.id)),
              authorization: authorization,
              wrong_session: wrong_session,
              replay: replay,
              count_before: length(before_caps),
              count_after: length(after_caps)
            }

          {:error, _} ->
            nil
        end

      %{
        provenance: provenance,
        grant_result: result,
        controls: controls,
        target_id: target.agent_id,
        resource: resource,
        session: session,
        owner_principal_stable: ready.principal_id == initial.principal_id
      }
    after
      Security.close_signing_authority(target_authority)
      Security.close_signing_authority(operator_authority)
    end
  end

  defp await_status(expected) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    await_status(expected, deadline)
  end

  defp await_status(expected, deadline) do
    status = CapabilityGrantOwner.status()

    if status.state == expected and is_binary(status.principal_id) do
      status
    else
      if System.monotonic_time(:millisecond) >= deadline,
        do: raise("canonical owner did not reach expected public state")

      receive do
      after
        10 -> await_status(expected, deadline)
      end
    end
  end

  defp prepare_operator_genesis! do
    claims = %{iss: "arbor://local", sub: "qualification-operator@isolated-qualification"}
    {:ok, generated} = Security.generate_identity(name: "Standalone qualification operator")

    operator = %{
      generated
      | agent_id: IdentityStore.derive_agent_id(claims),
        metadata: %{
          "oidc_issuer" => claims.iss,
          "oidc_sub" => claims.sub,
          "identity_type" => "human"
        }
    }

    :ok = Registry.register_local_human(Identity.public_only(operator))

    :ok =
      Security.store_signing_keypair(
        operator.agent_id,
        operator.private_key,
        operator.encryption_private_key
      )

    key_path =
      Path.join(System.fetch_env!("CAPABILITIES_COLD_STATE_ROOT"), "caller-held-operator.key")

    {:ok, ^key_path} =
      Security.write_key_file(
        key_path,
        %{agent_id: operator.agent_id, private_key: operator.private_key}
      )

    ensure(
      :erlang.band(File.stat!(key_path).mode, 0o077) == 0,
      "caller-held genesis key file is not private"
    )

    {:ok, device} = :file.open(String.to_charlist(key_path), [:read, :raw, :binary])

    try do
      {:ok, principal, proof} = Security.prepare_key_file_local_genesis(device)
      ensure(principal == operator.agent_id, "key-file genesis principal changed")
      {:ok, payload} = Security.local_genesis_request_payload(principal)
      ensure(proof.payload == payload, "key-file genesis did not bind the fixed public payload")
      {:ok, Identity.public_only(operator), proof}
    after
      :file.close(device)
    end
  end

  defp enroll!(name, actor) do
    {:ok, identity} = Security.generate_identity(name: name)

    ensure(
      Security.register_identity(identity) == {:error, :identity_registration_unauthorized},
      "raw identity registration admitted"
    )

    :ok =
      Security.store_signing_keypair(
        identity.agent_id,
        identity.private_key,
        identity.encryption_private_key
      )

    :ok = Security.register_identity(identity, actor)
    {:ok, Identity.public_only(identity)}
  end

  defp authority!(principal) do
    {:ok, proof} =
      Security.build_stored_signing_authority_acquisition_proof(
        principal,
        :session,
        self(),
        __MODULE__
      )

    {:ok, authority} = Security.open_signing_authority(proof)
    authority
  end

  defp ensure(true, _), do: :ok
  defp ensure(false, label), do: raise("strict grant-owner peer bootstrap: " <> label)
end

defmodule Arbor.Trust.TestSupport.GrantOwnerJSONPeer.DormantLifecycleOwner do
  @moduledoc false
  # Explicit unavailable role in the closed identity-registration vocabulary.
  # This fixture never starts this child or admits lifecycle authority.
end
