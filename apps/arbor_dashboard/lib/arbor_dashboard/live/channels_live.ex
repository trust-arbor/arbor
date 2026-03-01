defmodule Arbor.Dashboard.Live.ChannelsLive do
  @moduledoc """
  Channel communications dashboard.

  Shows active channels, allows filtering by name and type,
  creating new channels, and viewing channel details.
  """

  use Phoenix.LiveView
  use Arbor.Dashboard.Live.SignalSubscription

  import Arbor.Web.Components

  @impl true
  def mount(_params, _session, socket) do
    channels = safe_load_channels()
    {total, public_count} = count_stats(channels)

    socket =
      socket
      |> assign(
        page_title: "Channels",
        total_count: total,
        public_count: public_count,
        name_filter: "",
        type_filter: "",
        selected_channel: nil,
        channel_detail: nil,
        show_create: false,
        create_name: "",
        create_type: "group"
      )
      |> stream_configure(:channels, dom_id: &"channel-#{&1.channel_id}")
      |> stream(:channels, channels)

    socket = subscribe_signals(socket, "comms.*", &reload_channels/1)

    {:ok, socket}
  end

  defp reload_channels(socket) do
    channels = safe_load_channels(socket.assigns.name_filter, socket.assigns.type_filter)
    {total, public_count} = count_stats(channels)

    socket
    |> assign(total_count: total, public_count: public_count)
    |> stream(:channels, channels, reset: true)
  end

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("filter-name", %{"name" => name}, socket) do
    channels = safe_load_channels(name, socket.assigns.type_filter)

    socket =
      socket
      |> assign(name_filter: name)
      |> stream(:channels, channels, reset: true)

    {:noreply, socket}
  end

  def handle_event("filter-type", %{"type" => type}, socket) do
    channels = safe_load_channels(socket.assigns.name_filter, type)

    socket =
      socket
      |> assign(type_filter: type)
      |> stream(:channels, channels, reset: true)

    {:noreply, socket}
  end

  def handle_event("select-channel", %{"id" => channel_id}, socket) do
    detail = safe_load_detail(channel_id)
    {:noreply, assign(socket, selected_channel: channel_id, channel_detail: detail)}
  end

  def handle_event("close-detail", _params, socket) do
    {:noreply, assign(socket, selected_channel: nil, channel_detail: nil)}
  end

  def handle_event("show-create", _params, socket) do
    {:noreply, assign(socket, show_create: true)}
  end

  def handle_event("close-create", _params, socket) do
    {:noreply, assign(socket, show_create: false, create_name: "", create_type: "group")}
  end

  def handle_event("create-channel", %{"name" => name, "type" => type}, socket) do
    case safe_create_channel(name, type) do
      {:ok, _channel_id} ->
        channels = safe_load_channels(socket.assigns.name_filter, socket.assigns.type_filter)
        {total, public_count} = count_stats(channels)

        socket =
          socket
          |> assign(
            show_create: false,
            create_name: "",
            create_type: "group",
            total_count: total,
            public_count: public_count
          )
          |> stream(:channels, channels, reset: true)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Channels" subtitle="Internal channel communications" />

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-top: 1rem;">
      <.stat_card value={@total_count} label="Total Channels" color={:blue} />
      <.stat_card value={@public_count} label="Public" color={:green} />
    </div>

    <div style="display: flex; gap: 1rem; margin-top: 1rem; align-items: center;">
      <input
        type="text"
        placeholder="Search by name..."
        value={@name_filter}
        phx-keyup="filter-name"
        phx-value-name={@name_filter}
        name="name"
        style="
          flex: 1;
          padding: 0.5rem 0.75rem;
          border: 1px solid var(--aw-border, #333);
          border-radius: 4px;
          background: var(--aw-surface, #1a1a1a);
          color: var(--aw-text, #fff);
          font-size: 0.9rem;
        "
      />

      <select
        phx-change="filter-type"
        name="type"
        style="
          padding: 0.5rem 0.75rem;
          border: 1px solid var(--aw-border, #333);
          border-radius: 4px;
          background: var(--aw-surface, #1a1a1a);
          color: var(--aw-text, #fff);
          font-size: 0.9rem;
        "
      >
        <option value="">All Types</option>
        <option value="group" selected={@type_filter == "group"}>Group</option>
        <option value="public" selected={@type_filter == "public"}>Public</option>
        <option value="private" selected={@type_filter == "private"}>Private</option>
        <option value="dm" selected={@type_filter == "dm"}>DM</option>
        <option value="ops_room" selected={@type_filter == "ops_room"}>Ops Room</option>
      </select>

      <button
        phx-click="show-create"
        style="
          padding: 0.5rem 1rem;
          border: none;
          border-radius: 4px;
          background: var(--aw-primary, #60a5fa);
          color: white;
          font-weight: 500;
          cursor: pointer;
          transition: opacity 0.2s;
          white-space: nowrap;
        "
        onmouseover="this.style.opacity='0.8';"
        onmouseout="this.style.opacity='1';"
      >
        + New Channel
      </button>
    </div>

    <div id="channels-stream" phx-update="stream" style="margin-top: 1rem;">
      <div
        :for={{dom_id, channel} <- @streams.channels}
        id={dom_id}
        phx-click="select-channel"
        phx-value-id={channel.channel_id}
        style="
          border: 1px solid var(--aw-border, #333);
          border-radius: 6px;
          padding: 1rem;
          margin-bottom: 0.75rem;
          background: var(--aw-surface, #1a1a1a);
          cursor: pointer;
          transition: border-color 0.2s, box-shadow 0.2s;
        "
        onmouseover="this.style.borderColor='var(--aw-primary, #60a5fa)'; this.style.boxShadow='0 2px 8px rgba(96, 165, 250, 0.1)';"
        onmouseout="this.style.borderColor='var(--aw-border, #333)'; this.style.boxShadow='none';"
      >
        <div style="display: flex; justify-content: space-between; align-items: center;">
          <div style="flex: 1;">
            <div style="display: flex; align-items: center; gap: 0.75rem; margin-bottom: 0.25rem;">
              <h3 style="margin: 0; font-size: 1.1rem; color: var(--aw-text, #fff);">
                {channel.name}
              </h3>
              <.badge label={to_string(channel.type)} color={type_color(channel.type)} />
              <.badge :if={channel.encrypted} label="encrypted" color={:purple} />
            </div>
            <div style="display: flex; gap: 1rem; font-size: 0.9rem; color: var(--aw-text-muted, #888);">
              <span>{channel.member_count} members</span>
              <span>{channel.message_count} messages</span>
              <span :if={channel.owner_id}>Owner: {channel.owner_id}</span>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div :if={@total_count == 0} style="margin-top: 1rem;">
      <.empty_state
        icon="📡"
        title="No channels yet"
        hint="Create a channel or start agents that communicate to see channels here."
      />
    </div>

    <%!-- Detail Modal --%>
    <.modal
      :if={@channel_detail}
      id="channel-detail"
      show={@channel_detail != nil}
      title={"Channel: #{@selected_channel}"}
      on_cancel={Phoenix.LiveView.JS.push("close-detail")}
    >
      <div :if={detail = @channel_detail}>
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin-bottom: 1rem;">
          <div>
            <div style="color: var(--aw-text-muted, #888); font-size: 0.8rem;">Name</div>
            <div style="color: var(--aw-text, #fff);">{detail.name}</div>
          </div>
          <div>
            <div style="color: var(--aw-text-muted, #888); font-size: 0.8rem;">Type</div>
            <div><.badge label={to_string(detail.type)} color={type_color(detail.type)} /></div>
          </div>
          <div>
            <div style="color: var(--aw-text-muted, #888); font-size: 0.8rem;">Owner</div>
            <div style="color: var(--aw-text, #fff);">{detail.owner_id || "none"}</div>
          </div>
          <div>
            <div style="color: var(--aw-text-muted, #888); font-size: 0.8rem;">Encryption</div>
            <div style="color: var(--aw-text, #fff);">
              {if detail.encrypted, do: to_string(detail.encryption_type), else: "none"}
            </div>
          </div>
          <div>
            <div style="color: var(--aw-text-muted, #888); font-size: 0.8rem;">Members</div>
            <div style="color: var(--aw-text, #fff);">{detail.member_count}</div>
          </div>
          <div>
            <div style="color: var(--aw-text-muted, #888); font-size: 0.8rem;">Messages</div>
            <div style="color: var(--aw-text, #fff);">{detail.message_count}</div>
          </div>
        </div>

        <div :if={detail[:members] && detail.members != []} style="margin-top: 1rem;">
          <h4 style="color: var(--aw-text, #fff); margin-bottom: 0.5rem;">Members</h4>
          <div
            :for={member <- detail.members}
            style="
              display: flex; justify-content: space-between; align-items: center;
              padding: 0.5rem; border-bottom: 1px solid var(--aw-border, #333);
            "
          >
            <div>
              <span style="color: var(--aw-text, #fff);">{member.name || member.id}</span>
              <.badge label={to_string(member.type)} color={:gray} />
            </div>
            <span
              :if={member[:joined_at]}
              style="color: var(--aw-text-muted, #888); font-size: 0.8rem;"
            >
              {format_datetime(member.joined_at)}
            </span>
          </div>
        </div>
      </div>
    </.modal>

    <%!-- Create Modal --%>
    <.modal
      :if={@show_create}
      id="create-channel"
      show={@show_create}
      title="Create Channel"
      on_cancel={Phoenix.LiveView.JS.push("close-create")}
    >
      <form phx-submit="create-channel" style="display: flex; flex-direction: column; gap: 1rem;">
        <div>
          <label style="display: block; color: var(--aw-text-muted, #888); margin-bottom: 0.25rem; font-size: 0.9rem;">
            Channel Name
          </label>
          <input
            type="text"
            name="name"
            value={@create_name}
            required
            placeholder="e.g. brainstorm, ops-room"
            style="
              width: 100%;
              padding: 0.5rem 0.75rem;
              border: 1px solid var(--aw-border, #333);
              border-radius: 4px;
              background: var(--aw-surface, #1a1a1a);
              color: var(--aw-text, #fff);
              font-size: 0.9rem;
            "
          />
        </div>
        <div>
          <label style="display: block; color: var(--aw-text-muted, #888); margin-bottom: 0.25rem; font-size: 0.9rem;">
            Type
          </label>
          <select
            name="type"
            style="
              width: 100%;
              padding: 0.5rem 0.75rem;
              border: 1px solid var(--aw-border, #333);
              border-radius: 4px;
              background: var(--aw-surface, #1a1a1a);
              color: var(--aw-text, #fff);
              font-size: 0.9rem;
            "
          >
            <option value="group" selected={@create_type == "group"}>Group</option>
            <option value="public" selected={@create_type == "public"}>Public</option>
            <option value="private" selected={@create_type == "private"}>Private</option>
            <option value="ops_room" selected={@create_type == "ops_room"}>Ops Room</option>
          </select>
        </div>
        <button
          type="submit"
          style="
            padding: 0.5rem 1rem;
            border: none;
            border-radius: 4px;
            background: var(--aw-primary, #60a5fa);
            color: white;
            font-weight: 500;
            cursor: pointer;
            font-size: 0.9rem;
          "
        >
          Create Channel
        </button>
      </form>
    </.modal>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp type_color(:public), do: :green
  defp type_color(:private), do: :purple
  defp type_color(:dm), do: :blue
  defp type_color(:ops_room), do: :yellow
  defp type_color(:group), do: :gray
  defp type_color(_), do: :gray

  defp format_datetime(nil), do: ""
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(other), do: to_string(other)

  defp count_stats(channels) do
    total = length(channels)
    public = Enum.count(channels, &(&1.type == :public))
    {total, public}
  end

  # ── Safe wrappers ───────────────────────────────────────────────

  defp safe_load_channels(name_filter \\ "", type_filter \\ "") do
    comms = Arbor.Comms

    if Code.ensure_loaded?(comms) do
      opts = build_filter_opts(name_filter, type_filter)

      if opts == [] do
        # No filters — list from Registry + enrich
        comms.list_channels()
        |> Enum.map(fn {channel_id, _pid} ->
          case comms.get_channel_info(channel_id) do
            {:ok, info} -> Map.put(info, :channel_id, channel_id)
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      else
        comms.search_channels(opts)
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp build_filter_opts(name_filter, type_filter) do
    opts = []
    opts = if name_filter != "", do: [{:name, name_filter} | opts], else: opts
    opts = if type_filter != "", do: [{:type, type_filter} | opts], else: opts
    opts
  end

  defp safe_load_detail(channel_id) do
    comms = Arbor.Comms

    if Code.ensure_loaded?(comms) do
      case comms.get_channel_info(channel_id) do
        {:ok, info} ->
          members =
            case comms.channel_members(channel_id) do
              {:ok, m} -> m
              _ -> []
            end

          Map.put(info, :members, members)

        _ ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_create_channel(name, type) do
    comms = Arbor.Comms

    if Code.ensure_loaded?(comms) do
      type_atom = String.to_existing_atom(type)
      comms.create_channel(name, type: type_atom)
    else
      {:error, :comms_unavailable}
    end
  rescue
    _ -> {:error, :create_failed}
  catch
    :exit, _ -> {:error, :create_failed}
  end
end
