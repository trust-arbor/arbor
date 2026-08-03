defmodule Arbor.Agent.TaskDispatchFacadeSecurityRegressionTest do
  @moduledoc """
  VP-05C security regression: public Arbor.Agent.dispatch_task/4 credential
  boundary with real Arbor.Security proof + exact dispatch capability.

  Distinctive human proof reaches only Security authorize opts and never
  TaskStore / grants / audit / retained state. Candidate passes; base fails.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Agent.DispatchFacade
  alias Arbor.Agent.Orchestration
  alias Arbor.Security
  alias Arbor.Security.SessionToken

  @distinctive_token "vp05c-dispatch-security-token-9e4b1c7a"

  # ---------------------------------------------------------------------------
  # Capture collaborators (TaskStore / audit) — Security is real
  # ---------------------------------------------------------------------------

  defmodule CaptureTaskStore do
    @moduledoc false
    @table :arbor_agent_dispatch_facade_task_store_capture

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset do
      ensure!()
      :ets.insert(@table, {:dispatches, []})
      :ok
    end

    def dispatches do
      ensure!()

      case :ets.lookup(@table, :dispatches) do
        [{:dispatches, list}] -> list
        _ -> []
      end
    end

    def dispatch(agent_id, task, opts) do
      ensure!()
      entry = %{agent_id: agent_id, task: task, opts: opts}

      case :ets.lookup(@table, :dispatches) do
        [{:dispatches, list}] -> :ets.insert(@table, {:dispatches, list ++ [entry]})
        _ -> :ets.insert(@table, {:dispatches, [entry]})
      end

      task_id =
        case Keyword.get(opts, :task_id) do
          id when is_binary(id) and id != "" -> id
          _ -> "task_dispatch_" <> Integer.to_string(System.unique_integer([:positive]))
        end

      {:ok, task_id}
    end
  end

  defmodule CaptureAudit do
    @moduledoc false
    @table :arbor_agent_dispatch_facade_audit_capture

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset do
      ensure!()
      :ets.insert(@table, {:records, []})
      :ok
    end

    def records do
      ensure!()

      case :ets.lookup(@table, :records) do
        [{:records, list}] -> list
        _ -> []
      end
    end

    def record_orchestration_task_dispatched(caller_id, task_id, agent_id, data) do
      ensure!()
      entry = %{caller_id: caller_id, task_id: task_id, agent_id: agent_id, data: data}

      case :ets.lookup(@table, :records) do
        [{:records, list}] -> :ets.insert(@table, {:records, list ++ [entry]})
        _ -> :ets.insert(@table, {:records, [entry]})
      end

      :ok
    end
  end

  # Probe wraps real Security.authorize/grant/revoke and records calls so we can
  # prove exactly-once authorize and token non-retention on grant paths.
  defmodule RealSecurityProbe do
    @moduledoc false
    @table :arbor_agent_dispatch_facade_real_security_probe

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset do
      ensure!()
      :ets.insert(@table, {:authorize_calls, []})
      :ets.insert(@table, {:grant_calls, []})
      :ok
    end

    def authorize_calls do
      ensure!()

      case :ets.lookup(@table, :authorize_calls) do
        [{:authorize_calls, list}] -> list
        _ -> []
      end
    end

    def grant_calls do
      ensure!()

      case :ets.lookup(@table, :grant_calls) do
        [{:grant_calls, list}] -> list
        _ -> []
      end
    end

    def authorize(actor, resource_uri, action, opts) do
      ensure!()
      entry = %{actor: actor, resource_uri: resource_uri, action: action, opts: opts}

      case :ets.lookup(@table, :authorize_calls) do
        [{:authorize_calls, list}] -> :ets.insert(@table, {:authorize_calls, list ++ [entry]})
        _ -> :ets.insert(@table, {:authorize_calls, [entry]})
      end

      Security.authorize(actor, resource_uri, action, opts)
    end

    def grant(opts) do
      ensure!()

      case :ets.lookup(@table, :grant_calls) do
        [{:grant_calls, list}] -> :ets.insert(@table, {:grant_calls, list ++ [opts]})
        _ -> :ets.insert(@table, {:grant_calls, [opts]})
      end

      Security.grant(opts)
    end

    def revoke(id), do: Security.revoke(id)
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_agent)

    backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    for {name, collection} <- [
          {:arbor_security_capabilities, "capabilities"},
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"}
        ] do
      child =
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: name, backend: backend, write_mode: :sync, collection: collection},
          id: name
        )

      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []}
        ] do
      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    assert Process.whereis(Arbor.Security.CapabilityStore) != nil
    :ok
  end

  setup do
    CaptureTaskStore.ensure!()
    CaptureTaskStore.reset()
    CaptureAudit.ensure!()
    CaptureAudit.reset()
    RealSecurityProbe.ensure!()
    RealSecurityProbe.reset()

    original_identity = Application.get_env(:arbor_security, :identity_verification, true)
    original_reflex = Application.get_env(:arbor_security, :reflex_checking_enabled, true)
    original_strict = Application.get_env(:arbor_security, :strict_identity_mode, false)
    original_signing = Application.get_env(:arbor_security, :capability_signing_required, true)
    prev_secret = Application.get_env(:arbor_security, :session_token_secret)

    Application.put_env(
      :arbor_security,
      :session_token_secret,
      "agent-dispatch-facade-secret-#{System.unique_integer([:positive])}"
    )

    Application.put_env(:arbor_security, :identity_verification, true)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)

    on_exit(fn ->
      case prev_secret do
        nil -> Application.delete_env(:arbor_security, :session_token_secret)
        v -> Application.put_env(:arbor_security, :session_token_secret, v)
      end

      Application.put_env(:arbor_security, :identity_verification, original_identity)
      Application.put_env(:arbor_security, :reflex_checking_enabled, original_reflex)
      Application.put_env(:arbor_security, :strict_identity_mode, original_strict)
      Application.put_env(:arbor_security, :capability_signing_required, original_signing)
    end)

    :ok
  end

  # Bounded benign managed task for the public path: unkinded map so the default
  # executor is used (not coding_change). Public facade requires a non-struct map.
  defp public_task do
    %{"message" => "vp05c public managed dispatch ping"}
  end

  # Kinded map used only by the library-local CaptureTaskStore probe (no real executor).
  defp probe_task do
    %{"kind" => "coding_change", "plan" => %{"version" => 2, "task" => "bounded intent"}}
  end

  # No-op executor so the real TaskStore path stays bounded (no Manager/chat host).
  defmodule BenignTaskExecutor do
    @moduledoc false
    @behaviour Arbor.Contracts.Agent.TaskExecutor

    @impl true
    def run(_agent_id, _task, _context) do
      {:ok, %{result_type: :test, payload: %{"ok" => true}, raw: "benign"}}
    end
  end

  defp with_benign_default_executor(fun) when is_function(fun, 0) do
    prev = Application.get_env(:arbor_agent, :default_task_executor)

    Application.put_env(:arbor_agent, :default_task_executor, BenignTaskExecutor)

    try do
      fun.()
    after
      case prev do
        nil -> Application.delete_env(:arbor_agent, :default_task_executor)
        mod -> Application.put_env(:arbor_agent, :default_task_executor, mod)
      end
    end
  end

  defp track_grant!(principal, resource) do
    assert {:ok, cap} = Security.grant(principal: principal, resource: resource)

    on_exit(fn ->
      _ = Security.revoke(cap.id)
    end)

    cap
  end

  defp bounded_cancel!(task_id, caller) when is_binary(task_id) do
    # Test-only cleanup of the real managed TaskStore entry. authorize?: false is
    # the internal Orchestration seam — not exposed on the public Agent facade.
    _ =
      Orchestration.cancel_task(task_id,
        caller_id: caller,
        authorize?: false
      )

    :ok
  end

  defp ensure_task_store! do
    case Process.whereis(Arbor.Agent.Orchestration.TaskStore) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        {:ok, _pid} = Arbor.Agent.Orchestration.TaskStore.start_link([])
        :ok
    end
  end

  # Humans require OIDC registration (Registry rejects bare human_ register).
  # Mirrors message_facade_security_regression_test.exs.
  defp register_active_human! do
    unique = System.unique_integer([:positive, :monotonic])
    issuer = "https://oidc-test.arbor.local/dispatchfacade/#{unique}"
    subject = "subject-#{unique}"
    client_id = "arbor-test-client"
    kid = "test-key-#{unique}"

    private_jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, private_map} = JOSE.JWK.to_map(private_jwk)
    {_, public_map} = JOSE.JWK.to_public_map(private_jwk)
    public_map = Map.merge(public_map, %{"alg" => "ES256", "kid" => kid})
    signer = Joken.Signer.create("ES256", private_map, %{"kid" => kid})

    claims = %{
      "iss" => issuer,
      "sub" => subject,
      "aud" => client_id,
      "exp" => System.os_time(:second) + 3_600,
      "iat" => System.os_time(:second),
      "email" => "operator-#{unique}@example.test",
      "name" => "DispatchFacade OIDC Human"
    }

    {:ok, id_token} = Joken.Signer.sign(claims, signer)

    table = :arbor_oidc_jwks_cache

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end

    true =
      :ets.insert(
        table,
        {issuer, %{"keys" => [public_map]}, System.monotonic_time(:millisecond) + 60_000}
      )

    {:ok, identity} = Arbor.Contracts.Security.Identity.generate(name: claims["name"])

    human_id =
      "human_" <>
        String.slice(
          Base.encode16(:crypto.hash(:sha256, "#{issuer}:#{subject}"), case: :lower),
          0,
          40
        )

    human_identity = %{
      identity
      | agent_id: human_id,
        metadata: %{
          "identity_type" => "human",
          "oidc_issuer" => issuer,
          "oidc_sub" => subject
        }
    }

    assert :ok =
             Security.register_oidc_identity(human_identity, id_token, %{
               issuer: issuer,
               client_id: client_id
             })

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table, issuer)
      _ = Security.deregister_identity(human_id)
    end)

    human_id
  end

  # Library-local DispatchFacade seam + CaptureTaskStore for exactly-once
  # authorize counting and token non-retention evidence. This is NOT the public
  # Agent path — see the public Arbor.Agent.dispatch_task/4 describe below.
  defp probe_dispatch(caller, target, task, opts) do
    DispatchFacade.dispatch(caller, target, task, opts, fn agent_id, t, orch_opts ->
      Orchestration.dispatch(
        agent_id,
        t,
        Keyword.merge(orch_opts,
          security_module: RealSecurityProbe,
          task_store: CaptureTaskStore,
          audit_module: CaptureAudit
        )
      )
    end)
  end

  # ---------------------------------------------------------------------------
  # Public path: Arbor.Agent.dispatch_task/4 + real Security + real TaskStore
  # This is the required public success/deny evidence (not DispatchFacade).
  # ---------------------------------------------------------------------------

  describe "security regression: public Arbor.Agent.dispatch_task/4" do
    test "security regression: valid human SessionToken + exact scoped grant succeeds via Arbor.Agent.dispatch_task/4" do
      ensure_task_store!()

      caller = register_active_human!()
      target = "agent_dispatch_public_ok_#{System.unique_integer([:positive])}"
      track_grant!(caller, "arbor://agent/dispatch/#{target}")
      assert {:ok, token} = SessionToken.generate(caller)
      assert is_binary(token) and byte_size(token) > 8

      with_benign_default_executor(fn ->
        # Real public facade only — fixed production Orchestration/Security/TaskStore.
        # Do not route this success through DispatchFacade.dispatch/5.
        assert {:ok, task_id} =
                 Arbor.Agent.dispatch_task(caller, target, public_task(), session_token: token)

        assert is_binary(task_id) and byte_size(task_id) > 0
        refute inspect({:ok, task_id}) =~ token

        on_exit(fn -> bounded_cancel!(task_id, caller) end)

        assert {:ok, status} =
                 Orchestration.task_status(task_id, caller_id: caller, authorize?: false)

        assert Map.get(status, :task_id) == task_id or Map.get(status, "task_id") == task_id
        refute inspect(status) =~ token

        assert :ok = bounded_cancel!(task_id, caller)
      end)
    end

    test "security regression: missing capability never dispatches via Arbor.Agent.dispatch_task/4" do
      caller = register_active_human!()
      target = "agent_dispatch_public_nocap_#{System.unique_integer([:positive])}"
      assert {:ok, token} = SessionToken.generate(caller)

      assert {:error, :unauthorized} =
               Arbor.Agent.dispatch_task(caller, target, public_task(), session_token: token)

      refute inspect({:error, :unauthorized}) =~ token
    end

    test "security regression: wrong-scope capability never dispatches via Arbor.Agent.dispatch_task/4" do
      caller = register_active_human!()
      target = "agent_dispatch_public_wrong_#{System.unique_integer([:positive])}"
      other = "agent_dispatch_public_other_#{System.unique_integer([:positive])}"
      track_grant!(caller, "arbor://agent/dispatch/#{other}")
      assert {:ok, token} = SessionToken.generate(caller)

      assert {:error, :unauthorized} =
               Arbor.Agent.dispatch_task(caller, target, public_task(), session_token: token)

      refute inspect({:error, :unauthorized}) =~ token
    end

    test "security regression: malformed proofs never dispatch via Arbor.Agent.dispatch_task/4" do
      caller = register_active_human!()
      target = "agent_dispatch_public_bad_#{System.unique_integer([:positive])}"
      track_grant!(caller, "arbor://agent/dispatch/#{target}")

      for bad <- [nil, "", :atom, String.duplicate("x", 4097)] do
        assert {:error, reason} =
                 Arbor.Agent.dispatch_task(caller, target, public_task(), session_token: bad)

        assert reason in [:invalid_opts, :unauthorized, :dispatch_failed]
      end
    end

    test "security regression: Arbor.Agent.dispatch_task/4 is exported" do
      exports = Arbor.Agent.module_info(:exports)
      assert {:dispatch_task, 4} in exports
      assert {:dispatch_task, 3} in exports
    end
  end

  # ---------------------------------------------------------------------------
  # Probe/seam path: exactly-once authorize + token non-retention evidence
  # ---------------------------------------------------------------------------

  describe "security regression: internal probe for exactly-once authorize + non-retention" do
    test "security regression: internal probe authorizes once; token absent from TaskStore/grants/audit" do
      # Internal evidence only — not a substitute for the public success test above.
      caller = register_active_human!()
      target = "agent_dispatch_probe_#{System.unique_integer([:positive])}"
      track_grant!(caller, "arbor://agent/dispatch/#{target}")
      assert {:ok, token} = SessionToken.generate(caller)

      assert {:ok, task_id} =
               probe_dispatch(caller, target, probe_task(), session_token: token)

      assert is_binary(task_id) and task_id != ""

      auth_calls = RealSecurityProbe.authorize_calls()

      dispatch_auths =
        Enum.filter(auth_calls, fn c ->
          c.action == :execute and
            c.resource_uri in [
              "arbor://agent/dispatch/#{target}",
              "arbor://agent/dispatch"
            ]
        end)

      assert length(dispatch_auths) == 1
      [auth] = dispatch_auths
      assert auth.actor == caller
      assert Keyword.get(auth.opts, :verify_identity) == false
      assert Keyword.get(auth.opts, :session_token) == token

      assert [dispatch] = CaptureTaskStore.dispatches()
      refute Keyword.has_key?(dispatch.opts, :session_token)
      refute Keyword.has_key?(dispatch.opts, "session_token")
      refute inspect(dispatch) =~ token
      assert dispatch.task == probe_task()
      assert dispatch.agent_id == target

      for grant <- RealSecurityProbe.grant_calls() do
        refute inspect(grant) =~ token
      end

      for record <- CaptureAudit.records() do
        refute inspect(record) =~ token
      end

      refute inspect({:ok, task_id}) =~ token
    end

    test "security regression: single string-key session_token does not crash and is stripped" do
      caller = register_active_human!()
      target = "agent_dispatch_strkey_#{System.unique_integer([:positive])}"
      track_grant!(caller, "arbor://agent/dispatch/#{target}")
      assert {:ok, token} = SessionToken.generate(caller)

      # Mixed list: atom collaborator keys + string session_token. Must not
      # raise via Keyword.get/3 before token parsing (owner correction).
      opts = [
        {:caller_id, caller},
        {"session_token", token},
        {:security_module, RealSecurityProbe},
        {:task_store, CaptureTaskStore},
        {:audit_module, CaptureAudit}
      ]

      assert {:ok, task_id} = Orchestration.dispatch(target, probe_task(), opts)
      assert is_binary(task_id)

      assert [auth | _] = RealSecurityProbe.authorize_calls()
      assert Keyword.get(auth.opts, :session_token) == token

      assert [dispatch] = CaptureTaskStore.dispatches()
      refute Keyword.has_key?(dispatch.opts, :session_token)
      refute Keyword.has_key?(dispatch.opts, "session_token")
      refute inspect(dispatch) =~ token
    end

    test "security regression: atom+string session_token alias duplicate denies without crash" do
      caller = register_active_human!()
      target = "agent_dispatch_alias_#{System.unique_integer([:positive])}"
      track_grant!(caller, "arbor://agent/dispatch/#{target}")
      assert {:ok, token} = SessionToken.generate(caller)

      opts = [
        {:caller_id, caller},
        {:session_token, token},
        {"session_token", token},
        {:security_module, RealSecurityProbe},
        {:task_store, CaptureTaskStore},
        {:audit_module, CaptureAudit}
      ]

      # Must return a closed unauthorized error, not raise ArgumentError.
      assert {:error, {:unauthorized, :invalid_session_token}} =
               Orchestration.dispatch(target, probe_task(), opts)

      assert CaptureTaskStore.dispatches() == []
      assert RealSecurityProbe.grant_calls() == []
    end
  end

  describe "security regression: public facade option/id validation" do
    test "security regression: invalid opts/ids/task never dispatch via public API" do
      caller = "human_dispatch_val_1"
      target = "agent_dispatch_val_1"

      assert {:error, :invalid_opts} =
               Arbor.Agent.dispatch_task(caller, target, public_task(), session_token: nil)

      assert {:error, :invalid_caller_id} =
               Arbor.Agent.dispatch_task("not_a_principal", target, public_task())

      assert {:error, :invalid_task} =
               Arbor.Agent.dispatch_task(caller, target, "string-task")
    end
  end
end
