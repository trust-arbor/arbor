defmodule Arbor.Dashboard.Live.ConversationHomePreviewTest do
  use ExUnit.Case, async: true
  import Phoenix.Component, only: [assign: 2]

  alias Arbor.Dashboard.Live.ConversationLive.Home

  @moduletag :fast
  @engagement "eng_11111111111111111111111111111111"
  @agent "agent_home_preview"

  test "empty transcript preview does not clear the authorized directory or selected conversation" do
    conversation = row(%{preview: ""})
    {socket, worker, selected} = pending_index()
    updated = publish(socket, worker, conversation)

    assert updated.assigns.home_loaded
    assert updated.assigns.home_rows == [conversation]
    assert updated.assigns.home_selected == selected
    assert updated.assigns.home_notice == nil
    assert updated.assigns.home_workers == %{}

    html = rail(updated)
    assert html =~ "conversation-link-#{@engagement}"
    assert html =~ "href=\"/c/#{@engagement}\""
    assert html =~ "aria-current=\"page\""
    assert html =~ "Cedar"
    refute html =~ "No accessible conversations on this page"
  end

  test "nil and bounded nonempty previews retain the directory and render safely" do
    for preview <- [nil, "Café <private>", String.duplicate("🌲", 160)] do
      conversation = row(%{preview: preview})
      {socket, worker, selected} = pending_index()
      updated = publish(socket, worker, conversation)

      assert updated.assigns.home_loaded
      assert updated.assigns.home_rows == [conversation]
      assert updated.assigns.home_selected == selected
      assert updated.assigns.home_notice == nil
      html = rail(updated)
      assert html =~ "conversation-link-#{@engagement}"
      assert html =~ "Cedar"
      refute html =~ "<private>"

      if preview == "Café <private>", do: assert(html =~ "Café &lt;private&gt;")
    end
  end

  test "security regression malformed preview agent and name still clear private directory rows" do
    for changes <- [
          %{preview: <<255>>},
          %{preview: 42},
          %{preview: String.duplicate("a", 161)},
          %{preview: "a" <> String.duplicate("\u0301", 1_280)},
          %{agent_id: ""},
          %{agent_id: "human_foreign"},
          %{display_name: ""}
        ] do
      {socket, worker, _selected} = pending_index()
      updated = publish(socket, worker, row(changes))

      refute updated.assigns.home_loaded
      assert updated.assigns.home_rows == []
      assert updated.assigns.home_selected == nil

      assert updated.assigns.home_notice ==
               "Conversations could not be loaded. Refresh to try again."

      html = rail(updated)
      refute html =~ "conversation-link-#{@engagement}"
      refute html =~ "Cedar"
      refute html =~ "Retained private preview"
    end
  end

  defp pending_index do
    {pid, ref} = spawn_monitor(fn -> receive(do: (:stop -> :ok)) end)
    guard = spawn(fn -> receive(do: (:stop -> :ok)) end)
    timer = Process.send_after(self(), :test_home_index_timeout, 60_000)

    worker = %{
      pid: pid,
      ref: ref,
      generation: make_ref(),
      guard: guard,
      timer: timer,
      input: 0
    }

    on_exit(fn ->
      Process.cancel_timer(timer)
      Process.exit(pid, :kill)
      Process.exit(guard, :kill)
    end)

    selected = row(%{preview: "Retained private preview"})

    socket =
      %Phoenix.LiveView.Socket{}
      |> Home.mount(true)
      |> assign(
        agent_id: @agent,
        home_requested: @engagement,
        home_selected: selected,
        home_rows: [selected],
        home_loaded: true,
        home_workers: %{index: worker}
      )

    {socket, worker, selected}
  end

  defp publish(socket, worker, conversation) do
    page = %{conversations: [conversation], next_cursor: nil, has_more: false}
    updated = Home.result(socket, worker.pid, worker.generation, :index, {:ok, page})
    on_exit(fn -> Home.close(updated) end)
    updated
  end

  defp rail(socket) do
    %{
      __changed__: %{},
      rows: socket.assigns.home_rows,
      selected: socket.assigns.home_selected,
      loading: Map.has_key?(socket.assigns.home_workers, :index),
      loaded: socket.assigns.home_loaded,
      more: socket.assigns.home_has_more,
      cursor: socket.assigns.home_page_cursor,
      open: socket.assigns.home_rail_open
    }
    |> Home.rail()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp row(changes) do
    Map.merge(
      %{
        engagement_id: @engagement,
        agent_id: @agent,
        display_name: "Cedar",
        status: "active",
        updated_at: "2026-10-02T00:00:00Z",
        preview: "Private preview",
        last_message_at: "2026-10-02T00:00:00Z"
      },
      changes
    )
  end
end
