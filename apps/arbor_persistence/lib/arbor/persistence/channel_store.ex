defmodule Arbor.Persistence.ChannelStore do
  @moduledoc """
  Persistence context for communication channels and messages.

  Channels are shared message containers with sender identity tracking.
  Currently used as the durable backend for ChatHistory (DM channels)
  and will serve as the foundation for the unified channel communications
  architecture.
  """

  import Ecto.Query

  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.{Channel, ChannelMessage}

  require Logger

  # ── Channel lifecycle ──────────────────────────────────────────────

  @doc """
  Create a new channel.

  ## Options

  - `:type` — "dm", "group", "public", "ops_room" (default: "dm")
  - `:name` — display name
  - `:owner_id` — creator agent_id or user_id
  - `:members` — list of member maps `[%{id: ..., name: ..., type: ...}]`
  - `:metadata` — extensible JSONB
  """
  @spec create_channel(String.t(), keyword()) :: {:ok, Channel.t()} | {:error, term()}
  def create_channel(channel_id, opts \\ []) do
    attrs = %{
      channel_id: channel_id,
      type: Keyword.get(opts, :type, "dm"),
      name: Keyword.get(opts, :name),
      owner_id: Keyword.get(opts, :owner_id),
      members: Keyword.get(opts, :members, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get a channel by its channel_id string.
  """
  @spec get_channel(String.t()) :: {:ok, Channel.t()} | {:error, :not_found}
  def get_channel(channel_id) do
    case Repo.one(from c in Channel, where: c.channel_id == ^channel_id) do
      nil -> {:error, :not_found}
      channel -> {:ok, channel}
    end
  end

  @doc """
  Get or create a channel — idempotent.
  """
  @spec ensure_channel(String.t(), keyword()) :: {:ok, Channel.t()} | {:error, term()}
  def ensure_channel(channel_id, opts \\ []) do
    case get_channel(channel_id) do
      {:ok, channel} -> {:ok, channel}
      {:error, :not_found} -> create_channel(channel_id, opts)
    end
  end

  @doc """
  List channels with optional filters.

  ## Options

  - `:type` — filter by channel type
  - `:owner_id` — filter by owner
  - `:limit` — max results (default: 100)
  """
  @spec list_channels(keyword()) :: [Channel.t()]
  def list_channels(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    query = from c in Channel, order_by: [desc: c.updated_at], limit: ^limit

    query =
      case Keyword.get(opts, :type) do
        nil -> query
        type -> from c in query, where: c.type == ^type
      end

    query =
      case Keyword.get(opts, :owner_id) do
        nil -> query
        owner -> from c in query, where: c.owner_id == ^owner
      end

    Repo.all(query)
  end

  @doc """
  Add a member to a channel's members JSONB array.
  """
  @spec add_member(String.t(), map()) :: {:ok, Channel.t()} | {:error, term()}
  def add_member(channel_id, member) when is_map(member) do
    case get_channel(channel_id) do
      {:ok, channel} ->
        current = channel.members || []
        updated = current ++ [member]

        channel
        |> Channel.changeset(%{members: updated})
        |> Repo.update()

      error ->
        error
    end
  end

  @doc """
  Remove a member from a channel by their ID.
  """
  @spec remove_member(String.t(), String.t()) :: {:ok, Channel.t()} | {:error, term()}
  def remove_member(channel_id, member_id) do
    case get_channel(channel_id) do
      {:ok, channel} ->
        current = channel.members || []
        updated = Enum.reject(current, fn m -> m["id"] == member_id end)

        channel
        |> Channel.changeset(%{members: updated})
        |> Repo.update()

      error ->
        error
    end
  end

  # ── Messages ───────────────────────────────────────────────────────

  @doc """
  Append a message to a channel.

  ## Required attrs

  - `:sender_id` — who sent it
  - `:content` — message text

  ## Optional attrs

  - `:sender_name`, `:sender_type`, `:metadata`, `:timestamp`
  """
  @spec append_message(String.t(), map()) :: {:ok, ChannelMessage.t()} | {:error, term()}
  def append_message(channel_id, attrs) when is_map(attrs) do
    case get_channel(channel_id) do
      {:ok, channel} ->
        attrs
        |> Map.put(:channel_id, channel.id)
        |> Map.put_new(:timestamp, DateTime.utc_now())
        |> then(&ChannelMessage.changeset(%ChannelMessage{}, &1))
        |> Repo.insert()

      {:error, :not_found} ->
        {:error, :channel_not_found}
    end
  end

  @doc """
  Load messages from a channel, ordered by timestamp ascending.

  ## Options

  - `:limit` — max messages (default: 100)
  - `:before` — only messages before this DateTime
  - `:after` — only messages after this DateTime
  """
  @spec load_messages(String.t(), keyword()) :: [ChannelMessage.t()]
  def load_messages(channel_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    before_ts = Keyword.get(opts, :before)
    after_ts = Keyword.get(opts, :after)

    case get_channel(channel_id) do
      {:ok, channel} ->
        query =
          from m in ChannelMessage,
            where: m.channel_id == ^channel.id,
            order_by: [asc: m.timestamp],
            limit: ^limit

        query =
          if before_ts do
            from m in query, where: m.timestamp < ^before_ts
          else
            query
          end

        query =
          if after_ts do
            from m in query, where: m.timestamp > ^after_ts
          else
            query
          end

        Repo.all(query)

      {:error, _} ->
        []
    end
  end

  @doc """
  Load the N most recent messages, returned in ascending order (oldest first).
  """
  @spec load_recent_messages(String.t(), keyword()) :: [ChannelMessage.t()]
  def load_recent_messages(channel_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    case get_channel(channel_id) do
      {:ok, channel} ->
        # Subquery to get recent messages desc, then reverse for display order
        from(m in ChannelMessage,
          where: m.channel_id == ^channel.id,
          order_by: [desc: m.timestamp],
          limit: ^limit
        )
        |> Repo.all()
        |> Enum.reverse()

      {:error, _} ->
        []
    end
  end

  @doc """
  Count messages in a channel.
  """
  @spec message_count(String.t()) :: non_neg_integer()
  def message_count(channel_id) do
    case get_channel(channel_id) do
      {:ok, channel} ->
        Repo.one(
          from m in ChannelMessage,
            where: m.channel_id == ^channel.id,
            select: count()
        )

      {:error, _} ->
        0
    end
  end

  # ── Search & Management ──────────────────────────────────────────

  @doc """
  Search channels with composable filters.

  ## Options

  - `:name` — ILIKE substring match on channel name
  - `:type` — exact type match
  - `:owner_id` — exact owner match
  - `:member_id` — JSONB containment check on members array
  - `:limit` — max results (default: 50)
  """
  @spec search_channels(keyword()) :: [Channel.t()]
  def search_channels(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    query = from(c in Channel, order_by: [desc: c.updated_at], limit: ^limit)

    query =
      case Keyword.get(opts, :name) do
        nil -> query
        name -> from(c in query, where: ilike(c.name, ^"%#{name}%"))
      end

    query =
      case Keyword.get(opts, :type) do
        nil -> query
        type -> from(c in query, where: c.type == ^type)
      end

    query =
      case Keyword.get(opts, :owner_id) do
        nil -> query
        owner -> from(c in query, where: c.owner_id == ^owner)
      end

    query =
      case Keyword.get(opts, :member_id) do
        nil ->
          query

        member_id ->
          member_json = Jason.encode!([%{"id" => member_id}])
          from(c in query, where: fragment("? @> ?::jsonb", c.members, ^member_json))
      end

    Repo.all(query)
  end

  @doc """
  Update a channel's name and/or metadata.

  Attrs can include `:name` and/or `:metadata` (merged into existing).
  """
  @spec update_channel(String.t(), map()) :: {:ok, Channel.t()} | {:error, term()}
  def update_channel(channel_id, attrs) when is_map(attrs) do
    case get_channel(channel_id) do
      {:ok, channel} ->
        update_attrs =
          attrs
          |> maybe_merge_metadata(channel)
          |> Map.take([:name, :metadata])

        channel
        |> Channel.changeset(update_attrs)
        |> Repo.update()

      error ->
        error
    end
  end

  defp maybe_merge_metadata(%{metadata: new_meta} = attrs, channel) when is_map(new_meta) do
    merged = Map.merge(channel.metadata || %{}, new_meta)
    Map.put(attrs, :metadata, merged)
  end

  defp maybe_merge_metadata(attrs, _channel), do: attrs

  @doc """
  Soft-archive a channel by setting metadata.archived = true.
  """
  @spec archive_channel(String.t()) :: {:ok, Channel.t()} | {:error, term()}
  def archive_channel(channel_id) do
    update_channel(channel_id, %{metadata: %{"archived" => true}})
  end

  @doc """
  Hard-delete a channel and its messages.
  """
  @spec delete_channel(String.t()) :: :ok | {:error, term()}
  def delete_channel(channel_id) do
    case get_channel(channel_id) do
      {:ok, channel} ->
        # Delete messages first (FK constraint)
        from(m in ChannelMessage, where: m.channel_id == ^channel.id)
        |> Repo.delete_all()

        Repo.delete(channel)
        :ok

      error ->
        error
    end
  end

  @doc """
  Check if the channel store is available (Repo process running).
  """
  @spec available?() :: boolean()
  def available? do
    Process.whereis(Repo) != nil
  end
end
