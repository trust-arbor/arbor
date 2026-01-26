defmodule Arbor.Signals.Bus do
  @moduledoc """
  Signal pub/sub bus for real-time signal distribution.

  Subscribers can register handlers that receive signals matching their
  subscription patterns. Supports both sync and async delivery.

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

      Arbor.Signals.Bus.unsubscribe(sub_id)
  """

  use GenServer

  alias Arbor.Signals.Signal
  alias Arbor.Identifiers

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

  ## Returns

  `{:ok, subscription_id}` on success.
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
         total_errors: 0
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
    sub_id = generate_subscription_id()

    subscription = %{
      id: sub_id,
      pattern: pattern,
      handler: handler,
      async: Keyword.get(opts, :async, true),
      filter: Keyword.get(opts, :filter),
      created_at: DateTime.utc_now()
    }

    state = put_in(state, [:subscriptions, sub_id], subscription)
    {:reply, {:ok, sub_id}, state}
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
      |> Enum.map(&Map.take(&1, [:id, :pattern, :async, :created_at]))

    {:reply, subs, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = Map.put(state.stats, :active_subscriptions, map_size(state.subscriptions))
    {:reply, stats, state}
  end

  # Private functions

  defp deliver_to_subscribers(signal, state) do
    matching_subs =
      state.subscriptions
      |> Map.values()
      |> Enum.filter(&matches_pattern?(&1.pattern, signal))
      |> Enum.filter(&passes_filter?(&1.filter, signal))

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

  defp deliver_signal(signal, %{async: true, handler: handler}) do
    Task.start(fn ->
      try do
        handler.(signal)
      rescue
        _ -> :error
      end
    end)

    :ok
  end

  defp deliver_signal(signal, %{async: false, handler: handler}) do
    try do
      handler.(signal)
    rescue
      e -> {:error, e}
    end
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
