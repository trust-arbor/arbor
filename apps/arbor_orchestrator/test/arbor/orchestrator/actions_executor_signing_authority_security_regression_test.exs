defmodule Arbor.Orchestrator.ActionsExecutorSigningAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Orchestrator.ActionsExecutor
  alias Arbor.Security
  alias Arbor.Security.SigningAuthorityBroker

  setup do
    ensure_authority_stack!()
    {:ok, _} = Application.ensure_all_started(:arbor_trust)
    {:ok, _} = Application.ensure_all_started(:arbor_shell)

    unless Process.whereis(Arbor.Trust.Store) do
      start_supervised!({Arbor.Trust.Store, []})
    end

    previous = %{
      identity_verification: Application.get_env(:arbor_security, :identity_verification),
      capability_signing: Application.get_env(:arbor_security, :capability_signing_required),
      strict_identity: Application.get_env(:arbor_security, :strict_identity_mode),
      uri_registry: Application.get_env(:arbor_security, :uri_registry_enforcement),
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      escalation: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      approval_guard: Application.get_env(:arbor_trust, :approval_guard_enabled),
      policy_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    }

    Application.put_env(:arbor_security, :identity_verification, true)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
    Application.put_env(:arbor_trust, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)

    {:ok, identity} = Identity.generate(name: "actions-executor-authority")
    public_identity = Identity.public_only(identity)
    :ok = Security.register_identity(public_identity)
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    :ok =
      Arbor.Orchestrator.TestCapabilities.grant_capability(
        identity.agent_id,
        "arbor://shell/exec/**"
      )

    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(identity.agent_id)

    :ok =
      Arbor.Trust.Store.store_profile(%{
        profile
        | rules: Map.put(profile.rules, "arbor://shell/exec/**", :auto)
      })

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :actions_executor_test,
        owner: self()
      )

    {:ok, authority} = Security.open_signing_authority(proof)
    root = Path.join(System.tmp_dir!(), "actions-authority-#{System.unique_integer()}")
    File.mkdir_p!(root)

    on_exit(fn ->
      _ = Security.close_signing_authority(authority)
      _ = Arbor.Orchestrator.TestCapabilities.revoke_all(identity.agent_id)

      if Process.whereis(Arbor.Trust.Store) do
        _ = Arbor.Trust.Store.delete_profile(identity.agent_id)
      end

      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
      File.rm_rf(root)
      restore_env(:arbor_security, :identity_verification, previous.identity_verification)
      restore_env(:arbor_security, :capability_signing_required, previous.capability_signing)
      restore_env(:arbor_security, :strict_identity_mode, previous.strict_identity)
      restore_env(:arbor_security, :uri_registry_enforcement, previous.uri_registry)
      restore_env(:arbor_security, :reflex_checking_enabled, previous.reflex)
      restore_env(:arbor_security, :consensus_escalation_enabled, previous.escalation)
      restore_env(:arbor_trust, :approval_guard_enabled, previous.approval_guard)
      restore_env(:arbor_trust, :policy_enforcer_enabled, previous.policy_enforcer)
    end)

    %{
      agent_id: identity.agent_id,
      private_key: identity.private_key,
      authority: authority,
      root: root
    }
  end

  test "security regression: authority signs the canonical shell resource", ctx do
    assert {:ok, output} =
             ActionsExecutor.execute(
               "shell.execute",
               %{"command" => "echo authority-signed"},
               ctx.root,
               agent_id: ctx.agent_id,
               signing_authority: ctx.authority
             )

    assert output =~ "authority-signed"
  end

  test "security regression: authority plus signer key is rejected by presence", ctx do
    legacy_signer = fn resource ->
      send(self(), :legacy_signer_called)
      Security.make_signer(ctx.agent_id, ctx.private_key).(resource)
    end

    assert {:error, message} =
             ActionsExecutor.execute(
               "shell.execute",
               %{"command" => "echo must-not-run"},
               ctx.root,
               agent_id: ctx.agent_id,
               signer: legacy_signer,
               signing_authority: nil
             )

    assert message =~ "mixed_signing_credentials"
    refute_received :legacy_signer_called
  end

  test "security regression: authority rejects nil legacy credential keys", ctx do
    for legacy <- [[signer: nil], [signed_request: nil]] do
      assert {:error, message} =
               ActionsExecutor.execute(
                 "shell.execute",
                 %{"command" => "echo must-not-run"},
                 ctx.root,
                 [agent_id: ctx.agent_id, signing_authority: ctx.authority] ++ legacy
               )

      assert message =~ "mixed_signing_credentials"
    end
  end

  test "security regression: authority rejects recursively hidden caller credentials", ctx do
    marker = Path.join(ctx.root, "must-not-run")

    hidden_credentials = [
      %{"review_context" => %{"signed_request" => %{token: "caller"}}},
      %{metadata: [auth_context: %{signer: fn _ -> {:error, :caller} end}]},
      %{"payload" => %{"identityPrivateKey" => "caller-key"}},
      %{nested: [[authorizer: fn _, _ -> :ok end]]},
      %{"request" => %{"bearer-token" => "caller-token"}}
    ]

    for hidden <- hidden_credentials do
      assert {:error, message} =
               ActionsExecutor.execute(
                 "shell.execute",
                 %{"command" => "touch #{marker}", "input" => hidden},
                 ctx.root,
                 agent_id: ctx.agent_id,
                 signing_authority: ctx.authority
               )

      assert message =~ "caller_supplied_signing_credentials"
      refute File.exists?(marker)
    end

    assert {:error, message} =
             ActionsExecutor.execute(
               "shell.execute",
               %{"command" => "touch #{marker}"},
               ctx.root,
               agent_id: ctx.agent_id,
               signing_authority: ctx.authority,
               metadata: %{request: [signing_authority: :caller_controlled]}
             )

    assert message =~ "caller_supplied_signing_credentials"
    refute File.exists?(marker)
  end

  test "security regression: authority is absent from action context", ctx do
    :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, true, [])

    tracer = self()

    assert {:ok, _output} =
             Task.async(fn ->
               :erlang.trace(self(), true, [:call, {:tracer, tracer}])

               ActionsExecutor.execute(
                 "shell.execute",
                 %{"command" => "echo context-check"},
                 ctx.root,
                 agent_id: ctx.agent_id,
                 signing_authority: ctx.authority
               )
             end)
             |> Task.await()

    assert_receive {:trace, _pid, :call,
                    {Arbor.Actions, :authorize_and_execute,
                     [_agent_id, Arbor.Actions.Shell.Execute, _params, context]}}

    refute Map.has_key?(context, :signing_authority)

    case Map.get(context, :nested_engine_opts) do
      nil -> :ok
      nested -> refute Keyword.has_key?(nested, :signing_authority)
    end

    :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, false, [])
  end

  test "security regression: trusted nested action gets a boundary without the bearer", ctx do
    :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, true, [])

    on_exit(fn ->
      :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, false, [])
    end)

    tracer = self()

    task =
      Task.async(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, tracer}])

        ActionsExecutor.execute(
          "council_review_change",
          %{"diff" => "", "branch" => "review-boundary"},
          ctx.root,
          agent_id: ctx.agent_id,
          signing_authority: ctx.authority,
          max_depth: 3
        )
      end)

    assert_receive {:trace, _pid, :call,
                    {Arbor.Actions, :authorize_and_execute,
                     [_agent_id, Arbor.Actions.Council.ReviewChange, _params, context]}}

    nested = context.nested_engine_opts
    refute Keyword.has_key?(nested, :signing_authority)
    signer = Keyword.fetch!(nested, :signer)
    assert is_function(signer, 1)
    assert is_function(Keyword.fetch!(nested, :authorizer), 2)

    _result = Task.await(task)

    assert {:error, :signing_boundary_unavailable} = signer.("arbor://shell/exec/retained")
  end

  test "security regression: generic actions never receive authority-derived closures", ctx do
    :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, true, [])

    on_exit(fn ->
      :erlang.trace_pattern({Arbor.Actions, :authorize_and_execute, 4}, false, [])
    end)

    tracer = self()

    assert {:ok, _output} =
             Task.async(fn ->
               :erlang.trace(self(), true, [:call, {:tracer, tracer}])

               ActionsExecutor.execute(
                 "shell.execute",
                 %{"command" => "echo generic-boundary-check"},
                 ctx.root,
                 agent_id: ctx.agent_id,
                 signing_authority: ctx.authority,
                 max_depth: 3
               )
             end)
             |> Task.await()

    assert_receive {:trace, _pid, :call,
                    {Arbor.Actions, :authorize_and_execute,
                     [_agent_id, Arbor.Actions.Shell.Execute, _params, context]}}

    nested = context.nested_engine_opts
    refute Keyword.has_key?(nested, :signer)
    refute Keyword.has_key?(nested, :authorizer)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp ensure_authority_stack! do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    ensure_buffered_store!(:arbor_security_identities, "identities")
    ensure_buffered_store!(:arbor_security_signing_keys, "signing_keys")
    ensure_buffered_store!(:arbor_security_capabilities, "capabilities")
    ensure_child!(Arbor.Security.Identity.Registry, [])
    ensure_child!(Arbor.Security.Identity.NonceCache, [])
    ensure_child!(Arbor.Security.SystemAuthority, [])
    ensure_authority_pair!()
  end

  defp ensure_authority_pair! do
    case {Process.whereis(Arbor.Security.SigningAuthorityStateOwner),
          Process.whereis(SigningAuthorityBroker)} do
      {nil, nil} ->
        token = make_ref()
        ensure_child!(Arbor.Security.SigningAuthorityStateOwner, broker_token: token)
        ensure_child!(SigningAuthorityBroker, state_owner_token: token)

      {owner, nil} when is_pid(owner) ->
        case Supervisor.restart_child(Arbor.Security.Supervisor, SigningAuthorityBroker) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          other -> flunk("failed to restart SigningAuthorityBroker: #{inspect(other)}")
        end

      {owner, broker} when is_pid(owner) and is_pid(broker) ->
        :ok

      partial ->
        flunk("partial signing authority stack: #{inspect(partial)}")
    end
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
