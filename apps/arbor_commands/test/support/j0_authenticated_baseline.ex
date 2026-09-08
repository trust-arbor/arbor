defmodule Arbor.Commands.J0AuthenticatedBaseline do
  @moduledoc false

  # Journey-local bootstrap. Intentionally not in test_helper.exs so the rest
  # of arbor_commands keeps its existing (narrow) boot.
  #
  # OTP applications started here are left running: `ensure_all_started/1` is
  # process-global, later files in the same arbor_commands BEAM may need them,
  # and `Application.stop/1` would race that shared tree. Test config uses
  # `start_children: false`, so Application start only brings empty supervisors.
  # Children this module adds are stopped in `stop_suite!/1` when this file
  # started them. Security's canonical test tree is restored via TestBootstrap.
  #
  # Cleanup bags and the TraceHub tracer are unlinked. ExUnit 1.19.5 test
  # processes exit :shutdown before on_exit, and start_supervised children die
  # at the same point, so a linked Agent cannot hold the final restore state.

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Arbor.Agent.{Lifecycle, SessionManager}
  alias Arbor.Agent.Registry, as: AgentRegistry

  alias Arbor.Commands.J0AuthenticatedBaseline.{
    CaptureAdapter,
    ClosedAdapter,
    Identities,
    SqliteEvidence,
    TraceHub
  }

  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.LLM.{Client, ConfigurationError, ProviderRegistry, Request}
  alias Arbor.Persistence.BufferedStore

  @preference "Please remember that my favorite midnight snack is pickled-mango-XYZZY-PLUGH-42."
  @preference_marker "pickled-mango-XYZZY-PLUGH-42"
  @preference_reply "Noted. I heard your midnight-snack preference."
  @follow_up "What snack do I like at midnight?"
  @follow_up_reply "I do not have a stored midnight-snack preference."
  @capture_provider "ollama"
  @capture_model "j0-capture-model"
  @unexpected_provider "openai"
  @unexpected_model "gpt-4o"
  @turn_timeout_ms 30_000
  @env_keys [
    {:arbor_security, :identity_verification},
    {:arbor_security, :strict_identity_mode},
    {:arbor_security, :capability_signing_required},
    {:arbor_security, :reflex_checking_enabled},
    {:arbor_security, :uri_registry_enforcement},
    {:arbor_security, :policy_enforcer_enabled},
    {:arbor_security, :approval_guard_enabled},
    {:arbor_security, :egress_gate_enforcing},
    {:arbor_security, :session_token_secret},
    {:arbor_memory, :embedding_service_enabled},
    {:arbor_ai, :session_turn_dot},
    {:arbor_agent, :orchestrator_session_module},
    {:arbor_persistence, Arbor.Persistence.Repo}
  ]

  def preference, do: @preference
  def preference_marker, do: @preference_marker
  def preference_reply, do: @preference_reply
  def follow_up, do: @follow_up
  def follow_up_reply, do: @follow_up_reply
  def capture_provider, do: @capture_provider
  def unexpected_provider, do: @unexpected_provider
  def unexpected_model, do: @unexpected_model

  def production_turn_dot! do
    cwd = File.cwd!()

    candidates = [
      Path.expand("apps/arbor_orchestrator/specs/pipelines/session/turn.dot", cwd),
      Path.expand("../arbor_orchestrator/specs/pipelines/session/turn.dot", cwd)
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil -> flunk("production turn.dot not found in #{inspect(candidates)}")
      path -> path
    end
  end

  def mock_turn_dot?(path \\ Application.get_env(:arbor_ai, :session_turn_dot))
  def mock_turn_dot?(nil), do: false

  def mock_turn_dot?(path) when is_binary(path) do
    expanded = Path.expand(path)
    production = Path.expand(production_turn_dot!())
    expanded != production and not String.ends_with?(expanded, "session/turn.dot")
  end

  def mock_turn_dot?(_), do: true

  def start_cleanup_owner!(initial) when is_map(initial) do
    # Unlinked: ExUnit 1.19.5 test/setup_all processes exit :shutdown before
    # on_exit, and start_supervised children die at the same point.
    case Agent.start(fn -> initial end) do
      {:ok, pid} -> pid
      {:error, reason} -> flunk("failed to start J0 cleanup owner: #{inspect(reason)}")
    end
  end

  def cleanup_owner_state(bag) when is_pid(bag) do
    case fetch_cleanup_owner_state(bag) do
      {:ok, state} ->
        state

      {:error, reason} ->
        flunk("J0 cleanup owner was created but is dead or unreadable: #{inspect(reason)}")
    end
  end

  def stop_cleanup_owner(bag) when is_pid(bag) do
    if Process.alive?(bag) do
      Agent.stop(bag, :normal, 5_000)
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  def stop_cleanup_owner(_), do: :ok

  def start_suite! do
    previous_home = System.get_env("ARBOR_HOME")
    env_snapshot = snapshot_env()
    previous_client = safe_default_client()

    bag =
      start_cleanup_owner!(%{
        root: nil,
        home: nil,
        database: nil,
        previous_home: previous_home,
        previous_client: previous_client,
        env_snapshot: env_snapshot,
        repo: nil,
        client: nil,
        started_apps: [],
        trust_children: [],
        agent_children: [],
        orchestrator_children: [],
        event_registry_started_here?: false
      })

    register_suite_cleanup!(bag)

    root = exclusive_root!()
    home = Path.join(root, "home")
    db = Path.join(root, "arbor_j0.sqlite3")
    File.mkdir_p!(home)
    remember(bag, :root, root)
    remember(bag, :home, home)
    remember(bag, :database, db)

    System.put_env("ARBOR_HOME", home)
    configure_security!()
    Application.put_env(:arbor_memory, :embedding_service_enabled, false)

    refute mock_turn_dot?(),
           "J0 must use production session/turn.dot; do not replace :session_turn_dot"

    _ = production_turn_dot!()

    started_apps = start_applications!()
    remember(bag, :started_apps, started_apps)
    :ok = Arbor.Security.TestBootstrap.start!()
    :ok = Arbor.Memory.TestBootstrap.start!()
    trust_children = start_trust!()
    remember(bag, :trust_children, trust_children)
    agent_children = start_agent_children!()
    remember(bag, :agent_children, agent_children)
    orchestrator_children = start_session_task_supervisor!()
    remember(bag, :orchestrator_children, orchestrator_children)
    event_registry_started_here? = start_event_registry!()
    remember(bag, :event_registry_started_here?, event_registry_started_here?)

    repo = SqliteEvidence.start_owned_repo!(db)
    remember(bag, :repo, repo)
    client = install_closed_llm_client!()
    remember(bag, :client, client)

    cleanup_owner_state(bag)
  end

  def stop_suite!(state) when is_map(state) do
    try do
      CaptureAdapter.clear_parent()
      ClosedAdapter.clear_parent()
    after
      try do
        SqliteEvidence.stop_owned_repo(Map.get(state, :repo))
      after
        try do
          stop_started_children(Map.get(state, :orchestrator_children, []))
        after
          try do
            stop_started_children(Map.get(state, :agent_children, []))
          after
            try do
              stop_started_children(Map.get(state, :trust_children, []))
            after
              try do
                maybe_stop_event_registry(Map.get(state, :event_registry_started_here?, false))
              after
                try do
                  maybe_restore_security_tree()
                after
                  try do
                    restore_default_client(Map.get(state, :previous_client, :unset))
                  after
                    try do
                      restore_env(Map.get(state, :env_snapshot, %{}))
                    after
                      try do
                        restore_home(Map.get(state, :previous_home, :unset))
                      after
                        remove_owned_root(Map.get(state, :root))
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    :ok
  end

  def stop_suite!(_), do: :ok

  def start_case!(parent) when is_pid(parent) do
    flush_mailbox()

    assert is_pid(alive_named(Arbor.Orchestrator.Session.TaskSupervisor)),
           "J0 turn tracing requires Arbor.Orchestrator.Session.TaskSupervisor; refusing Task.start fallback"

    bag =
      start_cleanup_owner!(%{
        grants: [],
        conversationalist: nil,
        control: nil,
        hub: nil
      })

    register_case_cleanup!(bag)

    CaptureAdapter.set_parent(parent)
    ClosedAdapter.set_parent(parent)

    owner = Identities.register_human_identity!("owner")
    conversant = Identities.register_human_identity!("conversant")
    refute owner.id == conversant.id

    conversationalist = create_conversationalist!("J0 Conversationalist", owner.id)
    remember(bag, :conversationalist, conversationalist)
    control = create_conversationalist!("J0 Control Conversationalist", owner.id)
    remember(bag, :control, control)
    refute conversationalist.agent_id == control.agent_id

    grants =
      grant_chat_and_execute!(conversationalist.agent_id, [owner.id, conversant.id]) ++
        grant_chat_and_execute!(control.agent_id, [owner.id, conversant.id])

    remember(bag, :grants, grants)

    # Trace Session.TaskSupervisor before any live Session exists so a turn
    # cannot start on an untraced start_child owner.
    hub =
      TraceHub.install!(
        parent,
        [conversationalist.agent_id, control.agent_id],
        []
      )

    remember(bag, :hub, hub)

    conversationalist_pid = start_live_session!(conversationalist)
    control_pid = start_live_session!(control)
    hub = TraceHub.trace_pids!(hub, [conversationalist_pid, control_pid])
    remember(bag, :hub, hub)

    %{
      owner: owner,
      conversant: conversant,
      conversationalist: conversationalist,
      control: control,
      conversationalist_pid: conversationalist_pid,
      control_pid: control_pid,
      hub: hub
    }
  end

  def send_authenticated!(human_id, agent_id, content) do
    token = Identities.session_token!(human_id)
    message = UserMessage.from_cli(content, nil, sender_id: human_id)

    Arbor.Agent.send_message(human_id, agent_id, message,
      session_token: token,
      timeout: @turn_timeout_ms
    )
  end

  def await_provider_request!(timeout_ms \\ 10_000) do
    receive do
      {:j0_provider_request, %Request{} = request} -> request
    after
      timeout_ms -> flunk("timed out waiting for captured provider request")
    end
  end

  def drain_provider_requests do
    drain_provider_requests([], :fast)
  end

  def request_transcript(%Request{messages: messages}) do
    messages
    |> Enum.map(&message_content/1)
    |> Enum.join("\n")
  end

  def newest_user_content(%Request{messages: messages}) do
    messages
    |> Enum.filter(&user_message?/1)
    |> List.last()
    |> message_content()
  end

  def session_id!(agent_id) do
    assert {:ok, pid} = SessionManager.get_session(agent_id)
    state = Arbor.Orchestrator.Session.get_state(pid)
    session_id = Map.get(state, :session_id)
    assert is_binary(session_id) and session_id != "", "live session has no session_id"
    session_id
  end

  def engagement_id!(agent_id, human_id) do
    assert {:ok, engagement} = Arbor.Comms.resolve_user_engagement(agent_id, human_id)
    engagement.id
  end

  def complete_unexpected_provider!(client) do
    request = %Request{
      provider: @unexpected_provider,
      model: @unexpected_model,
      messages: [Arbor.LLM.Message.new(:user, "should not escape")]
    }

    Client.complete(client, request)
  end

  def inspect_index(agent_id, query) do
    case Arbor.Memory.recall(agent_id, query) do
      {:ok, results} -> {:ok, results}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_index_result, other}}
    end
  end

  def assert_no_escapes!(hub) do
    events = TraceHub.drain(hub)
    mailbox = flush_escape_mailbox()
    escapes = Enum.filter(events ++ mailbox, &TraceHub.escape_event?/1)

    assert escapes == [],
           "external provider/ACP escaped the hermetic harness: #{inspect(escapes)}"

    events
  end

  defp drain_provider_requests(acc, :fast) do
    receive do
      {:j0_provider_request, %Request{} = request} ->
        drain_provider_requests([request | acc], :fast)
    after
      0 -> drain_provider_requests(acc, :quiet)
    end
  end

  defp drain_provider_requests(acc, :quiet) do
    receive do
      {:j0_provider_request, %Request{} = request} ->
        drain_provider_requests([request | acc], :fast)
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp message_content(%{content: content}) when is_binary(content), do: content
  defp message_content(%{"content" => content}) when is_binary(content), do: content
  defp message_content(other), do: inspect(other)

  defp user_message?(%{role: role}) when role in [:user, "user"], do: true
  defp user_message?(%{"role" => role}) when role in [:user, "user"], do: true
  defp user_message?(_), do: false

  defp flush_mailbox do
    receive do
      {:j0_provider_request, _} -> flush_mailbox()
      {:j0_outbound_denied, _, _, _} -> flush_mailbox()
      {:j0_dispatched_recall, _, _, _} -> flush_mailbox()
      {:j0_req_llm_escape, _, _} -> flush_mailbox()
      {:j0_acp_escape, _, _} -> flush_mailbox()
      {:j0_llm_client_dispatch, _, _} -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp flush_escape_mailbox(acc \\ []) do
    receive do
      {:j0_req_llm_escape, _, _} = msg -> flush_escape_mailbox([msg | acc])
      {:j0_acp_escape, _, _} = msg -> flush_escape_mailbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp remember(bag, key, value) do
    Agent.update(bag, &Map.put(&1, key, value))
    value
  end

  defp register_suite_cleanup!(bag) do
    on_exit(fn ->
      {state, owner_failure} = read_created_cleanup_owner(bag)

      try do
        stop_suite!(state)
      after
        stop_cleanup_owner(bag)
      end

      if owner_failure do
        flunk(
          "J0 suite cleanup owner was created but dead/unreadable before on_exit: #{inspect(owner_failure)}"
        )
      end
    end)
  end

  defp register_case_cleanup!(bag) do
    on_exit(fn ->
      {state, owner_failure} = read_created_cleanup_owner(bag)

      try do
        cleanup_case!(state)
      after
        stop_cleanup_owner(bag)
      end

      if owner_failure do
        flunk(
          "J0 case cleanup owner was created but dead/unreadable before on_exit: #{inspect(owner_failure)}"
        )
      end
    end)
  end

  defp read_created_cleanup_owner(bag) when is_pid(bag) do
    case fetch_cleanup_owner_state(bag) do
      {:ok, state} -> {state, nil}
      {:error, reason} -> {%{}, reason}
    end
  end

  defp fetch_cleanup_owner_state(bag) when is_pid(bag) do
    if Process.alive?(bag) do
      try do
        {:ok, Agent.get(bag, & &1, 5_000)}
      catch
        :exit, reason -> {:error, {:unreadable, bag, reason}}
      end
    else
      {:error, {:dead, bag}}
    end
  end

  defp cleanup_case!(state) when is_map(state) do
    hub = Map.get(state, :hub)
    {events, drain_failure} = drain_created_hub(hub)

    try do
      :ok
    after
      try do
        case hub do
          nil -> :ok
          _ -> TraceHub.uninstall(hub)
        end
      after
        try do
          stop_case_agent(Map.get(state, :conversationalist))
          stop_case_agent(Map.get(state, :control))
        after
          Enum.each(List.wrap(Map.get(state, :grants)), fn cap ->
            _ = Arbor.Security.revoke(cap.id)
          end)
        end
      end
    end

    if drain_failure do
      flunk(
        "created TraceHub could not be drained (not a never-created hub): #{inspect(drain_failure)}"
      )
    end

    escapes = Enum.filter(List.wrap(events), &TraceHub.escape_event?/1)

    if escapes != [] do
      flunk("external provider/ACP escaped the hermetic harness: #{inspect(escapes)}")
    end

    :ok
  end

  defp cleanup_case!(_), do: :ok

  # nil = never installed. A %TraceHub{} was created and must fail closed if
  # its tracer is dead or unreadable; do not convert that into an empty drain.
  defp drain_created_hub(nil), do: {[], nil}

  defp drain_created_hub(%TraceHub{tracer: tracer} = hub) when is_pid(tracer) do
    if Process.alive?(tracer) do
      try do
        {TraceHub.drain(hub), nil}
      rescue
        exception ->
          {[], {:drain_failed, exception}}
      catch
        kind, reason ->
          {[], {:drain_failed, {kind, reason}}}
      end
    else
      {[], {:created_tracer_dead, tracer}}
    end
  end

  defp drain_created_hub(%TraceHub{} = hub), do: {[], {:created_tracer_invalid, hub}}
  defp drain_created_hub(other), do: {[], {:unexpected_hub, other}}

  defp stop_case_agent(%{agent_id: agent_id}) do
    stop_live_session(agent_id)
    _ = Arbor.Memory.cleanup_for_agent(agent_id)
    _ = Arbor.Security.deregister_identity(agent_id)
    :ok
  end

  defp stop_case_agent(_), do: :ok

  defp exclusive_root! do
    parent = Path.join(System.tmp_dir!(), "arbor-j0-authenticated-baseline")
    File.mkdir_p!(parent)
    token = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    root = Path.join(parent, "j0-" <> token)
    File.mkdir!(root)
    root
  end

  defp start_applications! do
    apps = [
      :arbor_kernel_runtime,
      :arbor_security,
      :arbor_trust,
      :arbor_persistence,
      :arbor_memory,
      :arbor_comms,
      :arbor_llm,
      :arbor_actions,
      :arbor_ai,
      :arbor_orchestrator,
      :arbor_agent
    ]

    Enum.flat_map(apps, fn app ->
      case Application.ensure_all_started(app) do
        {:ok, started} -> started
        {:error, {^app, reason}} -> flunk("failed to start #{app}: #{inspect(reason)}")
        {:error, reason} -> flunk("failed to start #{app}: #{inspect(reason)}")
      end
    end)
  end

  defp start_session_task_supervisor! do
    name = Arbor.Orchestrator.Session.TaskSupervisor
    spec = session_task_supervisor_spec(name)

    case alive_named(name) do
      pid when is_pid(pid) ->
        [{:task_supervisor, :preexisting, name, pid, false}]

      nil ->
        case alive_named(Arbor.Orchestrator.Supervisor) do
          sup when is_pid(sup) ->
            start_task_supervisor_under!(sup, spec, name)

          nil ->
            start_task_supervisor_standalone!(name)
        end
    end
  end

  defp session_task_supervisor_spec(name) do
    Supervisor.child_spec({Task.Supervisor, name: name}, id: name)
  end

  defp start_task_supervisor_under!(sup, spec, name) do
    case Supervisor.start_child(sup, spec) do
      {:ok, pid} ->
        [{:task_supervisor, sup, name, pid, true}]

      {:error, {:already_started, pid}} ->
        if Process.alive?(pid) do
          [{:task_supervisor, sup, name, pid, false}]
        else
          flunk("#{inspect(name)} is registered but dead")
        end

      {:error, :already_present} ->
        flunk(
          "#{inspect(name)} already has a child spec but is not available; refusing to restart a preexisting child"
        )

      {:error, reason} ->
        flunk("failed to start {Task.Supervisor, name: #{inspect(name)}}: #{inspect(reason)}")
    end
  end

  defp start_task_supervisor_standalone!(name) do
    case Task.Supervisor.start_link(name: name) do
      {:ok, pid} ->
        [{:task_supervisor, :standalone, name, pid, true}]

      {:error, {:already_started, pid}} ->
        if Process.alive?(pid) do
          [{:task_supervisor, :preexisting, name, pid, false}]
        else
          flunk("#{inspect(name)} is registered but dead")
        end

      {:error, reason} ->
        flunk("failed to start {Task.Supervisor, name: #{inspect(name)}}: #{inspect(reason)}")
    end
  end

  defp start_event_registry! do
    case alive_named(Arbor.Orchestrator.EventRegistry) do
      pid when is_pid(pid) ->
        false

      nil ->
        case Elixir.Registry.start_link(keys: :duplicate, name: Arbor.Orchestrator.EventRegistry) do
          {:ok, _} ->
            true

          {:error, {:already_started, pid}} ->
            if Process.alive?(pid), do: false, else: flunk("EventRegistry is registered but dead")
        end
    end
  end

  defp maybe_stop_event_registry(true) do
    case alive_named(Arbor.Orchestrator.EventRegistry) do
      pid when is_pid(pid) ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp maybe_stop_event_registry(_), do: :ok

  defp start_trust! do
    supervisor =
      alive_named(Arbor.Trust.ApplicationSupervisor) ||
        flunk("Arbor.Trust.ApplicationSupervisor is not running")

    Enum.map(
      [
        {Arbor.Trust.Store, [persistence: :memory]},
        {Arbor.Trust.Manager,
         [circuit_breaker: false, decay: false, event_store: false, persistence: :memory]}
      ],
      &ensure_supervisor_child(supervisor, &1)
    )
  end

  defp start_agent_children! do
    supervisor =
      alive_named(Arbor.Agent.AppSupervisor) ||
        flunk("Arbor.Agent.AppSupervisor is not running")

    profiles =
      Supervisor.child_spec(
        {BufferedStore, name: :arbor_agent_profiles, backend: nil, write_mode: :sync},
        id: :arbor_agent_profiles
      )

    Enum.map(
      [
        {Elixir.Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry},
        {Elixir.Registry, keys: :unique, name: Arbor.Agent.ReasoningLoopRegistry},
        profiles,
        AgentRegistry,
        Arbor.Agent.SessionManager,
        Arbor.Agent.Supervisor
      ],
      &ensure_supervisor_child(supervisor, &1)
    )
  end

  defp ensure_supervisor_child(supervisor, child) do
    spec = Supervisor.child_spec(child, [])

    started_here? =
      case Supervisor.start_child(supervisor, spec) do
        {:ok, _pid} -> true
        {:error, {:already_started, _pid}} -> false
        {:error, :already_present} -> false
        {:error, reason} -> flunk("failed to start #{inspect(spec.id)}: #{inspect(reason)}")
      end

    {supervisor, spec.id, started_here?}
  end

  defp stop_started_children(children) do
    Enum.each(children, fn
      {:task_supervisor, :standalone, name, pid, true} ->
        stop_owned_task_supervisor(name, pid)

      {:task_supervisor, sup, id, pid, true} when is_pid(sup) ->
        if is_pid(pid) and Process.whereis(id) == pid do
          _ = Supervisor.terminate_child(sup, id)
          _ = Supervisor.delete_child(sup, id)
        end

        :ok

      {:task_supervisor, _origin, _name, _pid, false} ->
        :ok

      {supervisor, id, true} ->
        _ = Supervisor.terminate_child(supervisor, id)
        _ = Supervisor.delete_child(supervisor, id)
        :ok

      _ ->
        :ok
    end)
  end

  defp stop_owned_task_supervisor(name, pid) when is_pid(pid) do
    current = Process.whereis(name)

    if current == pid and Process.alive?(pid) do
      try do
        Supervisor.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  defp stop_owned_task_supervisor(_, _), do: :ok

  defp install_closed_llm_client! do
    adapters =
      (ProviderRegistry.list() ++ ["acp", @unexpected_provider])
      |> Enum.uniq()
      |> Map.new(&{&1, ClosedAdapter})
      |> Map.put(@capture_provider, CaptureAdapter)

    deny_unallowed = fn request, next ->
      parent = :persistent_term.get({CaptureAdapter, :parent}, nil)

      if is_pid(parent) do
        send(parent, {:j0_llm_client_dispatch, request.provider, request.model})
      end

      if request.provider == @capture_provider do
        next.(request)
      else
        if is_pid(parent) do
          send(parent, {:j0_outbound_denied, request.provider, request.model, request})
        end

        {:error, :outbound_denied}
      end
    end

    client =
      Client.new(
        default_provider: @capture_provider,
        adapters: adapters,
        model_catalog: %{},
        middleware: [deny_unallowed]
      )

    :ok = Client.set_default_client(client)
    client
  end

  defp safe_default_client do
    Client.default_client()
  rescue
    ConfigurationError -> nil
  end

  defp create_conversationalist!(name, owner_id) do
    assert {:ok, profile, identity} =
             Lifecycle.create(name,
               template: "conversationalist",
               principal_id: owner_id,
               return_identity: true,
               memory_opts: [index_enabled: true, graph_enabled: true]
             )

    %{
      agent_id: profile.agent_id,
      profile: profile,
      identity: identity,
      signer: fn resource ->
        Arbor.Contracts.Security.SignedRequest.sign(
          resource,
          identity.agent_id,
          identity.private_key
        )
      end
    }
  end

  defp grant_chat_and_execute!(agent_id, human_ids) do
    agent_grants =
      for resource <- [
            "arbor://orchestrator/execute",
            "arbor://orchestrator/execute/compute",
            "arbor://orchestrator/execute/llm_query",
            "arbor://orchestrator/execute/transform",
            "arbor://memory/read/#{agent_id}",
            "arbor://memory/write/#{agent_id}",
            "arbor://memory/search/#{agent_id}"
          ] do
        Identities.grant!(agent_id, resource)
      end

    human_grants =
      for human_id <- human_ids do
        Identities.grant!(human_id, Identities.chat_resource(agent_id))
      end

    agent_grants ++ human_grants
  end

  defp start_live_session!(%{agent_id: agent_id, signer: signer}) do
    assert {:ok, session_pid} =
             SessionManager.ensure_session(agent_id,
               provider: :ollama,
               model: @capture_model,
               runtime: :arbor,
               stream: false,
               start_heartbeat: false,
               tools: [],
               signer: signer,
               fallback_chain: [],
               context_management: :none
             )

    assert :ok =
             AgentRegistry.register(agent_id, session_pid, %{
               runtime: :arbor,
               model_config: %{runtime: :arbor, provider: :ollama, model: @capture_model},
               host_pid: session_pid,
               module: Arbor.Orchestrator.Session,
               agent_id: agent_id
             })

    session_pid
  end

  defp stop_live_session(agent_id) do
    _ = AgentRegistry.unregister(agent_id)
    _ = SessionManager.stop_session(agent_id)
    :ok
  catch
    _, _ -> :ok
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
      "j0-authenticated-baseline-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp snapshot_env do
    Map.new(@env_keys, fn {app, key} -> {{app, key}, Application.fetch_env(app, key)} end)
  end

  defp restore_env(snapshot) when is_map(snapshot) do
    Enum.each(snapshot, fn
      {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
      {{app, key}, :error} -> Application.delete_env(app, key)
    end)
  end

  defp restore_env(_), do: :ok

  defp restore_home(:unset), do: :ok
  defp restore_home(nil), do: System.delete_env("ARBOR_HOME")
  defp restore_home(value) when is_binary(value), do: System.put_env("ARBOR_HOME", value)
  defp restore_home(_), do: :ok

  defp restore_default_client(%Client{} = client), do: Client.set_default_client(client)
  defp restore_default_client(nil), do: Client.clear_default_client()
  defp restore_default_client(:unset), do: :ok
  defp restore_default_client(_), do: Client.clear_default_client()

  defp maybe_restore_security_tree do
    if is_pid(alive_named(Arbor.Security.Supervisor)) do
      Arbor.Security.TestBootstrap.restore_supervised_tree!()
    else
      :ok
    end
  end

  # OTP unregisters a dead process's name. Do not Process.unregister/1 from a
  # sampled dead pid: a replacement can acquire the name between the check and
  # unregister. Treat a dead sample as absent; fail closed if an owned child
  # is gone rather than evicting whoever holds the name now.
  defp alive_named(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: nil

      _ ->
        nil
    end
  end

  defp remove_owned_root(root) when is_binary(root) and root != "" do
    File.rm_rf(root)
    :ok
  end

  defp remove_owned_root(_), do: :ok
end
