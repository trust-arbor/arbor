defmodule ArborBreeze.NoticeViewTest do
  use ExUnit.Case, async: true
  alias ArborBreeze.{Controller, View}
  @moduletag :fast
  @page JSON.decode!(File.read!(Path.join(__DIR__, "support/notice_page.json")))

  defp start do
    observer = self()
    host = start_supervised!({Agent, fn -> %{head: 5, mode: :normal} end})

    options = [
      caller: "human_linked_alias",
      target: @page["target_agent_id"],
      poll_interval_ms: 100,
      notice_page_limit: 2,
      proof_provider: fn _ -> {:ok, [session_token: "private-notice-proof"]} end,
      adapter_options: [
        transport: fn context, proof ->
          assert proof == [session_token: "private-notice-proof"]
          send(observer, {:native_notice_read, context})
          state = Agent.get(host, & &1)

          if state.mode == :denied do
            {:error, :unauthorized}
          else
            case context.operation do
              :window ->
                {:ok,
                 %{
                   engagement_id: @page["engagement_id"],
                   entries: [
                     %{
                       id: "message",
                       role: "assistant",
                       content: "Transcript only",
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

              :activity ->
                {:error, :unsupported_conversation_capability}

              :notices ->
                if(state.mode == :failed,
                  do: {:error, :conversation_unavailable},
                  else: {:ok, page(state.head, context.options)}
                )

              :submit ->
                send(observer, :unexpected_submit)
                {:error, :invalid_command}
            end
          end
        end
      ]
    ]

    {:ok, controller} = Controller.start(connection_options: options)
    session = Breeze.Test.start!(View, size: {100, 30}, start_opts: [controller: controller])

    on_exit(fn ->
      try do
        Breeze.Test.stop(session)
      catch
        :exit, {:noproc, {GenServer, :stop, _}} -> :ok
      end

      Controller.close(controller)
    end)

    eventually(fn -> assigns(session).snapshot.notices_status == :available end)
    {host, controller, session}
  end

  defp assigns(session), do: Breeze.Test.metadata(session).assigns
  defp eventually(fun, remaining \\ 200)
  defp eventually(fun, 0), do: assert(fun.(), "Notice view did not reach expected state")

  defp eventually(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, remaining - 1)
        )
  end

  test "native F13 panel pages notices independently and returns to the untouched draft" do
    {host, _controller, session} = start()
    Breeze.Test.event(session, "chat:draft", %{value: "independent draft café"})
    Breeze.Test.input(session, "F13")
    eventually(fn -> Breeze.Test.focused(session) == "notices" end)
    assert Breeze.Test.render_text!(session) =~ "Notice 5"
    refute Breeze.Test.render_text!(session) =~ "Transcript only"
    Breeze.Test.input(session, "PageUp")

    eventually(fn ->
      Enum.map(assigns(session).snapshot.projection["notices"], & &1["ordinal"]) == [3, 2]
    end)

    Agent.update(host, &%{&1 | head: 7})
    eventually(fn -> assigns(session).snapshot.notice_window.head == 7 end)
    assert assigns(session).snapshot.notice_window.through == 5
    Breeze.Test.input(session, "Home")

    eventually(fn ->
      Enum.map(assigns(session).snapshot.projection["notices"], & &1["ordinal"]) == [7, 6]
    end)

    Breeze.Test.input(session, "Escape")
    assert Breeze.Test.focused(session) == "draft"
    assert assigns(session).editor.draft == "independent draft café"
    assert Breeze.Test.render_text!(session) =~ "Transcript only"
    assert assigns(session).snapshot.projection["speech"] == []
    refute_receive :unexpected_submit
  end

  test "native notice failure clears notices while transcript remains; revocation clears both and resets panel" do
    {host, _controller, session} = start()
    Breeze.Test.input(session, "F13")
    Agent.update(host, &%{&1 | mode: :failed})
    eventually(fn -> assigns(session).snapshot.notices_status == :unavailable end)
    assert Breeze.Test.render_text!(session) =~ "Notices unavailable"
    refute Breeze.Test.render_text!(session) =~ "Notice 5"
    Breeze.Test.input(session, "Escape")
    assert Breeze.Test.render_text!(session) =~ "Transcript only"
    Agent.update(host, &%{&1 | mode: :denied})
    eventually(fn -> assigns(session).snapshot.private_cleared end)
    assert assigns(session).snapshot.projection["notices"] == []
    assert assigns(session).snapshot.projection["messages"] == []
    refute assigns(session).notices_open
    assert Breeze.Test.focused(session) == "draft"
  end

  test "native notice host text is literal, never ANSI authority or hidden OSC output" do
    {_host, _controller, session} = start()
    Breeze.Test.event(session, "chat:send", %{value: " /notices"})
    text = Breeze.Test.render_text!(session)
    assert text =~ "visible malicious"
    refute text =~ "\e"
    refute text =~ "credential-sentinel"
    refute text =~ "recipient_subject_id"
    refute text =~ "payload_sha256"
    refute_receive :unexpected_submit
  end

  test "documented shortcut matches the actual portable decoder and native panel receives its modifier event" do
    assert {:key, %{"key" => "F7", "shiftKey" => true}} = Breeze.Input.decode("\e[18;2~")
    assert {:key, "F13"} = Breeze.Input.decode("\e[57376u")
    assert {:key, "25~"} = Breeze.Input.decode("\e[25~")
    {_host, _controller, session} = start()
    Breeze.Test.input(session, %{"key" => "F7", "shiftKey" => true})
    assert Breeze.Test.focused(session) == "notices"
    assert Breeze.Test.render_text!(session) =~ "Notice 5"
    refute assigns(session).controls_open
    refute_receive :unexpected_submit
  end

  defp page(head, opts) do
    through = opts[:through] || head

    eligible =
      for ordinal <- through..1//-1,
          is_nil(opts[:before]) or ordinal < opts[:before],
          do: notice(ordinal)

    records = Enum.take(eligible, opts[:limit])
    older = length(eligible) > length(records)

    %{
      @page
      | "head" => head,
        "through" => through,
        "notices" => records,
        "has_older" => older,
        "next_before" => if(older, do: List.last(records)["ordinal"])
    }
  end

  defp notice(ordinal) do
    text = "Notice #{ordinal} · café 東京\n\e]0;hidden title\a\e[31mvisible malicious\e[0m"

    record =
      hd(@page["notices"])
      |> Map.put("ordinal", ordinal)
      |> Map.put("text", text)
      |> Map.put(
        "notice_id",
        "notice_" <> (ordinal |> Integer.to_string(16) |> String.pad_leading(32, "0"))
      )

    payload = [
      "arbor.notice.provenance.v1",
      @page["owner_id"],
      @page["target_agent_id"],
      @page["engagement_id"],
      record["recipient_subject_id"],
      record["notice_id"],
      record["kind"],
      text
    ]

    digest = :crypto.hash(:sha256, JSON.encode!(payload)) |> Base.encode16(case: :lower)
    put_in(record, ["provenance", "taint", "payload_sha256"], digest)
  end
end
