defmodule TrustStandaloneConsumer.CoreContext do
  @moduledoc "Actual production Core example's first-install genesis, actor enrollment and stored authority acquisition. Actor tokens never leave the admitted provisioner PID."
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.OIDC.IdentityStore

  def context! do
    ensure(
      self() == Process.whereis(TrustStandaloneConsumer.Provisioner),
      "actor context escaped admitted provisioner"
    )

    state = if File.exists?(state_file()), do: recover!(), else: first_install!()

    %{
      operator_id: state["operator"],
      operator_authority: authority!(state["operator"]),
      agent_id: state["agent"],
      agent_authority: authority!(state["agent"]),
      pubsub: TrustStandaloneConsumer.PubSub,
      phase: :write
    }
  end

  defp first_install! do
    ensure(
      Security.complete_local_genesis(:unproved) == {:error, :genesis_unauthorized},
      "unproved genesis admitted"
    )

    {:ok, operator, proof} = prepare_operator_genesis!()
    {:ok, _root_capability} = Security.complete_local_genesis(proof)
    ensure(match?({:error, _}, Security.complete_local_genesis(proof)), "genesis replay admitted")
    actor = authority!(operator.agent_id)
    {:ok, agent} = enroll!("trust-portable-agent", actor)
    :ok = Security.close_signing_authority(actor)

    state = %{
      "operator" => operator.agent_id,
      "agent" => agent.agent_id,
      "system_authority" => Security.stats().system_authority_id
    }

    {:ok, file} =
      :file.open(String.to_charlist(state_file()), [:write, :exclusive, :raw, :binary])

    try do
      :ok = :file.write(file, Jason.encode!(state))
      :ok = :file.sync(file)
    after
      :file.close(file)
    end

    File.chmod!(state_file(), 0o600)
    state
  end

  defp recover! do
    state = state_file() |> File.read!() |> Jason.decode!()
    {:ok, operator, :existing} = operator()
    ensure(operator.agent_id == state["operator"], "persistent local operator changed")

    ensure(
      Security.stats().system_authority_id == state["system_authority"],
      "persistent system authority changed"
    )

    for id <- [state["operator"], state["agent"]] do
      ensure(Security.identity_status(id) == {:ok, :active}, "persistent identity missing")

      ensure(
        Security.signing_key_status(id) == {:ok, :available},
        "persistent encrypted key missing"
      )
    end

    state
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
        TrustStandaloneConsumer.Provisioner
      )

    {:ok, authority} = Security.open_signing_authority(proof)
    authority
  end

  defp state_file,
    do: Path.join(System.fetch_env!("PAIRED_STATE_ROOT"), "trust-core-public-context.json")

  defp ensure(true, _), do: :ok
  defp ensure(false, label), do: raise("Trust Core context failed: " <> label)
end
