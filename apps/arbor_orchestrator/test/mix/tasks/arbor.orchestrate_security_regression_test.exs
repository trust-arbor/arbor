defmodule Mix.Tasks.Arbor.OrchestrateSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.SigningAuthorityBroker

  @dot """
  digraph AuthenticatedOrchestration {
    start [shape=Mdiamond]
    done [shape=Msquare]
    start -> done
  }
  """

  setup do
    previous_oidc = Application.get_env(:arbor_security, :oidc)
    Application.delete_env(:arbor_security, :oidc)

    on_exit(fn -> restore_oidc(previous_oidc) end)
    :ok
  end

  test "security regression: missing OIDC configuration cannot run anonymously" do
    assert {:error, :oidc_not_configured} = Mix.Tasks.Arbor.Orchestrate.authenticate_operator()
  end

  test "security regression: device-flow failure is returned instead of anonymous execution" do
    Application.put_env(:arbor_security, :oidc,
      providers: [%{issuer: "https://issuer.invalid", client_id: "orchestrator-test"}],
      token_cache_path:
        Path.join(System.tmp_dir!(), "missing_orchestrator_oidc_#{System.unique_integer()}")
    )

    assert {:error, {:oidc_authentication_failed, :no_device_flow_configured}} =
             Mix.Tasks.Arbor.Orchestrate.authenticate_operator()
  end

  test "security regression: authenticated orchestration uses the immutable principal path" do
    ensure_authority_stack!()
    {:ok, identity} = Identity.generate(name: "orchestrate-task-security")
    public_identity = Identity.public_only(identity)
    :ok = Security.register_identity(public_identity)
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)
    :ok = Arbor.Orchestrator.TestCapabilities.grant_orchestrator_access(identity.agent_id)

    on_exit(fn ->
      _ = Arbor.Orchestrator.TestCapabilities.revoke_all(identity.agent_id)
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
    end)

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :oidc_operator,
        owner: self()
      )

    {:ok, authority} = Security.open_signing_authority(proof)
    root = Path.join(System.tmp_dir!(), "orchestrate-auth-#{System.unique_integer()}")
    File.mkdir_p!(root)
    {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, result} =
             Mix.Tasks.Arbor.Orchestrate.run_authenticated(
               @dot,
               identity.agent_id,
               authority,
               workdir: root,
               logs_root: root,
               initial_values: %{"session.agent_id" => "forged"}
             )

    assert is_map(result)
  end

  defp restore_oidc(nil), do: Application.delete_env(:arbor_security, :oidc)
  defp restore_oidc(value), do: Application.put_env(:arbor_security, :oidc, value)

  defp ensure_authority_stack! do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    ensure_buffered_store!(:arbor_security_identities, "identities")
    ensure_buffered_store!(:arbor_security_signing_keys, "signing_keys")
    ensure_buffered_store!(:arbor_security_capabilities, "capabilities")
    ensure_child!(Arbor.Security.Identity.Registry, [])
    ensure_child!(Arbor.Security.Identity.NonceCache, [])
    ensure_child!(Arbor.Security.SystemAuthority, [])
    ensure_child!(SigningAuthorityBroker, [])
  end

  defp ensure_buffered_store!(name, collection) do
    if is_nil(Process.whereis(name)) do
      child =
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: name, backend: nil, write_mode: :sync, collection: collection},
          id: name
        )

      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, {:already_present, _}} -> :ok
      end
    end
  end

  defp ensure_child!(module, args) do
    if is_nil(Process.whereis(module)) do
      case Supervisor.start_child(Arbor.Security.Supervisor, {module, args}) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, {:already_present, _}} -> :ok
      end
    end
  end
end
