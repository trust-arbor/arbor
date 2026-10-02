Code.require_file(
  Path.expand("../../../arbor_security/test/support/oidc_test_helper.ex", __DIR__)
)

defmodule Arbor.Voice.ConversationCrossSurfaceFixture do
  @moduledoc """
  Isolated extension of the retained ConversationKit real-host fixture and the
  existing Voice binding journey. Security, linked OIDC identities, Comms,
  SQLite, Agent, standard turn.dot, Session, Engine, Voice Desk and its cleanup
  owners are real. Only model/provider and native device I/O are substituted.
  The fixture disables the same wider policy/reflex/preprocessor integrations
  as the existing real-auth journey; it does not qualify every policy profile.
  """
  use ExUnit.CaseTemplate

  alias Arbor.Agent.{IdentityAliases, IdentityAliasProof, SessionManager}
  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Orchestrator.Session
  alias Arbor.Persistence.Repo
  alias Arbor.Security
  alias Arbor.Security.{OIDCTestHelper, SessionToken}

  @turn_dot Path.expand("../../../arbor_orchestrator/specs/pipelines/session/turn.dot", __DIR__)
  @migrations Path.expand("../../../arbor_persistence/priv/repo/migrations", __DIR__)
  @voice_supervisors [
    Arbor.Voice.DeskSupervisor,
    Arbor.Voice.SessionSupervisor,
    Arbor.Voice.ResourceSupervisor,
    Arbor.Voice.CleanupLeaseSupervisor,
    Arbor.Voice.BackendWorkerSupervisor,
    Arbor.Voice.DeskWorkerSupervisor
  ]

  @voice_task_supervisors [
    Arbor.Voice.ToolTaskSupervisor,
    Arbor.Voice.SpeechOutputTaskSupervisor,
    Arbor.Voice.ResourceCleanupTaskSupervisor
  ]

  using do
    quote do
      alias Arbor.Voice.ConversationCrossSurfaceFixture, as: Fixture
      @moduletag :integration
      @moduletag :database
      @moduletag :isolated_repo
      @moduletag :conversation_cross_surface
      @moduletag capture_log: true
    end
  end

  defmodule CaptureProvider do
    def provider, do: "lm_studio"
    def runtime_contract, do: %Arbor.Contracts.AI.RuntimeContract{}

    def complete(request, _opts) do
      Arbor.Voice.ConversationCrossSurfaceFixture.record(:requests, request.messages)

      # Exercise the same translation and JSON encoder as a real OpenRouter
      # request. No Req request is executed and no provider key is required.
      context =
        request.messages
        |> Arbor.LLM.Adapter.ReqLLM.translate_messages()
        |> ReqLLM.Context.new()

      wire =
        %Req.Request{options: %{context: context, model: "openrouter/free", operation: :chat}}
        |> ReqLLM.Providers.OpenRouter.encode_body()
        |> Map.fetch!(:body)
        |> Jason.decode!()

      Arbor.Voice.ConversationCrossSurfaceFixture.record(:wire_requests, wire["messages"])

      {:ok,
       %Arbor.LLM.Response{
         text: "Conversation received.",
         finish_reason: :stop,
         content_parts: [Arbor.LLM.ContentPart.text("Conversation received.")],
         usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5},
         raw: %{}
       }}
    end

    def complete_single_attempt(request, opts), do: complete(request, opts)
  end

  defmodule Media do
    def capture_pcm(opts) do
      audio = %{
        pcm: :binary.copy(<<0, 1>>, opts[:duration_ms] * 16),
        sample_rate: 16_000,
        channels: 1,
        sample_format: :s16le
      }

      Arbor.Voice.ConversationCrossSurfaceFixture.record(:captures, audio)
      {:ok, %{audio: audio, utterance_ended_at: DateTime.utc_now()}}
    end

    def play_pcm(audio, _opts) do
      Arbor.Voice.ConversationCrossSurfaceFixture.record(:playbacks, audio)
      :ok
    end

    def device_status, do: :idle
  end

  defmodule Backend do
    @behaviour Arbor.Voice.RealtimeBackend
    def egress_route, do: :none
    def open(opts), do: {:ok, Map.new(opts) |> Map.put(:events, [])}
    def configure(state, _), do: {:ok, state}
    def send_text(state, _), do: {:ok, state}

    def send_tool_result(state, id, output) do
      Arbor.Voice.ConversationCrossSurfaceFixture.record(:tool_results, {id, output})

      reply =
        case state.mode do
          :remember_phrase -> "The test phrase is silver birch at dawn."
          :recall_phrase -> "The earlier test phrase is silver birch at dawn."
          _ -> "Voice willow answer."
        end

      final = [{:output_audio, <<7, 8, 9, 10>>}, {:turn_done, %{text: reply}}]
      {:ok, %{state | events: state.events ++ final}}
    end

    def send_audio(state, pcm) do
      Arbor.Voice.ConversationCrossSurfaceFixture.record(:inputs, pcm)
      send(state.observer, {:provider_audio_received, state.mode})

      events =
        case state.mode do
          :complete ->
            [
              {:input_transcript, "Voice willow utterance"},
              {:output_audio, <<7, 8, 9, 10>>},
              {:turn_done, %{text: "Voice willow answer."}}
            ]

          :consult ->
            [
              {:input_transcript, "Voice willow utterance"},
              {:tool_call,
               %{
                 id: "consult-ash",
                 name: "consult_agent",
                 arguments: %{"message" => "Voice consult ash request"}
               }},
              {:turn_done, %{text: ""}}
            ]

          mode when mode in [:remember_phrase, :recall_phrase] ->
            utterance =
              if mode == :remember_phrase,
                do: "Remember the test phrase silver birch at dawn.",
                else: "Ask the backend for the earlier test phrase."

            [
              {:input_transcript, utterance},
              {:tool_call,
               %{
                 id: "consult-#{mode}",
                 name: "consult_agent",
                 arguments: %{"message" => "Consultation paraphrase must not replace speech"}
               }},
              {:turn_done, %{text: ""}}
            ]

          :hold ->
            []
        end

      {:ok, %{state | events: events}}
    end

    def recv(%{events: [event | rest]} = state, _), do: {:ok, %{state | events: rest}, event}

    def recv(_, timeout) do
      Process.sleep(min(timeout, 10))
      {:error, :timeout}
    end

    def close(state) do
      metrics = Application.fetch_env!(:arbor_voice, :cross_surface_metrics)
      Agent.update(metrics, &Map.update!(&1, :closes, fn count -> count + 1 end))
      send(state.observer, :provider_closed)
      :ok
    end

    def meta(_),
      do: %{
        backend: :cross_surface_fixture,
        mode: :local,
        input_format: Arbor.Voice.PcmFormat.mono_s16le(16_000),
        output_format: Arbor.Voice.PcmFormat.mono_s16le(24_000)
      }
  end

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "cross-surface-runtime-#{System.pid()}-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      )

    runtime = start_runtime!(data_root: root)
    on_exit(fn -> assert :ok = stop_runtime(runtime) end)
    {:ok, fixture_runtime: runtime, database: runtime.database}
  end

  setup %{fixture_runtime: runtime} do
    context = start_context!(runtime, self())
    on_exit(fn -> assert :ok = stop_context(context) end)
    {:ok, context}
  end

  @doc "Start the disposable fixture in a dedicated MIX_ENV=test VM; data_root must be a fresh absolute directory."
  def start_runtime!(opts) do
    unless Mix.env() == :test and is_list(opts) and Keyword.keyword?(opts) and
             Enum.all?(Keyword.keys(opts), &(&1 in [:data_root, :endpoint])) do
      raise ArgumentError, "isolated test fixture options required"
    end

    root = Keyword.fetch!(opts, :data_root)

    unless is_binary(root) and Path.type(root) == :absolute and not File.exists?(root),
      do: raise(ArgumentError, "fixture data_root must be a fresh absolute directory")

    unless Process.whereis(Repo) == nil and Process.whereis(:arbor_user_config) == nil,
      do: raise("fixture refuses an existing Repo or identity-alias store")

    for app <- [:arbor_security, :arbor_agent, :arbor_memory, :arbor_multimedia] do
      unless Application.get_env(app, :start_children) == false,
        do: raise("fixture requires the isolated test startup profile")
    end

    endpoint = endpoint_options(Keyword.get(opts, :endpoint, []))
    File.mkdir_p!(Path.dirname(root))
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    construct(fn scope ->
      {:ok, owned_apps} = Application.ensure_all_started(:arbor_voice)
      defer(scope, fn -> stop_apps(owned_apps) end)
      :ok = Arbor.Security.TestBootstrap.start!()
      :ok = Arbor.Memory.TestBootstrap.start!()
      {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)
      # The explicit handle outlives ExUnit's setup process. The interactive
      # host owns this handle and must call stop_runtime; a private VM exit is
      # containment only, never a positive cleanup receipt.
      Process.unlink(supervisor)
      defer(scope, fn -> Supervisor.stop(supervisor, :normal, 10_000) end)

      {:ok, control} =
        Supervisor.start_child(supervisor, {Agent, fn -> %{context: nil, closing: false} end})

      runtime = %{
        supervisor: supervisor,
        control: control,
        data_root: root,
        database: Path.join(root, "conversation.sqlite3")
      }

      {:ok, _repo} =
        Supervisor.start_child(
          supervisor,
          {Repo,
           database: runtime.database,
           pool: DBConnection.ConnectionPool,
           pool_size: 4,
           busy_timeout: 5_000,
           journal_mode: :wal}
        )

      [_ | _] = Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)

      for {name, child} <- [
            {Arbor.Agent.Registry, Arbor.Agent.Registry},
            {Arbor.Agent.SessionManager, Arbor.Agent.SessionManager},
            {Arbor.Orchestrator.EventRegistry,
             {Registry, keys: :duplicate, name: Arbor.Orchestrator.EventRegistry}},
            {Arbor.Comms.EngagementStore, Arbor.Comms.EngagementStore},
            {Arbor.Agent.Orchestration.TaskSupervisor,
             {Task.Supervisor, name: Arbor.Agent.Orchestration.TaskSupervisor}},
            {:arbor_user_config,
             {Arbor.Persistence.BufferedStore,
              name: :arbor_user_config,
              backend: Arbor.Security.Store.JSONFile,
              write_mode: :sync,
              ack_mode: :backend,
              backend_opts: [base_dir: Path.join(root, "aliases")],
              collection: "entrypoint_aliases"}}
          ] do
        if Process.whereis(name) == nil do
          {:ok, _} = Supervisor.start_child(supervisor, Supervisor.child_spec(child, id: name))
        end
      end

      set_env(scope, :conversation_demo, ConversationDemo.Endpoint, endpoint)
      {:ok, demo_apps} = Application.ensure_all_started(:conversation_demo)
      defer(scope, fn -> stop_apps(demo_apps) end)
      runtime
    end)
  end

  @doc "Create one linked, scripted conversation context; no live device/provider selector is accepted."
  def start_context!(runtime, observer) when is_pid(observer) do
    token = make_ref()

    case Agent.get_and_update(runtime.control, fn
           %{context: nil, closing: false} = state -> {:ok, %{state | context: token}}
           state -> {:busy, state}
         end) do
      :ok -> :ok
      :busy -> raise("fixture runtime already owns a context or is closing")
    end

    construct(fn scope ->
      defer(scope, fn ->
        Agent.update(runtime.control, fn %{context: ^token} = state -> %{state | context: nil} end)
      end)

      build_context(runtime, observer, scope)
    end)
  end

  @doc """
  Seal admission and prove real Desk/worker cleanup before releasing fixture state.
  The host first stops browser/Breeze admission (including existing sockets).
  Chat grants are then revoked here to fence retained or racing renderer clients.
  Unknown cleanup leaves the context/runtime owned and returns an error.
  """
  def stop_context(context) do
    Agent.update(context.metrics, &%{&1 | closing: true})

    with :ok <- wait_until(fn -> metrics(context).admitting == 0 end),
         :ok <- revoke(context.primary_cap.id),
         :ok <- revoke(context.secondary_cap.id),
         :ok <- close_desks(context),
         :ok <- wait_until(fn -> voice_quiescent?(context) end),
         result when result in [:ok, {:error, :no_turn_in_flight}] <-
           Session.cancel_turn(context.session),
         :ok <-
           wait_until(fn ->
             not Session.get_state(context.session).turn_in_flight and
               MapSet.new(Task.Supervisor.children(Arbor.Agent.Orchestration.TaskSupervisor)) ==
                 context.agent_task_baseline
           end),
         :ok <- retire_desks(context),
         :ok <- cleanup(context.cleanup) do
      :ok
    else
      _ -> {:error, :fixture_cleanup_pending}
    end
  catch
    _, _ -> {:error, :fixture_cleanup_pending}
  end

  @doc "Stop only fixture-owned runtime resources after its context has positively closed; preserve private evidence files."
  def stop_runtime(runtime) do
    case Agent.get_and_update(runtime.control, fn
           %{context: nil} = state -> {:ready, %{state | closing: true}}
           state -> {:active, state}
         end) do
      :ready -> cleanup(runtime.cleanup)
      :active -> {:error, :context_active}
    end
  catch
    _, _ -> {:error, :fixture_runtime_unavailable}
  end

  defp build_context(runtime, observer, scope) do
    for {app, key, value} <- [
          {:arbor_security, :identity_verification, true},
          {:arbor_security, :capability_signing_required, true},
          {:arbor_security, :strict_identity_mode, false},
          {:arbor_security, :policy_enforcer_enabled, false},
          {:arbor_security, :approval_guard_enabled, false},
          {:arbor_security, :reflex_checking_enabled, false},
          {:arbor_security, :uri_registry_enforcement, false},
          {:arbor_security, :identity_alias_resolver, Arbor.Agent.IdentityAliasResolver},
          {:arbor_security, :session_token_secret, :crypto.strong_rand_bytes(32)},
          {:arbor_trust, :policy_enforcer_enabled, false},
          {:arbor_trust, :approval_guard_enabled, false},
          {:arbor_orchestrator, :private_conversation_memory, false},
          {:arbor_orchestrator, :preprocessor_enabled, false},
          {:arbor_voice, :security_module, Arbor.Security},
          {:arbor_voice, :budget_backend, Arbor.Persistence.QueryableStore.Postgres},
          {:arbor_voice, :budget_backend_opts, [repo: Repo]},
          {:arbor_voice, :desk_voice_module, Arbor.Voice},
          {:arbor_voice, :desk_comms_module, Arbor.Comms},
          {:arbor_voice, :desk_multimedia_module, Media},
          {:arbor_voice, :agent_module, Arbor.Agent},
          {:arbor_voice, :trust_module, Arbor.Trust},
          {:arbor_comms, :conversation_journal,
           [
             backend: Arbor.Persistence.EventLog.Ecto,
             name: :conversation_journal,
             opts: [repo: Repo]
           ]}
        ],
        do: set_env(scope, app, key, value)

    previous = Arbor.LLM.Client.default_client()

    client =
      Arbor.LLM.Client.new(default_provider: "lm_studio")
      |> Arbor.LLM.Client.register_adapter(CaptureProvider)

    Arbor.LLM.Client.set_default_client(client)

    defer(scope, fn ->
      Arbor.LLM.Client.set_default_client(previous)
      :ok
    end)

    primary = human!(scope)
    secondary = human!(scope)
    {:ok, agent} = Identity.generate(name: "Real entrypoint convergence journey")
    :ok = Security.register_identity(Identity.public_only(agent))
    defer(scope, fn -> Security.deregister_identity(agent.agent_id) end)
    resource = "arbor://chat/agent/" <> agent.agent_id
    primary_cap = grant!(scope, primary.agent_id, resource)
    secondary_cap = grant!(scope, secondary.agent_id, resource)
    grant!(scope, primary.agent_id, "arbor://identity/alias/manage")

    for uri <- [
          "arbor://orchestrator/execute",
          "arbor://orchestrator/execute/llm_query",
          "arbor://orchestrator/execute/transform",
          "arbor://orchestrator/execute/unknown",
          "arbor://memory/read/" <> agent.agent_id,
          "arbor://memory/write/" <> agent.agent_id
        ],
        do: grant!(scope, agent.agent_id, uri)

    link!(primary, secondary)
    defer(scope, fn -> unlink(primary, secondary) end)
    {:ok, token} = SessionToken.generate(primary.agent_id)
    {:ok, voice_token} = SessionToken.generate(secondary.agent_id)

    metrics =
      start_owned!(
        runtime,
        scope,
        {Agent,
         fn ->
           %{
             requests: [],
             wire_requests: [],
             appends: 0,
             captures: [],
             inputs: [],
             playbacks: [],
             tool_results: [],
             closes: 0,
             closing: false,
             admitting: 0,
             operations: [],
             terminals: MapSet.new()
           }
         end}
      )

    set_env(scope, :arbor_voice, :cross_surface_metrics, metrics)

    append = fn session_id, entries ->
      Agent.update(metrics, &Map.update!(&1, :appends, fn count -> count + 1 end))
      Arbor.Persistence.append_session_entries(session_id, entries)
    end

    session_id = "agent-session-" <> agent.agent_id

    session =
      start_owned!(
        runtime,
        scope,
        {Session,
         [
           session_id: session_id,
           agent_id: agent.agent_id,
           turn_dot: @turn_dot,
           start_heartbeat: false,
           signer: fn resource ->
             SignedRequest.sign(resource, agent.agent_id, agent.private_key)
           end,
           adapters: %{append_session_entries: append},
           config: %{
             "llm_provider" => "lm_studio",
             "llm_model" => "convergence-response",
             "stream" => false,
             "recover_session" => false,
             "tools" => []
           }
         ]}
      )

    :ok =
      Arbor.Agent.Registry.register(agent.agent_id, session, %{
        runtime: :arbor,
        model_config: %{runtime: :arbor},
        host_pid: session,
        module: Session,
        agent_id: agent.agent_id
      })

    defer(scope, fn -> Arbor.Agent.Registry.unregister(agent.agent_id) end)

    :sys.replace_state(SessionManager, fn state ->
      true = :ets.insert(SessionManager, {agent.agent_id, session})
      state
    end)

    defer(scope, fn ->
      :sys.replace_state(SessionManager, fn state ->
        :ets.delete(SessionManager, agent.agent_id)
        state
      end)

      :ok
    end)

    set_env(
      scope,
      :conversation_demo,
      :arbor_client_options,
      client_options(primary.agent_id, agent.agent_id, token)
    )

    set_env(scope, :arbor_voice, :desk_session_options, voice_options(observer, :complete))
    {:ok, %{durability: :node_restart}} = Arbor.Voice.BudgetLedger.readiness()

    baseline = Map.new(@voice_supervisors, &{&1, children(&1)})
    task_baseline = Map.new(@voice_task_supervisors, &{&1, task_children(&1)})

    unless Enum.all?(Map.values(baseline) ++ Map.values(task_baseline), &(MapSet.size(&1) == 0)),
      do: raise("fixture requires idle Voice supervisors")

    %{
      primary: primary,
      secondary: secondary,
      target: agent.agent_id,
      token: token,
      voice_token: voice_token,
      session: session,
      session_id: session_id,
      metrics: metrics,
      voice_baseline: baseline,
      voice_task_baseline: task_baseline,
      primary_cap: primary_cap,
      secondary_cap: secondary_cap,
      runtime: runtime,
      observer: observer,
      agent_task_baseline:
        Task.Supervisor.children(Arbor.Agent.Orchestration.TaskSupervisor) |> MapSet.new()
    }
  end

  def record(key, item) do
    metrics = Application.fetch_env!(:arbor_voice, :cross_surface_metrics)
    Agent.update(metrics, &Map.update!(&1, key, fn values -> values ++ [item] end))
  end

  def metrics(c), do: Agent.get(c.metrics, & &1)

  def client_options(caller, target, token),
    do: [
      caller: caller,
      target: target,
      proof_provider: fn _ -> {:ok, [session_token: token]} end,
      adapter_options: [page_limit: 1]
    ]

  def voice_options(observer, mode),
    do: [
      backend: Backend,
      backend_opts: [observer: observer, mode: mode],
      session_budget_ms: 30_000,
      daily_budget_ms: 120_000,
      resource_owner_opts: [close_timeout_ms: 5_000]
    ]

  def voice_mode(mode)
      when mode in [:complete, :consult, :hold, :remember_phrase, :recall_phrase] do
    # Fixed collaborators: this helper cannot enable a real provider or device.
    unless Application.get_env(:arbor_voice, :desk_multimedia_module) == Media,
      do: raise("scripted media fixture is not installed")

    Application.put_env(:arbor_voice, :desk_session_options, voice_options(self(), mode))
  end

  def record_voice(c, engagement_id) do
    admitted =
      Agent.get_and_update(c.metrics, fn
        %{closing: false} = state -> {true, %{state | admitting: state.admitting + 1}}
        state -> {false, state}
      end)

    if admitted do
      try do
        result =
          Arbor.Voice.start_desk_turn(c.secondary.agent_id, c.target,
            session_token: c.voice_token,
            expected_engagement_id: engagement_id,
            duration_ms: 100
          )

        case result do
          {:ok, id} -> Agent.update(c.metrics, &%{&1 | operations: &1.operations ++ [id]})
          _ -> :ok
        end

        result
      after
        Agent.update(c.metrics, &%{&1 | admitting: &1.admitting - 1})
      end
    else
      {:error, :fixture_closing}
    end
  end

  def desk_status(c, id) do
    if id in metrics(c).operations do
      result = Arbor.Voice.desk_turn_status(id)

      case result do
        {:ok, %{terminal: true}} ->
          Agent.update(c.metrics, &%{&1 | terminals: MapSet.put(&1.terminals, id)})

        _ ->
          :ok
      end

      result
    else
      {:error, :unknown_fixture_operation}
    end
  end

  def cancel_voice(c, id) do
    if id in metrics(c).operations,
      do: Arbor.Voice.cancel_desk_turn(id),
      else: {:error, :unknown_fixture_operation}
  end

  def history(c) do
    {:ok, page} =
      Arbor.Agent.conversation_history(c.primary.agent_id, c.target, session_token: c.token)

    page
  end

  def latest_command(c) do
    {:ok, page} =
      Arbor.Agent.conversation_events(c.primary.agent_id, c.target, 0, session_token: c.token)

    List.last(page.events).command
  end

  def completed!(c, id),
    do:
      await(fn ->
        case Arbor.Agent.conversation_command(c.primary.agent_id, c.target, id,
               session_token: c.token
             ) do
          {:ok, %{status: :completed} = command} -> {:ok, command}
          {:ok, %{status: status}} when status in [:admitted, :dispatch_started] -> :pending
          _ -> raise("unexpected fixture command state")
        end
      end)

  def desk_completed!(id),
    do:
      await(fn ->
        case desk_status(
               %{metrics: Application.fetch_env!(:arbor_voice, :cross_surface_metrics)},
               id
             ) do
          {:ok, %{terminal: true} = status} -> {:ok, status}
          {:ok, _} -> :pending
          _ -> raise("unexpected fixture Desk status")
        end
      end)

  def quiescent!(c),
    do: await(fn -> if voice_quiescent?(c), do: {:ok, :quiescent}, else: :pending end)

  defp voice_quiescent?(c) do
    Enum.all?(
      @voice_supervisors -- [Arbor.Voice.DeskSupervisor],
      &(children(&1) == c.voice_baseline[&1])
    ) and
      Enum.all?(@voice_task_supervisors, &(task_children(&1) == c.voice_task_baseline[&1])) and
      Registry.lookup(Arbor.Voice.Registry, :desk_active) == []
  end

  defp task_children(supervisor), do: Task.Supervisor.children(supervisor) |> MapSet.new()

  defp children(supervisor),
    do: DynamicSupervisor.which_children(supervisor) |> Enum.map(&elem(&1, 1)) |> MapSet.new()

  defp await(fun, attempts \\ 500)
  defp await(_fun, 0), do: raise("cross-surface operation did not converge within 10 seconds")

  defp await(fun, attempts) do
    case fun.() do
      {:ok, result} ->
        result

      :pending ->
        Process.sleep(20)
        await(fun, attempts - 1)
    end
  end

  defp human!(scope) do
    fixture =
      OIDCTestHelper.issue_identity(subject: "entrypoint-#{System.unique_integer([:positive])}")

    defer(scope, fixture.cleanup)
    :ok = Security.register_oidc_identity(fixture.identity, fixture.id_token, fixture.provider)
    defer(scope, fn -> Security.deregister_identity(fixture.identity.agent_id) end)

    fixture.identity
  end

  defp grant!(scope, principal, resource) do
    {:ok, cap} = Security.grant(principal: principal, resource: resource)
    defer(scope, fn -> revoke(cap.id) end)
    cap
  end

  defp link!(primary, secondary) do
    {:ok, proof} = IdentityAliasProof.sign(primary, {:link, secondary.agent_id, primary.agent_id})

    :ok =
      IdentityAliases.link(primary.agent_id, secondary.agent_id, primary.agent_id,
        signed_request: proof
      )
  end

  defp unlink(primary, secondary) do
    {:ok, proof} = IdentityAliasProof.sign(primary, {:unlink, secondary.agent_id})
    IdentityAliases.unlink(primary.agent_id, secondary.agent_id, signed_request: proof)
  end

  defp set_env(scope, app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    defer(scope, fn ->
      case previous do
        {:ok, old} -> Application.put_env(app, key, old)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp endpoint_options(overrides) do
    unless is_list(overrides) and Keyword.keyword?(overrides) and
             Enum.all?(Keyword.keys(overrides), &(&1 in [:server, :http, :url, :check_origin])),
           do: raise(ArgumentError, "closed fixture endpoint options required")

    base = [
      url: [host: "127.0.0.1"],
      server: false,
      adapter: Phoenix.Endpoint.Cowboy2Adapter,
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
      live_view: [signing_salt: "adapter-qualification"],
      pubsub_server: ConversationDemo.PubSub,
      render_errors: [formats: [html: ConversationDemo.ErrorHTML], layout: false],
      check_origin: false
    ]

    endpoint = Keyword.merge(base, overrides)

    if endpoint[:server] do
      http = endpoint[:http] || []
      port = http[:port]
      origins = ["http://127.0.0.1:#{port}", "http://localhost:#{port}"]

      unless http[:ip] == {127, 0, 0, 1} and is_integer(port) and port in 1024..65_535 and
               endpoint[:check_origin] == origins and
               endpoint[:url] == [host: "127.0.0.1", port: port],
             do:
               raise(ArgumentError, "interactive endpoint must bind loopback with exact origins")
    end

    endpoint
  end

  defp construct(fun) do
    scope = {__MODULE__, :construction, make_ref()}
    Process.put(scope, [])

    try do
      result = fun.(scope)
      Map.put(result, :cleanup, Process.delete(scope))
    catch
      kind, reason ->
        stack = __STACKTRACE__
        rollback = cleanup(Process.delete(scope) || [])

        if rollback == :ok,
          do: :erlang.raise(kind, reason, stack),
          else: raise("fixture startup failed and rollback remains incomplete")
    end
  end

  defp defer(scope, fun),
    do:
      Process.put(scope, [
        fun | Process.get(scope) || raise("fixture construction scope is missing")
      ])

  defp cleanup(callbacks) do
    Enum.reduce_while(callbacks, :ok, fn fun, :ok ->
      result =
        try do
          fun.()
        catch
          _, _ -> :failed
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, {:error, :fixture_cleanup_pending}}
    end)
  end

  defp start_owned!(runtime, scope, spec) do
    id = {__MODULE__, make_ref()}

    {:ok, pid} =
      Supervisor.start_child(
        runtime.supervisor,
        Supervisor.child_spec(spec, id: id, restart: :temporary)
      )

    defer(scope, fn ->
      case Supervisor.terminate_child(runtime.supervisor, id) do
        :ok ->
          case Supervisor.delete_child(runtime.supervisor, id) do
            :ok -> :ok
            {:error, :not_found} -> :ok
          end

        {:error, :not_found} ->
          :ok
      end
    end)

    pid
  end

  defp stop_apps(apps) do
    Enum.reduce_while(Enum.reverse(apps), :ok, fn app, :ok ->
      case Application.stop(app) do
        :ok -> {:cont, :ok}
        {:error, {:not_started, ^app}} -> {:cont, :ok}
        _ -> {:halt, {:error, :fixture_application_stop_failed}}
      end
    end)
  end

  defp revoke(id) do
    case Security.revoke(id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      _ -> {:error, :fixture_revocation_failed}
    end
  end

  defp close_desks(c) do
    Enum.reduce_while(metrics(c).operations, :ok, fn id, :ok ->
      result =
        case desk_status(c, id) do
          {:ok, %{terminal: true}} ->
            :ok

          {:error, :not_found} ->
            if MapSet.member?(metrics(c).terminals, id), do: :ok, else: :unproven

          {:ok, _} ->
            _ = cancel_voice(c, id)
            wait_until(fn -> match?({:ok, %{terminal: true}}, desk_status(c, id)) end)

          _ ->
            :unproven
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, {:error, :fixture_cleanup_pending}}
    end)
  end

  defp retire_desks(c) do
    Enum.reduce_while(metrics(c).operations, :ok, fn id, :ok ->
      result =
        case Registry.lookup(Arbor.Voice.Registry, {:desk, id}) do
          [] -> :ok
          [{pid, _}] -> DynamicSupervisor.terminate_child(Arbor.Voice.DeskSupervisor, pid)
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, {:error, :fixture_cleanup_pending}}
    end)
  end

  defp wait_until(fun, attempts \\ 500)
  defp wait_until(_fun, 0), do: {:error, :fixture_deadline}

  defp wait_until(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          wait_until(fun, attempts - 1)
        )
  end
end
