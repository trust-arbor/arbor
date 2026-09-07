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

  # `ensure_oidc_config/0` falls back to OIDC_ISSUER / OIDC_CLIENT_ID from the
  # SYSTEM env when the application env is empty (arbor.orchestrate.ex:521).
  # Clearing only the application env left this suite's "no OIDC configured"
  # premise false on any machine that exports those — a developer with them in
  # .env got {:oidc_authentication_failed, {:invalid_issuer, :scheme_not_allowed}}
  # instead of :oidc_not_configured, and the security regression looked broken
  # when the code was behaving correctly. The assertions are unchanged; only the
  # precondition is now actually established.
  @oidc_env_vars ~w(OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_SCOPES OIDC_ALLOW_HTTP)

  setup do
    previous_oidc = Application.get_env(:arbor_security, :oidc)
    Application.delete_env(:arbor_security, :oidc)

    previous_env = Map.new(@oidc_env_vars, &{&1, System.get_env(&1)})
    Enum.each(@oidc_env_vars, &System.delete_env/1)

    on_exit(fn ->
      restore_oidc(previous_oidc)

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

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

    assert result.context["session.agent_id"] == identity.agent_id
  end

  defp restore_oidc(nil), do: Application.delete_env(:arbor_security, :oidc)
  defp restore_oidc(value), do: Application.put_env(:arbor_security, :oidc, value)

  # Canonical bootstrap: it freezes the authority root and starts the whole
  # topology in the required order, instead of a hand-copied subset that can
  # drift from it. Idempotent, so it also restores children a test stopped.
  defp ensure_authority_stack! do
    :ok = Arbor.Security.TestBootstrap.start!()
  end
end
