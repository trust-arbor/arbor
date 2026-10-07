defmodule Arbor.Security.ApplicationSpecSecurityRegressionTest do
  @moduledoc """
  Security regression: generated OTP spec omits JWT/HTTP providers, and a
  fresh peer :activation_only start neither starts nor loads them.
  """
  use ExUnit.Case, async: false

  alias Arbor.KernelRuntime.ApplicationSpecPeer

  @startup_timeout 15_000
  @omitted [:joken, :joken_jwks, :req, :jose, :finch, :mint]
  @required MapSet.new([
              :arbor_kernel_runtime,
              :elixir,
              :jason,
              :kernel,
              :logger,
              :plug_crypto,
              :stdlib,
              :telemetry
            ])
  @named_stores [
    :arbor_security_capabilities,
    :arbor_security_identities,
    :arbor_security_signing_keys,
    :arbor_security_issuers
  ]

  @tag :fast
  test "security regression: consulted .app required set omits JWT and HTTP providers" do
    props =
      ApplicationSpecPeer.consult_env_app!(:arbor_security, Mix.Project.build_path())

    required = MapSet.new(Keyword.get(props, :applications, []))
    optional = Keyword.get(props, :optional_applications, [])
    included = Keyword.get(props, :included_applications, [])

    assert required == @required
    assert optional == []
    assert included == []

    Enum.each(@omitted, fn app ->
      refute app in required
      refute app in optional
      refute app in included
    end)
  end

  @tag :slow
  @tag :integration
  @tag :security_regression
  test "security regression: activation_only peer does not start or load provider apps" do
    control = ApplicationSpecPeer.start!()

    try do
      :ok =
        ApplicationSpecPeer.prepare_restricted!(
          control,
          :arbor_security,
          [:arbor_kernel, :arbor_security],
          Mix.Project.build_path()
        )

      :ok =
        ApplicationSpecPeer.assert_omitted_ebins(
          control,
          @omitted,
          Mix.Project.build_path()
        )

      :ok = ApplicationSpecPeer.put_activation_profile(control, start_profile: :activation_only)

      assert {:ok, _} =
               ApplicationSpecPeer.call(
                 control,
                 Application,
                 :ensure_all_started,
                 [:arbor_security]
               )

      :ok =
        ApplicationSpecPeer.assert_omitted_ebins(
          control,
          @omitted,
          Mix.Project.build_path()
        )

      started = ApplicationSpecPeer.started_applications(control)
      loaded = ApplicationSpecPeer.loaded_applications(control)

      Enum.each(@omitted, fn app ->
        refute app in started
        refute app in loaded
      end)

      refute ApplicationSpecPeer.call(control, :erlang, :module_loaded, [Joken])
      refute ApplicationSpecPeer.call(control, :erlang, :module_loaded, [Req])
      refute ApplicationSpecPeer.call(control, :erlang, :module_loaded, [Finch])
      refute ApplicationSpecPeer.call(control, :erlang, :module_loaded, [Mint])

      assert ApplicationSpecPeer.call(
               control,
               Process,
               :whereis,
               [Arbor.Security.ProviderGate]
             ) == nil

      Enum.each(@named_stores, fn name ->
        assert ApplicationSpecPeer.call(control, Process, :whereis, [name]) == nil
      end)
    after
      ApplicationSpecPeer.stop(control)
    end
  end

  @tag :slow
  @tag :integration
  @tag :security_regression
  test "security regression: full persistent peer returns ready and preserves authority across restart" do
    control = ApplicationSpecPeer.start!()
    authority_root = private_authority_root!()

    try do
      prepare_full_peer!(control, authority_root)

      assert {:ok, _started} =
               peer_call(control, Application, :ensure_all_started, [:arbor_security])

      first = assert_full_security_ready!(control)

      assert :ok = peer_call(control, Application, :stop, [:arbor_security])

      assert {:ok, _restarted} =
               peer_call(control, Application, :ensure_all_started, [:arbor_security])

      second = assert_full_security_ready!(control)

      assert second.agent_id == first.agent_id
      assert second.public_key == first.public_key
      assert second.system_authority != first.system_authority
      assert second.signing_broker != first.signing_broker
      assert second.capability_store != first.capability_store
      assert second.terminal_login != first.terminal_login
    after
      ApplicationSpecPeer.stop(control)
      File.rm_rf!(authority_root)
      File.rm(authority_root <> ".revocation-ledger.json")
    end
  end

  defp prepare_full_peer!(control, authority_root) do
    :ok =
      ApplicationSpecPeer.prepare_restricted!(
        control,
        :arbor_security,
        [:arbor_kernel, :arbor_security],
        Mix.Project.build_path()
      )

    eex_ebin =
      :eex
      |> :code.lib_dir()
      |> List.to_string()
      |> Path.join("ebin")
      |> String.to_charlist()

    all_ebins =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.map(&String.to_charlist/1)
      |> List.insert_at(0, eex_ebin)

    :ok = peer_call(control, :code, :add_paths, [all_ebins])
    :ok = ApplicationSpecPeer.put_activation_profile(control, start_profile: :full)

    session_secret = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

    Enum.each(
      [
        start_children: true,
        storage_backend: Arbor.Security.Store.JSONFile,
        authority_state_root: authority_root,
        revocation_ledger_path: authority_root <> ".revocation-ledger.json",
        audit_journal_mode: :durable,
        system_authority_mode: :persistent,
        master_key_path: Path.join(authority_root, "master.key"),
        session_token_secret: session_secret,
        distributed_signals: false
      ],
      fn {key, value} ->
        :ok =
          peer_call(control, Application, :put_env, [
            :arbor_security,
            key,
            value,
            [persistent: true]
          ])
      end
    )
  end

  defp assert_full_security_ready!(control) do
    system_authority = peer_process!(control, Arbor.Security.SystemAuthority)
    signing_broker = peer_process!(control, Arbor.Security.SigningAuthorityBroker)
    capability_store = peer_process!(control, Arbor.Security.CapabilityStore)
    terminal_login = peer_process!(control, Arbor.Security.TerminalLogin)

    Enum.each(@named_stores, &peer_process!(control, &1))

    agent_id = peer_call(control, Arbor.Security.SystemAuthority, :agent_id, [])
    public_key = peer_call(control, Arbor.Security.SystemAuthority, :public_key, [])

    assert is_binary(agent_id)
    assert is_binary(public_key)

    assert {:ok, ^public_key} =
             peer_call(control, Arbor.Security.Identity.Registry, :lookup, [agent_id])

    assert [] = peer_call(control, Arbor.Security.IssuerRegistry, :list, [])

    assert %{active_capabilities: 0} =
             peer_call(control, Arbor.Security.CapabilityStore, :stats, [])

    assert :node_restart =
             peer_call(control, Arbor.Security.AuthorityStore, :durability_class, [
               [name: :arbor_security_signing_keys]
             ])

    assert {:ok, %{"mode" => "durable", "serving" => true}} =
             peer_call(control, Arbor.Security, :audit_journal_status, [])

    %{
      agent_id: agent_id,
      public_key: public_key,
      system_authority: system_authority,
      signing_broker: signing_broker,
      capability_store: capability_store,
      terminal_login: terminal_login
    }
  end

  defp peer_process!(control, name) do
    pid = peer_call(control, Process, :whereis, [name])
    assert is_pid(pid), "expected peer process #{inspect(name)} to be running"
    pid
  end

  defp private_authority_root! do
    {:ok, canonical_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    authority_root = Path.join(canonical_tmp, "arbor-security-peer-startup-#{token}")
    File.mkdir!(authority_root)
    File.chmod!(authority_root, 0o700)
    on_exit(fn -> File.rm_rf!(authority_root) end)
    authority_root
  end

  defp peer_call(control, module, function, args) do
    :peer.call(control, module, function, args, @startup_timeout)
  end
end
