defmodule Arbor.Dashboard.Live.ConversationLive.Home do
  @moduledoc """
  Socket-first owner-authorized conversation directory. Only closed public
  facade rows reach the socket. Proof stays in sensitive, short-lived workers;
  each reply must match its monitored PID and generation before publication.
  """
  use Phoenix.Component
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3]
  alias Arbor.Dashboard.{Config, Components.VoiceDeskComponent}
  alias Arbor.Dashboard.Live.ConversationLive.Surface
  @timeout 6_000
  @refresh 30_000
  @limit 20

  def mount(socket, enabled) do
    assign(socket,
      home_enabled: enabled,
      home_rows: [],
      home_selected: nil,
      home_requested: nil,
      home_workers: %{},
      home_cursor: nil,
      home_page_cursor: 0,
      home_has_more: false,
      home_notice: nil,
      home_notices: %{},
      home_loaded: false,
      home_refresh_timer: nil,
      home_rail_open: true
    )
  end

  def route(socket, params) do
    if socket.assigns.home_enabled and connected?(socket) do
      requested = params["engagement_id"]
      socket = if socket.assigns.home_loaded, do: socket, else: start_index(socket, 0)

      if requested != socket.assigns.home_requested do
        socket
        |> cancel_worker(:reference)
        |> reset_surface()
        |> assign(home_requested: requested, home_selected: nil)
        |> notice(:reference, nil)
        |> start_reference(requested)
      else
        socket
      end
    else
      socket
    end
  end

  def event(socket, "home:refresh", _) do
    socket = start_index(socket, socket.assigns.home_page_cursor)

    if is_nil(socket.assigns.agent_id),
      do: start_reference(socket, socket.assigns.home_requested),
      else: socket
  end

  def event(socket, "home:more", _) do
    if socket.assigns.home_has_more and is_integer(socket.assigns.home_cursor),
      do: start_index(socket, socket.assigns.home_cursor),
      else: socket
  end

  def event(socket, "home:previous", _) do
    if socket.assigns.home_page_cursor > 0,
      do: start_index(socket, max(0, socket.assigns.home_page_cursor - @limit)),
      else: socket
  end

  def event(socket, "home:rail", _),
    do: assign(socket, home_rail_open: !socket.assigns.home_rail_open)

  def event(socket, "home:close-rail", _), do: assign(socket, home_rail_open: false)

  def event(socket, _, _), do: socket

  def refresh(socket) do
    socket = assign(socket, home_refresh_timer: nil)

    if socket.assigns.home_enabled,
      do: start_index(socket, socket.assigns.home_page_cursor),
      else: socket
  end

  def result(socket, pid, generation, kind, value) do
    case socket.assigns.home_workers[kind] do
      %{pid: ^pid, generation: ^generation} = worker ->
        socket = finish_worker(socket, kind, worker)
        consume(socket, kind, worker, value)

      _ ->
        socket
    end
  end

  def timeout(socket, pid, generation, kind) do
    case socket.assigns.home_workers[kind] do
      %{pid: ^pid, generation: ^generation} ->
        socket |> cancel_worker(kind) |> unavailable(kind)

      _ ->
        socket
    end
  end

  def down(socket, ref) do
    case Enum.find(socket.assigns.home_workers, fn {_kind, worker} -> worker.ref == ref end) do
      {kind, worker} -> socket |> finish_worker(kind, worker) |> unavailable(kind)
      nil -> socket
    end
  end

  # A connection's live authority check is independent of directory refresh.
  # An idle revocation must also remove names/previews already on the rail.
  def sync(socket) do
    if socket.assigns.conversation_rebind_required do
      clear_directory(socket)
    else
      socket
    end
  end

  def close(socket) do
    for {_kind, worker} <- socket.assigns[:home_workers] || %{}, do: stop(worker)
    if timer = socket.assigns[:home_refresh_timer], do: Process.cancel_timer(timer)
    :ok
  end

  defp start_index(socket, cursor) do
    if socket.assigns.home_enabled do
      socket
      |> start_worker(:index, cursor, :list_conversations, cursor: cursor, limit: @limit)
      |> notice(:index, nil)
    else
      socket
    end
  end

  defp start_reference(socket, nil), do: socket

  defp start_reference(socket, id) do
    if is_binary(id) and Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, id),
      do:
        socket
        |> start_worker(:reference, id, :resolve_conversation_reference, [])
        |> notice(:reference, nil),
      else: notice(socket, :reference, "This conversation is unavailable or access has changed.")
  end

  defp start_worker(socket, kind, input, function, options) do
    socket = cancel_worker(socket, kind)
    owner = self()
    generation = make_ref()
    caller = socket.assigns[:current_agent_id]
    proof = socket.assigns[:session_token]
    api = Config.conversation_api()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:sensitive, true)
        args = if kind == :index, do: [caller], else: [caller, input]
        result = call(api, function, args ++ [[session_token: proof] ++ options])
        send(owner, {:home_result, self(), generation, kind, result})
      end)

    # The owner may die without terminate/2 (for example an untrappable kill).
    # This independent lifetime guard never holds proof and can retire a
    # blocked facade call even when neither owner nor worker can handle mail.
    guard = spawn(fn -> guard_worker(owner, pid) end)
    timer = Process.send_after(self(), {:home_timeout, pid, generation, kind}, @timeout)

    worker = %{
      pid: pid,
      ref: ref,
      timer: timer,
      guard: guard,
      generation: generation,
      input: input
    }

    assign(socket, home_workers: Map.put(socket.assigns.home_workers, kind, worker))
  end

  defp guard_worker(owner, worker) do
    owner_ref = Process.monitor(owner)
    worker_ref = Process.monitor(worker)

    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_ref, :process, ^worker, _} -> :ok
    after
      @timeout -> Process.exit(worker, :kill)
    end
  end

  defp consume(socket, :index, worker, {:ok, page}) do
    case validate_page(page, worker.input) do
      {:ok, rows, next, more} ->
        socket =
          assign(socket,
            home_rows: rows,
            home_page_cursor: worker.input,
            home_cursor: next,
            home_has_more: more,
            home_loaded: true
          )

        socket = socket |> notice(:index, nil) |> notice(:access, nil) |> schedule_refresh()

        # Empty filtered pages can still have later authorized entries. Never
        # describe that as an empty directory; the explicit More action remains.
        if is_nil(socket.assigns.home_requested) and is_nil(socket.assigns.agent_id) and
             rows != [] do
          row = hd(rows)
          start_reference(socket, row.engagement_id)
        else
          socket
        end

      :error ->
        unavailable(socket, :index)
    end
  end

  defp consume(socket, :reference, worker, {:ok, row}) do
    if valid_row?(row) and row.engagement_id == worker.input do
      socket =
        socket
        |> reset_surface()
        |> Surface.mount(row.agent_id)
        |> assign(
          conversation_engagement_id: row.engagement_id,
          home_selected: row,
          home_rail_open: false
        )
        |> notice(:reference, nil)
        |> notice(:access, nil)
        |> Surface.connect()

      if socket.assigns.conversation_authorized,
        do: socket,
        else: socket |> assign(home_selected: nil) |> sync()
    else
      unavailable(socket, :reference)
    end
  end

  defp consume(socket, _kind, _worker, {:error, :unauthorized}), do: deny(socket)

  defp consume(socket, :reference, _worker, {:error, reason})
       when reason in [:not_found, :conversation_scope_changed, :invalid_identifier],
       do:
         socket
         |> assign(home_selected: nil)
         |> notice(:reference, "This conversation is unavailable or access has changed.")

  defp consume(socket, kind, _worker, _), do: unavailable(socket, kind)

  defp unavailable(socket, :index) do
    socket
    |> assign(
      home_rows: [],
      home_selected: nil,
      home_cursor: nil,
      home_has_more: false,
      home_loaded: false
    )
    |> notice(:index, "Conversations could not be loaded. Refresh to try again.")
    |> schedule_refresh()
  end

  defp unavailable(socket, :reference),
    do:
      socket
      |> assign(home_selected: nil)
      |> notice(
        :reference,
        "This conversation could not be opened. Refresh or choose another conversation."
      )

  defp deny(socket) do
    socket
    |> reset_surface(socket.assigns.agent_id)
    |> clear_directory()
    |> push_event("conversation-access-denied", %{})
    |> push_event("conversation-home-clear", %{subject: socket.assigns[:current_agent_id]})
    |> assign(home_loaded: false)
    |> notice(:access, "Sign in with a valid session and chat access to continue.")
  end

  defp notice(socket, kind, value) do
    notices = Map.put(socket.assigns.home_notices, kind, value)

    assign(socket,
      home_notices: notices,
      home_notice: notices[:access] || notices[:reference] || notices[:index]
    )
  end

  defp clear_directory(socket) do
    socket = socket |> cancel_worker(:index) |> cancel_worker(:reference)

    assign(socket,
      home_rows: [],
      home_selected: nil,
      home_cursor: nil,
      home_has_more: false,
      home_loaded: false
    )
  end

  defp reset_surface(socket, target \\ nil) do
    socket =
      if socket.assigns[:voice_operation],
        do: VoiceDeskComponent.event(socket, "cancel", %{}),
        else: socket

    Surface.close(socket)
    if ref = socket.assigns.conversation_monitor, do: Process.demonitor(ref, [:flush])
    Surface.mount(socket, target)
  end

  defp schedule_refresh(socket) do
    if timer = socket.assigns.home_refresh_timer, do: Process.cancel_timer(timer)
    assign(socket, home_refresh_timer: Process.send_after(self(), :home_refresh, @refresh))
  end

  defp cancel_worker(socket, kind) do
    if worker = socket.assigns.home_workers[kind], do: stop(worker)
    assign(socket, home_workers: Map.delete(socket.assigns.home_workers, kind))
  end

  defp stop(worker) do
    Process.cancel_timer(worker.timer)
    Process.demonitor(worker.ref, [:flush])
    Process.exit(worker.pid, :kill)
    Process.exit(worker.guard, :kill)
  end

  defp finish_worker(socket, kind, worker) do
    Process.cancel_timer(worker.timer)
    Process.demonitor(worker.ref, [:flush])
    Process.exit(worker.guard, :kill)
    assign(socket, home_workers: Map.delete(socket.assigns.home_workers, kind))
  end

  defp call(api, function, args) do
    apply(api, function, args)
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  defp validate_page(%{conversations: rows, next_cursor: next, has_more: more} = page, cursor)
       when map_size(page) == 3 and is_list(rows) and is_boolean(more) do
    if length(rows) <= @limit and Enum.all?(rows, &valid_row?/1) and
         ((more and next == cursor + @limit) or (!more and is_nil(next))),
       do: {:ok, rows, next, more},
       else: :error
  end

  defp validate_page(_, _), do: :error

  defp valid_row?(
         %{
           engagement_id: id,
           agent_id: agent,
           display_name: name,
           status: status,
           updated_at: updated,
           preview: preview,
           last_message_at: last
         } = row
       ) do
    map_size(row) == 7 and is_binary(id) and Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, id) and
      bounded?(agent, 256) and Regex.match?(~r/\Aagent_[A-Za-z0-9_-]+\z/, agent) and
      bounded?(name, 640) and String.length(name) <= 160 and
      status in ["active", "parked", "archived"] and timestamp?(updated) and
      (is_nil(preview) or preview == "" or
         (bounded?(preview, 2_560) and String.length(preview) <= 160)) and
      (is_nil(last) or timestamp?(last))
  end

  defp valid_row?(_), do: false

  defp bounded?(value, bytes),
    do: is_binary(value) and byte_size(value) in 1..bytes and String.valid?(value)

  defp timestamp?(value) when is_binary(value) and byte_size(value) <= 40,
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp timestamp?(_), do: false

  attr :rows, :list, required: true
  attr :selected, :map, default: nil
  attr :loading, :boolean, default: false
  attr :loaded, :boolean, default: false
  attr :more, :boolean, default: false
  attr :cursor, :integer, default: 0
  attr :open, :boolean, default: true

  def rail(assigns) do
    ~H"""
    <aside
      id="conversation-rail"
      class={"aw-home-rail" <> if(@open, do: " is-open", else: "")}
      aria-label="Your conversations"
      aria-busy={to_string(@loading)}
    >
      <div class="aw-home-rail-heading">
        <h2>Your conversations</h2>
        <button
          type="button"
          phx-click="home:refresh"
          disabled={@loading}
          aria-label="Refresh conversations"
        >
          ↻
        </button>
      </div>
      <p :if={@loading && !@loaded} class="aw-home-rail-state" role="status">
        Loading conversations…
      </p>
      <p :if={@loaded && @rows == [] && !@more} class="aw-home-rail-state">
        No accessible conversations on this page.
      </p>
      <p :if={@loaded && @rows == [] && @more} class="aw-home-rail-state">
        More conversations are available to check.
      </p>
      <nav aria-label="Choose a conversation">
        <.link
          :for={row <- @rows}
          patch={"/c/" <> row.engagement_id}
          phx-click={
            Phoenix.LiveView.JS.push("home:close-rail")
            |> Phoenix.LiveView.JS.focus(to: "#conversation-main")
          }
          id={"conversation-link-" <> row.engagement_id}
          class={"aw-home-conversation" <> if(@selected && @selected.engagement_id == row.engagement_id, do: " is-selected", else: "")}
          aria-current={
            if(@selected && @selected.engagement_id == row.engagement_id, do: "page", else: nil)
          }
        >
          <strong>{row.display_name}</strong>
          <span :if={row.preview}>{row.preview}</span>
          <time datetime={row.updated_at}>{String.slice(row.updated_at, 0, 10)}</time>
        </.link>
      </nav>
      <div class="aw-home-pages" aria-label="Conversation directory pages">
        <button :if={@cursor > 0} type="button" phx-click="home:previous" disabled={@loading}>
          ← Previous
        </button>
        <button :if={@more} type="button" phx-click="home:more" disabled={@loading}>
          Next →
        </button>
      </div>
    </aside>
    """
  end

  attr :selected, :map, required: true
  attr :snapshot, :map, required: true

  def inspector(assigns) do
    ~H"""
    <details id="conversation-inspector" class="aw-home-inspector">
      <summary>Conversation details</summary>
      <dl>
        <dt>Agent</dt>
        <dd>{@selected.agent_id}</dd>
        <dt>Conversation</dt>
        <dd>{@selected.engagement_id}</dd>
        <dt>State</dt>
        <dd>{@selected.status}</dd>
        <dt>History in view</dt>
        <dd>{@snapshot.window.first}–{@snapshot.window.last} of {@snapshot.window.head}</dd>
        <dt>Connection</dt>
        <dd>{if @snapshot.connected, do: "Connected", else: "Disconnected"}</dd>
        <dt :if={@snapshot.receipt}>Delivery</dt>
        <dd :if={@snapshot.receipt}>{@snapshot.receipt["status"]}</dd>
      </dl>
    </details>
    """
  end
end
