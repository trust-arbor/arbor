defmodule Arbor.Comms.InteractionRegistry do
  @moduledoc """
  Cluster-aware discovery for interaction requests with origin-node authority.

  `Arbor.Comms.InteractionRegistry.Authority` is the canonical lifecycle owner
  for interactions created on its node. Every response, abandonment, or expiry
  is routed back to that one GenServer and serialized there. Phoenix.Tracker is
  only an eventually-consistent discovery and audit mirror; it is never used as
  a compare-and-set authority.
  """

  use Phoenix.Tracker

  alias Arbor.Comms.InteractionRegistry.{Authority, Routing}
  alias Arbor.Comms.InteractionRegistry.Supervisor, as: RegistrySupervisor
  alias Arbor.Contracts.Comms.Interaction

  @topic "interactions"
  @terminal_topic "interactions:resolved"
  @rpc_timeout_ms 5_000

  @type terminal_status :: :responded | :abandoned | :expired
  @type timeout_capture :: %{
          authority_node: node(),
          authority_pid: pid(),
          request_id: String.t()
        }

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    Supervisor.child_spec({RegistrySupervisor, opts},
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    )
  end

  @doc "Start the interaction authority and its Tracker discovery mirror."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> {:error, {:already_started, pid}}
      nil -> RegistrySupervisor.start_link(opts)
    end
  end

  @doc false
  @spec start_tracker(keyword()) :: GenServer.on_start()
  def start_tracker(opts) do
    pubsub = Keyword.get(opts, :pubsub_server, Arbor.Comms.PubSub)
    opts = Keyword.merge([name: __MODULE__, pubsub_server: pubsub], opts)
    Phoenix.Tracker.start_link(__MODULE__, opts, opts)
  end

  @doc """
  Record a new interaction under the trusted local authority.

  The authority node is assigned from the running node and mirrored by the
  authority process. Caller data cannot select or override it.
  """
  @spec put(Interaction.t(), keyword()) :: {:ok, Interaction.t()} | {:error, term()}
  def put(%Interaction{request_id: request_id} = interaction, _opts \\ []) do
    case authority_for(request_id) do
      :not_found ->
        route_call(node(), :put, [interaction])

      {:ok, authority_node} when authority_node == node() ->
        route_call(node(), :put, [interaction])

      {:ok, _remote_authority} ->
        {:error, :already_tracked}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Look up a canonically pending interaction by request ID."
  @spec get(String.t()) :: {:ok, Interaction.t()} | :not_found
  def get(request_id) when is_binary(request_id) do
    case with_authority(request_id, :pending, [request_id]) do
      {:ok, %Interaction{}} = found -> found
      _ -> :not_found
    end
  end

  @doc """
  Route a response to the interaction's trusted authority node.

  The authority serializes the terminal transition and returns the original
  interaction to the router for response publication.
  """
  @spec resolve(String.t(), keyword()) ::
          {:ok, Interaction.t()}
          | {:error,
             {:already_terminal, terminal_status()}
             | :ambiguous_authority
             | :authority_unavailable}
          | :not_found
  def resolve(request_id, opts \\ []) when is_binary(request_id) do
    response = Keyword.get(opts, :response)
    metadata = Keyword.get(opts, :metadata, %{})
    metadata = if is_map(metadata), do: metadata, else: %{}

    with_authority(request_id, :respond, [request_id, response, metadata])
  end

  @doc """
  Atomically abandon a pending interaction with an explicit reason.

  Repeating abandonment is idempotent. If a response already won, the
  authority returns `{:error, {:already_terminal, :responded}}` and never
  changes the stored response.
  """
  @spec abandon(String.t(), atom() | String.t(), keyword()) ::
          {:ok, Interaction.t() | :already_abandoned}
          | {:error,
             {:already_terminal, terminal_status()}
             | :ambiguous_authority
             | :authority_unavailable}
          | :not_found
  def abandon(request_id, reason, _opts \\ [])
      when is_binary(request_id) and (is_atom(reason) or is_binary(reason)) do
    with_authority(request_id, :abandon, [request_id, reason])
  end

  @doc false
  @spec capture_timeout_authority(String.t(), non_neg_integer()) ::
          {:ok, timeout_capture(), :armed | {:terminal, map()}}
          | {:error, term()}
          | :not_found
  def capture_timeout_authority(request_id, timeout_ms)
      when is_binary(request_id) and is_integer(timeout_ms) and timeout_ms >= 0 do
    case authority_for(request_id) do
      {:ok, authority_node} ->
        case route_call(authority_node, :arm_timeout, [request_id, timeout_ms]) do
          {:ok, %{authority_pid: authority_pid, outcome: outcome}}
          when is_pid(authority_pid) and node(authority_pid) == authority_node ->
            capture = %{
              authority_node: authority_node,
              authority_pid: authority_pid,
              request_id: request_id
            }

            {:ok, capture, outcome}

          {:ok, _invalid_authority_receipt} ->
            {:error, :authority_unavailable}

          other ->
            other
        end

      :not_found ->
        :not_found

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec finalize_timeout(timeout_capture(), String.t()) ::
          {:ok, map()} | {:error, term()} | :not_found
  def finalize_timeout(
        %{
          authority_node: authority_node,
          authority_pid: authority_pid,
          request_id: request_id
        },
        request_id
      )
      when is_atom(authority_node) and is_pid(authority_pid) and
             node(authority_pid) == authority_node and is_binary(request_id) do
    Authority.finalize_timeout(authority_pid, request_id)
  end

  def finalize_timeout(_capture, _request_id), do: {:error, :invalid_timeout_capture}

  @doc "Return the authoritative first terminal transition for an interaction."
  @spec get_terminal(String.t()) :: {:ok, map()} | :not_found
  def get_terminal(request_id) when is_binary(request_id) do
    case with_authority(request_id, :terminal, [request_id]) do
      {:ok, %{} = terminal} -> {:ok, terminal}
      _ -> :not_found
    end
  end

  @doc """
  Look up a resolved response while it remains in the authority's bounded
  terminal retention window. Abandonment and expiry are not responses.
  """
  @spec get_resolved(String.t()) ::
          {:ok, %{response: term(), metadata: map(), resolved_at: integer()}} | :not_found
  def get_resolved(request_id) when is_binary(request_id) do
    case get_terminal(request_id) do
      {:ok,
       %{
         status: :responded,
         response: response,
         metadata: metadata,
         resolved_at: resolved_at
       }} ->
        {:ok, %{response: response, metadata: metadata, resolved_at: resolved_at}}

      _ ->
        :not_found
    end
  end

  @doc "List interactions that their authority still reports as pending."
  @spec list_pending() :: [Interaction.t()]
  def list_pending do
    __MODULE__
    |> Phoenix.Tracker.list(@topic)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.flat_map(fn request_id ->
      case get(request_id) do
        {:ok, interaction} -> [interaction]
        :not_found -> []
      end
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "Pending interactions for a specific user, newest first."
  @spec list_pending_for_user(String.t()) :: [Interaction.t()]
  def list_pending_for_user(user_id) when is_binary(user_id) do
    list_pending()
    |> Enum.filter(fn %Interaction{user_id: pending_user} -> pending_user == user_id end)
    |> Enum.sort_by(& &1.submitted_at, {:desc, DateTime})
  end

  @doc false
  @spec authority_for(String.t()) :: {:ok, node()} | {:error, term()} | :not_found
  def authority_for(request_id) when is_binary(request_id) do
    authorities =
      request_id
      |> discovered_authorities()
      |> maybe_add_local_authority(request_id)
      |> Enum.uniq()

    case authorities do
      [authority_node] -> {:ok, authority_node}
      [] -> :not_found
      _ -> {:error, :ambiguous_authority}
    end
  end

  @doc "Reset local authority and Tracker mirror state (test-only)."
  @spec reset(keyword()) :: :ok
  def reset(_opts \\ []) do
    if Process.whereis(Authority), do: Authority.reset()

    # Remove entries owned by the pre-authority implementation, if any remain
    # during a live upgrade. Authority-owned entries were removed by reset/0.
    case Process.whereis(__MODULE__) do
      owner when is_pid(owner) ->
        for topic <- [@topic, @terminal_topic],
            {key, _meta} <- Phoenix.Tracker.list(__MODULE__, topic) do
          Phoenix.Tracker.untrack(__MODULE__, owner, topic, key)
        end

      nil ->
        :ok
    end

    Process.sleep(20)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    server = Keyword.fetch!(opts, :pubsub_server)
    {:ok, %{pubsub_server: server, node_name: Phoenix.PubSub.node_name(server)}}
  end

  @impl true
  def handle_diff(_diff, state), do: {:ok, state}

  defp with_authority(request_id, function, args) do
    case authority_for(request_id) do
      {:ok, authority_node} -> route_call(authority_node, function, args)
      :not_found -> :not_found
      {:error, _reason} = error -> error
    end
  end

  defp route_call(authority_node, function, args) do
    local_call = fn module, local_function, local_args ->
      if Process.whereis(module) do
        apply(module, local_function, local_args)
      else
        {:error, :authority_unavailable}
      end
    end

    Routing.dispatch(authority_node, function, args,
      timeout: @rpc_timeout_ms,
      local_call: local_call
    )
  rescue
    _ -> {:error, :authority_unavailable}
  catch
    :exit, _ -> {:error, :authority_unavailable}
  end

  defp discovered_authorities(request_id) do
    [@topic, @terminal_topic]
    |> Enum.flat_map(fn topic -> tracker_authorities(topic, request_id) end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp tracker_authorities(topic, request_id) do
    __MODULE__
    |> Phoenix.Tracker.get_by_key(topic, request_id)
    |> Enum.flat_map(fn
      {owner, meta} when is_pid(owner) and is_map(meta) ->
        case map_value(meta, :authority_node) do
          authority_node when is_atom(authority_node) -> [authority_node]
          _ -> [node(owner)]
        end

      _ ->
        []
    end)
  end

  defp maybe_add_local_authority(authorities, request_id) do
    if Process.whereis(Authority) do
      case Authority.status(request_id) do
        {:ok, _status} -> [node() | authorities]
        _ -> authorities
      end
    else
      authorities
    end
  end

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
