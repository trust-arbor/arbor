defmodule Arbor.Security.OIDCOptionalAdapterHostSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.SafePath
  alias Arbor.KernelRuntime.ApplicationSpecPeer

  @omitted [:arbor_capabilities_oidc, :joken, :joken_jwks, :jose]
  @http_providers [:req, :finch, :mint]
  @startup_timeout 60_000

  driver =
    defmodule PeerDriver do
      @moduledoc false

      alias Arbor.Contracts.Security.Identity
      alias Arbor.Contracts.Security.SignedRequest
      alias Arbor.Security
      alias Arbor.Security.Identity.Registry

      @provider %{issuer: "https://unavailable.idp.invalid", client_id: "arbor"}
      @unavailable {:error, :oidc_adapter_unavailable}

      def exercise do
        false = Node.alive?()
        {:ok, boot_profile} = Arbor.KernelRuntime.boot_profile()
        true = is_binary(boot_profile["manifest_sha256"])
        true = is_binary(boot_profile["profile_id"])

        for name <- [
              Arbor.KernelRuntime.ProviderGate,
              Arbor.Security.ProviderGate,
              Arbor.Security.SigningAuthorityBroker,
              Arbor.Security.SigningKeyStore.Owner,
              Arbor.Security.Identity.Registry,
              Arbor.Security.OIDC.JwksCache,
              Arbor.Security.TerminalLogin
            ] do
          true = is_pid(Process.whereis(name))
        end

        {:ok, %{"mode" => "durable", "serving" => true}} = Security.audit_journal_status()

        # Keep every unsupported adapter selection closed without conflating
        # configuration with the availability of an executable protocol module.
        for selector <- [:unset, nil, false, "invalid", :missing_oidc_protocol_adapter] do
          put_selector(selector)
          true = Security.oidc_enabled?() == false
          [] = Security.oidc_providers()
          true = is_binary(Security.generate_oidc_state())
          true = is_binary(Security.generate_oidc_nonce())

          @unavailable = Security.verify_oidc_token("original.signed.token", @provider)

          @unavailable =
            Security.build_oidc_authorize_url(
              @provider,
              "http://127.0.0.1/callback",
              Security.generate_oidc_state()
            )

          @unavailable =
            Security.exchange_oidc_code(
              @provider,
              "unavailable-code",
              "http://127.0.0.1/callback",
              "unavailable-verifier"
            )
        end

        put_selector(nil)
        operator = registered_local_operator()
        {:ok, payload} = Security.local_genesis_request_payload(operator.agent_id)
        {:ok, proof} = SignedRequest.sign(payload, operator.agent_id, operator.private_key)

        Application.put_env(:arbor_capabilities, :oidc, providers: [@provider])
        true = Security.oidc_enabled?()
        [configured] = Security.oidc_providers()
        true = configured.issuer == @provider.issuer

        {:error, :oidc_configured} =
          Security.create_local_human_identity(user: "must-not-fall-back", host: "peer")

        # This proof has a real registered key and an otherwise open genesis.
        # The same proof must succeed below once configured policy is removed.
        {:error, :oidc_configured} = Security.complete_local_genesis(proof)
        @unavailable = Security.verify_oidc_token("original.signed.token", @provider)

        Application.put_env(:arbor_capabilities, :oidc, [])
        {:ok, capability_id} = Security.complete_local_genesis(proof)
        true = is_binary(capability_id)

        {:ok, acquisition} =
          Security.build_signing_authority_acquisition_proof(
            operator.agent_id,
            operator.private_key,
            purpose: :optional_oidc_peer
          )

        {:ok, authority} =
          Security.open_ephemeral_signing_authority(acquisition, operator.private_key)

        payload = "arbor://test/signing/optional-oidc-peer"
        {:ok, signed} = Security.sign_with_authority(authority, payload)
        true = signed.payload == payload
        {:ok, principal} = Security.verify_request(signed)
        true = principal == operator.agent_id

        {:ok, grantee} = Security.generate_identity(name: "optional OIDC grantee")
        :ok = Security.register_identity(grantee, authority)
        resource = "arbor://fs/read/optional-oidc-peer"

        {:ok, granted} =
          Security.grant(
            principal: grantee.agent_id,
            resource: resource,
            actor_authority: authority
          )

        true = granted.principal_id == grantee.agent_id
        true = is_binary(granted.issuer_signature)
        {:ok, :authorized} = Security.authorize(grantee.agent_id, resource, :read)

        %{
          bound_boot: true,
          configured_policy_preserved: true,
          signed_request_verified: true,
          ordinary_grant_authorized: true
        }
      end

      defp put_selector(:unset), do: Application.delete_env(:arbor_capabilities, :oidc_adapter)

      defp put_selector(value),
        do: Application.put_env(:arbor_capabilities, :oidc_adapter, value)

      # This is the existing local-genesis regression fixture's real key and
      # registration path. Grants below use production proof and grant APIs.
      defp registered_local_operator do
        {:ok, base} = Security.generate_identity(name: "optional OIDC local operator")
        subject = "optional-oidc-peer@local"

        principal =
          "human_" <>
            String.slice(
              Base.encode16(:crypto.hash(:sha256, "arbor://local:" <> subject), case: :lower),
              0,
              40
            )

        operator = %{
          base
          | agent_id: principal,
            metadata: %{
              "oidc_issuer" => "arbor://local",
              "oidc_sub" => subject,
              "identity_type" => "human"
            }
        }

        :ok = Registry.register_local_human(Identity.public_only(operator))
        {:ok, :active} = Registry.identity_status(operator.agent_id)
        operator
      end
    end

  @driver elem(driver, 1)
  @driver_binary elem(driver, 2)

  @tag :slow
  @tag :integration
  @tag :security_regression
  @tag timeout: 120_000
  test "security regression: full Security works with OIDC and JWT ebins absent while configured policy stays closed" do
    control = ApplicationSpecPeer.start!()
    base_dir = private_authority_fixture!()

    try do
      prepare_full_peer!(control, base_dir)
      assert_omitted!(control)

      assert {:ok, _started} =
               peer_call(control, Application, :ensure_all_started, [:arbor_capabilities])

      {:module, @driver} =
        peer_call(control, :code, :load_binary, [
          @driver,
          ~c"optional_oidc_peer_driver",
          @driver_binary
        ])

      assert %{
               bound_boot: true,
               configured_policy_preserved: true,
               signed_request_verified: true,
               ordinary_grant_authorized: true
             } = peer_call(control, @driver, :exercise, [])

      assert_omitted!(control)

      for app <- @http_providers do
        assert app in ApplicationSpecPeer.started_applications(control)
      end

      for app <- @omitted do
        refute app in ApplicationSpecPeer.started_applications(control)
        refute app in ApplicationSpecPeer.loaded_applications(control)
      end

      for module <- [Arbor.Capabilities.OIDC, Joken, JokenJwks, JOSE, JOSE.JWT] do
        refute peer_call(control, Code, :ensure_loaded?, [module])
      end
    after
      ApplicationSpecPeer.stop(control)
      File.rm_rf!(base_dir)
    end
  end

  defp prepare_full_peer!(control, base_dir) do
    :ok =
      ApplicationSpecPeer.prepare_restricted!(
        control,
        :arbor_capabilities,
        [:arbor_kernel, :arbor_capabilities],
        Mix.Project.build_path()
      )

    omitted = MapSet.new(Enum.map(@omitted, &Atom.to_string/1))

    paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.reject(&MapSet.member?(omitted, Path.basename(Path.dirname(&1))))
      |> Enum.map(&String.to_charlist/1)

    eex_ebin = :eex |> :code.lib_dir() |> List.to_string() |> Path.join("ebin")
    :ok = peer_call(control, :code, :add_paths, [[String.to_charlist(eex_ebin) | paths]])
    :ok = ApplicationSpecPeer.put_activation_profile(control, start_profile: :full)

    authority_root = Path.join(base_dir, "authority")
    File.mkdir!(authority_root)
    File.chmod!(authority_root, 0o700)

    for {key, value} <- [
          start_children: true,
          storage_backend: Arbor.Security.Store.JSONFile,
          authority_state_root: authority_root,
          revocation_ledger_path: Path.join(base_dir, "revocations.json"),
          audit_journal_mode: :durable,
          system_authority_mode: :persistent,
          master_key_path: Path.join(authority_root, "master.key"),
          session_token_secret: Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false),
          distributed_signals: false,
          event_log_adapter: nil,
          allow_local_human_identity: true,
          oidc_adapter: nil,
          oidc: []
        ] do
      :ok =
        peer_call(control, Application, :put_env, [
          :arbor_capabilities,
          key,
          value,
          [persistent: true]
        ])
    end
  end

  defp assert_omitted!(control) do
    :ok = ApplicationSpecPeer.assert_omitted_ebins(control, @omitted, Mix.Project.build_path())

    for app <- @omitted do
      assert {:error, :bad_name} = peer_call(control, :code, :lib_dir, [app])
    end
  end

  defp private_authority_fixture! do
    {:ok, canonical_tmp} = SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    base_dir = Path.join(canonical_tmp, "arbor-security-no-oidc-#{token}")
    File.mkdir!(base_dir)
    File.chmod!(base_dir, 0o700)
    base_dir
  end

  defp peer_call(control, module, function, args),
    do: :peer.call(control, module, function, args, @startup_timeout)
end
