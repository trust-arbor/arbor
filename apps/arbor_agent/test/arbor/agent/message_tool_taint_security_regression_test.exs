defmodule Arbor.Agent.MessageToolTaintSecurityRegressionTest do
  @moduledoc """
  Public VP-05D2B B0/B1 candidate/base security selector.

  The selector enters through `Arbor.Agent.send_message/4`, exchanges and
  consumes a real human-session delivery receipt, executes a real Session DOT
  compute node, and reaches the normal ToolLoop/ActionsExecutor/Arbor.Actions
  path. On the candidate, model output derived from authenticated human input
  remains untrusted and cannot control the test action. On the base revision,
  the same action executes and emits the assertion-breaking marker.
  """

  use ExUnit.Case, async: false

  alias Arbor.Agent.{Registry, SessionManager}
  alias Arbor.Common.ActionRegistry
  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.LLM.{Client, ContentPart, Request, Response}
  alias Arbor.Security
  alias Arbor.Security.SessionToken

  @moduletag :security_regression
  @moduletag :fast

  @action Arbor.Actions.SecurityRegression.MessageToolTaint
  @first_prompt "voice-alpha requests the bounded control probe"
  @second_prompt "voice-beta checks engagement isolation"
  @resume_prompt "voice-alpha resumes the canonical engagement"

  defmodule ScriptedAdapter do
    @moduledoc false
    @behaviour Arbor.LLM.ProviderAdapter

    @parent_key {__MODULE__, :test_parent}
    @first_prompt "voice-alpha requests the bounded control probe"
    @second_prompt "voice-beta checks engagement isolation"
    @resume_prompt "voice-alpha resumes the canonical engagement"

    def set_test_parent(pid) when is_pid(pid), do: :persistent_term.put(@parent_key, pid)
    def clear_test_parent, do: :persistent_term.erase(@parent_key)

    @impl true
    def provider, do: "lm_studio"

    @impl true
    def complete(%Request{} = request, _opts) do
      transcript = transcript_text(request.messages)

      cond do
        String.contains?(transcript, @second_prompt) ->
          notify({:message_tool_taint_second_request, transcript})
          text_response("engagement-isolated")

        String.contains?(transcript, @resume_prompt) ->
          notify({:message_tool_taint_resume_request, transcript})
          text_response("engagement-resumed")

        tool_message = Enum.find(Enum.reverse(request.messages), &(&1.role == :tool)) ->
          notify({:message_tool_taint_tool_result, tool_message.content})
          text_response("tainted-control-refused")

        String.contains?(transcript, @first_prompt) ->
          notify({:message_tool_taint_first_request, transcript})

          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             content_parts: [
               ContentPart.tool_call(
                 "message_tool_taint_call",
                 "security_regression_message_tool_taint",
                 %{"command" => "bounded-model-command"}
               )
             ],
             usage: %{input_tokens: 1, output_tokens: 1},
             raw: %{}
           }}

        true ->
          {:error, :unexpected_scripted_request}
      end
    end

    @impl true
    def complete_single_attempt(request, opts), do: complete(request, opts)

    defp text_response(text) do
      {:ok,
       %Response{
         text: text,
         finish_reason: :stop,
         content_parts: [ContentPart.text(text)],
         usage: %{input_tokens: 1, output_tokens: 1},
         raw: %{}
       }}
    end

    defp transcript_text(messages) do
      messages
      |> Enum.map(fn message -> if is_binary(message.content), do: message.content, else: "" end)
      |> Enum.join("\n")
    end

    defp notify(message) do
      case :persistent_term.get(@parent_key, nil) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  setup_all do
    for app <- [:arbor_security, :arbor_trust, :arbor_comms, :arbor_orchestrator, :arbor_agent] do
      assert {:ok, _started} = Application.ensure_all_started(app)
    end

    :ok
  end

  setup do
    ensure_security_children!()
    registry_started_here? = ensure_action_registry!()

    previous_env = snapshot_env()
    configure_security!()

    registry_snapshot = ActionRegistry.snapshot()
    assert :ok = ActionRegistry.register_action(@action)

    ScriptedAdapter.set_test_parent(self())
    @action.set_test_parent(self())

    client =
      Client.new(default_provider: ScriptedAdapter.provider(), model_catalog: %{})
      |> Client.register_adapter(ScriptedAdapter)

    :ok = Client.set_default_client(client)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor_message_tool_taint_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    turn_path = Path.join(tmp_dir, "turn.dot")
    File.write!(turn_path, turn_dot())
    Application.put_env(:arbor_ai, :session_turn_dot, turn_path)

    on_exit(fn ->
      ScriptedAdapter.clear_test_parent()
      @action.clear_test_parent()
      Client.clear_default_client()
      :ok = ActionRegistry.restore(registry_snapshot)

      if registry_started_here? do
        :ok = Supervisor.terminate_child(Arbor.Common.Supervisor, ActionRegistry)
        :ok = Supervisor.delete_child(Arbor.Common.Supervisor, ActionRegistry)
      end

      restore_env(previous_env)
      File.rm_rf(tmp_dir)
    end)

    :ok
  end

  test "security regression: authenticated public voice text cannot drive a control action" do
    %{agent_id: agent_id, signer: signer} = register_agent_identity!()
    action_resource = Arbor.Actions.canonical_uri_for(@action, %{})

    grants =
      for resource <- [
            "arbor://orchestrator/execute",
            "arbor://orchestrator/execute/compute",
            "arbor://orchestrator/execute/llm_query",
            "arbor://orchestrator/execute/transform",
            action_resource
          ] do
        grant!(agent_id, resource)
      end

    human_a = register_human_identity!("alpha")
    human_b = register_human_identity!("beta")

    grants = [
      grant!(human_a, chat_resource(agent_id)),
      grant!(human_b, chat_resource(agent_id)) | grants
    ]

    on_exit(fn -> Enum.each(grants, &Security.revoke(&1.id)) end)

    assert {:ok, session_pid} =
             SessionManager.ensure_session(agent_id,
               provider: :lm_studio,
               model: "selector-local-model",
               tools: [@action],
               signer: signer,
               stream: false,
               start_heartbeat: false
             )

    assert :ok =
             Registry.register(agent_id, session_pid, %{
               runtime: :arbor,
               model_config: %{runtime: :arbor},
               host_pid: session_pid,
               module: Arbor.Orchestrator.Session,
               agent_id: agent_id
             })

    on_exit(fn ->
      _ = Registry.unregister(agent_id)
      _ = SessionManager.stop_session(agent_id)
    end)

    assert {:ok, token_a} = SessionToken.generate(human_a)

    first =
      UserMessage.from_voice(@first_prompt,
        sender_id: human_a,
        transport_metadata: %{backend: "selector", input: :speech}
      )

    assert {:ok, "tainted-control-refused"} =
             Arbor.Agent.send_message(human_a, agent_id, first,
               session_token: token_a,
               timeout: 10_000
             )

    assert_receive {:message_tool_taint_tool_result, tool_result}, 2_000

    refute_received {:message_tool_taint_action_executed, "bounded-model-command"}

    assert inspect(tool_result) =~ "taint_blocked"

    {:ok, alpha_engagement} = Arbor.Comms.resolve_user_engagement(agent_id, human_a)
    {:ok, beta_engagement} = Arbor.Comms.resolve_user_engagement(agent_id, human_b)
    refute alpha_engagement.id == beta_engagement.id

    # B0 public evidence: a different authenticated human gets a fresh private
    # transcript, while the first human later resumes the same canonical one.
    assert {:ok, token_b} = SessionToken.generate(human_b)
    second = UserMessage.from_voice(@second_prompt, sender_id: human_b)

    assert {:ok, "engagement-isolated"} =
             Arbor.Agent.send_message(human_b, agent_id, second,
               session_token: token_b,
               timeout: 10_000
             )

    assert_receive {:message_tool_taint_second_request, beta_transcript}, 2_000
    assert beta_transcript =~ @second_prompt
    refute beta_transcript =~ @first_prompt

    assert {:ok, resumed_token_a} = SessionToken.generate(human_a)
    resumed = UserMessage.from_voice(@resume_prompt, sender_id: human_a)

    assert {:ok, "engagement-resumed"} =
             Arbor.Agent.send_message(human_a, agent_id, resumed,
               session_token: resumed_token_a,
               timeout: 10_000
             )

    assert_receive {:message_tool_taint_resume_request, alpha_transcript}, 2_000
    assert alpha_transcript =~ @first_prompt
    assert alpha_transcript =~ @resume_prompt
    refute alpha_transcript =~ @second_prompt
  end

  defp turn_dot do
    """
    digraph MessageToolTaintSecurityRegression {
      graph [goal="Public authenticated tool-taint selector"]
      start [shape=Mdiamond]
      call_llm [
        type="compute",
        simulate="false",
        prompt_context_key="session.input",
        messages_context_key="session.messages",
        use_tools="true"
      ]
      format [
        type="transform",
        transform="identity",
        source_key="last_response",
        output_key="session.response"
      ]
      done [shape=Msquare]
      start -> call_llm -> format -> done
    }
    """
  end

  defp register_agent_identity! do
    assert {:ok, identity} = Identity.generate(name: "Message tool taint agent")
    assert :ok = Security.register_identity(Identity.public_only(identity))

    on_exit(fn -> _ = Security.deregister_identity(identity.agent_id) end)

    %{
      agent_id: identity.agent_id,
      signer: fn resource ->
        SignedRequest.sign(resource, identity.agent_id, identity.private_key)
      end
    }
  end

  defp register_human_identity!(label) do
    unique = System.unique_integer([:positive, :monotonic])
    issuer = "https://oidc-test.arbor.local/message-tool-taint/#{label}/#{unique}"
    subject = "subject-#{label}-#{unique}"
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
      "email" => "#{label}-#{unique}@example.test",
      "name" => "Message Tool Taint #{label} Human"
    }

    assert {:ok, id_token} = Joken.Signer.sign(claims, signer)
    jwks_table = :arbor_oidc_jwks_cache

    if :ets.whereis(jwks_table) == :undefined do
      :ets.new(jwks_table, [:named_table, :public, :set, read_concurrency: true])
    end

    true =
      :ets.insert(
        jwks_table,
        {issuer, %{"keys" => [public_map]}, System.monotonic_time(:millisecond) + 60_000}
      )

    assert {:ok, identity} = Identity.generate(name: claims["name"])

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
      if :ets.whereis(jwks_table) != :undefined, do: :ets.delete(jwks_table, issuer)
      _ = Security.deregister_identity(human_id)
    end)

    human_id
  end

  defp grant!(principal, resource) do
    assert {:ok, capability} =
             Security.grant(principal: principal, resource: resource, constraints: %{})

    capability
  end

  defp chat_resource(agent_id), do: "arbor://chat/agent/#{agent_id}"

  defp ensure_action_registry! do
    if Process.whereis(ActionRegistry) do
      false
    else
      case Supervisor.start_child(Arbor.Common.Supervisor, ActionRegistry) do
        {:ok, _pid} -> true
        {:error, {:already_started, _pid}} -> false
        other -> flunk("failed to start action registry: #{inspect(other)}")
      end
    end
  end

  defp ensure_security_children! do
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

      ensure_security_child!(child)
    end

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []},
          {Arbor.Security.DeliveryReceiptBroker, []}
        ] do
      ensure_security_child!(child)
    end

    :ok
  end

  defp ensure_security_child!(child) do
    case Supervisor.start_child(Arbor.Security.Supervisor, child) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> :ok
      other -> flunk("failed to start security child: #{inspect(other)}")
    end
  end

  defp configure_security! do
    Application.put_env(:arbor_security, :identity_verification, true)
    Application.put_env(:arbor_security, :strict_identity_mode, true)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :policy_enforcer_enabled, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_security, :egress_gate_enforcing, true)

    Application.put_env(
      :arbor_security,
      :session_token_secret,
      "message-tool-taint-selector-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp snapshot_env do
    for {app, key} <- [
          {:arbor_security, :identity_verification},
          {:arbor_security, :strict_identity_mode},
          {:arbor_security, :capability_signing_required},
          {:arbor_security, :reflex_checking_enabled},
          {:arbor_security, :uri_registry_enforcement},
          {:arbor_security, :policy_enforcer_enabled},
          {:arbor_security, :approval_guard_enabled},
          {:arbor_security, :egress_gate_enforcing},
          {:arbor_security, :session_token_secret},
          {:arbor_ai, :session_turn_dot}
        ],
        into: %{} do
      {{app, key}, Application.fetch_env(app, key)}
    end
  end

  defp restore_env(snapshot) do
    Enum.each(snapshot, fn
      {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
      {{app, key}, :error} -> Application.delete_env(app, key)
    end)
  end
end
