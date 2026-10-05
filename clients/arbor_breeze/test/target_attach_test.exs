defmodule ArborBreeze.TargetAttachTest.Client do
  def request(operation, args) do
    Agent.get_and_update(__MODULE__, fn state ->
      send(state.observer, {:navigation_request, operation, args})

      result =
        case operation do
          :list ->
            {:ok, %{agents: state.rows, truncated: state.truncated}}

          :resolve ->
            {:ok, Map.get(state.targets, List.last(args), List.last(args))}

          :start_login ->
            {:ok,
             %Arbor.Client.Login.Pending{
               handle: "private_handle",
               verification_uri: "https://example.test/review",
               user_code: "PUBLIC-CODE",
               expires_in: 30,
               interval: 1
             }}

          :poll_login ->
            {:ok,
             %Arbor.Client.Login.Session{
               principal: state.principal,
               target: Map.get(state, :poll_target, state.login_target),
               credential: "private_credential",
               lifetime: :connection
             }}

          :cancel_login ->
            Map.get(state, :cancel_reply, :ok)

          :logout ->
            Map.get(state, :logout_reply, :ok)
        end

      next =
        if operation == :start_login,
          do: Map.put(state, :login_target, List.last(args)),
          else: state

      {result, next}
    end)
  end

  def list_agents(identity, url), do: request(:list, [identity.agent_id, url])

  def resolve_agent(identity, url, token) do
    state = Agent.get(__MODULE__, & &1)

    if Map.get(state, :hold_resolve, false) do
      send(state.observer, {:resolve_blocked, self()})

      receive do
        :release_resolve -> :ok
      after
        5_000 -> :ok
      end
    end

    request(:resolve, [identity.agent_id, url, token])
  end

  def start_login(url, target) do
    state = Agent.get(__MODULE__, & &1)

    if Map.get(state, :hold_login, false) do
      send(state.observer, {:login_blocked, self()})

      receive do
        :release_login -> :ok
      after
        5_000 -> :ok
      end
    end

    request(:start_login, [url, target])
  end

  def poll_login(url, _handle) do
    state = Agent.get(__MODULE__, & &1)

    if Map.get(state, :hold_poll, false) do
      send(state.observer, {:poll_blocked, self()})

      receive do
        :release_poll -> :ok
      after
        5_000 -> :ok
      end
    end

    request(:poll_login, [url])
  end

  def cancel_login(url, _handle), do: request(:cancel_login, [url])
  def logout(url, session), do: request(:logout, [url, session.target, session.principal])
end

defmodule ArborBreeze.TargetAttachTest do
  use ExUnit.Case, async: false
  alias ArborBreeze.{Controller, Hints, View}
  alias ArborBreeze.TargetAttachTest.Client
  alias ArborBreeze.ViewTest.Host
  @url "http://127.0.0.1:4321"
  @a "agent_fixture"
  @b "agent_other"

  setup do
    observer = self()

    {:ok, client} =
      Agent.start_link(
        fn ->
          %{
            observer: observer,
            rows: [row(@a), row(@b)],
            truncated: true,
            targets: %{"Cedar 東京" => @b},
            principal: "human_fixture",
            login_target: nil
          }
        end,
        name: Client
      )

    {:ok, host} = Host.start(2)

    path =
      Path.join(
        System.fetch_env!("ARBOR_HOME"),
        "hint-#{System.unique_integer([:positive])}.json"
      )

    factory = fn opts, owner ->
      if Agent.get(Client, &Map.get(&1, :hold_open, false)) do
        send(observer, {:open_blocked, self(), owner})

        receive do
          :release_open -> :ok
        after
          5_000 -> :ok
        end
      end

      target = opts[:target]
      send(observer, {:binding_open, target, opts[:session] && opts[:session].principal})

      options =
        Host.options(host)
        |> Keyword.put(:target, target)
        |> Keyword.put(:poll_interval_ms, 5_000)

      options =
        Keyword.put(options, :disconnect, fn ->
          send(observer, {:binding_closed, target, self()})
          :ok
        end)

      {:ok, nil, options}
    end

    on_exit(fn ->
      if Process.alive?(host), do: Agent.stop(host)
      if Process.alive?(client), do: Agent.stop(client)
      File.rm(path)
    end)

    %{host: host, path: path, factory: factory}
  end

  defp row(id),
    do: %{
      agent_id: id,
      display_name: "Café 東京 " <> id,
      running: false,
      template: "test",
      model: "fixture"
    }

  defp options(context, mode, target) do
    workspace = [gateway_url: @url, client: Client, hint_path: context.path]

    workspace =
      if mode == :signed,
        do:
          Keyword.put(workspace, :identity, %{
            agent_id: "agent_operator",
            private_key: :binary.copy(<<1>>, 32)
          }),
        else: workspace

    workspace = if target, do: Keyword.put(workspace, :target, target), else: workspace
    [workspace_options: workspace, gateway_options: workspace, binding_factory: context.factory]
  end

  defp start_native(context, mode, target \\ nil) do
    {:ok, controller} = Controller.start(options(context, mode, target))
    session = Breeze.Test.start!(View, size: {110, 35}, start_opts: [controller: controller])

    on_exit(fn ->
      try do
        Breeze.Test.stop(session)
      catch
        :exit, {:noproc, _} -> :ok
      end

      Controller.close(controller)
    end)

    {controller, session}
  end

  defp assigns(session), do: Breeze.Test.metadata(session).assigns
  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          eventually(fun, attempts - 1)
        )
  end

  defp attach(session, token),
    do: Breeze.Test.event(session, "chat:send", %{value: "/attach " <> token})

  defp ready_target(session, target) do
    eventually(fn -> target_ready?(assigns(session).snapshot, target) end)
  end

  defp target_ready?(snapshot, target),
    do:
      snapshot.connected and snapshot.navigation.bound and not snapshot.navigation.directory and
        snapshot.navigation.target == target and not snapshot.busy and
        not snapshot.navigation.busy

  defp native_draft(session, pasted, keys) do
    assert {:ok, _} = Breeze.Test.element(session, "draft")
    Breeze.Test.focus(session, "draft")
    Breeze.Test.paste(session, pasted)
    Enum.each(keys, &Breeze.Test.input(session, &1))
    text = pasted <> Enum.join(keys)
    assert assigns(session).editor.draft == text

    assert Breeze.Test.metadata(session).implicit_state["draft"] |> elem(1) |> Map.fetch!(:value) ==
             text
  end

  test "no-agent signed directory and remembered target require explicit native attach",
       context do
    Hints.save(context.path, @url, @b)
    {_controller, session} = start_native(context, :signed)
    assert assigns(session).target_input == @b
    refute_receive {:binding_open, _, _}, 50
    refute_receive {:navigation_request, :resolve, _}, 50
    Breeze.Test.input(session, "F2")
    eventually(fn -> length(assigns(session).snapshot.navigation.rows) == 2 end)
    frame = Breeze.Test.render_text!(session)
    assert frame =~ "Directory truncated"
    assert frame =~ "Café 東京"
    Breeze.Test.focus(session, "targets")
    Breeze.Test.input(session, "ArrowDown")
    Breeze.Test.input(session, "Enter")
    eventually(fn -> assigns(session).snapshot.connected end)
    assert_receive {:navigation_request, :resolve, ["agent_operator", @url, @a]}
    assert_receive {:binding_open, @a, nil}
    assert assigns(session).snapshot.review_path == "/conversation/" <> @a
  end

  test "target switch closes the old owner, ignores late frames and restores only scoped unsubmitted drafts",
       context do
    {controller, session} = start_native(context, :signed, @a)
    ready_target(session, @a)
    native_draft(session, "draft A ", ["東", "京"])
    attach(session, "Cedar 東京")
    assert_receive {:binding_closed, @a, old_connection}, 1_000

    ready_target(session, @b)

    refute Process.alive?(old_connection)
    assert assigns(session).editor.draft == ""
    assert_receive {:binding_open, @b, nil}
    stale = %{assigns(session).snapshot | error: "late old private frame"}
    send(controller, {:conversation_updated, old_connection, stale})
    native_draft(session, "draft B caf", ["é"])
    attach(session, @a)
    ready_target(session, @a)

    assert assigns(session).editor.draft == "draft A 東京"
    refute Breeze.Test.render_text!(session) =~ "late old private frame"
    attach(session, @b)
    ready_target(session, @b)

    assert assigns(session).editor.draft == "draft B café"
    assert {:ok, _} = Breeze.Test.element(session, "draft")

    assert Breeze.Test.metadata(session).implicit_state["draft"] |> elem(1) |> Map.fetch!(:value) ==
             "draft B café"
  end

  test "native target readiness is an atomic bound snapshot; detached input cannot name a draft",
       context do
    {_controller, session} = start_native(context, :signed, @a)
    ready_target(session, @a)
    native_draft(session, "parked A ", ["東", "京"])
    old = assigns(session).snapshot
    Agent.update(Client, &Map.put(&1, :hold_open, true))
    attach(session, @b)
    assert_receive {:open_blocked, worker, _owner}, 1_000

    eventually(fn ->
      snapshot = assigns(session).snapshot
      snapshot.navigation.target == @b and not snapshot.navigation.bound
    end)

    detached = assigns(session).snapshot
    # Two reads from opposite sides of detach falsely satisfy the old predicate.
    assert old.connected and detached.navigation.target == @b
    refute target_ready?(detached, @b)
    refute detached.connected
    assert {:error, {:element_not_found, "draft"}} = Breeze.Test.element(session, "draft")
    assert {:ok, _} = Breeze.Test.element(session, "target")
    Agent.update(Client, &Map.put(&1, :hold_open, false))
    send(worker, :release_open)
    ready_target(session, @b)
    native_draft(session, "parked B caf", ["é"])
    attach(session, @a)
    ready_target(session, @a)
    assert assigns(session).editor.draft == "parked A 東京"
    attach(session, @b)
    ready_target(session, @b)
    assert assigns(session).editor.draft == "parked B café"
    assert {:ok, _} = Breeze.Test.element(session, "draft")
    refute Enum.any?(Host.calls(context.host), &(&1.operation == :submit))
  end

  test "an uncertain request blocks attach and preserves same ID until explicit reconciliation",
       context do
    {_controller, session} = start_native(context, :signed, @a)
    eventually(fn -> assigns(session).snapshot.connected end)
    Host.mode(context.host, :uncertain_once)
    Breeze.Test.event(session, "chat:send", %{value: "uncertain original"})

    eventually(fn ->
      assigns(session).snapshot.pending_id != nil and not assigns(session).snapshot.busy
    end)

    id = assigns(session).snapshot.pending_id
    Breeze.Test.event(session, "chat:draft", %{value: "newer draft"})
    attach(session, @b)
    assert assigns(session).snapshot.pending_id == id
    assert assigns(session).editor.draft == "newer draft"
    assert Breeze.Test.render_text!(session) =~ "Finish or reconcile"
    refute_receive {:navigation_request, :resolve, _}, 50
    refute_receive {:binding_closed, @a, _}, 50
    Breeze.Test.event(session, "chat:send", %{value: "/retry"})
    eventually(fn -> assigns(session).snapshot.pending_id == nil end)
    attach(session, @b)

    eventually(fn ->
      assigns(session).snapshot.connected and assigns(session).snapshot.navigation.target == @b
    end)

    assert Enum.count(Host.calls(context.host), &(&1.operation == :submit and &1.input.id == id)) ==
             1
  end

  test "busy host observation refuses switching; stale directory generations never resolve a target",
       context do
    {controller, session} = start_native(context, :signed, @a)
    eventually(fn -> assigns(session).snapshot.connected end)
    Agent.update(context.host, &%{&1 | hold: :window})
    Breeze.Test.input(session, "F3")
    assert_receive {:native_host_blocked, :window, worker}
    attach(session, @b)
    refute_receive {:navigation_request, :resolve, _}, 50
    send(worker, :release_host)
    eventually(fn -> not assigns(session).snapshot.busy end)
    old = assigns(session).snapshot.navigation.generation
    Breeze.Test.input(session, "F2")
    eventually(fn -> not assigns(session).snapshot.navigation.busy end)
    Breeze.Test.event(session, "targets:select", %{value: "#{old}:#{@b}"})
    Breeze.Test.focus(session, "targets")
    Breeze.Test.input(session, "Enter")
    refute_receive {:navigation_request, :resolve, _}, 50

    task =
      Task.async(fn -> Controller.act(controller, :attach, %{target: @b, generation: old}) end)

    assert Task.await(task) == {:error, :not_surface_owner}
    refute_receive {:binding_closed, @a, _}, 50
  end

  test "human target changes require a fresh exact browser login and retire the prior lease",
       context do
    {_controller, session} = start_native(context, :human)
    Breeze.Test.input(session, "F2")
    refute_receive {:navigation_request, :list, _}, 50
    attach(session, "Cedar 東京")
    assert Breeze.Test.render_text!(session) =~ "exact agent ID"
    refute_receive {:navigation_request, :start_login, _}, 50
    attach(session, @a)
    assert_receive {:navigation_request, :start_login, [@url, @a]}, 1_000
    eventually(fn -> assigns(session).snapshot.navigation.sign_in != nil end)
    display = inspect(assigns(session).snapshot)
    assert display =~ "PUBLIC-CODE"
    refute display =~ "private_handle"
    refute display =~ "private_credential"
    eventually(fn -> assigns(session).snapshot.connected end)
    attach(session, @b)
    assert_receive {:binding_closed, @a, _}, 1_000
    assert_receive {:navigation_request, :logout, [@url, @a, "human_fixture"]}, 1_000
    assert_receive {:navigation_request, :start_login, [@url, @b]}, 1_000

    eventually(fn ->
      assigns(session).snapshot.connected and assigns(session).snapshot.navigation.target == @b
    end)

    assert_receive {:binding_open, @b, "human_fixture"}
    refute_receive {:navigation_request, :resolve, _}, 50
  end

  test "access invalidation clears per-target drafts and native target selection remains literal",
       context do
    Agent.update(Client, &%{&1 | rows: [%{row(@b) | display_name: "evil\e]52;c;private\a café"}]})
    {_controller, session} = start_native(context, :signed, @a)
    eventually(fn -> assigns(session).snapshot.connected end)
    Breeze.Test.event(session, "chat:draft", %{value: "private draft"})
    attach(session, @b)

    eventually(fn ->
      assigns(session).snapshot.connected and assigns(session).snapshot.navigation.target == @b
    end)

    Host.mode(context.host, :denied)
    Breeze.Test.input(session, "F3")
    eventually(fn -> assigns(session).snapshot.private_cleared end)
    assert assigns(session).drafts.values == %{}
    Host.mode(context.host, :normal)
    Breeze.Test.input(session, "F2")
    eventually(fn -> not assigns(session).snapshot.navigation.busy end)
    raw = Breeze.Test.render!(session)
    refute raw =~ "\e]52;c;private"
    assert Breeze.Test.render_text!(session) =~ "\\u001B]52;c;private\\u0007"
    attach(session, @a)

    eventually(fn ->
      assigns(session).snapshot.connected and assigns(session).snapshot.navigation.target == @a
    end)

    assert assigns(session).editor.draft == ""
  end

  test "unconfirmed old cleanup prevents every replacement binding", context do
    opts = options(context, :signed, @a) |> Keyword.put(:on_close, fn -> {:error, :timeout} end)
    {:ok, controller} = Controller.start(opts)
    session = Breeze.Test.start!(View, size: {110, 35}, start_opts: [controller: controller])
    on_exit(fn -> Controller.close(controller) end)
    eventually(fn -> assigns(session).snapshot.connected end)
    attach(session, @b)
    eventually(fn -> assigns(session).snapshot.navigation.notice == :cleanup_unconfirmed end)
    assert_receive {:binding_closed, @a, old}
    refute Process.alive?(old)
    refute_receive {:binding_open, @b, _}, 50
    attach(session, @b)
    refute_receive {:binding_open, @b, _}, 50
    assert Breeze.Test.render_text!(session) =~ "Finish or reconcile"
    Breeze.Test.stop(session)
  end

  test "closing during target resolution kills its exact worker and retains no replacement owner",
       context do
    {controller, session} = start_native(context, :signed, @a)
    eventually(fn -> assigns(session).snapshot.connected end)
    Agent.update(Client, &Map.put(&1, :hold_resolve, true))
    attach(session, @b)
    assert_receive {:resolve_blocked, worker}, 1_000
    ref = Process.monitor(worker)
    owner_ref = Process.monitor(controller)
    Breeze.Test.stop(session)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^owner_ref, :process, ^controller, :normal}, 1_000
    assert_receive {:binding_closed, @a, _}, 1_000
    send(worker, :release_resolve)
    refute_receive {:binding_open, @b, _}, 50
  end

  test "closing pending human login cancels the exact private handle; mismatched target never binds",
       context do
    {controller, session} = start_native(context, :human)
    attach(session, @a)
    eventually(fn -> assigns(session).snapshot.navigation.sign_in != nil end)
    ref = Process.monitor(controller)
    Breeze.Test.stop(session)
    assert_receive {:DOWN, ^ref, :process, ^controller, :normal}, 1_000
    assert_receive {:navigation_request, :cancel_login, [@url]}, 1_000
    refute_receive {:binding_open, _, _}, 50
    Agent.update(Client, &Map.put(&1, :poll_target, @b))
    {_controller, session} = start_native(context, :human)
    attach(session, @a)
    eventually(fn -> assigns(session).snapshot.navigation.notice == :login_failed end)
    assert_receive {:navigation_request, :logout, [@url, @b, "human_fixture"]}, 1_000
    refute_receive {:binding_open, @a, _}, 50
  end

  test "a newly signed-in human principal cannot recover another principal's draft", context do
    {_controller, session} = start_native(context, :human)
    attach(session, @a)
    eventually(fn -> assigns(session).snapshot.connected end)
    Breeze.Test.event(session, "chat:draft", %{value: "private first principal draft"})
    Agent.update(Client, &%{&1 | principal: "human_other"})
    attach(session, @b)

    eventually(fn ->
      assigns(session).snapshot.connected and assigns(session).snapshot.navigation.target == @b
    end)

    attach(session, @a)

    eventually(fn ->
      assigns(session).snapshot.connected and assigns(session).snapshot.navigation.target == @a
    end)

    assert assigns(session).snapshot.navigation.principal == "human_other"
    assert assigns(session).editor.draft == ""

    refute Enum.any?(assigns(session).drafts.values, fn {_scope, text} ->
             text == "private first principal draft"
           end)
  end

  test "the actual subscribed owner has closed bounded attach selectors", context do
    {:ok, controller} = Controller.start(options(context, :signed, nil))
    on_exit(fn -> Controller.close(controller) end)
    {:ok, snapshot} = Controller.subscribe(controller)

    for input <- [
          %{target: @a, generation: snapshot.navigation.generation + 1},
          %{target: nil, generation: snapshot.navigation.generation},
          %{target: <<255>>, generation: snapshot.navigation.generation},
          %{target: String.duplicate("é", 129), generation: snapshot.navigation.generation},
          %{target: "agent_bad\e[2J", generation: snapshot.navigation.generation},
          %{target: @a, generation: snapshot.navigation.generation, authority: true}
        ] do
      assert {:error, _} = Controller.act(controller, :attach, input)
    end

    refute_receive {:navigation_request, :resolve, _}, 50
    refute_receive {:binding_open, _, _}, 50
  end

  test "small-screen target input and help remain separate from chat submission", context do
    {_controller, session} = start_native(context, :human)
    session = Breeze.Test.resize(session, {36, 20})
    Breeze.Test.render_text!(session)
    assert Breeze.Test.focused(session) == "target"
    Breeze.Test.event(session, "target:change", %{value: @a})
    Breeze.Test.input(session, "F1")
    assert Breeze.Test.render_text!(session) =~ "Local conversation commands"
    Breeze.Test.input(session, "Escape")
    assert Breeze.Test.focused(session) == "target"
    assert assigns(session).target_input == @a
    refute_receive {:navigation_request, :start_login, _}, 50
    Breeze.Test.focus(session, "navigation-info")
    Breeze.Test.input(session, %{"key" => "Enter", "ctrlKey" => true})
    refute Enum.any?(Host.calls(context.host), &(&1.operation == :submit))
    Breeze.Test.event(session, "target:attach", %{value: @a})
    eventually(fn -> assigns(session).snapshot.navigation.sign_in != nil end)
    Breeze.Test.focus(session, "navigation-info")
    Breeze.Test.input(session, "End")
    assert Breeze.Test.render_text!(session) =~ "PUBLIC-CODE"
  end

  test "security regression: detached public Controller refuses credentialed and unsafe origins before display",
       context do
    for mode <- [:signed, :human],
        url <- [
          "https://name:private@example.test",
          "https://example.test?credential=private",
          "https://example.test#private",
          "http://example.test",
          "https://example.test/wrong",
          <<255>>
        ] do
      opts = options(context, mode, nil)
      opts = Keyword.update!(opts, :workspace_options, &Keyword.put(&1, :gateway_url, url))
      assert {:error, :invalid_gateway} = Controller.start(opts)
    end

    refute_receive {:navigation_request, _, _}, 30
    opts = options(context, :signed, nil)

    opts =
      Keyword.update!(
        opts,
        :workspace_options,
        &Keyword.put(&1, :gateway_url, "ws://127.0.0.1:4321/api/chat/socket")
      )

    {:ok, controller} = Controller.start(opts)
    {:ok, snapshot} = Controller.subscribe(controller)
    assert snapshot.navigation.gateway == @url
    assert :ok = Controller.close(controller)
  end

  test "untrappable owner death cancels an acquired login result before it can be adopted",
       context do
    {controller, session} = start_native(context, :human)
    Agent.update(Client, &Map.put(&1, :hold_login, true))
    attach(session, @a)
    assert_receive {:login_blocked, worker}, 1_000
    :ok = :sys.suspend(controller)
    worker_ref = Process.monitor(worker)
    owner_ref = Process.monitor(controller)
    send(worker, :release_login)
    assert_receive {:navigation_request, :start_login, [@url, @a]}, 1_000
    Process.exit(controller, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^controller, :killed}, 1_000
    assert_receive {:navigation_request, :cancel_login, [@url]}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 1_000
    refute_receive {:binding_open, _, _}, 30
  end

  test "untrappable owner death during open closes its acquired Connection and best-effort logs out the owned lease",
       context do
    {controller, session} = start_native(context, :human)
    Agent.update(Client, &Map.put(&1, :hold_open, true))
    attach(session, @a)
    assert_receive {:open_blocked, worker, ^controller}, 2_000
    :ok = :sys.suspend(controller)
    worker_ref = Process.monitor(worker)
    owner_ref = Process.monitor(controller)
    send(worker, :release_open)
    eventually(fn -> Enum.any?(Host.calls(context.host), &(&1.operation == :window)) end)
    Process.exit(controller, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^controller, :killed}, 1_000
    assert_receive {:navigation_request, :logout, [@url, @a, "human_fixture"]}, 1_000
    assert_receive {:binding_closed, @a, connection}, 1_000
    refute Process.alive?(connection)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 2_000
  end

  test "normal human logout uncertainty blocks target replacement", context do
    {_controller, session} = start_native(context, :human)
    attach(session, @a)
    eventually(fn -> assigns(session).snapshot.connected end)
    Agent.update(Client, &Map.put(&1, :logout_reply, {:error, :timeout}))
    attach(session, @b)
    eventually(fn -> assigns(session).snapshot.navigation.notice == :cleanup_unconfirmed end)
    assert_receive {:navigation_request, :logout, [@url, @a, "human_fixture"]}, 1_000
    refute_receive {:navigation_request, :start_login, [@url, @b]}, 30
    refute_receive {:binding_open, @b, _}, 30
  end

  test "normal public close discards an acquired pending login before terminating its worker",
       context do
    {controller, session} = start_native(context, :human)
    Agent.update(Client, &Map.put(&1, :hold_login, true))
    attach(session, @a)
    assert_receive {:login_blocked, worker}, 1_000
    :ok = :sys.suspend(controller)
    ref = Process.monitor(worker)
    owner_ref = Process.monitor(controller)
    closer = close_queued(controller)
    send(worker, :release_login)
    assert_receive {:navigation_request, :start_login, [@url, @a]}, 1_000
    :ok = :sys.resume(controller)
    assert :ok = Task.await(closer, 2_000)
    assert_receive {:navigation_request, :cancel_login, [@url]}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 1_000
    assert_receive {:DOWN, ^owner_ref, :process, ^controller, :normal}, 1_000
    refute_receive {:binding_open, _, _}, 30
  end

  test "normal public close logs out an acquired unadopted session with no committed guardian",
       context do
    {controller, session} = start_native(context, :human)
    Agent.update(Client, &Map.put(&1, :hold_poll, true))
    attach(session, @a)
    assert_receive {:poll_blocked, worker}, 2_000
    :ok = :sys.suspend(controller)
    ref = Process.monitor(worker)
    owner_ref = Process.monitor(controller)
    closer = close_queued(controller)
    send(worker, :release_poll)
    assert_receive {:navigation_request, :poll_login, [@url]}, 1_000
    :ok = :sys.resume(controller)
    assert :ok = Task.await(closer, 2_000)
    assert_receive {:navigation_request, :logout, [@url, @a, "human_fixture"]}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 1_000
    assert_receive {:DOWN, ^owner_ref, :process, ^controller, :normal}, 1_000
    refute_receive {:binding_open, _, _}, 30
  end

  test "public close preserves failed discard cleanup even when the receipt worker exits normally",
       context do
    {controller, session} = start_native(context, :human)
    Agent.update(Client, &Map.merge(&1, %{hold_poll: true, logout_reply: {:error, :timeout}}))
    attach(session, @a)
    assert_receive {:poll_blocked, worker}, 2_000
    :ok = :sys.suspend(controller)
    ref = Process.monitor(worker)
    closer = close_queued(controller)
    send(worker, :release_poll)
    assert_receive {:navigation_request, :poll_login, [@url]}, 1_000
    :ok = :sys.resume(controller)
    assert {:error, :cleanup_unconfirmed} = Task.await(closer, 2_000)
    assert_receive {:navigation_request, :logout, [@url, @a, "human_fixture"]}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 1_000
    refute Process.alive?(controller)
    refute_receive {:binding_open, _, _}, 30
  end

  test "bounded public close leaves a held acquisition receipt owned and reports uncertainty",
       context do
    opts = Keyword.put(options(context, :human, nil), :cleanup_wait_ms, 20)
    {:ok, controller} = Controller.start(opts)
    {:ok, snapshot} = Controller.subscribe(controller)
    Agent.update(Client, &Map.put(&1, :hold_login, true))

    :ok =
      Controller.act(controller, :attach, %{
        target: @a,
        generation: snapshot.navigation.generation
      })

    assert_receive {:login_blocked, worker}, 1_000
    ref = Process.monitor(worker)
    assert {:error, :cleanup_unconfirmed} = Controller.close(controller)
    refute Process.alive?(controller)
    assert Process.alive?(worker)
    send(worker, :release_login)
    assert_receive {:navigation_request, :start_login, [@url, @a]}, 1_000
    assert_receive {:navigation_request, :cancel_login, [@url]}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 1_000
    refute_receive {:binding_open, _, _}, 30
  end

  test "CLI propagates cleanup uncertainty after a successful native exit", context do
    Agent.update(Client, &Map.put(&1, :cancel_reply, {:error, :timeout}))
    {:ok, options} = ArborBreeze.CLI.parse(["--url", @url])

    assert {:error, :cleanup_unconfirmed} =
             ArborBreeze.CLI.run(options, Client, fn controller ->
               {:ok, snapshot} = Controller.subscribe(controller)

               :ok =
                 Controller.act(controller, :attach, %{
                   target: @a,
                   generation: snapshot.navigation.generation
                 })

               eventually(fn ->
                 {:ok, snapshot} = Controller.subscribe(controller)
                 not is_nil(snapshot.navigation.sign_in)
               end)

               send(self(), {:cli_owner, controller})
               :ok
             end)

    assert_receive {:cli_owner, controller}
    refute Process.alive?(controller)
    assert_receive {:navigation_request, :cancel_login, [@url]}, 1_000
    refute_receive {:binding_open, _, _}, 30
    refute Enum.any?(Host.calls(context.host), &(&1.operation == :submit))
  end

  test "CLI preserves cleanup results after the actual native surface has already terminated" do
    for {reply, expected} <- [
          {:ok, :ok},
          {{:error, :timeout}, {:error, :cleanup_unconfirmed}}
        ] do
      Agent.update(Client, &Map.put(&1, :cancel_reply, reply))
      {:ok, options} = ArborBreeze.CLI.parse(["--url", @url])

      assert expected ==
               ArborBreeze.CLI.run(options, Client, fn controller ->
                 session =
                   Breeze.Test.start!(View, size: {80, 24}, start_opts: [controller: controller])

                 attach(session, @a)
                 eventually(fn -> assigns(session).snapshot.navigation.sign_in != nil end)
                 ref = Process.monitor(controller)
                 Breeze.Test.stop(session)
                 assert_receive {:DOWN, ^ref, :process, ^controller, :normal}, 1_000
                 :ok
               end)

      assert_receive {:navigation_request, :cancel_login, [@url]}, 1_000
    end
  end

  defp close_queued(controller) do
    {:message_queue_len, before_count} = Process.info(controller, :message_queue_len)
    task = Task.async(fn -> Controller.close(controller) end)

    eventually(fn ->
      {:message_queue_len, count} = Process.info(controller, :message_queue_len)
      count > before_count
    end)

    task
  end
end
