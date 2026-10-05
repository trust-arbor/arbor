defmodule Arbor.Dashboard.Live.ConversationNoticesTest do
  use Arbor.Dashboard.ConnCase, async: false
  @moduletag :fast
  @page JSON.decode!(File.read!(Path.join(__DIR__, "../fixtures/notice_page.json")))

  defmodule Host do
    def conversation_window(caller, target, opts) do
      read(:window, caller, target, opts, fn page, _mode ->
        {:ok,
         %{
           engagement_id: page["engagement_id"],
           entries: [
             %{
               id: "transcript",
               role: "assistant",
               content: "Transcript separate café",
               timestamp: "2026-10-03T00:00:00Z",
               entry_ordinal: 1
             }
           ],
           head: 1,
           first: 1,
           last: 1,
           has_older: false,
           has_newer: false
         }}
      end)
    end

    def conversation_activity(caller, target, opts),
      do:
        read(:activity, caller, target, opts, fn _, _ ->
          {:error, :unsupported_conversation_capability}
        end)

    def conversation_notices(caller, target, opts) do
      read(:notices, caller, target, opts, fn page, mode ->
        case mode do
          :failed -> {:error, :conversation_unavailable}
          :unsupported -> {:error, :notice_subject_required}
          _ -> {:ok, page}
        end
      end)
    end

    def submit_conversation_command(_, _, _, _),
      do: raise("local notices command reached host admission")

    defp read(operation, caller, target, opts, run) do
      {host, observer} = Application.fetch_env!(:arbor_dashboard, :notice_surface_fixture)
      state = Agent.get(host, & &1)
      send(observer, {:mounted_notice_read, operation, opts})

      cond do
        caller != "human_linked_alias" or target != state.page["target_agent_id"] or
          opts[:session_token] != "notice-proof" or state.mode == :denied ->
          {:error, :unauthorized}

        opts[:expected_engagement_id] &&
            opts[:expected_engagement_id] != state.page["engagement_id"] ->
          {:error, :conversation_scope_changed}

        true ->
          run.(state.page, state.mode)
      end
    end
  end

  defmodule Voice do
    def desk_recording_options, do: {:ok, %{default_ms: 12_000, min_ms: 100, max_ms: 30_000}}
  end

  setup do
    settings = [conversation_api: Host, voice_api: Voice, local_voice_controls: false]

    old =
      Map.new(
        [:notice_surface_fixture | Keyword.keys(settings)],
        &{&1, Application.fetch_env(:arbor_dashboard, &1)}
      )

    host = start_supervised!({Agent, fn -> %{page: @page, mode: :normal} end})
    for {key, value} <- settings, do: Application.put_env(:arbor_dashboard, key, value)
    Application.put_env(:arbor_dashboard, :notice_surface_fixture, {host, self()})

    on_exit(fn ->
      for {key, value} <- old do
        case value do
          {:ok, value} -> Application.put_env(:arbor_dashboard, key, value)
          :error -> Application.delete_env(:arbor_dashboard, key)
        end
      end
    end)

    %{host: host}
  end

  defp open(conn) do
    conn =
      Plug.Test.init_test_session(conn, %{
        "agent_id" => "human_linked_alias",
        "session_token" => "notice-proof"
      })

    live(conn, "/conversation/" <> @page["target_agent_id"])
  end

  defp await(view, predicate, remaining \\ 250)
  defp await(_, _, 0), do: flunk("Mounted notice panel did not reach expected state")

  defp await(view, predicate, remaining) do
    html = render(view)

    if predicate.(html),
      do: html,
      else:
        (
          Process.sleep(10)
          await(view, predicate, remaining - 1)
        )
  end

  test "mounted notice panel renders producer text separately without identity provenance or audio effects",
       %{conn: conn} do
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "Notices available"))
    assert has_element?(view, "#conversation-notices ol li", "進捗: café 🌳")
    assert has_element?(view, "#conversation-scroll", "Transcript separate café")
    refute has_element?(view, "#conversation-scroll", "進捗:")
    panel = view |> element("#conversation-notices") |> render()
    refute panel =~ "human_fixture_original_recipient"
    refute panel =~ "payload_sha256"
    refute panel =~ "<audio"
    assert has_element?(view, "#conversation-notices-status[role=status][aria-live=polite]")

    render_submit(element(view, "#conversation-composer"), %{
      "message" => "  /notices",
      "command_id" => "local_notice"
    })

    assert has_element?(view, "#conversation-local-notice", "separate read-only panel")
    refute has_element?(view, "#conversation-scroll", "/notices")
  end

  test "mounted notice-only failure clears prior notice text while auth loss clears the entire conversation",
       %{conn: conn, host: host} do
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "Notices available"))
    Agent.update(host, &%{&1 | mode: :failed})
    render_click(element(view, "button[phx-click='conversation:latest-notices']"))
    await(view, &String.contains?(&1, "Notices could not be checked"))
    refute has_element?(view, "#conversation-notices li")
    assert has_element?(view, "#conversation-scroll", "Transcript separate café")
    Agent.update(host, &%{&1 | mode: :denied})
    render_click(element(view, "button[phx-click='conversation:latest-notices']"))
    await(view, &(not String.contains?(&1, "Transcript separate café")))
    refute has_element?(view, "#conversation-notices li")
    refute render(view) =~ "進捗:"
  end

  test "mounted unsupported notices retain transcript and explicitly disable latest read", %{
    conn: conn,
    host: host
  } do
    Agent.update(host, &%{&1 | mode: :unsupported})
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "Notices require a human conversation identity"))
    assert has_element?(view, "button[phx-click='conversation:latest-notices'][disabled]")
    assert has_element?(view, "#conversation-scroll", "Transcript separate café")
  end
end
