defmodule Arbor.Dashboard.Live.ConversationHomeTest do
  use Arbor.Dashboard.ConnCase, async: false
  @moduletag :fast
  @first "eng_11111111111111111111111111111111"
  @second "eng_22222222222222222222222222222222"
  @foreign "eng_33333333333333333333333333333333"

  defmodule Host do
    def list_conversations(caller, opts) do
      {state, owner} = fixture()
      send(owner, {:directory, self(), caller, opts})
      if state.block_index, do: receive(do: (:release -> :ok))

      cond do
        not authorized?(state, caller, opts) ->
          {:error, :unauthorized}

        state.index_error ->
          {:error, :conversation_unavailable}

        state.filtered_page and opts[:cursor] == 0 ->
          {:ok, %{conversations: [], next_cursor: 20, has_more: true}}

        state.paged ->
          cursor = opts[:cursor]

          rows =
            for n <- (cursor + 1)..(cursor + 20) do
              %{
                engagement_id:
                  "eng_" <> String.pad_leading(String.downcase(Integer.to_string(n, 16)), 32, "0"),
                agent_id: "agent_page_#{n}",
                display_name: "Page #{n}",
                status: "active",
                updated_at: "2026-10-02T00:00:00Z",
                preview: "Preview #{n}",
                last_message_at: nil
              }
            end

          {:ok, %{conversations: rows, next_cursor: cursor + 20, has_more: true}}

        true ->
          {:ok, %{conversations: state.rows, next_cursor: nil, has_more: false}}
      end
    end

    def resolve_conversation_reference(caller, id, opts) do
      {state, owner} = fixture()
      send(owner, {:reference, self(), caller, id, opts})
      if state.block_reference == id, do: receive(do: (:release -> :ok))

      if authorized?(state, caller, opts) do
        case Enum.find(state.rows, &(&1.engagement_id == id)) do
          nil -> {:error, :not_found}
          row -> {:ok, row}
        end
      else
        {:error, :unauthorized}
      end
    end

    def conversation_window(caller, target, opts) do
      {state, owner} = fixture()
      send(owner, {:window, caller, target, opts})
      row = Enum.find(state.rows, &(&1.agent_id == target))

      cond do
        not authorized?(state, caller, opts) or is_nil(row) ->
          {:error, :unauthorized}

        opts[:expected_engagement_id] && opts[:expected_engagement_id] != row.engagement_id ->
          {:error, :conversation_scope_changed}

        true ->
          {:ok,
           %{
             engagement_id: row.engagement_id,
             entries: [
               %{
                 id: target <> "-row",
                 role: "assistant",
                 content: "Private answer for " <> target,
                 timestamp: "2026-10-02T00:00:00Z",
                 entry_ordinal: 1
               }
             ],
             head: 1,
             first: 1,
             last: 1,
             has_older: false,
             has_newer: false
           }}
      end
    end

    def submit_conversation_command(caller, target, command, opts) do
      {state, owner} = fixture()
      send(owner, {:submit, caller, target, command, opts})
      row = Enum.find(state.rows, &(&1.agent_id == target))

      if (authorized?(state, caller, opts) and row) &&
           opts[:expected_engagement_id] == row.engagement_id do
        {:ok,
         %{
           id: command.id,
           name: "chat.send",
           text: command.text,
           principal_id: caller,
           agent_id: target,
           engagement_id: row.engagement_id,
           status: :admitted,
           outcome: nil,
           admitted_cursor: 1,
           updated_cursor: 1
         }}
      else
        {:error, :unauthorized}
      end
    end

    def conversation_command(_, _, _, _), do: {:error, :not_found}

    defp authorized?(state, caller, opts),
      do: state.allowed and caller == "human_ui" and opts[:session_token] == "proof"

    defp fixture do
      {pid, owner} = Application.fetch_env!(:arbor_dashboard, :home_fixture)
      {Agent.get(pid, & &1), owner}
    end
  end

  defmodule Voice do
    def desk_recording_options, do: {:ok, %{default_ms: 12_000, min_ms: 100, max_ms: 30_000}}

    def start_desk_turn(caller, target, opts) do
      {_pid, owner} = Application.fetch_env!(:arbor_dashboard, :home_fixture)
      send(owner, {:voice_start, caller, target, opts})
      {:ok, String.duplicate("v", 43)}
    end

    def cancel_desk_turn(_), do: {:error, :cleanup_pending}

    def desk_turn_status(_) do
      {pid, _} = Application.fetch_env!(:arbor_dashboard, :home_fixture)

      if Agent.get(pid, & &1.voice_complete),
        do: {:ok, %{terminal: true, state: :cancelled}},
        else: {:ok, %{terminal: false, state: :capture}}
    end
  end

  setup do
    keys = [:conversation_api, :local_voice_controls, :voice_api, :home_fixture]
    previous = Map.new(keys, &{&1, Application.fetch_env(:arbor_dashboard, &1)})
    rows = [row(@first, "agent_ui", "Cedar"), row(@second, "agent_other", "Willow")]

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             allowed: true,
             rows: rows,
             block_index: false,
             block_reference: nil,
             index_error: false,
             filtered_page: false,
             paged: false,
             voice_complete: false
           }
         end}
      )

    Application.put_env(:arbor_dashboard, :home_fixture, {state, self()})
    Application.put_env(:arbor_dashboard, :conversation_api, Host)
    Application.put_env(:arbor_dashboard, :local_voice_controls, false)
    Application.put_env(:arbor_dashboard, :voice_api, Voice)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, old} -> Application.put_env(:arbor_dashboard, key, old)
          :error -> Application.delete_env(:arbor_dashboard, key)
        end
      end
    end)

    %{state: state}
  end

  test "Home opens the authorized recent conversation and links closed rows with accessible details",
       %{conn: conn} do
    {:ok, view, _} = open(conn, "/home")
    html = await(view, &String.contains?(&1, "Private answer for agent_ui"))
    assert has_element?(view, "h1", "Cedar")
    assert has_element?(view, "a[href='/c/#{@first}'][aria-current='page']", "Cedar")
    assert has_element?(view, "details#conversation-inspector:not([open])")
    assert has_element?(view, "#conversation-main[tabindex='-1']")
    assert has_element?(view, "#conversation-rail[aria-busy='false']")
    assert html =~ "Cedar preview"
    refute html =~ "proof"
    assert_received {:directory, _, "human_ui", [session_token: "proof", cursor: 0, limit: 20]}
    assert_received {:reference, _, "human_ui", @first, [session_token: "proof"]}
    assert_received {:window, "human_ui", "agent_ui", opts}
    assert opts[:expected_engagement_id] == @first
  end

  test "reselecting the current conversation closes its rail and preserves the same draft and scope",
       %{conn: conn} do
    {:ok, view, _} = open(conn, "/c/" <> @first)
    await(view, &String.contains?(&1, "Private answer for agent_ui"))
    draft = "Home mobile draft café 東京\nsecond line"
    view |> element("#conversation-composer") |> render_change(%{"message" => draft})

    retained =
      :sys.get_state(view.pid).socket.assigns
      |> Map.take([
        :home_requested,
        :home_selected,
        :agent_id,
        :conversation_engagement_id,
        :conversation_connection,
        :conversation_authorized,
        :conversation_composer,
        :input
      ])

    assert retained.input == draft
    assert retained.conversation_engagement_id == @first
    assert retained.conversation_authorized
    assert is_pid(retained.conversation_connection)
    view |> element("button[phx-click='home:rail']") |> render_click()
    assert has_element?(view, "button[aria-controls='conversation-rail'][aria-expanded='true']")
    assert has_element?(view, "#conversation-rail.is-open")

    view
    |> element("#conversation-link-#{@first}[aria-current='page'][data-phx-link='patch']")
    |> render_click()

    assert has_element?(view, "button[aria-controls='conversation-rail'][aria-expanded='false']")
    assert has_element?(view, "#conversation-rail:not(.is-open)")
    assert has_element?(view, "#conversation-link-#{@first}[aria-current='page']")
    assert has_element?(view, "#conversation-message-agent_ui-row", "Private answer for agent_ui")

    assert :sys.get_state(view.pid).socket.assigns |> Map.take(Map.keys(retained)) == retained

    assert render(view)
           |> Floki.parse_document!()
           |> Floki.find("#conversation-message-input")
           |> Floki.text() == draft
  end

  test "security regression foreign deep link cannot reveal its target name or transcript", %{
    conn: conn
  } do
    {:ok, view, _} = open(conn, "/c/" <> @foreign)
    html = await(view, &String.contains?(&1, "This conversation is unavailable"))
    refute html =~ "Private answer"
    refute html =~ "conversation-inspector"
    refute_received {:window, _, _, _}
    assert has_element?(view, "#conversation-link-#{@first}")
    refute has_element?(view, "#conversation-composer")
  end

  test "late directory success cannot hide a deep-link resolution error", %{
    conn: conn,
    state: state
  } do
    Agent.update(state, &%{&1 | block_index: true})
    {:ok, view, _} = open(conn, "/c/" <> @foreign)
    assert_receive {:directory, worker, _, _}
    await(view, &String.contains?(&1, "This conversation is unavailable"))
    send(worker, :release)
    await(view, &String.contains?(&1, "Cedar preview"))
    assert render(view) =~ "This conversation is unavailable"
  end

  test "repeated Next and Previous directory navigation retains only the current bounded page", %{
    conn: conn,
    state: state
  } do
    Agent.update(state, &%{&1 | paged: true})
    {:ok, view, _} = open(conn, "/c/" <> @foreign)
    await(view, &String.contains?(&1, "Preview 20"))

    for page <- 1..8 do
      render_click(view, "home:more", %{})
      last = (page + 1) * 20
      html = await(view, &String.contains?(&1, ">Preview #{last}<"))
      assert length(Floki.find(Floki.parse_document!(html), ".aw-home-conversation")) == 20
      assert length(:sys.get_state(view.pid).socket.assigns.home_rows) == 20
      refute html =~ ">Preview #{last - 20}<"
    end

    render_click(view, "home:previous", %{})
    await(view, &String.contains?(&1, ">Preview 160<"))
    assert :sys.get_state(view.pid).socket.assigns.home_page_cursor == 140
  end

  test "pending directory refresh cannot block composition or expose proof", %{
    conn: conn,
    state: state
  } do
    {:ok, view, _} = open(conn, "/home")
    await(view, &String.contains?(&1, "Private answer for agent_ui"))
    flush_messages()
    Agent.update(state, &%{&1 | block_index: true})
    render_click(view, "home:refresh", %{"session_token" => "forged", "owner" => "foreign"})
    assert_receive {:directory, worker, "human_ui", opts}
    assert opts[:session_token] == "proof"
    render_change(view, "update-input", %{"message" => "Fresh draft"})

    render_submit(view, "send-message", %{
      "message" => "Fresh draft",
      "command_id" => "home-command"
    })

    assert_receive {:submit, "human_ui", "agent_ui", %{id: "home-command", text: "Fresh draft"},
                    _}

    assert Process.alive?(worker)
    send(worker, :release)
    await(view, &String.contains?(&1, "aria-busy=\"false\""))
  end

  test "security regression superseded reference workers and forged late replies cannot change selection",
       %{conn: conn, state: state} do
    Agent.update(state, &%{&1 | block_reference: @first})
    {:ok, view, _} = open(conn, "/c/" <> @first)
    assert_receive {:reference, old_worker, _, @first, _}
    old = :sys.get_state(view.pid).socket.assigns.home_workers.reference
    render_patch(view, "/c/" <> @second)
    await(view, &String.contains?(&1, "Private answer for agent_other"))
    refute_push_event(view, "conversation-access-denied", %{})
    refute Process.alive?(old_worker)

    send(
      view.pid,
      {:home_result, old_worker, old.generation, :reference,
       {:ok, row(@first, "agent_ui", "Foreign late sentinel")}}
    )

    send(view.pid, {:home_timeout, old_worker, old.generation, :reference})
    html = render(view)
    assert html =~ "Willow"
    refute html =~ "Foreign late sentinel"
    refute html =~ "Private answer for agent_ui"
    assert has_element?(view, "a[aria-current='page']", "Willow")
  end

  test "worker deadline and unavailable index distinguish failures from an empty directory", %{
    conn: conn,
    state: state
  } do
    Agent.update(state, &%{&1 | block_index: true})
    {:ok, view, _} = open(conn, "/home")
    assert_receive {:directory, worker, _, _}
    current = :sys.get_state(view.pid).socket.assigns.home_workers.index
    send(view.pid, {:home_timeout, worker, current.generation, :index})
    html = await(view, &String.contains?(&1, "Conversations could not be loaded"))
    refute Process.alive?(worker)
    refute html =~ "No accessible conversations on this page"
    refute html =~ "Cedar preview"
  end

  test "filtered empty page remains navigable to later authorized conversations", %{
    conn: conn,
    state: state
  } do
    Agent.update(state, &%{&1 | filtered_page: true})
    {:ok, view, _} = open(conn, "/home")
    html = await(view, &String.contains?(&1, "More conversations are available to check"))
    refute html =~ "No accessible conversations on this page"
    render_click(view, "home:more", %{})
    assert_receive {:directory, _, "human_ui", [session_token: "proof", cursor: 20, limit: 20]}
    await(view, &String.contains?(&1, "Private answer for agent_ui"))
  end

  test "security regression idle connection denial also clears rail names previews and details",
       %{conn: conn, state: state} do
    {:ok, view, _} = open(conn, "/home")
    await(view, &String.contains?(&1, "Private answer for agent_ui"))
    render_change(view, "update-input", %{"message" => "private draft"})
    Agent.update(state, &%{&1 | allowed: false})
    html = await(view, &String.contains?(&1, "Private data was cleared"))
    refute html =~ "Private answer"
    refute html =~ "Cedar preview"
    refute html =~ "Willow preview"
    refute has_element?(view, "h1", "Cedar")
    refute has_element?(view, "details#conversation-inspector")
    assert_push_event view, "conversation-access-denied", %{}
  end

  test "blocked private workers retire when their owner dies without a cleanup callback", %{
    state: state
  } do
    Agent.update(state, &%{&1 | block_index: true})

    owner =
      spawn(fn ->
        %Phoenix.LiveView.Socket{
          assigns: %{__changed__: %{}, current_agent_id: "human_ui", session_token: "proof"}
        }
        |> Arbor.Dashboard.Live.ConversationLive.Surface.mount(nil)
        |> Arbor.Dashboard.Live.ConversationLive.Home.mount(true)
        |> Arbor.Dashboard.Live.ConversationLive.Home.event("home:refresh", %{})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:directory, worker, "human_ui", _}
    monitor = Process.monitor(worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
  end

  test "target selection retains voice cleanup ownership before another recording is admitted", %{
    conn: conn,
    state: state
  } do
    Application.put_env(:arbor_dashboard, :local_voice_controls, true)
    {:ok, view, _} = open(conn, "/home")
    await(view, &String.contains?(&1, "Private answer for agent_ui"))
    render_click(view, "voice:talk", %{})
    assert_receive {:voice_start, "human_ui", "agent_ui", _}
    render_patch(view, "/c/" <> @second)
    await(view, &String.contains?(&1, "Private answer for agent_other"))
    assert has_element?(view, "button[phx-click='voice:talk'][disabled]")
    render_click(view, "voice:talk", %{})
    refute_receive {:voice_start, _, "agent_other", _}
    Agent.update(state, &%{&1 | voice_complete: true})
    await(view, &String.contains?(&1, "Voice operation cancelled. Audio is closed."))
    render_click(view, "voice:talk", %{})
    assert_receive {:voice_start, "human_ui", "agent_other", opts}
    assert opts[:expected_engagement_id] == @second
  end

  defp row(id, agent, name),
    do: %{
      engagement_id: id,
      agent_id: agent,
      display_name: name,
      status: "active",
      updated_at: "2026-10-02T00:00:00Z",
      preview: name <> " preview",
      last_message_at: "2026-10-02T00:00:00Z"
    }

  defp open(conn, path),
    do:
      conn
      |> Plug.Conn.put_private(:live_view_connect_info, %{
        peer_data: %{address: {127, 0, 0, 1}},
        uri: %URI{host: "localhost"},
        x_headers: [{"x-arbor-voice-direct", "true"}]
      })
      |> Plug.Test.init_test_session(%{"agent_id" => "human_ui", "session_token" => "proof"})
      |> live(path)

  defp await(view, predicate, tries \\ 300)
  defp await(_, _, 0), do: flunk("Home did not reach expected display state")

  defp await(view, predicate, tries) do
    html = render(view)

    if predicate.(html),
      do: html,
      else:
        (
          Process.sleep(10)
          await(view, predicate, tries - 1)
        )
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end
end
