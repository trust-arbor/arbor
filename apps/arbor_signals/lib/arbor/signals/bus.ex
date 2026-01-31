defmodule Arbor.Signals.Bus do
  @moduledoc """
  Signal pub/sub bus for real-time signal distribution.

  Subscribers can register handlers that receive signals matching their
  subscription patterns. Supports both sync and async delivery.

  ## Authorization

  Restricted topics (configured via `Arbor.Signals.Config.restricted_topics/0`)
  require capability-based authorization. Two-layer defense:

  1. **Subscribe-time**: patterns that overlap restricted topics are checked
     against the configured authorizer before the subscription is created.
  2. **Delivery-time**: signals on restricted topics are only delivered to
     subscriptions that have been authorized for that topic.

  When no principal_id is provided (legacy callers), subscriptions to
  non-restricted patterns are allowed, but restricted patterns are denied.

  ## Patterns

  Patterns use dot-notation to match signal categories and types:

  - `"activity.*"` - All activity signals
  - `"*.agent_started"` - Agent started signals from any category
  - `"activity.agent_started"` - Specific category and type
  - `"*"` - All signals

  ## Usage

      {:ok, sub_id} = Arbor.Signals.Bus.subscribe("activity.*", fn signal ->
        IO.inspect(signal, label: "Activity")
        :ok
      end)

      # With authorization for restricted topics:
      {:ok, sub_id} = Arbor.Signals.Bus.subscribe("security.*", handler,
        principal_id: "agent_abc123")

      Arbor.Signals.Bus.unsubscribe(sub_id)
  """

  use GenServer

  alias Arbor.Identifiers
  alias Arbor.Signals.Config
  alias Arbor.Signals.Signal

  # Client API

  @doc """
  Start the signal bus.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Publish a signal to all matching subscribers.
  """
  @spec publish(Signal.t()) :: :ok
  def publish(%Signal{} = signal) do
    GenServer.cast(__MODULE__, {:publish, signal})
  end

  @doc """
  Subscribe to signals matching a pattern.

  ## Options

  - `:async` - Deliver signals asynchronously (default: true)
  - `:filter` - Additional filter function `(signal -> boolean)`
  - `:principal_id` - Agent ID for authorization (required for restricted topics)

  ## Returns

  `{:ok, subscription_id}` on success.
  `{:error, :unauthorized}` if the principal lacks capability for a restricted topic.
  """
  @spec subscribe(String.t(), (Signal.t() -> :ok | {:error, term()}), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def subscribe(pattern, handler, opts \\ []) when is_function(handler, 1) do
    GenServer.call(__MODULE__, {:subscribe, pattern, handler, opts})
  end

  @doc """
  Unsubscribe from signals.
  """
  @spec unsubscribe(String.t()) :: :ok | {:error, :not_found}
  def unsubscribe(subscription_id) do
    GenServer.call(__MODULE__, {:unsubscribe, subscription_id})
  end

  @doc """
  List active subscriptions.
  """
  @spec list_subscriptions() :: [map()]
  def list_subscriptions do
    GenServer.call(__MODULE__, :list_subscriptions)
  end

  @doc """
  Get bus statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok,
     %{
       subscriptions: %{},
       stats: %{
         total_published: 0,
         total_delivered: 0,
         total_errors: 0,
         total_auth_denied: 0
       }
     }}
  end

  @impl true
  def handle_cast({:publish, signal}, state) do
    state = deliver_to_subscribers(signal, state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:subscribe, pattern, handler, opts}, _from, state) do
    principal_id = Keyword.get(opts, :principal_id)
    restricted_topics = Config.restricted_topics()
    overlapping_topics = restricted_topics_for_pattern(pattern, restricted_topics)

    case authorize_subscription(principal_id, overlapping_topics) do
      {:ok, authorized_topics} ->
        sub_id = generate_subscription_id()

        subscription = %{
          id: sub_id,
          pattern: pattern,
          handler: handler,
          async: Keyword.get(opts, :async, true),
          filter: Keyword.get(opts, :filter),
          principal_id: principal_id,
          authorized_topics: authorized_topics,
          created_at: DateTime.utc_now()
        }

        state = put_in(state, [:subscriptions, sub_id], subscription)
        {:reply, {:ok, sub_id}, state}

      {:error, _reason} = error ->
        state = update_in(state, [:stats, :total_auth_denied], &(&1 + 1))
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:unsubscribe, subscription_id}, _from, state) do
    if Map.has_key?(state.subscriptions, subscription_id) do
      state = update_in(state, [:subscriptions], &Map.delete(&1, subscription_id))
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_subscriptions, _from, state) do
    subs =
      state.subscriptions
      |> Map.values()
      |> Enum.map(&Map.take(&1, [:id, :pattern, :async, :principal_id, :created_at]))

    {:reply, subs, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = Map.put(state.stats, :active_subscriptions, map_size(state.subscriptions))
    {:reply, stats, state}
  end

  # Private functions — Authorization

  # Compute which restricted topics a pattern overlaps with.
  # A wildcard category ("*") or category matching a restricted topic triggers auth.
  defp restricted_topics_for_pattern(pattern, restricted_topics) do
    pattern_category = extract_category(pattern)

    cond do
      # "*" or "*.something" matches all categories including restricted
      pattern_category == "*" ->
        restricted_topics

      # Exact category match
      String.to_existing_atom(pattern_category) in restricted_topics ->
        [String.to_existing_atom(pattern_category)]

      true ->
        []
    end
  rescue
    # If the category isn't an existing atom, it can't be a restricted topic
    ArgumentError -> []
  end

  defp extract_category("*"), do: "*"

  defp extract_category(pattern) do
    case String.split(pattern, ".", parts: 2) do
      ["*" | _] -> "*"
      [cat | _] -> cat
      _ -> pattern
    end
  end

  # No restricted topics overlap — no auth needed
  defp authorize_subscription(_principal_id, []) do
    {:ok, MapSet.new()}
  end

  # Restricted topics overlap but no principal — deny
  defp authorize_subscription(nil, _restricted_topics) do
    {:error, :unauthorized}
  end

  # Check authorization for each restricted topic
  defp authorize_subscription(principal_id, restricted_topics) do
    authorizer = Config.authorizer()

    results =
      Enum.map(restricted_topics, fn topic ->
        {topic, authorizer.authorize_subscription(principal_id, topic)}
      end)

    authorized =
      results
      |> Enum.filter(fn {_topic, result} -> result == {:ok, :authorized} end)
      |> Enum.map(fn {topic, _} -> topic end)
      |> MapSet.new()

    denied =
      Enum.any?(results, fn {_topic, result} -> result != {:ok, :authorized} end)

    if denied and MapSet.size(authorized) == 0 do
      {:error, :unauthorized}
    else
      # Partial authorization: subscriber gets signals for authorized topics only
      {:ok, authorized}
    end
  end

  # Private functions — Delivery

  defp deliver_to_subscribers(signal, state) do
    restricted_topics = Config.restricted_topics()
    signal_topic = signal.category
    signal_restricted? = signal_topic in restricted_topics

    matching_subs =
      state.subscriptions
      |> Map.values()
      |> Enum.filter(fn sub ->
        matches_pattern?(sub.pattern, signal) and
          passes_filter?(sub.filter, signal) and
          authorized_for_signal?(sub, signal_topic, signal_restricted?)
      end)

    stats = Map.update!(state.stats, :total_published, &(&1 + 1))

    {delivered, errors} =
      Enum.reduce(matching_subs, {0, 0}, fn sub, {d, e} ->
        case deliver_signal(signal, sub) do
          :ok -> {d + 1, e}
          {:error, _} -> {d, e + 1}
        end
      end)

    stats =
      stats
      |> Map.update!(:total_delivered, &(&1 + delivered))
      |> Map.update!(:total_errors, &(&1 + errors))

    %{state | stats: stats}
  end

  # Delivery-time authorization filter.
  # Non-restricted signals: always delivered.
  # Restricted signals: only delivered if subscriber is authorized for that topic.
  defp authorized_for_signal?(_sub, _topic, false), do: true

  defp authorized_for_signal?(%{authorized_topics: authorized_topics}, topic, true) do
    MapSet.member?(authorized_topics, topic)
  end

  defp deliver_signal(signal, %{async: true, handler: handler}) do
    Task.start(fn -> safe_invoke(handler, signal) end)
    :ok
  end

  defp deliver_signal(signal, %{async: false, handler: handler}) do
    safe_invoke_with_error(handler, signal)
  end

  defp safe_invoke(handler, signal) do
    handler.(signal)
  rescue
    _ -> :error
  end

  defp safe_invoke_with_error(handler, signal) do
    handler.(signal)
  rescue
    e -> {:error, e}
  end

  defp matches_pattern?("*", _signal), do: true

  defp matches_pattern?(pattern, %Signal{category: category, type: type}) do
    [pattern_category, pattern_type] =
      case String.split(pattern, ".") do
        [cat] -> [cat, "*"]
        [cat, typ] -> [cat, typ]
        _ -> ["*", "*"]
      end

    category_matches?(pattern_category, category) and
      type_matches?(pattern_type, type)
  end

  defp category_matches?("*", _), do: true
  defp category_matches?(pattern, category), do: pattern == to_string(category)

  defp type_matches?("*", _), do: true
  defp type_matches?(pattern, type), do: pattern == to_string(type)

  defp passes_filter?(nil, _signal), do: true
  defp passes_filter?(filter, signal) when is_function(filter, 1), do: filter.(signal)

  defp generate_subscription_id do
    Identifiers.generate_id("sub_")
  end
end
