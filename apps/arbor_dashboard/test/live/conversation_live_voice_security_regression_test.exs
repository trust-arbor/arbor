defmodule Arbor.Dashboard.Live.ConversationLiveVoiceSecurityRegressionTest do
  use Arbor.Dashboard.ConnCase, async: false

  # Voice desk and private-conversation transport as mounted by the routed
  # ConversationLive (`/conversation/:agent_id`). Ported 2026-10-08 from the
  # retired ChatLive suite: every test drives the real LiveView, its Surface
  # access check and its ConversationKit connection through the public
  # conversation facade double below.

  @moduletag :fast
  @engagement "eng_11111111111111111111111111111111"
  @other_engagement "eng_22222222222222222222222222222222"
  @operation String.duplicate("v", 43)

  defmodule Host do
    @moduledoc false
    # Public `Arbor.Agent` conversation facade as consumed by the Surface access
    # check and the ConversationKit adapter. Every call is reported to the test
    # and independently requires the socket proof and exact scope.

    def conversation_window(caller, target, opts) do
      request(:window, caller, target, opts, fn state ->
        head = Keyword.get(opts, :through, List.last(state.entries).entry_ordinal)
        entries = Enum.filter(state.entries, &(&1.entry_ordinal <= head))

        selected =
          cond do
            before = opts[:before] ->
              entries |> Enum.filter(&(&1.entry_ordinal < before)) |> Enum.take(-opts[:limit])

            after_cursor = opts[:after] ->
              entries
              |> Enum.filter(&(&1.entry_ordinal > after_cursor))
              |> Enum.take(opts[:limit])

            true ->
              Enum.take(entries, -opts[:limit])
          end

        first = if selected == [], do: 0, else: hd(selected).entry_ordinal
        last = if selected == [], do: 0, else: List.last(selected).entry_ordinal

        {:ok,
         %{
           engagement_id: state.engagement,
           entries: selected,
           head: head,
           first: first,
           last: last,
           has_older: Enum.any?(entries, &(&1.entry_ordinal < first)),
           has_newer: Enum.any?(entries, &(&1.entry_ordinal > last))
         }}
      end)
    end

    def submit_conversation_command(caller, target, command, opts) do
      request({:submit, command}, caller, target, opts, fn state ->
        if state.fail_submit,
          do: {:error, :conversation_unavailable},
          else: {:ok, receipt(state, command)}
      end)
    end

    def conversation_command(caller, target, id, opts),
      do: request({:command, id}, caller, target, opts, fn _ -> {:error, :not_found} end)

    def conversation_activity(caller, target, opts) do
      request(:activity, caller, target, opts, fn state ->
        {:ok,
         %{
           commands: [],
           source_watermark: 9,
           index_watermark: 9,
           incomplete: false,
           has_more: false,
           next_cursor: nil,
           engagement_id: state.engagement,
           truncated: false
         }}
      end)
    end

    def conversation_interactions(caller, target, id, opts) do
      request({:interactions, id}, caller, target, opts, fn state ->
        {:ok, %{command_id: id, engagement_id: state.engagement, interactions: []}}
      end)
    end

    defp receipt(state, command) do
      %{
        id: command.id,
        name: "chat.send",
        text: command.text,
        principal_id: "human_ui",
        agent_id: "agent_ui",
        engagement_id: state.engagement,
        status: :admitted,
        outcome: nil,
        admitted_cursor: 1,
        updated_cursor: 1
      }
    end

    defp request(operation, caller, target, opts, run) do
      {pid, owner} = Application.fetch_env!(:arbor_dashboard, :voice_fixture)
      send(owner, {:host, operation, caller, target, opts})
      state = Agent.get(pid, & &1)

      cond do
        not state.allowed or caller != "human_ui" or target != "agent_ui" or
            opts[:session_token] != "proof" ->
          {:error, :unauthorized}

        opts[:expected_engagement_id] && opts[:expected_engagement_id] != state.engagement ->
          {:error, :conversation_scope_changed}

        true ->
          run.(state)
      end
    end
  end

  defmodule VoiceAPI do
    @moduledoc false

    def desk_recording_options do
      {state, _owner} = Application.fetch_env!(:arbor_dashboard, :voice_fixture)

      Agent.get(
        state,
        &Map.get(
          &1,
          :voice_recording_options,
          {:ok, %{default_ms: 10_000, min_ms: 100, max_ms: 30_000}}
        )
      )
    end

    def start_desk_turn(user, agent, opts) do
      {_state, owner} = Application.fetch_env!(:arbor_dashboard, :voice_fixture)
      send(owner, {:voice_start, user, agent, opts})
      {:ok, String.duplicate("v", 43)}
    end

    def desk_turn_status(_id) do
      {state, _owner} = Application.fetch_env!(:arbor_dashboard, :voice_fixture)
      Agent.get(state, &Map.get(&1, :voice_status, {:ok, %{terminal: false, state: :capture}}))
    end

    def finish_desk_turn(id) do
      {state, owner} = Application.fetch_env!(:arbor_dashboard, :voice_fixture)
      send(owner, {:voice_finish, id})

      Agent.update(
        state,
        &Map.put(
          &1,
          :voice_status,
          {:ok, %{terminal: false, state: :finishing, can_finish: false}}
        )
      )

      :ok
    end

    def cancel_desk_turn(id) do
      {_state, owner} = Application.fetch_env!(:arbor_dashboard, :voice_fixture)
      send(owner, {:voice_cancel, id})
      {:error, :cleanup_pending}
    end
  end

  defmodule MultimediaAPI do
    @moduledoc false

    def request_microphone_permission do
      {_state, owner} = Application.fetch_env!(:arbor_dashboard, :voice_fixture)
      send(owner, :microphone_permission_requested)
      :authorized
    end
  end

  setup do
    keys = [:conversation_api, :voice_fixture]
    previous = Map.new(keys, &{&1, Application.fetch_env(:arbor_dashboard, &1)})

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             allowed: true,
             engagement: @engagement,
             entries: [entry("owned-history", "owned private text", 61)],
             fail_submit: false
           }
         end}
      )

    Application.put_env(:arbor_dashboard, :conversation_api, Host)
    Application.put_env(:arbor_dashboard, :voice_fixture, {state, self()})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_env(:arbor_dashboard, key, value) end)
    end)

    %{state: state}
  end

  test "security regression: real LiveView uses scoped history and durable admission with socket proof",
       %{conn: conn} do
    {:ok, view, html} = live(authenticated(conn), "/conversation/agent_ui")
    refute html =~ ~s(value="proof")
    html = await(view, &String.contains?(&1, "owned private text"))
    refute html =~ ~s(value="proof")

    # Unbound access check, then the bounded page pinned to that engagement.
    assert_receive {:host, :window, "human_ui", "agent_ui", access}
    assert access[:session_token] == "proof"
    assert access[:limit] == 1
    assert_receive {:host, :window, "human_ui", "agent_ui", page}
    assert page[:session_token] == "proof"
    assert page[:expected_engagement_id] == @engagement

    render_change(view, "update-input", %{"message" => "durable draft"})

    render_submit(view, "send-message", %{
      "message" => "durable draft",
      "command_id" => "ui-request-1"
    })

    assert_receive {:host, {:submit, command}, "human_ui", "agent_ui", opts}
    assert command == %{id: "ui-request-1", text: "durable draft"}
    assert opts[:session_token] == "proof"
    assert opts[:expected_engagement_id] == @engagement
    assert await(view, &String.contains?(&1, "Message received")) =~ "Message received"
  end

  test "security regression: local voice control uses socket proof and exact existing conversation",
       %{conn: conn} do
    enable_voice()
    {:ok, view, html} = open(conn)
    assert html =~ "Local voice check"
    refute_received {:voice_start, _, _, _}
    refute_received :microphone_permission_requested
    flush_host()

    render_click(view, "voice:loopback", %{
      "user" => "human_attacker",
      "session_token" => "forged",
      "duration_ms" => "30000"
    })

    # The click itself re-checks current authority with the socket proof and
    # the bound engagement before any device is opened.
    assert_received {:host, :window, "human_ui", "agent_ui",
                     [expected_engagement_id: @engagement, session_token: "proof", limit: 1]}

    assert_received {:voice_start, "human_ui", "agent_ui", opts}
    assert opts[:session_token] == "proof"
    assert opts[:mode] == :loopback
    assert opts[:duration_ms] == 10_000
    assert opts[:expected_engagement_id] == @engagement
    refute render(view) =~ ~s(value="proof")
    assert has_element?(view, "#voice-desk button[phx-click='voice:talk'][disabled]")
  end

  test "voice cue waits for sample delivery before telling the user to speak", %{
    conn: conn,
    state: state
  } do
    enable_voice()

    put_voice_status(
      state,
      {:ok, %{terminal: false, state: :preparing_capture, can_finish: true}}
    )

    {:ok, view, _} = open(conn)
    render_click(view, "voice:talk", %{})
    send(view.pid, {:voice_desk_poll, @operation})
    assert render(view) =~ "Starting microphone—wait to speak."
    refute render(view) =~ "speak now"
    assert has_element?(view, "#voice-desk button[phx-click='voice:finish']")

    put_voice_status(state, {:ok, %{terminal: false, state: :capture, can_finish: true}})
    send(view.pid, {:voice_desk_poll, @operation})
    assert render(view) =~ "speak now"
  end

  test "voice duration uses operator settings, preserves exact milliseconds, and persists across turns",
       %{conn: conn, state: state} do
    enable_voice()

    Agent.update(
      state,
      &Map.put(
        &1,
        :voice_recording_options,
        {:ok, %{default_ms: 4_500, min_ms: 1_001, max_ms: 12_999}}
      )
    )

    {:ok, view, _} = open(conn)
    assert has_element?(view, "#voice-duration[value='4.5'][min='1.001'][max='12.999']")

    view |> form("#voice-duration-form", %{"seconds" => "7.501"}) |> render_change()
    render_click(view, "voice:talk", %{})
    assert_received {:voice_start, "human_ui", "agent_ui", first}
    assert first[:duration_ms] == 7_501

    # A forged change while capture owns the device cannot change this turn or
    # the user's saved choice. The status names the actual admitted duration.
    render_change(view, "voice:duration", %{"seconds" => "2"})
    send(view.pid, {:voice_desk_poll, @operation})
    assert render(view) =~ "Recording for 7.501 seconds"
    assert has_element?(view, "#voice-duration[value='7.501'][disabled]")

    put_voice_status(
      state,
      {:ok, %{terminal: true, state: :complete, mode: :conversation, error: nil, result: %{}}}
    )

    send(view.pid, {:voice_desk_poll, @operation})
    assert render(view) =~ "Voice turn complete"
    assert has_element?(view, "#voice-duration[value='7.501']:not([disabled])")
    render_click(view, "voice:loopback", %{})
    assert_received {:voice_start, "human_ui", "agent_ui", second}
    assert second[:duration_ms] == 7_501
    assert second[:mode] == :loopback
  end

  test "voice duration rejects malformed and out-of-range input before recording", %{conn: conn} do
    enable_voice()
    {:ok, view, _} = open(conn)

    for value <- [
          "",
          "0.099",
          "30.001",
          "-1",
          "1e1",
          "1.0001",
          "NaN",
          %{},
          String.duplicate("1", 100)
        ] do
      render_change(view, "voice:duration", %{"seconds" => value})
      assert has_element?(view, "#voice-duration[aria-invalid='true']")
      assert has_element?(view, "#voice-desk button[phx-click='voice:talk'][disabled]")
      render_click(view, "voice:talk", %{})
      refute_received {:voice_start, _, _, _}
    end

    render_change(view, "voice:duration", %{"seconds" => "0.1"})
    render_click(view, "voice:loopback", %{})
    assert_received {:voice_start, "human_ui", "agent_ui", opts}
    assert opts[:duration_ms] == 100
  end

  test "voice duration rechecks operator limits immediately before starting", %{
    conn: conn,
    state: state
  } do
    enable_voice()
    {:ok, view, _} = open(conn)
    assert has_element?(view, "#voice-duration[value='10']")

    Agent.update(
      state,
      &Map.put(
        &1,
        :voice_recording_options,
        {:ok, %{default_ms: 3_000, min_ms: 100, max_ms: 5_000}}
      )
    )

    render_click(view, "voice:talk", %{})
    refute_received {:voice_start, _, _, _}
    assert has_element?(view, "#voice-duration[value='10'][max='5'][aria-invalid='true']")
    assert render(view) =~ "Choose a recording length from 0.1 to 5 seconds."

    render_change(view, "voice:duration", %{"seconds" => "5"})
    render_click(view, "voice:talk", %{})
    assert_received {:voice_start, "human_ui", "agent_ui", opts}
    assert opts[:duration_ms] == 5_000
  end

  test "unavailable voice duration policy disables recording without requesting devices",
       %{conn: conn, state: state} do
    enable_voice()
    Agent.update(state, &Map.put(&1, :voice_recording_options, {:error, :invalid_config}))

    {:ok, view, _} = open(conn)
    assert render(view) =~ "Recording settings are unavailable"
    assert has_element?(view, "#voice-desk button[phx-click='voice:talk'][disabled]")
    render_click(view, "voice:talk", %{})
    refute_received {:voice_start, _, _, _}
    refute_received :microphone_permission_requested
  end

  test "security regression: remote browser cannot request host microphone or start capture", %{
    conn: conn
  } do
    enable_voice()
    {:ok, view, html} = open(conn, {203, 0, 113, 8})
    refute html =~ "Local voice check"
    render_click(view, "voice:talk", %{})
    render_click(view, "voice:request-permission", %{})
    refute_received {:voice_start, _, _, _}
    refute_received :microphone_permission_requested
  end

  test "security regression: revoked chat authority blocks even explicit permission and recording",
       %{conn: conn, state: state} do
    enable_voice()
    {:ok, view, _} = open(conn)
    Agent.update(state, &%{&1 | allowed: false})
    render_click(view, "voice:talk", %{})
    render_click(view, "voice:request-permission", %{})
    refute_received {:voice_start, _, _, _}
    refute_received :microphone_permission_requested
    refute render(view) =~ "owned private text"
  end

  test "voice finish is advertised only by active status and invokes the public control", %{
    conn: conn,
    state: state
  } do
    enable_voice()
    {:ok, view, _} = open(conn)
    render_click(view, "voice:talk", %{})
    refute has_element?(view, "#voice-desk button[phx-click='voice:finish']")

    put_voice_status(state, {:ok, %{terminal: false, state: :capture, can_finish: true}})
    send(view.pid, {:voice_desk_poll, @operation})
    assert render(view) =~ "Finish and send"
    render_click(view, "voice:finish", %{})
    assert_received {:voice_finish, @operation}
    refute has_element?(view, "#voice-desk button[phx-click='voice:finish']")
    assert render(view) =~ "Finishing recording and closing the microphone"
    assert has_element?(view, "#voice-desk button[phx-click='voice:cancel']")
  end

  test "security regression: finishing voice rechecks current conversation authority", %{
    conn: conn,
    state: state
  } do
    enable_voice()
    {:ok, view, _} = open(conn)
    render_click(view, "voice:talk", %{})

    put_voice_status(state, {:ok, %{terminal: false, state: :capture, can_finish: true}})
    send(view.pid, {:voice_desk_poll, @operation})
    assert render(view) =~ "Finish and send"
    Agent.update(state, &%{&1 | allowed: false})
    render_click(view, "voice:finish", %{})
    refute_received {:voice_finish, _}
    assert_received {:voice_cancel, @operation}
  end

  test "voice completion reloads canonical history without rendering status reply payload", %{
    conn: conn,
    state: state
  } do
    enable_voice()
    {:ok, view, _} = open(conn)
    render_click(view, "voice:talk", %{})

    # The voice turn's canonical transcript row lands in the host history; the
    # status reply is an unscoped payload that must never be rendered.
    Agent.update(state, fn current ->
      %{current | entries: current.entries ++ [entry("voice-row", "canonical voice turn", 62)]}
    end)

    put_voice_status(
      state,
      {:ok,
       %{
         terminal: true,
         state: :complete,
         mode: :conversation,
         error: nil,
         result: %{reply: "unscoped-status-reply"}
       }}
    )

    send(view.pid, {:voice_desk_poll, @operation})
    html = render(view)
    assert html =~ "Voice turn complete"
    refute html =~ "unscoped-status-reply"
    refute has_element?(view, "#voice-desk button[phx-click='voice:talk'][disabled]")
    html = await(view, &String.contains?(&1, "canonical voice turn"))
    refute html =~ "unscoped-status-reply"
  end

  test "security regression: revoked terminal result cannot be presented as successful completion",
       %{conn: conn, state: state} do
    enable_voice()
    {:ok, view, _} = open(conn)
    render_click(view, "voice:talk", %{})

    put_voice_status(
      state,
      {:ok,
       %{
         terminal: true,
         state: :complete,
         mode: :conversation,
         result: nil,
         error: :conversation_unauthorized
       }}
    )

    send(view.pid, {:voice_desk_poll, @operation})
    html = render(view)
    assert html =~ "Conversation access changed"
    refute html =~ "Voice turn complete"
    refute has_element?(view, "#voice-desk button[phx-click='voice:talk'][disabled]")
  end

  test "security regression: lost scope retains disabled controls until positive desk termination",
       %{conn: conn, state: state} do
    enable_voice()
    {:ok, view, _} = open(conn)
    render_click(view, "voice:talk", %{})
    assert_received {:voice_start, "human_ui", "agent_ui", started}
    assert started[:expected_engagement_id] == @engagement

    # Conversation ownership moves to another engagement while capture runs.
    Agent.update(state, &%{&1 | engagement: @other_engagement})
    send(view.pid, :refresh_conversation)
    await(view, &String.contains?(&1, "Private data was cleared"))

    # Explicitly rebinding to the new, authorized scope does not adopt or
    # release the earlier operation: it is cancelled and stays reserved.
    render_click(view, "conversation:reconnect", %{})
    assert has_element?(view, "textarea:not([disabled])")
    send(view.pid, {:voice_desk_poll, @operation})
    assert_receive {:voice_cancel, @operation}
    assert render(view) =~ "Audio cleanup is still pending"
    assert has_element?(view, "#voice-desk button[phx-click='voice:cancel']")
    assert has_element?(view, "#voice-desk button[phx-click='voice:talk'][disabled]")

    send(view.pid, {:voice_desk_poll, @operation})
    assert has_element?(view, "#voice-desk button[phx-click='voice:cancel']")
    render_click(view, "voice:talk", %{})
    refute_received {:voice_start, _, _, _}

    put_voice_status(state, {:ok, %{terminal: true, state: :cancelled, error: :cancelled}})
    send(view.pid, {:voice_desk_poll, @operation})
    assert render(view) =~ "Voice operation cancelled. Audio is closed."
    refute has_element?(view, "#voice-desk button[phx-click='voice:cancel']")
    refute has_element?(view, "#voice-desk button[phx-click='voice:talk'][disabled]")
  end

  test "security regression: a loopback proxy forwarding remote traffic cannot expose host audio",
       %{conn: conn} do
    enable_voice()
    {:ok, view, html} = open(conn, {127, 0, 0, 1}, [{"x-forwarded-for", "203.0.113.8"}])
    refute html =~ "Local voice check"
    render_click(view, "voice:talk", %{})
    refute_received {:voice_start, _, _, _}
  end

  test "security regression: missing or negative transport evidence denies voice but preserves chat",
       %{conn: conn} do
    enable_voice()

    for headers <- [[], [{"x-arbor-voice-direct", "false"}]] do
      connection =
        conn
        |> Plug.Conn.put_private(:live_view_connect_info, %{
          peer_data: %{address: {127, 0, 0, 1}},
          uri: %URI{host: "localhost"},
          x_headers: headers
        })
        |> authenticated()

      {:ok, view, html} = live(connection, "/conversation/agent_ui")
      refute html =~ "Local voice check"
      assert await(view, &String.contains?(&1, "owned private text")) =~ "owned private text"
      refute has_element?(view, "#voice-desk")
      render_click(view, "voice:talk", %{})
      render_click(view, "voice:request-permission", %{})
      refute_received {:voice_start, _, _, _}
      refute_received :microphone_permission_requested
    end
  end

  test "uncertain submission keeps exact ID and text; reload restore only reads receipt", %{
    conn: conn,
    state: state
  } do
    Agent.update(state, &%{&1 | fail_submit: true})
    {:ok, view, _} = live(authenticated(conn), "/conversation/agent_ui")
    await(view, &String.contains?(&1, "owned private text"))
    render_change(view, "update-input", %{"message" => "draft"})
    render_submit(view, "send-message", %{"message" => "draft", "command_id" => "stable-id"})

    assert_receive {:host, {:submit, %{id: "stable-id", text: "draft"}}, "human_ui", "agent_ui",
                    _}

    await(view, &String.contains?(&1, "Delivery is unconfirmed"))
    assert has_element?(view, "textarea", "draft")

    # A reloaded tab restores the saved request from browser storage. Restoring
    # reads only the durable receipt for that exact ID; it never resubmits.
    {:ok, reloaded, _} = live(authenticated(conn), "/conversation/agent_ui")
    await(reloaded, &String.contains?(&1, "owned private text"))
    flush_host()
    render_click(reloaded, "conversation:restore", %{"id" => "stable-id", "text" => "draft"})
    assert_receive {:host, {:command, "stable-id"}, "human_ui", "agent_ui", _}
    await(reloaded, &String.contains?(&1, "Delivery is unconfirmed"))
    refute_receive {:host, {:submit, _}, _, _, _}, 100

    # A different request cannot replace the unresolved one, even when the
    # disabled send control is bypassed with a forged submit.
    render_change(reloaded, "update-input", %{"message" => "different draft"})
    assert has_element?(reloaded, "#conversation-composer button[type='submit'][disabled]")

    render_submit(reloaded, "send-message", %{
      "message" => "different draft",
      "command_id" => "different-id"
    })

    refute_receive {:host, {:submit, _}, _, _, _}, 100

    # Only an explicit retry resubmits, and only the exact original ID and text.
    Agent.update(state, &%{&1 | fail_submit: false})
    render_click(reloaded, "conversation:retry", %{})
    assert_receive {:host, {:command, "stable-id"}, "human_ui", "agent_ui", _}
    assert_receive {:host, {:submit, command}, "human_ui", "agent_ui", _}
    assert command == %{id: "stable-id", text: "draft"}
    await(reloaded, &String.contains?(&1, "Message received"))
    refute_receive {:host, {:submit, %{id: "different-id"}}, _, _, _}, 100
  end

  test "voice completion distinguishes played audio from screen-only presentation", %{
    conn: conn,
    state: state
  } do
    enable_voice()
    {:ok, view, _} = open(conn)

    for {disposition, expected} <- [
          {:played, "The response finished playing through the host speaker."},
          {:screen_only, "The response is on screen; no audio was played."}
        ] do
      render_click(view, "voice:talk", %{})

      put_voice_status(
        state,
        {:ok,
         %{
           terminal: true,
           state: :complete,
           mode: :conversation,
           error: nil,
           result: %{disposition: disposition, reply: "private-status-payload"}
         }}
      )

      send(view.pid, {:voice_desk_poll, @operation})
      html = render(view)
      assert html =~ expected
      refute html =~ "private-status-payload"
      refute has_element?(view, "#voice-desk button[phx-click='voice:talk'][disabled]")
    end
  end

  defp entry(id, content, ordinal),
    do: %{
      id: id,
      role: "user",
      content: content,
      timestamp: "2026-09-27T12:00:00Z",
      entry_ordinal: ordinal
    }

  defp authenticated(conn),
    do: Plug.Test.init_test_session(conn, %{"agent_id" => "human_ui", "session_token" => "proof"})

  defp open(conn, address \\ {127, 0, 0, 1}, headers \\ []) do
    conn
    |> Plug.Conn.put_private(:live_view_connect_info, %{
      peer_data: %{address: address},
      uri: %URI{host: "localhost"},
      x_headers: [{"x-arbor-voice-direct", "true"} | headers]
    })
    |> authenticated()
    |> live("/conversation/agent_ui")
  end

  defp put_voice_status(state, status),
    do: Agent.update(state, &Map.put(&1, :voice_status, status))

  defp enable_voice do
    for {key, value} <- [
          voice_api: VoiceAPI,
          multimedia_api: MultimediaAPI,
          local_voice_controls: true
        ] do
      previous = Application.fetch_env(:arbor_dashboard, key)
      on_exit(fn -> restore_env(:arbor_dashboard, key, previous) end)
      Application.put_env(:arbor_dashboard, key, value)
    end
  end

  defp await(view, predicate, tries \\ 200)
  defp await(_, _, 0), do: flunk("conversation did not reach expected display state")

  defp await(view, predicate, tries) do
    html = render(view)

    if predicate.(html) do
      html
    else
      Process.sleep(10)
      await(view, predicate, tries - 1)
    end
  end

  defp flush_host do
    receive do
      {:host, _, _, _, _} -> flush_host()
    after
      0 -> :ok
    end
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
