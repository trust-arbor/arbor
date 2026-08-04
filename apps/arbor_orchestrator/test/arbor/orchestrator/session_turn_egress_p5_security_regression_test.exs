defmodule Arbor.Orchestrator.SessionTurnEgressP5SecurityRegressionTest do
  @moduledoc """
  VP-05D2A1P5 security regressions: Session disclosure activation + egress fencing.

  Security prerequisite for VOICE-17 (planned) — does not un-plan the normative
  VOICE-17 statement.

  Candidate/base: the Session nil-authority external blob compiles on base and
  fails behaviorally there (RecordingAdapter is reached). On candidate it makes
  zero external calls. Failure must not be missing-module/compilation.
  """

  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag voice_id: "VOICE-17"
  @moduletag spec: "VOICE-17"

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Session.TurnAuthority
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Identifiers
  alias Arbor.LLM.Client
  alias Arbor.LLM.Request
  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.Handlers.LlmHandler
  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Session.TurnEgress
  alias Arbor.Security

  @external_tier :external_provider
  @local_tier :on_host

  defmodule RecordingAdapter do
    @moduledoc false
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "anthropic"

    def complete(_request, _opts) do
      note_external_call()

      {:ok,
       %Arbor.LLM.Response{
         text: "p5-external-ok",
         finish_reason: :stop,
         content_parts: [Arbor.LLM.ContentPart.text("p5-external-ok")],
         usage: %{input_tokens: 1, output_tokens: 1},
         raw: %{}
       }}
    end

    def complete_single_attempt(request, opts), do: complete(request, opts)

    defp note_external_call do
      parent = Application.get_env(:arbor_orchestrator, :_p5_test_pid)
      if is_pid(parent), do: send(parent, {:external_complete, self()})

      case Application.get_env(:arbor_orchestrator, :_p5_call_counter) do
        ref when not is_nil(ref) -> :atomics.add(ref, 1, 1)
        _ -> :ok
      end
    end
  end

  defmodule CountingToolAdapter do
    @moduledoc false
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "anthropic"

    def complete(request, _opts) do
      parent = Application.get_env(:arbor_orchestrator, :_p5_test_pid)
      n_ref = Application.get_env(:arbor_orchestrator, :_p5_wave_counter)
      n = if n_ref, do: :atomics.add_get(n_ref, 1, 1), else: 1
      if is_pid(parent), do: send(parent, {:wave, n, request.provider, request.model})

      if n == 1 do
        {:ok,
         %Arbor.LLM.Response{
           text: "",
           finish_reason: :tool_calls,
           content_parts: [
             Arbor.LLM.ContentPart.tool_call("call_1", "echo_tool", %{"x" => 1})
           ],
           usage: %{input_tokens: 1, output_tokens: 1},
           raw: %{}
         }}
      else
        {:ok,
         %Arbor.LLM.Response{
           text: "done-after-tools",
           finish_reason: :stop,
           content_parts: [Arbor.LLM.ContentPart.text("done-after-tools")],
           usage: %{input_tokens: 1, output_tokens: 1},
           raw: %{}
         }}
      end
    end

    def complete_single_attempt(request, opts), do: complete(request, opts)
  end

  defmodule EchoTools do
    @moduledoc false
    def execute(_name, args, _workdir, _opts), do: {:ok, %{"echo" => args}}
  end

  defmodule RecordingDispatcher do
    @moduledoc false
    @behaviour Arbor.LLM.Dispatcher

    def dispatch(request, opts) do
      parent = Application.get_env(:arbor_orchestrator, :_p5_test_pid)
      if is_pid(parent), do: send(parent, {:dispatch_call, request, opts})

      case Application.get_env(:arbor_orchestrator, :_p5_call_counter) do
        ref when not is_nil(ref) -> :atomics.add(ref, 1, 1)
        _ -> :ok
      end

      # Invoke route_authorizer when present (P1 single-attempt semantics).
      case Keyword.get(opts, :route_authorizer) do
        fun when is_function(fun, 1) ->
          route = Application.get_env(:arbor_orchestrator, :_p5_dispatch_route, default_route())

          case fun.(route) do
            :allow ->
              {:ok,
               %Arbor.LLM.Response{
                 text: "dispatched",
                 finish_reason: :stop,
                 usage: %{input_tokens: 1, output_tokens: 1}
               }}

            other ->
              {:error, {:route_authorization_denied, other}}
          end

        _ ->
          {:ok,
           %Arbor.LLM.Response{
             text: "dispatched-open",
             finish_reason: :stop,
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
      end
    end

    defp default_route do
      %{
        destination: "anthropic",
        provider: "anthropic",
        runtime: "arbor",
        model: "claude-test-p5"
      }
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    ensure_security_children!()
    :ok
  end

  setup do
    prev = %{
      identity_verification: Application.get_env(:arbor_security, :identity_verification),
      strict: Application.get_env(:arbor_security, :strict_identity_mode),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement),
      secret: Application.get_env(:arbor_security, :session_token_secret),
      egress: Application.get_env(:arbor_security, :egress_gate_enforcing),
      dispatcher: Application.get_env(:arbor_orchestrator, :llm_dispatcher)
    }

    Application.put_env(:arbor_security, :identity_verification, true)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :egress_gate_enforcing, false)

    Application.put_env(
      :arbor_security,
      :session_token_secret,
      "vp05d2a1p5-test-secret-#{System.unique_integer([:positive])}"
    )

    Application.put_env(:arbor_orchestrator, :_p5_test_pid, self())
    counter = :atomics.new(1, [])
    Application.put_env(:arbor_orchestrator, :_p5_call_counter, counter)

    on_exit(fn ->
      restore_sec(:identity_verification, prev.identity_verification)
      restore_sec(:strict_identity_mode, prev.strict)
      restore_sec(:capability_signing_required, prev.signing)
      restore_sec(:reflex_checking_enabled, prev.reflex)
      restore_sec(:uri_registry_enforcement, prev.uri)
      restore_sec(:session_token_secret, prev.secret)
      restore_sec(:egress_gate_enforcing, prev.egress)

      case prev.dispatcher do
        nil -> Application.delete_env(:arbor_orchestrator, :llm_dispatcher)
        v -> Application.put_env(:arbor_orchestrator, :llm_dispatcher, v)
      end

      Application.delete_env(:arbor_orchestrator, :_p5_test_pid)
      Application.delete_env(:arbor_orchestrator, :_p5_call_counter)
      Application.delete_env(:arbor_orchestrator, :_p5_wave_counter)
      Application.delete_env(:arbor_orchestrator, :_p5_dispatch_route)
      Application.delete_env(:arbor_orchestrator, :_session_lifecycle_probe)
    end)

    agent = register_active_agent!()
    human_id = register_active_human!()
    resource = "arbor://chat/agent/#{agent.agent_id}"
    grant!(human_id, resource)
    put_orchestrator_cap!(agent.agent_id)

    %{
      agent_id: agent.agent_id,
      agent_signer: agent.signer,
      human_id: human_id,
      resource: resource,
      call_counter: counter
    }
  end

  defp restore_sec(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_sec(key, value), do: Application.put_env(:arbor_security, key, value)

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

      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, :already_present} -> :ok
      end
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
      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, :already_present} -> :ok
      end
    end
  end

  defp register_active_agent! do
    assert {:ok, identity} = Identity.generate(name: "VP05D2A1P5 agent")
    assert :ok = Security.register_identity(Identity.public_only(identity))

    on_exit(fn ->
      _ = Security.deregister_identity(identity.agent_id)
    end)

    %{
      agent_id: identity.agent_id,
      signer: fn resource ->
        SignedRequest.sign(resource, identity.agent_id, identity.private_key)
      end
    }
  end

  defp register_active_human! do
    unique = System.unique_integer([:positive, :monotonic])
    issuer = "https://oidc-test.arbor.local/vp05d2a1p5/#{unique}"
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
      "name" => "VP05D2A1P5 OIDC Human"
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

    {:ok, identity} = Identity.generate(name: claims["name"])

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

  defp grant!(principal, resource) do
    assert {:ok, cap} = Security.grant(principal: principal, resource: resource)

    on_exit(fn ->
      _ = Security.revoke(cap.id)
    end)

    cap
  end

  defp put_orchestrator_cap!(agent_id) do
    assert {:ok, cap} =
             Arbor.Contracts.Security.Capability.new(
               resource_uri: "arbor://orchestrator/execute/**",
               principal_id: agent_id,
               delegation_depth: 0,
               constraints: %{},
               metadata: %{test: true}
             )

    Arbor.Security.CapabilityStore.put(cap)

    on_exit(fn ->
      _ = Arbor.Security.CapabilityStore.revoke(cap.id)
    end)

    cap
  end

  defp tool_loop_graph! do
    dot = """
    digraph P5ToolLoop {
      graph [goal="p5 tool loop"]
      start [shape=Mdiamond]
      call_llm [
        type="compute",
        simulate="false",
        prompt="hello",
        use_tools="true"
      ]
      done [shape=Msquare]
      start -> call_llm -> done
    }
    """

    assert {:ok, graph} = Orchestrator.compile(dot)
    graph
  end

  defp hermetic_success_graph! do
    dot = """
    digraph P5Hermetic {
      graph [goal="hermetic"]
      start [shape=Mdiamond]
      echo [type="transform", transform="identity", source_key="session.input", output_key="session.response"]
      done [shape=Msquare]
      start -> echo -> done
    }
    """

    assert {:ok, graph} = Orchestrator.compile(dot)
    graph
  end

  defp recording_client do
    Arbor.LLM.Client.new(default_provider: "anthropic")
    |> Arbor.LLM.Client.register_adapter(RecordingAdapter)
  end

  defp session_state(agent_id, overrides) do
    session_id =
      "session_p5_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    # Base-compatible literal: do NOT set candidate-only fields such as
    # turn_token (absent on base Session struct). Overrides may Map.put them
    # on candidate when a test needs an explicit token.
    base = %Session{
      session_id: session_id,
      agent_id: agent_id,
      phase: :idle,
      turn_count: 0,
      messages: [],
      turn_in_flight: false,
      turn_from: nil,
      turn_caller_ref: nil,
      turn_task_ref: nil,
      turn_task_pid: nil,
      turn_user_message: nil,
      turn_authority: nil,
      turn_egress_fence: nil,
      streaming_buffer: nil,
      turn_queue: [],
      cancelled_task_ids: %{},
      cancelled_task_id_order: [],
      config: %{
        "llm_provider" => "anthropic",
        "llm_model" => "claude-test-p5",
        "stream" => false
      },
      session_state: nil,
      behavior: nil,
      steer_froms: [],
      execution_mode: :session,
      pid: self(),
      adapters: %{}
    }

    Enum.reduce(overrides, base, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  defp authority!(human_id) do
    assert {:ok, auth} =
             TurnAuthority.new(
               turn_id: Identifiers.generate_id("turn_"),
               authenticated_principal_id: human_id,
               disclosure_capability_id: nil
             )

    auth
  end

  defp external_route do
    %{
      destination: "anthropic",
      provider: "anthropic",
      runtime: "arbor",
      model: "claude-test-p5"
    }
  end

  defp await_turn_result(timeout \\ 8_000) do
    receive do
      # Candidate 4-tuple with process-local turn token.
      {:turn_result, token, _msg, _result} = full when is_reference(token) ->
        full

      # Base 3-tuple — accepted so the overlaid suite can drive Session.handle_info
      # on both base and candidate without compile/shape failures.
      {:turn_result, _msg, _result} = full ->
        full
    after
      timeout -> flunk("expected turn_result")
    end
  end

  defp issue_disclosure!(state, auth, route, tier \\ @external_tier) do
    # Base has arity-3 issue helper; candidate has arity-4 with frozen tier.
    assert Code.ensure_loaded?(TurnEgress)

    result =
      if function_exported?(TurnEgress, :issue_disclosure_if_needed, 4) do
        apply(TurnEgress, :issue_disclosure_if_needed, [state, auth, route, tier])
      else
        apply(TurnEgress, :issue_disclosure_if_needed, [state, auth, route])
      end

    assert {:ok, bound, cap_id} = result
    {bound, cap_id}
  end

  defp build_authz!(opts) do
    bindings =
      %{
        frozen_tier: Keyword.get(opts, :frozen_tier, @external_tier)
      }
      |> Map.merge(Map.new(Keyword.delete(opts, :frozen_tier)))

    TurnEgress.build_authorizer(bindings)
  end

  defp with_recording_default_client(fun) do
    prev = Client.default_client()
    Client.set_default_client(recording_client())

    try do
      fun.()
    after
      Client.set_default_client(prev)
    end
  end

  # ── Candidate/base behavioral security regressions ───────────────────

  test "VOICE-17 security regression: nil-authority external Session zero external calls",
       %{agent_id: agent_id, agent_signer: signer, call_counter: counter} do
    # Behavioral candidate/base: install recording client via the pre-existing
    # Client.set_default_client/1 seam (not candidate-only Session adapter
    # forwarding). On base without turn authorizer RecordingAdapter is reached
    # and this assertion fails behaviorally (counter nonzero). On candidate:
    # zero calls. Do not read candidate-only fields (turn_token).
    with_recording_default_client(fn ->
      state =
        session_state(agent_id,
          turn_graph: tool_loop_graph!(),
          signer: signer
        )

      from = {self(), make_ref()}

      assert {:noreply, started} =
               Session.handle_call({:send_message, "untrusted external hello"}, from, state)

      assert started.turn_in_flight
      assert started.turn_authority == nil

      msg = await_turn_result()
      _ = Session.handle_info(msg, started)

      assert :atomics.get(counter, 1) == 0
      refute_received {:external_complete, _}
    end)
  end

  test "VOICE-17 security regression: LlmHandler without seam reaches external (base path)",
       %{agent_id: agent_id, call_counter: counter} do
    # Proves the fake boundary is live: without Session seam, dark gate admits.
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, RecordingDispatcher)
    Application.put_env(:arbor_security, :egress_gate_enforcing, false)

    context =
      Arbor.Orchestrator.Engine.Context.new(%{
        "session.agent_id" => agent_id,
        "session.llm_provider" => "anthropic",
        "session.llm_model" => "claude-test-p5",
        "session.llm_runtime" => :arbor
      })

    node = %{id: "n", attrs: %{"simulate" => "false", "prompt" => "hi"}}
    graph = %{attrs: %{"goal" => "g"}}

    outcome = LlmHandler.execute(node, context, graph, [])
    assert outcome.status == :success
    assert :atomics.get(counter, 1) >= 1
    assert_received {:dispatch_call, _, _}
  end

  test "VOICE-17 security regression: LlmHandler Session seam blocks before provider I/O",
       %{agent_id: agent_id, call_counter: counter} do
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, RecordingDispatcher)
    :atomics.put(counter, 1, 0)

    # Plain arity-1 deny — does not depend on TurnEgress for the assertion path.
    # Candidate installs this shape from Session; base ignores the keys and would
    # reach the dispatcher (see previous test).
    route = external_route()
    fence = TurnEgress.new_fence()

    authorizer =
      build_authz!(
        fence: fence,
        frozen_route: route,
        agent_id: agent_id,
        session_id: "session_p5_llm",
        turn_id: nil,
        human_id: nil,
        disclosure_capability_id: nil
      )

    client = recording_client()

    context =
      Arbor.Orchestrator.Engine.Context.new(%{
        "session.agent_id" => agent_id,
        "session.llm_provider" => "anthropic",
        "session.llm_model" => "claude-test-p5",
        "session.llm_runtime" => :arbor
      })

    node = %{
      id: "call_llm",
      attrs: %{"simulate" => "false", "prompt" => "hi", "use_tools" => "true"}
    }

    graph = %{attrs: %{"goal" => "g"}}

    outcome =
      LlmHandler.execute(node, context, graph,
        llm_client: client,
        frozen_egress_route: route,
        turn_egress_authorizer: authorizer,
        tool_executor: EchoTools,
        authorization: false
      )

    assert outcome.context_updates["egress_blocked"] == true
    assert :atomics.get(counter, 1) == 0
    refute_received {:external_complete, _}
    refute_received {:dispatch_call, _, _}
  end

  # ── Authorizer / disclosure unit evidence ────────────────────────────

  test "VOICE-17 security regression: authorizer denies external without disclosure",
       %{agent_id: agent_id} do
    fence = TurnEgress.new_fence()
    route = external_route()

    authorizer =
      build_authz!(
        fence: fence,
        frozen_route: route,
        agent_id: agent_id,
        session_id: "session_p5_authz",
        turn_id: nil,
        human_id: nil,
        disclosure_capability_id: nil
      )

    assert {:error, {:egress_blocked, :external_provider, :disclosure_required}} =
             authorizer.(route)

    assert {:error, {:egress_blocked, :external_provider, :route_mismatch}} =
             authorizer.(%{route | model: "other-model"})
  end

  test "VOICE-17 security regression: callback fault classes fail closed",
       %{agent_id: agent_id} do
    route = external_route()

    for {label, fun} <- [
          {"raise", fn _ -> raise "boom" end},
          {"throw", fn _ -> throw(:boom) end},
          {"exit", fn _ -> exit(:boom) end},
          {"pending", fn _ -> {:requires_approval, :egress} end},
          {"deny", fn _ -> :deny end},
          {"unknown", fn _ -> :wat end},
          {"malformed", fn _ -> "not-a-result" end}
        ] do
      # Wrap via LlmHandler projection path: authorizer that faults after match.
      # Direct TurnEgress authorizer already catch-safes Trust; exercise wrap
      # by substituting a faulting authorizer at the LlmHandler seam.
      faulting = fn r ->
        assert r == route
        fun.(r)
      end

      client = recording_client()

      context =
        Arbor.Orchestrator.Engine.Context.new(%{
          "session.agent_id" => agent_id,
          "session.llm_provider" => "anthropic",
          "session.llm_model" => "claude-test-p5"
        })

      node = %{id: "n", attrs: %{"simulate" => "false", "prompt" => "hi", "use_tools" => "true"}}

      outcome =
        LlmHandler.execute(node, context, %{attrs: %{}},
          llm_client: client,
          frozen_egress_route: route,
          turn_egress_authorizer: faulting,
          tool_executor: EchoTools,
          authorization: false
        )

      assert outcome.context_updates["egress_blocked"] == true,
             "expected #{label} to fail closed before provider I/O"

      refute_received {:external_complete, _}
    end
  end

  test "VOICE-17 security regression: authenticated external issues disclosure and admits exact route",
       %{agent_id: agent_id, human_id: human_id} do
    fence = TurnEgress.new_fence()
    route = external_route()
    auth = authority!(human_id)
    state = %{agent_id: agent_id, session_id: "session_p5_issue"}

    {bound, cap_id} = issue_disclosure!(state, auth, route)
    assert is_binary(cap_id)
    assert bound.disclosure_capability_id == cap_id

    authorizer =
      build_authz!(
        fence: fence,
        frozen_route: route,
        agent_id: agent_id,
        session_id: "session_p5_issue",
        turn_id: bound.turn_id,
        human_id: human_id,
        disclosure_capability_id: cap_id
      )

    assert :allow = authorizer.(route)
    assert :allow = authorizer.(route)
    assert {:error, _} = authorizer.(%{route | provider: "openai", destination: "openai"})

    TurnEgress.deactivate_fence(fence)
    assert {:error, _} = authorizer.(route)

    TurnEgress.safe_revoke_disclosure(cap_id)
    Application.put_env(:arbor_security, :egress_gate_enforcing, true)

    authorizer2 =
      build_authz!(
        fence: TurnEgress.new_fence(),
        frozen_route: route,
        agent_id: agent_id,
        session_id: "session_p5_issue",
        turn_id: bound.turn_id,
        human_id: human_id,
        disclosure_capability_id: cap_id
      )

    assert {:error, _} = authorizer2.(route)
    Application.put_env(:arbor_security, :egress_gate_enforcing, false)
  end

  test "VOICE-17 security regression: ToolLoop multi-wave exact route with disclosure",
       %{agent_id: agent_id, human_id: human_id} do
    fence = TurnEgress.new_fence()
    route = external_route()
    auth = authority!(human_id)
    state = %{agent_id: agent_id, session_id: "session_p5_waves"}
    {bound, cap_id} = issue_disclosure!(state, auth, route)

    authorizer =
      build_authz!(
        fence: fence,
        frozen_route: route,
        agent_id: agent_id,
        session_id: "session_p5_waves",
        turn_id: bound.turn_id,
        human_id: human_id,
        disclosure_capability_id: cap_id
      )

    wave = :atomics.new(1, [])
    Application.put_env(:arbor_orchestrator, :_p5_wave_counter, wave)

    client =
      Arbor.LLM.Client.new(default_provider: "anthropic")
      |> Arbor.LLM.Client.register_adapter(CountingToolAdapter)

    tool_defs = [
      %{
        "type" => "function",
        "function" => %{
          "name" => "echo_tool",
          "description" => "echo",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      }
    ]

    context =
      Arbor.Orchestrator.Engine.Context.new(%{
        "session.agent_id" => agent_id,
        "session.llm_provider" => "anthropic",
        "session.llm_model" => "claude-test-p5",
        "session.llm_runtime" => :arbor,
        "session.tools" => tool_defs
      })

    node = %{
      id: "call_llm",
      attrs: %{"simulate" => "false", "prompt" => "hi", "use_tools" => "true"}
    }

    outcome =
      LlmHandler.execute(node, context, %{attrs: %{"goal" => "g"}},
        llm_client: client,
        frozen_egress_route: route,
        turn_egress_authorizer: authorizer,
        tool_executor: EchoTools,
        authorization: false
      )

    assert outcome.status in [:success, :partial_success]
    assert :atomics.get(wave, 1) >= 2
    assert_received {:wave, 1, "anthropic", "claude-test-p5"}
    assert_received {:wave, 2, "anthropic", "claude-test-p5"}
    assert {:error, _} = authorizer.(%{route | model: "mutated"})
    TurnEgress.safe_revoke_disclosure(cap_id)
  end

  test "VOICE-17 security regression: ProviderRouter primary admits fallback denied",
       %{agent_id: agent_id, human_id: human_id} do
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, RecordingDispatcher)
    route = external_route()
    fallback = %{route | provider: "openai", destination: "openai", model: "gpt-fallback"}

    auth = authority!(human_id)
    state = %{agent_id: agent_id, session_id: "session_p5_pr"}
    {bound, cap_id} = issue_disclosure!(state, auth, route)
    fence = TurnEgress.new_fence()

    authorizer =
      build_authz!(
        fence: fence,
        frozen_route: route,
        agent_id: agent_id,
        session_id: "session_p5_pr",
        turn_id: bound.turn_id,
        human_id: human_id,
        disclosure_capability_id: cap_id
      )

    Application.put_env(:arbor_orchestrator, :_p5_dispatch_route, route)

    context =
      Arbor.Orchestrator.Engine.Context.new(%{
        "session.agent_id" => agent_id,
        "session.llm_provider" => "anthropic",
        "session.llm_model" => "claude-test-p5"
      })

    node = %{id: "n", attrs: %{"simulate" => "false", "prompt" => "hi"}}

    outcome =
      LlmHandler.execute(node, context, %{attrs: %{}},
        provider_route_input: %{frozen: true, primary: route},
        frozen_egress_route: route,
        turn_egress_authorizer: authorizer
      )

    assert outcome.status in [:success, :partial_success, :fail]
    assert :allow = authorizer.(route)
    assert {:error, _} = authorizer.(fallback)
    TurnEgress.safe_revoke_disclosure(cap_id)
  end

  test "VOICE-17 security regression: initial taint labels final user keys untrusted" do
    pre = %{
      "session.agent_id" => "agent_x",
      "session.tools" => ["a"],
      "session.config" => %{"user_media" => [%{"type" => "image"}]}
    }

    final = %{
      "session.agent_id" => "agent_x",
      "session.input" => "hi",
      "session.query" => "hi",
      "session.messages" => [%{"role" => "user", "content" => "hi"}],
      "session.user_media" => [%{"type" => "image"}],
      "session.task_id" => "task_abc",
      "session.tools" => [],
      "session.config" => %{"user_media" => [%{"type" => "image"}]},
      "session.preprocessor.tier" => "direct"
    }

    taint = TurnEgress.derive_initial_taint(pre, final)

    for key <- [
          "session.input",
          "session.query",
          "session.messages",
          "session.user_media",
          "session.task_id",
          "session.tools",
          "session.config",
          "session.preprocessor.tier"
        ] do
      assert taint[key] == :untrusted
    end

    refute Map.has_key?(taint, "session.agent_id")
  end

  test "VOICE-17 security regression: real Engine taint is result.taint, no authority" do
    final = %{
      "session.input" => "user text",
      "session.query" => "user text",
      "session.messages" => [%{"role" => "user", "content" => "user text"}]
    }

    taint = TurnEgress.derive_initial_taint(%{}, final)
    graph = hermetic_success_graph!()

    assert {:ok, result} =
             Arbor.Orchestrator.Engine.run(graph,
               initial_values: final,
               initial_taint: taint,
               authorization: false
             )

    for key <- ["session.input", "session.query", "session.messages"] do
      assert result.taint[key].level == :untrusted
    end

    inspected = inspect(result, limit: :infinity)
    refute inspected =~ ~r/disclosure_capability/
    refute is_struct(result.context, TurnAuthority)
  end

  test "VOICE-17 security regression: project_request and project_dispatch deny malformed" do
    assert {:error, _} = TurnEgress.project_request_route(%{provider: nil, model: "m"})
    assert {:error, _} = TurnEgress.project_dispatch_route(%{provider: :x})
    assert {:error, _} = TurnEgress.canonicalize_route(%{destination: "a", provider: "a"})

    assert {:ok, _} =
             TurnEgress.project_request_route(%Request{
               provider: "anthropic",
               model: "m",
               runtime: :arbor
             })
  end

  test "VOICE-17 security regression: Router-disabled uncatalogued :legacy projects destination as provider" do
    # Dispatch legacy routes bind destination to the actual outbound provider
    # string while catalog id is the synthetic :legacy entry. Projection must
    # not emit provider=\"legacy\" or exact-match against configured freeze fails.
    rich = %{
      destination: "anthropic",
      model: "uncatalogued-custom-model",
      runtime: :arbor,
      provider: %{id: :legacy, ref: "uncatalogued-custom-model"}
    }

    assert {:ok, scalar} = TurnEgress.project_dispatch_route(rich)

    assert scalar == %{
             destination: "anthropic",
             provider: "anthropic",
             runtime: "arbor",
             model: "uncatalogued-custom-model"
           }

    # Missing destination cannot invent \"legacy\" as provider identity.
    assert {:error, _} =
             TurnEgress.project_dispatch_route(%{
               model: "m",
               runtime: :arbor,
               provider: %{id: :legacy}
             })
  end

  test "VOICE-17 security regression: Router-disabled uncatalogued model exact route admits; mutation/fallback denied",
       %{agent_id: agent_id, human_id: human_id} do
    # Configured freeze (Router disabled / tool-loop path): provider = destination.
    frozen = %{
      destination: "anthropic",
      provider: "anthropic",
      runtime: "arbor",
      model: "uncatalogued-custom-model"
    }

    auth = authority!(human_id)
    state = %{agent_id: agent_id, session_id: "session_p5_legacy_route"}
    {bound, cap_id} = issue_disclosure!(state, auth, frozen)
    fence = TurnEgress.new_fence()

    authorizer =
      build_authz!(
        fence: fence,
        frozen_route: frozen,
        agent_id: agent_id,
        session_id: "session_p5_legacy_route",
        turn_id: bound.turn_id,
        human_id: human_id,
        disclosure_capability_id: cap_id
      )

    # Exact Dispatch legacy projection of the same outbound identity admits.
    assert {:ok, projected} =
             TurnEgress.project_dispatch_route(%{
               destination: "anthropic",
               model: "uncatalogued-custom-model",
               runtime: :arbor,
               provider: %{id: :legacy, ref: "uncatalogued-custom-model"}
             })

    assert projected == frozen
    assert :allow = authorizer.(projected)

    # Destination/provider mutation denied (would have been \"legacy\" before fix).
    assert {:error, _} =
             authorizer.(%{
               destination: "openai",
               provider: "openai",
               runtime: "arbor",
               model: "uncatalogued-custom-model"
             })

    # Model mutation / fallback denied.
    assert {:error, _} =
             authorizer.(%{
               destination: "anthropic",
               provider: "anthropic",
               runtime: "arbor",
               model: "other-model"
             })

    # Synthesized provider=\"legacy\" must not admit against configured freeze.
    assert {:error, _} =
             authorizer.(%{
               destination: "anthropic",
               provider: "legacy",
               runtime: "arbor",
               model: "uncatalogued-custom-model"
             })

    TurnEgress.safe_revoke_disclosure(cap_id)
  end

  test "VOICE-17 security regression: local provider uses ordinary trust semantics",
       %{agent_id: agent_id} do
    fence = TurnEgress.new_fence()

    route = %{
      destination: "lmstudio",
      provider: "lmstudio",
      runtime: "arbor",
      model: "local-model"
    }

    authorizer =
      build_authz!(
        fence: fence,
        frozen_route: route,
        frozen_tier: @local_tier,
        agent_id: agent_id,
        session_id: "session_p5_local",
        turn_id: nil,
        human_id: nil,
        disclosure_capability_id: nil
      )

    assert :allow = authorizer.(route)
  end

  # ── Lifecycle rows ───────────────────────────────────────────────────

  test "VOICE-17 lifecycle: success path revokes before public reply",
       %{agent_id: agent_id, human_id: human_id, agent_signer: signer} do
    route = external_route()
    auth0 = authority!(human_id)

    {bound, cap_id} =
      issue_disclosure!(%{agent_id: agent_id, session_id: "session_p5_ok"}, auth0, route)

    fence = TurnEgress.new_fence()
    from = {self(), make_ref()}
    graph = hermetic_success_graph!()
    token = make_ref()

    state =
      session_state(agent_id,
        turn_graph: graph,
        signer: signer,
        turn_in_flight: true,
        turn_from: from,
        turn_authority: bound,
        turn_egress_fence: fence,
        turn_token: token,
        turn_user_message: UserMessage.from_string("ok"),
        phase: :processing,
        turn_task_ref: make_ref(),
        turn_caller_ref: make_ref()
      )

    assert {:ok, run} =
             Arbor.Orchestrator.Engine.run(graph,
               initial_values: %{"session.input" => "ok"},
               authorization: false
             )

    assert {:noreply, after_ok} =
             Session.handle_info(
               {:turn_result, token, state.turn_user_message, {:ok, run}},
               state
             )

    refute after_ok.turn_in_flight
    refute TurnEgress.fence_active?(fence)
    assert after_ok.turn_token == nil

    Application.put_env(:arbor_security, :egress_gate_enforcing, true)

    assert {:error, _} =
             build_authz!(
               fence: TurnEgress.new_fence(),
               frozen_route: route,
               agent_id: agent_id,
               session_id: "session_p5_ok",
               turn_id: bound.turn_id,
               human_id: human_id,
               disclosure_capability_id: cap_id
             ).(route)

    Application.put_env(:arbor_security, :egress_gate_enforcing, false)

    {_pid, ref} = from
    assert_receive {^ref, {:ok, _}}, 1_000
  end

  test "VOICE-17 lifecycle: engine fail/error cleanup revokes",
       %{agent_id: agent_id, human_id: human_id, agent_signer: signer} do
    route = external_route()
    auth0 = authority!(human_id)

    {bound, cap_id} =
      issue_disclosure!(%{agent_id: agent_id, session_id: "session_p5_fail"}, auth0, route)

    fence = TurnEgress.new_fence()
    from = {self(), make_ref()}
    token = make_ref()

    state =
      session_state(agent_id,
        signer: signer,
        turn_in_flight: true,
        turn_from: from,
        turn_authority: bound,
        turn_egress_fence: fence,
        turn_token: token,
        turn_user_message: UserMessage.from_string("fail"),
        phase: :processing,
        turn_task_ref: make_ref(),
        turn_caller_ref: make_ref()
      )

    assert {:noreply, after_err} =
             Session.handle_info(
               {:turn_result, token, state.turn_user_message, {:error, :engine_boom}},
               state
             )

    refute after_err.turn_in_flight
    refute TurnEgress.fence_active?(fence)
    TurnEgress.safe_revoke_disclosure(cap_id)
  end

  test "VOICE-17 lifecycle: user cancel kill-before-revoke and before finalize/reply",
       %{agent_id: agent_id, human_id: human_id, agent_signer: signer} do
    Application.put_env(:arbor_orchestrator, :_session_lifecycle_probe, self())
    route = external_route()
    auth0 = authority!(human_id)

    {bound, cap_id} =
      issue_disclosure!(%{agent_id: agent_id, session_id: "session_p5_cancel"}, auth0, route)

    fence = TurnEgress.new_fence()
    # Task that would keep authorizing if fence were still active after cancel.
    parent = self()

    task_pid =
      spawn(fn ->
        authorizer =
          build_authz!(
            fence: fence,
            frozen_route: route,
            agent_id: agent_id,
            session_id: "session_p5_cancel",
            turn_id: bound.turn_id,
            human_id: human_id,
            disclosure_capability_id: cap_id
          )

        Stream.repeatedly(fn ->
          case authorizer.(route) do
            :allow -> send(parent, {:late_wave, System.monotonic_time()})
            _ -> :ok
          end

          Process.sleep(5)
        end)
        |> Stream.run()
      end)

    state =
      session_state(agent_id,
        signer: signer,
        turn_in_flight: true,
        turn_from: {self(), make_ref()},
        turn_authority: bound,
        turn_egress_fence: fence,
        turn_task_pid: task_pid,
        turn_task_ref: Process.monitor(task_pid),
        turn_caller_ref: make_ref(),
        turn_user_message: UserMessage.from_string("c"),
        phase: :processing
      )

    # Drain any waves admitted before cancel (fence still active).
    flush_late_waves()

    assert {:reply, :ok, after_cancel} =
             Session.handle_call(:cancel_turn, {self(), make_ref()}, state)

    probes = drain_lifecycle_probes()
    assert_kill_before_revoke_before_reply!(probes)
    refute after_cancel.turn_in_flight
    refute TurnEgress.fence_active?(fence)
    refute Process.alive?(task_pid)
    # No wave after fence deactivation / kill / revoke.
    Process.sleep(30)
    refute_received {:late_wave, _}
    TurnEgress.safe_revoke_disclosure(cap_id)
  end

  test "VOICE-17 lifecycle: timeout kill-before-revoke and before finalize/reply",
       %{agent_id: agent_id, human_id: human_id, agent_signer: signer} do
    Application.put_env(:arbor_orchestrator, :_session_lifecycle_probe, self())
    route = external_route()
    auth0 = authority!(human_id)

    {bound, cap_id} =
      issue_disclosure!(%{agent_id: agent_id, session_id: "session_p5_to"}, auth0, route)

    fence = TurnEgress.new_fence()
    task_pid = spawn(fn -> Process.sleep(60_000) end)
    task_ref = Process.monitor(task_pid)

    state =
      session_state(agent_id,
        signer: signer,
        turn_in_flight: true,
        turn_from: {self(), make_ref()},
        turn_authority: bound,
        turn_egress_fence: fence,
        turn_task_pid: task_pid,
        turn_task_ref: task_ref,
        turn_caller_ref: make_ref(),
        turn_user_message: UserMessage.from_string("t"),
        phase: :processing
      )

    assert {:noreply, after_to} =
             Session.handle_info({:turn_timeout, task_ref}, state)

    probes = drain_lifecycle_probes()
    assert_kill_before_revoke_before_reply!(probes)
    refute after_to.turn_in_flight
    refute TurnEgress.fence_active?(fence)
    refute Process.alive?(task_pid)
    TurnEgress.safe_revoke_disclosure(cap_id)
  end

  test "VOICE-17 lifecycle: task DOWN crash cleanup revokes",
       %{agent_id: agent_id, human_id: human_id, agent_signer: signer} do
    route = external_route()
    auth0 = authority!(human_id)

    {bound, cap_id} =
      issue_disclosure!(
        %{agent_id: agent_id, session_id: "session_p5_down_task"},
        auth0,
        route
      )

    fence = TurnEgress.new_fence()
    task_ref = make_ref()

    state =
      session_state(agent_id,
        signer: signer,
        turn_in_flight: true,
        turn_from: {self(), make_ref()},
        turn_authority: bound,
        turn_egress_fence: fence,
        turn_task_ref: task_ref,
        turn_caller_ref: make_ref(),
        turn_user_message: UserMessage.from_string("crash"),
        phase: :processing
      )

    assert {:noreply, after_down} =
             Session.handle_info({:DOWN, task_ref, :process, self(), :killed}, state)

    refute after_down.turn_in_flight
    refute TurnEgress.fence_active?(fence)
    TurnEgress.safe_revoke_disclosure(cap_id)
  end

  test "VOICE-17 lifecycle: auth caller DOWN kills task before revoke",
       %{agent_id: agent_id, human_id: human_id, agent_signer: signer} do
    Application.put_env(:arbor_orchestrator, :_session_lifecycle_probe, self())
    route = external_route()
    auth0 = authority!(human_id)

    {bound, cap_id} =
      issue_disclosure!(%{agent_id: agent_id, session_id: "session_p5_caller"}, auth0, route)

    fence = TurnEgress.new_fence()
    parent = self()

    task_pid =
      spawn(fn ->
        authorizer =
          build_authz!(
            fence: fence,
            frozen_route: route,
            agent_id: agent_id,
            session_id: "session_p5_caller",
            turn_id: bound.turn_id,
            human_id: human_id,
            disclosure_capability_id: cap_id
          )

        Stream.repeatedly(fn ->
          case authorizer.(route) do
            :allow -> send(parent, {:late_wave, System.monotonic_time()})
            _ -> :ok
          end

          Process.sleep(5)
        end)
        |> Stream.run()
      end)

    task_ref = Process.monitor(task_pid)
    caller = spawn(fn -> Process.sleep(60_000) end)
    caller_ref = Process.monitor(caller)

    state =
      session_state(agent_id,
        signer: signer,
        turn_in_flight: true,
        turn_authority: bound,
        turn_egress_fence: fence,
        turn_task_pid: task_pid,
        turn_task_ref: task_ref,
        turn_caller_ref: caller_ref,
        turn_from: {caller, make_ref()},
        turn_user_message: UserMessage.from_string("auth in flight"),
        phase: :processing
      )

    Process.exit(caller, :kill)

    receive do
      {:DOWN, ^caller_ref, _, _, _} = down ->
        flush_late_waves()

        assert {:noreply, after_down} = Session.handle_info(down, state)
        probes = drain_lifecycle_probes()
        assert_kill_before_revoke!(probes)
        refute TurnEgress.fence_active?(fence)
        refute Process.alive?(task_pid)
        refute after_down.turn_in_flight

        fence_deactivated_at =
          Enum.find_value(probes, fn
            {:fence_deactivated, %{mono: mono}} -> mono
            _ -> nil
          end)

        assert fence_deactivated_at != nil
        Process.sleep(30)

        assert Enum.all?(drain_late_waves(), &(&1 < fence_deactivated_at)),
               "an egress wave was admitted after fence deactivation"
    after
      2_000 -> flunk("expected caller DOWN")
    end

    Application.put_env(:arbor_security, :egress_gate_enforcing, true)

    assert {:error, _} =
             build_authz!(
               fence: TurnEgress.new_fence(),
               frozen_route: route,
               agent_id: agent_id,
               session_id: "session_p5_caller",
               turn_id: bound.turn_id,
               human_id: human_id,
               disclosure_capability_id: cap_id
             ).(route)

    Application.put_env(:arbor_security, :egress_gate_enforcing, false)
  end

  test "VOICE-17 lifecycle: nil-authority caller DOWN deactivates fence, task continues",
       %{agent_id: agent_id, agent_signer: signer} do
    fence = TurnEgress.new_fence()
    task_pid = spawn(fn -> Process.sleep(60_000) end)
    task_ref = Process.monitor(task_pid)
    caller = spawn(fn -> Process.sleep(60_000) end)
    caller_ref = Process.monitor(caller)

    state =
      session_state(agent_id,
        signer: signer,
        turn_in_flight: true,
        turn_authority: nil,
        turn_egress_fence: fence,
        turn_task_pid: task_pid,
        turn_task_ref: task_ref,
        turn_caller_ref: caller_ref,
        turn_from: {caller, make_ref()},
        turn_user_message: UserMessage.from_string("nil auth"),
        phase: :processing
      )

    Process.exit(caller, :kill)

    receive do
      {:DOWN, ^caller_ref, _, _, _} = down ->
        assert {:noreply, after_down} = Session.handle_info(down, state)
        # Fence deactivated so any captured authorizer fails closed.
        refute TurnEgress.fence_active?(fence)
        # Background continuation: task still alive.
        assert Process.alive?(task_pid)
        refute after_down.turn_in_flight
        Process.exit(task_pid, :kill)
    after
      2_000 -> flunk("expected caller DOWN")
    end
  end

  test "VOICE-17 lifecycle: dead queued caller never issues disclosure",
       %{agent_id: agent_id, human_id: human_id, agent_signer: signer} do
    auth = authority!(human_id)
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      1_000 -> flunk("dead process did not exit")
    end

    from_dead = {dead, make_ref()}
    from_live = {self(), make_ref()}

    state =
      session_state(agent_id,
        turn_graph: tool_loop_graph!(),
        signer: signer,
        turn_queue: [
          {UserMessage.from_string("dead caller"), auth, from_dead},
          {UserMessage.from_string("live caller"), nil, from_live}
        ]
      )

    assert {:noreply, after_drain} = Session.handle_info(:drain_queue, state)

    refute match?(
             %TurnAuthority{disclosure_capability_id: id} when is_binary(id),
             after_drain.turn_authority
           )
  end

  test "VOICE-17 lifecycle: Session terminate cleans active turn",
       %{agent_id: agent_id, human_id: human_id, agent_signer: signer} do
    route = external_route()
    auth0 = authority!(human_id)

    {bound, cap_id} =
      issue_disclosure!(%{agent_id: agent_id, session_id: "session_p5_term"}, auth0, route)

    fence = TurnEgress.new_fence()
    task_pid = spawn(fn -> Process.sleep(60_000) end)

    state =
      session_state(agent_id,
        signer: signer,
        turn_in_flight: true,
        turn_authority: bound,
        turn_egress_fence: fence,
        turn_task_pid: task_pid,
        turn_task_ref: Process.monitor(task_pid),
        turn_from: {self(), make_ref()},
        turn_user_message: UserMessage.from_string("term"),
        phase: :processing
      )

    assert :ok = Session.terminate(:shutdown, state)
    refute TurnEgress.fence_active?(fence)
    refute Process.alive?(task_pid)
    TurnEgress.safe_revoke_disclosure(cap_id)
  end

  test "VOICE-17 lifecycle: preparation refusal does not start engine",
       %{agent_id: agent_id, agent_signer: signer} do
    # Tool-loop without configured provider/model → prepare refuses.
    state =
      session_state(agent_id,
        turn_graph: tool_loop_graph!(),
        signer: signer,
        config: %{"stream" => false}
      )

    from = {self(), make_ref()}

    assert {:noreply, after_prep} =
             Session.handle_call({:send_message, "no route"}, from, state)

    refute after_prep.turn_in_flight
    {_pid, ref} = from
    assert_receive {^ref, {:error, :turn_preparation_refused}}, 1_000
  end

  test "VOICE-17 security regression: public state strips authority and fence",
       %{agent_id: agent_id, human_id: human_id} do
    auth = authority!(human_id)
    fence = TurnEgress.new_fence()
    token = make_ref()

    state =
      session_state(agent_id,
        turn_authority: auth,
        turn_egress_fence: fence,
        turn_token: token,
        turn_in_flight: true,
        turn_user_message: user_message_auth(human_id)
      )

    assert {:reply, projected, returned} =
             Session.handle_call(:get_state, {self(), make_ref()}, state)

    assert returned.turn_authority == auth
    assert returned.turn_token == token
    assert projected.turn_authority == nil
    assert projected.turn_egress_fence == nil
    assert projected.turn_token == nil
  end

  # ── Five continuation-correction evidence rows ───────────────────────

  test "VOICE-17 security regression: dark-gate Trust allow still requires validate_disclosure",
       %{agent_id: agent_id, human_id: human_id} do
    Application.put_env(:arbor_security, :egress_gate_enforcing, false)
    route = external_route()
    auth = authority!(human_id)
    state = %{agent_id: agent_id, session_id: "session_p5_validate"}
    {bound, cap_id} = issue_disclosure!(state, auth, route)
    fence = TurnEgress.new_fence()

    good =
      build_authz!(
        fence: fence,
        frozen_route: route,
        agent_id: agent_id,
        session_id: "session_p5_validate",
        turn_id: bound.turn_id,
        human_id: human_id,
        disclosure_capability_id: cap_id
      )

    assert :allow = good.(route)

    # Shape-valid but forged id is denied by public validate_disclosure.
    forged_id = "cap_" <> String.duplicate("a", 32)

    forged =
      build_authz!(
        fence: fence,
        frozen_route: route,
        agent_id: agent_id,
        session_id: "session_p5_validate",
        turn_id: bound.turn_id,
        human_id: human_id,
        disclosure_capability_id: forged_id
      )

    assert {:error, {:egress_blocked, :external_provider, :disclosure_rejected}} =
             forged.(route)

    # Wrong human scope denied.
    wrong_human =
      build_authz!(
        fence: fence,
        frozen_route: route,
        agent_id: agent_id,
        session_id: "session_p5_validate",
        turn_id: bound.turn_id,
        human_id: "human_someone_else",
        disclosure_capability_id: cap_id
      )

    assert {:error, {:egress_blocked, :external_provider, :disclosure_rejected}} =
             wrong_human.(route)

    # Exact wrong-route disclosure validation: Trust may allow under dark gate,
    # but public validate_disclosure_capability rejects route mismatch.
    wrong_route = %{route | model: "wrong-model-not-bound"}

    wrong_route_authz =
      build_authz!(
        fence: fence,
        # Authorizer exact-match uses frozen_route first — install frozen as the
        # wrong route so we reach Trust + validate (not route_mismatch early).
        frozen_route: wrong_route,
        agent_id: agent_id,
        session_id: "session_p5_validate",
        turn_id: bound.turn_id,
        human_id: human_id,
        disclosure_capability_id: cap_id
      )

    assert {:error, {:egress_blocked, :external_provider, :disclosure_rejected}} =
             wrong_route_authz.(wrong_route)

    TurnEgress.safe_revoke_disclosure(cap_id)

    revoked =
      build_authz!(
        fence: fence,
        frozen_route: route,
        agent_id: agent_id,
        session_id: "session_p5_validate",
        turn_id: bound.turn_id,
        human_id: human_id,
        disclosure_capability_id: cap_id
      )

    assert {:error, {:egress_blocked, :external_provider, :disclosure_rejected}} =
             revoked.(route)
  end

  test "VOICE-17 security regression: unknown frozen tier fails closed even when gate dark",
       %{agent_id: agent_id} do
    Application.put_env(:arbor_security, :egress_gate_enforcing, false)
    fence = TurnEgress.new_fence()
    route = external_route()

    for bad_tier <- [nil, :on_premises, :external_peer, :none, :wat, "external_provider"] do
      assert {:error, :invalid_frozen_tier} =
               TurnEgress.admit_frozen_tier(bad_tier)

      authorizer =
        build_authz!(
          fence: fence,
          frozen_route: route,
          frozen_tier: bad_tier,
          agent_id: agent_id,
          session_id: "session_p5_bad_tier",
          turn_id: nil,
          human_id: nil,
          disclosure_capability_id: nil
        )

      assert {:error, {:egress_blocked, :external_provider, :invalid_frozen_tier}} =
               authorizer.(route),
             "expected deny for frozen_tier=#{inspect(bad_tier)}"
    end

    assert {:ok, :on_host} = TurnEgress.admit_frozen_tier(:on_host)
    assert {:ok, :external_provider} = TurnEgress.admit_frozen_tier(:external_provider)
  end

  test "VOICE-17 security regression: frozen tier ignores concurrent backend_trust reclassify",
       %{agent_id: agent_id, human_id: human_id} do
    route = external_route()
    auth = authority!(human_id)
    state = %{agent_id: agent_id, session_id: "session_p5_frozen_tier"}
    {bound, cap_id} = issue_disclosure!(state, auth, route, @external_tier)

    # Capture external at prepare time, then make live reclassification return
    # :on_host for anthropic (would bypass disclosure if re-read per attempt).
    prev = Application.get_env(:arbor_ai, :backend_trust_levels)

    Application.put_env(:arbor_ai, :backend_trust_levels, %{
      anthropic: :highest,
      lmstudio: :highest,
      ollama: :highest
    })

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:arbor_ai, :backend_trust_levels)
        v -> Application.put_env(:arbor_ai, :backend_trust_levels, v)
      end
    end)

    # Live classification would now treat anthropic as on_host.
    assert Arbor.AI.egress_tier_for("anthropic") == :on_host

    fence = TurnEgress.new_fence()

    authorizer =
      build_authz!(
        fence: fence,
        frozen_route: route,
        frozen_tier: @external_tier,
        agent_id: agent_id,
        session_id: "session_p5_frozen_tier",
        turn_id: bound.turn_id,
        human_id: human_id,
        disclosure_capability_id: cap_id
      )

    # Still external path: exact disclosure still required and admits.
    assert :allow = authorizer.(route)

    no_cap =
      build_authz!(
        fence: fence,
        frozen_route: route,
        frozen_tier: @external_tier,
        agent_id: agent_id,
        session_id: "session_p5_frozen_tier",
        turn_id: bound.turn_id,
        human_id: human_id,
        disclosure_capability_id: nil
      )

    assert {:error, {:egress_blocked, :external_provider, :disclosure_required}} =
             no_cap.(route)

    TurnEgress.safe_revoke_disclosure(cap_id)
  end

  test "VOICE-17 security regression: stale turn_token cannot finalize newer auth turn",
       %{agent_id: agent_id, human_id: human_id, agent_signer: signer} do
    route = external_route()
    auth0 = authority!(human_id)

    {bound, cap_id} =
      issue_disclosure!(%{agent_id: agent_id, session_id: "session_p5_token"}, auth0, route)

    active_token = make_ref()
    stale_token = make_ref()
    from = {self(), make_ref()}
    fence = TurnEgress.new_fence()
    graph = hermetic_success_graph!()

    state =
      session_state(agent_id,
        turn_graph: graph,
        signer: signer,
        turn_in_flight: true,
        turn_from: from,
        turn_authority: bound,
        turn_egress_fence: fence,
        turn_token: active_token,
        turn_user_message: UserMessage.from_string("active"),
        phase: :processing,
        turn_task_ref: make_ref(),
        turn_caller_ref: make_ref()
      )

    assert {:ok, run} =
             Arbor.Orchestrator.Engine.run(graph,
               initial_values: %{"session.input" => "x"},
               authorization: false
             )

    # Stale/forged tokens ignored — active authority and fence untouched.
    assert {:noreply, still} =
             Session.handle_info(
               {:turn_result, stale_token, state.turn_user_message, {:ok, run}},
               state
             )

    assert still.turn_in_flight
    assert still.turn_authority == bound
    assert Map.get(still, :turn_token) == active_token
    assert TurnEgress.fence_active?(fence)

    # Legacy 3-tuple ignored while a real active token exists.
    assert {:noreply, still2} =
             Session.handle_info({:turn_result, state.turn_user_message, {:ok, run}}, still)

    assert still2.turn_in_flight
    assert still2.turn_authority == bound

    # Matching token admits and cleans up.
    assert {:noreply, after_ok} =
             Session.handle_info(
               {:turn_result, active_token, state.turn_user_message, {:ok, run}},
               still2
             )

    refute after_ok.turn_in_flight
    assert Map.get(after_ok, :turn_token) == nil
    refute TurnEgress.fence_active?(fence)
    TurnEgress.safe_revoke_disclosure(cap_id)
  end

  test "VOICE-17 security regression: legacy 3-tuple cannot complete tokenless in-flight turn",
       %{agent_id: agent_id, human_id: human_id, agent_signer: signer} do
    route = external_route()
    auth0 = authority!(human_id)

    {bound, cap_id} =
      issue_disclosure!(%{agent_id: agent_id, session_id: "session_p5_legacy3"}, auth0, route)

    fence = TurnEgress.new_fence()
    reply_ref = make_ref()
    from = {self(), reply_ref}
    graph = hermetic_success_graph!()

    assert {:ok, run} =
             Arbor.Orchestrator.Engine.run(graph,
               initial_values: %{"session.input" => "legacy3"},
               authorization: false
             )

    # Missing token is an invariant failure, not compatibility authority. A
    # forged legacy result must not finalize, reply, reset, or revoke.
    tokenless =
      session_state(agent_id,
        turn_graph: graph,
        signer: signer,
        turn_in_flight: true,
        turn_from: from,
        turn_authority: bound,
        turn_egress_fence: fence,
        turn_token: nil,
        turn_user_message: UserMessage.from_string("legacy3"),
        phase: :processing,
        turn_task_ref: make_ref(),
        turn_caller_ref: make_ref()
      )

    assert {:noreply, still_tokenless} =
             Session.handle_info(
               {:turn_result, tokenless.turn_user_message, {:ok, run}},
               tokenless
             )

    assert still_tokenless.turn_in_flight
    assert still_tokenless.turn_authority == bound
    assert Map.get(still_tokenless, :turn_token) == nil
    assert TurnEgress.fence_active?(fence)
    refute_receive {^reply_ref, _}, 50

    TurnEgress.deactivate_fence(fence)
    TurnEgress.safe_revoke_disclosure(cap_id)
  end

  test "VOICE-17 security regression: task deactivates fence before turn_result is observed",
       %{agent_id: agent_id, agent_signer: signer} do
    # Real task path: by the time Session receives turn_result the fence is off.
    state =
      session_state(agent_id,
        turn_graph: hermetic_success_graph!(),
        signer: signer,
        config: %{
          "llm_provider" => "lmstudio",
          "llm_model" => "local-model",
          "stream" => false
        }
      )

    from = {self(), make_ref()}

    assert {:noreply, started} =
             Session.handle_call({:send_message, "hermetic"}, from, state)

    fence = started.turn_egress_fence
    assert fence != nil

    msg = await_turn_result()
    # Pre-send deactivate: fence must already be inactive when result arrives.
    refute TurnEgress.fence_active?(fence)

    assert {:noreply, after_done} = Session.handle_info(msg, started)
    refute after_done.turn_in_flight
  end

  defp user_message_auth(human_id) do
    UserMessage.from_voice("hi", sender_id: human_id)
  end

  defp drain_lifecycle_probes(acc \\ []) do
    receive do
      {:lifecycle_probe, event, meta} ->
        drain_lifecycle_probes([{event, meta} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp flush_late_waves do
    receive do
      {:late_wave, _} -> flush_late_waves()
    after
      0 -> :ok
    end
  end

  defp drain_late_waves(acc \\ []) do
    receive do
      {:late_wave, mono} -> drain_late_waves([mono | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_kill_before_revoke!(probes) do
    events = Enum.map(probes, &elem(&1, 0))
    fence_i = Enum.find_index(events, &(&1 == :fence_deactivated))
    kill_i = Enum.find_index(events, &(&1 == :task_kill_awaited))
    before_rev_i = Enum.find_index(events, &(&1 == :before_revoke))
    rev_i = Enum.find_index(events, &(&1 == :revoked))

    assert fence_i != nil, "missing fence_deactivated in #{inspect(events)}"
    assert kill_i != nil, "missing task_kill_awaited in #{inspect(events)}"
    assert before_rev_i != nil, "missing before_revoke in #{inspect(events)}"
    assert rev_i != nil, "missing revoked in #{inspect(events)}"
    assert fence_i < kill_i
    assert kill_i < before_rev_i
    assert before_rev_i < rev_i

    {_ev, kill_meta} = Enum.at(probes, kill_i)
    {_ev, before_meta} = Enum.at(probes, before_rev_i)
    assert kill_meta.task_alive? == false
    assert before_meta.task_alive? == false
  end

  defp assert_kill_before_revoke_before_reply!(probes) do
    assert_kill_before_revoke!(probes)
    events = Enum.map(probes, &elem(&1, 0))
    rev_i = Enum.find_index(events, &(&1 == :revoked))
    fin_i = Enum.find_index(events, &(&1 == :before_finalize))
    reply_i = Enum.find_index(events, &(&1 == :before_reply))

    assert fin_i != nil, "missing before_finalize in #{inspect(events)}"
    assert reply_i != nil, "missing before_reply in #{inspect(events)}"
    assert rev_i < fin_i
    assert fin_i < reply_i
  end
end
