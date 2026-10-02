defmodule ConversationDemo.ArborFixtureFacade do
  @moduledoc false
  @engagement "eng_11111111111111111111111111111111"

  def initial,
    do: %{
      entries: [],
      events: [],
      commands: %{},
      calls: [],
      mode: :normal,
      proofs: 0,
      owner: "human-fixture",
      engagement: @engagement
    }

  def owner(owner), do: Agent.update(__MODULE__, &%{&1 | owner: owner})

  def remap do
    Agent.update(
      __MODULE__,
      &%{
        &1
        | owner: "human-new-owner",
          engagement: "eng_22222222222222222222222222222222",
          entries: [],
          events: [],
          commands: %{}
      }
    )
  end

  def mode(mode), do: Agent.update(__MODULE__, &%{&1 | mode: mode})
  def state, do: Agent.get(__MODULE__, & &1)

  def proof(_context) do
    n =
      Agent.get_and_update(__MODULE__, fn state ->
        {state.proofs + 1, %{state | proofs: state.proofs + 1}}
      end)

    {:ok, [session_token: "private-proof-#{n}"]}
  end

  def conversation_history(caller, target, opts), do: request(:history, caller, target, nil, opts)

  def conversation_events(caller, target, cursor, opts),
    do: request(:events, caller, target, cursor, opts)

  def conversation_command(caller, target, id, opts),
    do: request(:command, caller, target, id, opts)

  def submit_conversation_command(caller, target, command, opts),
    do: request(:submit, caller, target, command, opts)

  defp request(operation, caller, target, input, opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = %{state | calls: state.calls ++ [{operation, input, opts}]}

      cond do
        caller != "human-fixture" or target != "agent-fixture" ->
          {{:error, :unauthorized}, state}

        state.mode == :denied ->
          {{:error, :unauthorized}, state}

        opts[:expected_engagement_id] && opts[:expected_engagement_id] != state.engagement ->
          {{:error, :conversation_scope_changed}, state}

        operation == :history and state.mode == :read_error ->
          {{:error, :conversation_unavailable}, state}

        true ->
          respond(operation, input, opts, state)
      end
    end)
  end

  defp respond(:history, _, opts, state) do
    page = page(state.entries, :entry_ordinal, Keyword.get(opts, :after, 0), opts)

    {{:ok,
      Map.merge(page, %{engagement_id: state.engagement, entries: page.items})
      |> Map.delete(:items)}, state}
  end

  defp respond(:events, after_cursor, opts, state) do
    page = page(state.events, :cursor, after_cursor, opts)

    {{:ok,
      Map.merge(page, %{events: page.items, engagement_id: state.engagement})
      |> Map.delete(:items)}, state}
  end

  defp respond(:command, id, _, state),
    do: {Map.fetch(state.commands, id) |> command_result(), state}

  defp respond(:submit, _command, _, %{mode: :unsupported_capability} = state),
    do: {{:error, :unsupported_conversation_capability}, state}

  defp respond(:submit, _command, _, %{mode: :reject} = state),
    do: {{:error, :invalid_command}, state}

  defp respond(:submit, _command, _, %{mode: :conflict} = state),
    do: {{:error, :command_conflict}, state}

  defp respond(:submit, _command, _, %{mode: :ambiguous_missing} = state),
    do: {{:error, :conversation_unavailable}, %{state | mode: :normal}}

  defp respond(:submit, input, _, state) do
    case Map.fetch(state.commands, input.id) do
      {:ok, command} ->
        {{:ok, command}, state}

      :error ->
        cursor = length(state.events) + 1

        command = %{
          id: input.id,
          name: "chat.send",
          text: input.text,
          principal_id: state.owner,
          agent_id: "agent-fixture",
          engagement_id: state.engagement,
          status: :admitted,
          outcome: nil,
          admitted_cursor: cursor,
          updated_cursor: cursor
        }

        event = %{id: "event-#{cursor}", cursor: cursor, kind: "admitted", command: command}

        entry = %{
          id: "message-#{cursor}",
          role: "user",
          content: input.text,
          timestamp: "2026-09-27T00:00:00Z",
          entry_ordinal: length(state.entries) + 1
        }

        mode =
          case state.mode do
            :read_fails_after_submit -> :read_error
            :unauthorized_saved -> :denied
            _ -> :normal
          end

        next = %{
          state
          | commands: Map.put(state.commands, command.id, command),
            events: state.events ++ [event],
            entries: state.entries ++ [entry],
            mode: mode
        }

        reply =
          case state.mode do
            :ambiguous_saved -> {:error, :conversation_unavailable}
            :unauthorized_saved -> {:error, :unauthorized}
            _ -> {:ok, command}
          end

        {reply, next}
    end
  end

  defp command_result({:ok, command}), do: {:ok, command}
  defp command_result(:error), do: {:error, :not_found}

  defp page(items, key, after_cursor, opts) do
    latest = items |> List.last() |> then(&if(&1, do: Map.fetch!(&1, key), else: 0))
    head = Keyword.get(opts, :through, latest)

    selected =
      Enum.filter(items, &(Map.fetch!(&1, key) > after_cursor and Map.fetch!(&1, key) <= head))
      |> Enum.take(Keyword.get(opts, :limit, 50))

    cursor = selected |> List.last() |> then(&if(&1, do: Map.fetch!(&1, key), else: head))
    %{items: selected, cursor: cursor, head: head, has_more: cursor < head}
  end
end

defmodule ConversationDemo.ArborInterfacesTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias ConversationDemo.{ArborBreezeView, ArborClient, ArborFixtureFacade, ArborInteraction}
  @endpoint ConversationDemo.Endpoint
  @moduletag :fast

  setup do
    start_supervised!(%{
      id: ArborFixtureFacade,
      start:
        {Agent, :start_link, [fn -> ArborFixtureFacade.initial() end, [name: ArborFixtureFacade]]}
    })

    old = Application.get_env(:conversation_demo, :arbor_client_options)

    opts = [
      caller: "human-fixture",
      target: "agent-fixture",
      proof_provider: &ArborFixtureFacade.proof/1,
      adapter_options: [facade: ArborFixtureFacade, page_limit: 2]
    ]

    Application.put_env(:conversation_demo, :arbor_client_options, opts)

    on_exit(fn ->
      if old,
        do: Application.put_env(:conversation_demo, :arbor_client_options, old),
        else: Application.delete_env(:conversation_demo, :arbor_client_options)
    end)

    {:ok, opts: opts}
  end

  test "independent LiveView and Breeze runtimes share records and preserve local drafts" do
    {:ok, web, _} = live(build_conn(), "/arbor")
    tui = Breeze.Test.start!(ArborBreezeView, size: {100, 38})
    on_exit(fn -> Breeze.Test.stop(tui) end)
    Breeze.Test.event(tui, "chat:draft", %{value: "terminal-only draft"})
    html = web |> form("#composer", text: "café 東京 🌿 from web") |> render_submit()
    assert html =~ "café 東京 🌿 from web"
    assert_push_event(web, "composer:sent", %{})
    refute Breeze.Test.render_text!(tui) =~ "café 東京 🌿 from web"
    Breeze.Test.event(tui, "chat:refresh", %{})
    assert Breeze.Test.render_text!(tui) =~ "café 東京 🌿 from web"
    assert Breeze.Test.render_text!(tui) =~ "terminal-only draft"
    web |> form("#composer", text: "web-only draft") |> render_change()
    Breeze.Test.event(tui, "chat:send", %{})
    assert web |> element("#refresh") |> render_click() =~ "terminal-only draft"
    assert web |> element("#composer") |> render() =~ "web-only draft"
    refute render(web) =~ "private-proof-"
    refute has_element?(web, "[phx-click='chat:approve']")
    assert render(web) =~ "audio is not playing"

    tokens =
      Enum.map(ArborFixtureFacade.state().calls, fn {_, _, opts} -> opts[:session_token] end)

    assert length(tokens) == length(Enum.uniq(tokens))
  end

  test "disconnect blocks sends and reconnect catches up without changing local draft" do
    left =
      ArborInteraction.new()
      |> ArborInteraction.act("draft", %{"text" => "keep this draft"})
      |> ArborInteraction.act("disconnect", %{})

    before = ArborFixtureFacade.state().calls
    blocked = ArborInteraction.act(left, "send", %{})
    assert blocked.draft == "keep this draft"
    assert blocked.snapshot.error =~ "Disconnected"
    assert ArborFixtureFacade.state().calls == before
    ArborInteraction.new() |> ArborInteraction.act("send", %{"text" => "remote update"})
    next = ArborInteraction.act(blocked, "reconnect", %{})
    assert next.draft == "keep this draft"
    assert Enum.any?(next.snapshot.projection["messages"], &(&1["text"] == "remote update"))
    assert next.snapshot.position == %{history: 1, commands: 1}
  end

  test "Breeze native input sends Unicode, clears the composer, and resizes within the viewport" do
    tui = Breeze.Test.start!(ArborBreezeView, size: {90, 36})
    on_exit(fn -> Breeze.Test.stop(tui) end)
    Breeze.Test.focus(tui, "draft")
    for char <- String.graphemes("café 東京 🌿"), do: Breeze.Test.input(tui, char)
    assert Breeze.Test.render_text!(tui) =~ "café 東京 🌿"
    Breeze.Test.input(tui, "Enter")
    assert [command] = Map.values(ArborFixtureFacade.state().commands)
    assert command.text == "café 東京 🌿"
    Breeze.Test.input(tui, "Enter")
    assert map_size(ArborFixtureFacade.state().commands) == 1
    narrow = Breeze.Test.resize(tui, {24, 14})
    rendered = Breeze.Test.render_text!(narrow)
    assert String.valid?(rendered)

    assert Enum.all?(
             String.split(rendered, "\n"),
             &(TermUI.Renderer.DisplayWidth.width(&1) <= 24)
           )
  end

  test "confirmed retry tells the browser to clear its focused composer" do
    {:ok, web, _} = live(build_conn(), "/arbor")
    ArborFixtureFacade.mode(:ambiguous_saved)
    web |> form("#composer", text: "one saved request") |> render_submit()
    refute_push_event(web, "composer:sent", %{})
    web |> element("#retry") |> render_click()
    assert_push_event(web, "composer:sent", %{text: "one saved request"})
    assert has_element?(web, "#message[value='']")
    assert map_size(ArborFixtureFacade.state().commands) == 1
  end

  test "acknowledging pending draft A preserves a newer draft B" do
    {:ok, web, _} = live(build_conn(), "/arbor")
    ArborFixtureFacade.mode(:ambiguous_saved)
    web |> form("#composer", text: "draft A") |> render_submit()
    render_change(web, "chat:draft", %{"text" => "draft B queued before disable"})
    web |> element("#retry") |> render_click()
    assert has_element?(web, "#message[value='draft B queued before disable']")
    assert_push_event(web, "composer:sent", %{text: "draft A"})
    assert [command] = Map.values(ArborFixtureFacade.state().commands)
    assert command.text == "draft A"
  end

  test "ambiguous saved admission retries its original ID without duplicating records" do
    ui =
      ArborInteraction.new()
      |> ArborInteraction.act("draft", %{"text" => "saved despite lost reply"})

    ArborFixtureFacade.mode(:ambiguous_saved)
    unknown = ArborInteraction.act(ui, "send", %{})
    assert unknown.snapshot.pending_id
    refute unknown.snapshot.send_allowed
    assert unknown.draft == "saved despite lost reply"
    blocked = ArborInteraction.act(unknown, "send", %{})
    assert blocked.snapshot.pending_id == unknown.snapshot.pending_id
    known = ArborInteraction.act(blocked, "retry", %{})
    assert known.snapshot.pending_id == nil
    assert known.draft == ""
    submissions = Enum.filter(ArborFixtureFacade.state().calls, &(elem(&1, 0) == :submit))
    assert [{:submit, same, _}, {:submit, same, _}] = submissions
    assert same.id == unknown.snapshot.pending_id
    assert length(ArborFixtureFacade.state().entries) == 1
    assert length(known.snapshot.projection["deliveries"]) == 1
  end

  test "retry after not-found uses original command ID and text" do
    ui =
      ArborInteraction.new()
      |> ArborInteraction.act("draft", %{"text" => "retry identical request"})

    ArborFixtureFacade.mode(:ambiguous_missing)
    unknown = ArborInteraction.act(ui, "send", %{})
    known = ArborInteraction.act(unknown, "retry", %{})
    assert known.draft == ""
    submissions = for {:submit, input, _} <- ArborFixtureFacade.state().calls, do: input
    assert [same, same] = submissions
    assert same.id == unknown.snapshot.pending_id
  end

  test "confirmed admission clears draft even when subsequent refresh fails" do
    {:ok, web, _} = live(build_conn(), "/arbor")
    ArborFixtureFacade.mode(:read_fails_after_submit)
    html = web |> form("#composer", text: "admitted only once") |> render_submit()
    assert_push_event(web, "composer:sent", %{})
    assert html =~ "could not confirm"
    refute web |> element("#composer") |> render() =~ "admitted only once"
    assert has_element?(web, "#message[value='']")
    web |> form("#composer", text: "") |> render_submit()
    assert length(ArborFixtureFacade.state().commands |> Map.keys()) == 1
  end

  test "deterministically rejected submission releases pending slot for correction" do
    ui = ArborInteraction.new() |> ArborInteraction.act("draft", %{"text" => "rejected text"})
    ArborFixtureFacade.mode(:reject)
    rejected = ArborInteraction.act(ui, "send", %{})
    assert rejected.snapshot.pending_id == nil
    assert rejected.snapshot.send_allowed
    assert rejected.draft == "rejected text"
    assert rejected.snapshot.error =~ "rejected"
  end

  test "security regression: access denial removes private projection, draft, positions and pending" do
    {:ok, web, _} = live(build_conn(), "/arbor")
    web |> form("#composer", text: "private conversation") |> render_submit()
    web |> form("#composer", text: "private draft") |> render_change()
    ArborFixtureFacade.mode(:ambiguous_missing)
    web |> form("#composer", text: "private pending") |> render_submit()
    assert has_element?(web, "#pending-request")
    ArborFixtureFacade.mode(:denied)
    html = web |> element("#refresh") |> render_click()
    assert_push_event(web, "composer:clear", %{})
    refute html =~ "private conversation"
    refute html =~ "private pending"
    refute html =~ "private draft"
    refute has_element?(web, "#pending-request")
    assert html =~ "Access unavailable"
    assert has_element?(web, "#history-position", "0")
    assert has_element?(web, "#command-position", "0")
    assert has_element?(web, "#message[disabled]")
  end

  test "server owner terminates with its renderer and snapshots contain no proof closures", %{
    opts: opts
  } do
    test = self()

    renderer =
      spawn(fn ->
        {:ok, client} = ArborClient.start(opts)
        send(test, {:client, client, ArborClient.snapshot(client)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:client, client, snapshot}
    refute inspect(snapshot) =~ "private-proof-"
    refute inspect(snapshot) =~ "human-fixture"
    refute Enum.any?(Map.values(snapshot), &is_function/1)
    monitor = Process.monitor(client)
    send(renderer, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
  end

  @tag :remote_uncertainty_regression
  test "security regression: post-admission denial retains only a reference and reconnect never retries" do
    ui = ArborInteraction.new() |> ArborInteraction.act("send", %{"text" => "private history"})
    ui = ArborInteraction.act(ui, "draft", %{"text" => "private uncertain message"})
    ArborFixtureFacade.mode(:unauthorized_saved)
    denied = ArborInteraction.act(ui, "send", %{})

    [{:submit, _, _}, {:submit, submitted, _}] =
      Enum.filter(ArborFixtureFacade.state().calls, &(elem(&1, 0) == :submit))

    assert Map.has_key?(ArborFixtureFacade.state().commands, submitted.id)
    assert denied.snapshot.private_cleared
    refute denied.snapshot.connected
    refute denied.snapshot.retry_allowed
    assert denied.snapshot.pending_id == nil
    assert denied.snapshot.position == %{history: 0, commands: 0}

    assert denied.snapshot.projection == %{
             "messages" => [],
             "deliveries" => [],
             "blocks" => [],
             "speech" => []
           }

    assert denied.draft == ""
    refute inspect(denied.snapshot) =~ "private history"
    refute inspect(denied.snapshot) =~ "private uncertain message"
    assert denied.snapshot.error =~ "Delivery unconfirmed. Reference: #{submitted.id}."

    blocked = ArborInteraction.act(denied, "retry", %{})
    still_denied = ArborInteraction.act(blocked, "reconnect", %{})
    assert still_denied.snapshot.error =~ submitted.id
    assert still_denied.snapshot.pending_id == nil
    ArborFixtureFacade.mode(:normal)
    connected = ArborInteraction.act(still_denied, "reconnect", %{})
    assert connected.snapshot.connected
    assert connected.snapshot.error == "Delivery unconfirmed. Reference: #{submitted.id}."
    assert connected.snapshot.pending_id == nil
    refute connected.snapshot.retry_allowed
    assert connected.draft == ""
    after_retry = ArborInteraction.act(connected, "retry", %{})
    assert after_retry.snapshot.error =~ submitted.id
    assert length(for {:submit, _, _} <- ArborFixtureFacade.state().calls, do: :submit) == 2
    refute Enum.any?(ArborFixtureFacade.state().calls, &(elem(&1, 0) == :command))
  end

  @tag :remote_uncertainty_regression
  test "both visual surfaces display the unconfirmed reference after private data clears" do
    {:ok, web, _} = live(build_conn(), "/arbor")
    ArborFixtureFacade.mode(:unauthorized_saved)
    html = web |> form("#composer", text: "private web uncertainty") |> render_submit()
    [web_command] = Map.values(ArborFixtureFacade.state().commands)
    assert html =~ "Delivery unconfirmed. Reference: #{web_command.id}."
    refute html =~ "private web uncertainty"
    refute has_element?(web, "#pending-request")
    assert_push_event(web, "composer:clear", %{})

    ArborFixtureFacade.mode(:normal)
    terminal = Breeze.Test.start!(ArborBreezeView, size: {100, 38})
    on_exit(fn -> Breeze.Test.stop(terminal) end)
    Breeze.Test.event(terminal, "chat:draft", %{value: "private terminal uncertainty"})
    ArborFixtureFacade.mode(:unauthorized_saved)
    Breeze.Test.event(terminal, "chat:send", %{})

    terminal_command =
      Enum.find(Map.values(ArborFixtureFacade.state().commands), &(&1.id != web_command.id))

    rendered = Breeze.Test.render_text!(terminal)
    assert rendered =~ "Delivery unconfirmed. Reference: #{terminal_command.id}."
    refute rendered =~ "private web uncertainty"
    refute rendered =~ "private terminal uncertainty"
    assert rendered =~ "Transcript 0"
    assert rendered =~ "Journal 0"
  end

  test "linked identity uses host canonical owner across both visual surfaces" do
    ArborFixtureFacade.owner("human-canonical-owner")
    {:ok, web, _} = live(build_conn(), "/arbor")
    terminal = Breeze.Test.start!(ArborBreezeView, size: {100, 38})
    on_exit(fn -> Breeze.Test.stop(terminal) end)
    web |> form("#composer", text: "same linked conversation") |> render_submit()
    Breeze.Test.event(terminal, "chat:refresh", %{})
    assert Breeze.Test.render_text!(terminal) =~ "same linked conversation"
    assert [command] = Map.values(ArborFixtureFacade.state().commands)
    assert command.principal_id == "human-canonical-owner"
    refute render(web) =~ "human-canonical-owner"
  end

  test "security regression: ownership change discards pending admission and draft before reconnect" do
    ui =
      ArborInteraction.new() |> ArborInteraction.act("draft", %{"text" => "old owner's pending"})

    ArborFixtureFacade.mode(:ambiguous_missing)
    unknown = ArborInteraction.act(ui, "send", %{})
    assert unknown.snapshot.pending_id
    newer = ArborInteraction.act(unknown, "draft", %{"text" => "newer unsent private draft"})
    ArborFixtureFacade.remap()
    cleared = ArborInteraction.act(newer, "refresh", %{})
    assert cleared.snapshot.private_cleared
    assert cleared.snapshot.pending_id == nil
    assert cleared.draft == ""
    refute cleared.snapshot.connected
    refute cleared.snapshot.retry_allowed
    assert cleared.snapshot.error =~ "ownership changed"
    blocked = ArborInteraction.act(cleared, "retry", %{})
    assert blocked.snapshot.pending_id == nil
    assert ArborFixtureFacade.state().commands == %{}
    connected = ArborInteraction.act(blocked, "reconnect", %{})
    assert connected.snapshot.connected
    assert ArborFixtureFacade.state().commands == %{}

    fresh =
      connected
      |> ArborInteraction.act("draft", %{"text" => "explicit new owner's turn"})
      |> ArborInteraction.act("send", %{})

    assert fresh.snapshot.error == nil
    assert [command] = Map.values(ArborFixtureFacade.state().commands)
    assert command.text == "explicit new owner's turn"
    refute command.id == unknown.snapshot.pending_id
  end

  test "unsupported capability rejects admission without retaining a retry" do
    ui = ArborInteraction.new() |> ArborInteraction.act("draft", %{"text" => "not admitted"})
    ArborFixtureFacade.mode(:unsupported_capability)
    rejected = ArborInteraction.act(ui, "send", %{})
    assert rejected.snapshot.pending_id == nil
    assert rejected.snapshot.error =~ "rejected"
    assert rejected.draft == "not admitted"
    assert ArborFixtureFacade.state().commands == %{}
  end

  test "initial synchronization failure cannot enable an unfenced submission" do
    ArborFixtureFacade.mode(:read_error)
    ui = ArborInteraction.new()
    refute ui.snapshot.connected
    refute ui.snapshot.send_allowed
    blocked = ArborInteraction.act(ui, "send", %{"text" => "must not send"})
    assert blocked.snapshot.error =~ "Disconnected"
    refute Enum.any?(ArborFixtureFacade.state().calls, &(elem(&1, 0) == :submit))
    ArborFixtureFacade.mode(:normal)
    assert ArborInteraction.act(blocked, "reconnect", %{}).snapshot.connected
  end

  test "security regression: repeated failed first reconnect preserves draft and refuses sends" do
    ArborFixtureFacade.mode(:read_error)
    ui = ArborInteraction.new() |> ArborInteraction.act("draft", %{"text" => "unsent draft"})
    retried = ArborInteraction.act(ui, "reconnect", %{})
    refute retried.snapshot.connected
    refute retried.snapshot.send_allowed
    assert retried.snapshot.pending_id == nil
    assert retried.draft == "unsent draft"
    blocked = ArborInteraction.act(retried, "send", %{})
    assert blocked.snapshot.error =~ "Disconnected"
    assert blocked.snapshot.pending_id == nil
    assert blocked.draft == "unsent draft"
    refute Enum.any?(ArborFixtureFacade.state().calls, &(elem(&1, 0) == :submit))
    ArborFixtureFacade.mode(:normal)
    connected = ArborInteraction.act(blocked, "reconnect", %{})
    assert connected.snapshot.send_allowed
    assert connected.draft == "unsent draft"
  end

  @tag :remote_uncertainty_regression
  test "security regression: later refusal cannot erase an earlier unknown admission" do
    for mode <- [:reject, :unsupported_capability, :conflict] do
      ArborFixtureFacade.mode(:ambiguous_missing)
      ui = ArborInteraction.new() |> ArborInteraction.act("draft", %{"text" => "uncertain"})
      unknown = ArborInteraction.act(ui, "send", %{})
      ArborFixtureFacade.mode(mode)
      refused = ArborInteraction.act(unknown, "retry", %{})
      assert refused.snapshot.pending_id == unknown.snapshot.pending_id
      refute refused.snapshot.send_allowed
      assert refused.snapshot.retry_allowed
      assert refused.draft == "uncertain"
      assert refused.snapshot.error =~ "Earlier delivery remains unresolved"
    end
  end

  test "disconnect invokes the trusted transport lifecycle without exposing it", %{opts: opts} do
    test = self()

    opts =
      Keyword.put(opts, :disconnect, fn ->
        send(test, :transport_disconnected)
        :ok
      end)

    {:ok, client} = ArborClient.start(opts)
    assert {:ok, snapshot} = ArborClient.act(client, :disconnect)
    assert_receive :transport_disconnected
    refute snapshot.connected
    refute Enum.any?(Map.values(snapshot), &is_function/1)
    GenServer.stop(client)
    assert_receive :transport_disconnected
  end
end
