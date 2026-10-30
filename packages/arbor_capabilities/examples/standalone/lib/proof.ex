defmodule CapabilitiesStandaloneConsumer.Proof do
  @moduledoc "Real public authority operations in an explicit isolated first-install host."
  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Security
  alias Arbor.Security.AuthDecision
  alias Arbor.Security.Config
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.IssuerRegistry
  alias Arbor.Security.OIDC.IdentityStore
  alias Arbor.Security.SystemAuthority
  alias CapabilitiesStandaloneConsumer.Provisioner

  @scope "arbor://standalone/read/documents/**"
  @resource "arbor://standalone/read/documents/one"
  @first_party ~w(arbor_capabilities arbor_custody arbor_kernel arbor_oauth arbor_support)
  @modules [
    Security,
    Config,
    Arbor.Security.CapabilityStore,
    Arbor.Security.Identity.Registry,
    Arbor.Security.Identity.ReplayPeers,
    SystemAuthority,
    Arbor.Security.SigningAuthorityBroker
  ]

  def run!(phase, opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:capabilities_standalone_consumer)

    if Keyword.get(opts, :require_no_mix, false) do
      ensure(not Code.ensure_loaded?(Mix), "Mix code was present")
      ensure(:code.lib_dir(:mix) == {:error, :bad_name}, "Mix metadata was present")
    end

    GenServer.call(Provisioner, {:phase, phase}, 120_000)
  end

  def run_owned!(phase) do
    strict_configuration!()

    result =
      case phase do
        :write ->
          write!()

        :recover ->
          recover!()

        :refused ->
          refused!()

        :peers ->
          state = state!()

          CapabilitiesStandaloneConsumer.PeerProof.run_owned!(fn ->
            Security.sign_with_authority(
              authority!(state["child"]),
              "arbor://standalone/read/peer-proof"
            )
          end)
      end

    assert_closure!()

    Map.merge(result, %{
      "phase" => Atom.to_string(phase),
      "first_party" => @first_party,
      "code_paths" =>
        Map.new(@modules, fn module ->
          ensure(
            :application.get_application(module) == {:ok, :arbor_capabilities},
            "wrong authority module owner"
          )

          {Atom.to_string(module), List.to_string(:code.which(module))}
        end),
      "mix_available" => Code.ensure_loaded?(Mix)
    })
  end

  defp write! do
    ensure(not File.exists?(state_file()), "write phase reused prior public state")

    ensure(
      match?({:error, _}, Security.complete_local_genesis(:unproved)),
      "unproved genesis admitted"
    )

    {:ok, operator, proof} = prepare_operator_genesis!()
    {:ok, root_capability} = Security.complete_local_genesis(proof)
    operator_authority = authority!(operator.agent_id)

    ensure(
      match?({:error, _}, Security.complete_local_genesis(proof)),
      "genesis proof replay admitted"
    )

    {:ok, parent} = enroll!("portable-parent", operator_authority)
    {:ok, child} = enroll!("portable-child", operator_authority)
    parent_authority = authority!(parent.agent_id)
    child_authority = authority!(child.agent_id)

    {:ok, capability} =
      Security.grant(
        principal: parent.agent_id,
        resource: @scope,
        delegation_depth: 2,
        actor_authority: operator_authority
      )

    ensure(is_binary(capability.issuer_signature), "public grant was unsigned")

    ensure(
      SystemAuthority.verify_capability_signature(capability) == :ok,
      "real capability signature failed"
    )

    forged = %{capability | metadata: Map.put(capability.metadata, "untrusted-forgery", true)}

    ensure(
      match?({:error, _}, SystemAuthority.verify_capability_signature(forged)),
      "forged signed fields verified"
    )

    ensure(
      audited_authorize(parent.agent_id, @resource, :read) == {:error, :missing_signed_request},
      "unsigned request admitted"
    )

    {:ok, request} = Security.sign_with_authority(parent_authority, @resource)

    ensure(
      audited_authorize(parent.agent_id, @resource, :read,
        signed_request: request,
        expected_resource: @resource
      ) == {:ok, :authorized},
      "real signed authorization failed"
    )

    ensure(
      audited_authorize(parent.agent_id, @resource, :read,
        signed_request: request,
        expected_resource: @resource
      ) == {:error, :replayed_nonce},
      "signed nonce replay admitted"
    )

    {:ok, fresh_request} = Security.sign_with_authority(parent_authority, @resource)

    forged_request = %{
      fresh_request
      | signature: :binary.copy(<<0>>, byte_size(fresh_request.signature))
    }

    ensure(
      Security.verify_signed_request_authenticity(forged_request) == {:error, :invalid_signature},
      "forged request signature was not specifically denied"
    )

    ensure(
      Security.verify_signed_request_authenticity(fresh_request) == {:ok, parent.agent_id},
      "forgery refusal consumed the genuine proof or hid an unavailable verifier"
    )

    {:ok, delegated} =
      Security.delegate(capability.id, child.agent_id, actor_authority: parent_authority)

    ensure(
      delegated.parent_capability_id == capability.id and delegated.delegation_depth == 1,
      "delegation attenuation changed"
    )

    authorize!(child.agent_id, child_authority, @resource)
    required_provider_denial!(child.agent_id, child_authority)
    decision_and_nonce!(parent.agent_id, parent_authority, operator_authority)
    {:ok, envelope} = Capability.new(principal_id: parent.agent_id, resource_uri: @scope)

    :ok =
      Security.register_issuer(parent.agent_id, [envelope], actor_authority: operator_authority)

    {:ok, candidate} = Capability.new(principal_id: child.agent_id, resource_uri: @resource)
    :ok = IssuerRegistry.verify_envelope(parent.agent_id, candidate)

    state = %{
      "operator" => operator.agent_id,
      "parent" => parent.agent_id,
      "child" => child.agent_id,
      "root_capability" => root_capability,
      "parent_capability" => capability.id,
      "delegated_capability" => delegated.id,
      "system_authority" => Security.stats().system_authority_id
    }

    File.write!(state_file(), Jason.encode!(state), [:exclusive])
    File.chmod!(state_file(), 0o600)

    %{
      "checks" => [
        "explicit local genesis and actor-authorized enrollment",
        "real signed grant/delegation and tampering refusal",
        "signed request and genesis replay refusal",
        "required verifier outage denied",
        "decision max-use/rate nonconsumption with nonce consumption"
      ]
    }
  end

  defp recover! do
    state = state!()
    {:ok, operator, :existing} = operator()
    ensure(operator.agent_id == state["operator"], "cold operator identity changed")
    operator_authority = authority!(operator.agent_id)

    ensure(
      Security.stats().system_authority_id == state["system_authority"],
      "persistent system authority changed"
    )

    for principal <- [state["parent"], state["child"]] do
      ensure(
        Security.identity_status(principal) == {:ok, :active},
        "cold identity was not recovered"
      )

      ensure(
        Security.signing_key_status(principal) == {:ok, :available},
        "encrypted signing key was not recovered"
      )
    end

    child_authority = authority!(state["child"])
    authorize!(state["child"], child_authority, @resource)

    {:ok, original_envelope} =
      Capability.new(principal_id: state["child"], resource_uri: @resource)

    :ok = IssuerRegistry.verify_envelope(state["parent"], original_envelope)

    {:ok, narrowed} =
      Capability.new(
        principal_id: state["parent"],
        resource_uri: "arbor://standalone/read/documents/restricted/**"
      )

    :ok =
      Security.update_issuer_envelopes(state["parent"], [narrowed],
        actor_authority: operator_authority
      )

    ensure(
      IssuerRegistry.verify_envelope(state["parent"], original_envelope) ==
        {:error, :exceeds_envelope},
      "issuer narrowing did not remove original scope"
    )

    :ok = Security.revoke(state["delegated_capability"], actor_authority: operator_authority)

    :ok =
      Security.revoke_issuer(state["parent"], "cold qualification",
        actor_authority: operator_authority
      )

    deny_authorize!(state["child"], child_authority, @resource)

    %{
      "checks" => [
        "fresh VM recovered system identity, enrolled keys and delegated authority",
        "actor-authorized issuer narrowing and durable revocation"
      ]
    }
  end

  defp refused! do
    state = state!()
    {:ok, operator, :existing} = operator()
    ensure(operator.agent_id == state["operator"], "recovered operator changed")

    ensure(
      Security.stats().system_authority_id == state["system_authority"],
      "recovered system authority changed"
    )

    operator_authority = authority!(operator.agent_id)
    authorize!(operator.agent_id, operator_authority, "arbor://standalone/read/operator-proof")

    ensure(
      Security.identity_status(state["child"]) == {:ok, :active},
      "refusal was caused by missing identity"
    )

    ensure(
      Security.signing_key_status(state["child"]) == {:ok, :available},
      "refusal was caused by missing key"
    )

    deny_authorize!(state["child"], authority!(state["child"]), @resource)

    ensure(
      Security.lookup_issuer(state["parent"]) == {:error, :revoked},
      "issuer revocation was not recovered"
    )

    ensure(
      match?({:error, _}, Security.load_signing_key(state["parent"])),
      "raw signing-key API disclosed material"
    )

    %{
      "checks" => [
        "fresh VM recovered usable root authority",
        "persisted capability and issuer revocations refuse with live identity/key",
        "public raw-key read remains denied"
      ]
    }
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

  defp operator,
    do:
      Security.create_local_human_identity(
        user: "qualification-operator",
        host: "isolated-qualification",
        name: "Standalone qualification operator"
      )

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
        Provisioner
      )

    {:ok, authority} = Security.open_signing_authority(proof)
    authority
  end

  defp authorize!(principal, authority, resource) do
    {:ok, signed} = Security.sign_with_authority(authority, resource)

    ensure(
      audited_authorize(principal, resource, :read,
        signed_request: signed,
        expected_resource: resource
      ) ==
        {:ok, :authorized},
      "public effect admission denied a valid signed capability"
    )
  end

  defp audited_authorize(principal, resource, action, opts \\ []) do
    path = Path.join(System.fetch_env!("CAPABILITIES_COLD_STATE_ROOT"), "invocations.jsonl")
    previous_size = if File.exists?(path), do: File.stat!(path).size, else: 0

    result =
      Security.with_invocation_audit(
        %{principal_id: principal, surface: :action, tool: "standalone-qualification"},
        fn -> Security.authorize(principal, resource, action, opts) end
      )

    bytes = File.read!(path)

    rows =
      bytes
      |> binary_part(previous_size, byte_size(bytes) - previous_size)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    ensure(
      Enum.map(rows, & &1["stage"]) == ["attempt", "authorization", "outcome"],
      "required durable invocation audit did not record the real authorization"
    )

    result
  end

  defp deny_authorize!(principal, authority, resource) do
    {:ok, signed} = Security.sign_with_authority(authority, resource)

    ensure(
      match?(
        {:error, _},
        audited_authorize(principal, resource, :read,
          signed_request: signed,
          expected_resource: resource
        )
      ),
      "revoked capability authorized"
    )
  end

  defp required_provider_denial!(principal, authority) do
    prior = Application.fetch_env(:arbor_capabilities, :delegation_signer_module)

    try do
      Application.put_env(
        :arbor_capabilities,
        :delegation_signer_module,
        __MODULE__.UnavailableVerifier
      )

      {:ok, proof} = Security.sign_with_authority(authority, @resource)

      ensure(
        audited_authorize(principal, @resource, :read,
          signed_request: proof,
          expected_resource: @resource
        ) ==
          {:error, {:delegation_chain_invalid, :verification_unavailable}},
        "missing required delegation verifier did not fail closed"
      )
    after
      case prior do
        {:ok, value} -> Application.put_env(:arbor_capabilities, :delegation_signer_module, value)
        :error -> Application.delete_env(:arbor_capabilities, :delegation_signer_module)
      end
    end

    authorize!(principal, authority, @resource)
  end

  defp decision_and_nonce!(principal, authority, actor) do
    resource = "arbor://standalone/read/single-use"

    {:ok, capability} =
      Security.grant(
        principal: principal,
        resource: resource,
        max_uses: 1,
        actor_authority: actor
      )

    for _ <- 1..3 do
      {:ok, proof} = Security.sign_with_authority(authority, resource)
      opts = [signed_request: proof, expected_resource: resource]

      ensure(
        AuthDecision.check(principal, resource, :read, opts) == :authorized,
        "non-consuming decision failed"
      )

      ensure(
        AuthDecision.check(principal, resource, :read, opts) == {:error, :replayed_nonce},
        "decision reused a signed nonce"
      )
    end

    {:ok, capabilities} = Security.list_capabilities(principal)

    ensure(
      Enum.any?(capabilities, &(&1.id == capability.id)),
      "decision consumed the one-use capability"
    )

    authorize!(principal, authority, resource)
    deny_authorize!(principal, authority, resource)
    rate_resource = "arbor://standalone/read/rate-limited"

    {:ok, _} =
      Security.grant(
        principal: principal,
        resource: rate_resource,
        constraints: %{rate_limit: 1},
        actor_authority: actor
      )

    for _ <- 1..3 do
      {:ok, proof} = Security.sign_with_authority(authority, rate_resource)

      ensure(
        AuthDecision.check(principal, rate_resource, :read,
          signed_request: proof,
          expected_resource: rate_resource
        ) == :authorized,
        "decision consumed rate allowance"
      )
    end

    authorize!(principal, authority, rate_resource)
    {:ok, rate_proof} = Security.sign_with_authority(authority, rate_resource)

    ensure(
      match?(
        {:error, {:constraint_violated, :rate_limit, _}},
        audited_authorize(principal, rate_resource, :read,
          signed_request: rate_proof,
          expected_resource: rate_resource
        )
      ),
      "effect admission did not consume rate allowance"
    )
  end

  defp strict_configuration! do
    ensure(self() == Process.whereis(Provisioner), "operations escaped the admitted provisioner")
    ensure(Config.identity_verification_enabled?(), "identity verification disabled")
    ensure(Config.capability_signing_required?(), "capability signatures disabled")
    ensure(Config.delegation_chain_verification_enabled?(), "delegation verification disabled")
    ensure(Config.constraint_enforcement_enabled?(), "constraint enforcement disabled")
    ensure(Config.invocation_audit_mode() == :required, "invocation audit disabled")
    root = System.fetch_env!("CAPABILITIES_COLD_STATE_ROOT")

    ensure(
      Config.authority_root() == {:ok, Path.join(root, "authority")},
      "authority root fell back or changed"
    )

    ensure(
      Config.revocation_ledger_path() ==
        {:ok, Path.join(root, "independent-revocations/capability_revocations.v1.json")},
      "independent revocation ledger changed"
    )

    ensure(not Security.oidc_enabled?(), "first-install mode unexpectedly configured OIDC")

    ensure(
      not function_exported?(Security, :register_identity_fixture, 1),
      "test identity helper leaked into artifact"
    )

    ensure(not Code.ensure_loaded?(Arbor.KernelRuntime), "Kernel Runtime code was present")
    ensure(not Code.ensure_loaded?(Arbor.Common), "product Common facade was present")
    ensure(not Code.ensure_loaded?(Arbor.Signals), "Signals code was present")
    ensure(not Code.ensure_loaded?(Arbor.Capabilities.OIDC), "optional OIDC code was present")
  end

  defp assert_closure! do
    for applications <- [Application.loaded_applications(), Application.started_applications()] do
      first_party =
        applications
        |> Enum.map(fn {app, _, _} -> Atom.to_string(app) end)
        |> Enum.filter(&String.starts_with?(&1, "arbor_"))
        |> Enum.sort()

      ensure(first_party == @first_party, "unexpected first-party runtime closure")
    end

    compiled =
      :code.get_path()
      |> Enum.map(&Path.basename(Path.dirname(List.to_string(&1))))
      |> Enum.filter(&String.starts_with?(&1, "arbor_"))
      |> Enum.map(&String.replace(&1, ~r/-\d.*$/, ""))
      |> Enum.uniq()
      |> Enum.sort()

    ensure(compiled == @first_party, "unexpected first-party compiled closure")

    ensure(
      Enum.all?([:req, :finch, :mint, :joken, :jose], fn app ->
        not List.keymember?(Application.started_applications(), app, 0)
      end),
      "Core-only proof started optional providers"
    )
  end

  defp state!, do: state_file() |> File.read!() |> Jason.decode!()

  defp state_file,
    do: Path.join(System.fetch_env!("CAPABILITIES_COLD_STATE_ROOT"), "public-state.json")

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("Capabilities qualification failed: " <> label)
end
