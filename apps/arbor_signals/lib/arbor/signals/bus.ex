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

  ## Encryption

  Signals on restricted topics have their `data` field encrypted with
  AES-256-GCM using topic-specific symmetric keys (managed by `TopicKeys`).

  - At **publish time**: `data` is encrypted and stored as an encrypted payload
  - At **delivery time**: `data` is decrypted for authorized subscribers

  Unauthorized subscribers never receive the plaintext data.

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
  alias Arbor.Signals.TopicKeys

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
    # Encrypt data for restricted topics before delivery
    signal = maybe_encrypt_signal(signal)
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

  defp deliver_signal(signal, %{async: true, handler: handler} = sub) do
    # Decrypt for authorized subscribers before delivery
    case prepare_signal_for_delivery(signal, sub) do
      nil ->
        # Signal should not be delivered (encryption failed or decryption failed)
        {:error, :delivery_skipped}

      decrypted_signal ->
        Task.start(fn -> safe_invoke(handler, decrypted_signal) end)
        :ok
    end
  end

  defp deliver_signal(signal, %{async: false, handler: handler} = sub) do
    case prepare_signal_for_delivery(signal, sub) do
      nil ->
        {:error, :delivery_skipped}

      decrypted_signal ->
        safe_invoke_with_error(handler, decrypted_signal)
    end
  end

  # Prepare signal for delivery: decrypt if encrypted and subscriber is authorized
  defp prepare_signal_for_delivery(signal, sub) do
    restricted_topics = Config.restricted_topics()
    signal_topic = signal.category
    signal_restricted? = signal_topic in restricted_topics

    if signal_restricted? do
      # Check if subscriber is authorized for this specific topic
      if MapSet.member?(sub.authorized_topics, signal_topic) do
        maybe_decrypt_signal(signal)
      else
        # Not authorized - don't deliver encrypted signals
        nil
      end
    else
      # Not restricted - deliver as-is
      signal
    end
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
    pattern_segments = String.split(pattern, ".")
    # Build signal topic from category.type - this is the minimum topic
    # Signals can match deeper patterns via their category/type combo
    signal_segments = [to_string(category), to_string(type)]

    match_segments?(pattern_segments, signal_segments)
  end

  # N-segment pattern matching with trailing wildcard support
  # Empty pattern matches empty signal - exact match at end
  defp match_segments?([], []), do: true
  # Trailing "*" matches any remaining segments (including none)
  defp match_segments?(["*"], _remaining), do: true
  # Pattern has more segments than signal - no match (unless trailing wildcard handled above)
  defp match_segments?([], _signal_rest), do: false
  # Signal exhausted but pattern continues (and it's not just "*") - no match
  defp match_segments?(_pattern_rest, []), do: false
  # "*" in middle position matches exactly one segment
  defp match_segments?(["*" | p_rest], [_ | s_rest]), do: match_segments?(p_rest, s_rest)
  # Exact segment match - continue
  defp match_segments?([seg | p_rest], [seg | s_rest]), do: match_segments?(p_rest, s_rest)
  # Segments don't match
  defp match_segments?(_, _), do: false

  defp passes_filter?(nil, _signal), do: true
  defp passes_filter?(filter, signal) when is_function(filter, 1), do: filter.(signal)

  defp generate_subscription_id do
    Identifiers.generate_id("sub_")
  end

  # Private functions — Encryption

  # Encrypt signal data for restricted topics.
  # Skips if already encrypted (e.g., pre-encrypted by emit_preconstructed_signal).
  defp maybe_encrypt_signal(%Signal{category: category, data: data} = signal) do
    restricted_topics = Config.restricted_topics()

    if category in restricted_topics and data != %{} and
         not match?(%{__encrypted__: true}, data) do
      try do
        with {:ok, json} <- Jason.encode(data),
             {:ok, encrypted_payload} <- TopicKeys.encrypt(category, json) do
          # Store encrypted payload in data, mark as encrypted
          %{
            signal
            | data: %{
                __encrypted__: true,
                payload: encrypted_payload
              }
          }
        else
          # If serialization or encryption fails, don't deliver at all for security
          {:error, _reason} ->
            %{signal | data: %{__encryption_failed__: true}}
        end
      catch
        :exit, _ ->
          %{signal | data: %{__encryption_failed__: true}}
      end
    else
      signal
    end
  end

  # Decrypt signal data for authorized subscribers
  defp maybe_decrypt_signal(%Signal{category: category, data: data} = signal) do
    case data do
      %{__encrypted__: true, payload: encrypted_payload} ->
        try do
          with {:ok, json} <- TopicKeys.decrypt(category, encrypted_payload),
               {:ok, decoded_data} <- Jason.decode(json) do
            %{signal | data: decoded_data}
          else
            {:error, _reason} ->
              %{signal | data: %{__decryption_failed__: true}}
          end
        catch
          :exit, _ ->
            %{signal | data: %{__decryption_failed__: true}}
        end

      %{__encryption_failed__: true} ->
        # Don't deliver signals that failed encryption
        nil

      _other ->
        # Not encrypted, return as-is (could be channel message)
        maybe_decrypt_channel_signal(signal)
    end
  end

  # Decrypt channel-encrypted signal data
  defp maybe_decrypt_channel_signal(%Signal{data: data} = signal) do
    case data do
      %{
        __channel_encrypted__: true,
        channel_id: channel_id,
        sender_id: _sender_id,
        payload: payload
      } ->
        channels_module =
          Application.get_env(:arbor_signals, :channels_module, Arbor.Signals.Channels)

        # Note: The subscriber must be a member of the channel.
        # For now, we attempt decryption using the channel key from Channels.
        # In practice, subscribers store the key in their keychain.
        # This is a simplified implementation - full implementation would
        # require passing the subscriber's keychain context.

        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        case apply(channels_module, :get_key, [channel_id, signal.source]) do
          {:ok, key} ->
            decrypt_channel_payload(signal, payload, key)

          {:error, _reason} ->
            # Not a member or channel not found - return signal as-is
            signal
        end

      _other ->
        signal
    end
  end

  defp decrypt_channel_payload(signal, payload, key) do
    %{ciphertext: ciphertext, iv: iv, tag: tag, key_version: payload_version} = payload

    crypto_module = Application.get_env(:arbor_signals, :crypto_module, Arbor.Security.Crypto)

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(crypto_module, :decrypt, [ciphertext, key, iv, tag]) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, decoded_data} ->
            %{
              signal
              | data:
                  Map.merge(decoded_data, %{
                    "__channel_id__" => signal.data.channel_id,
                    "__sender_id__" => signal.data.sender_id,
                    "__key_version__" => payload_version
                  })
            }

          {:error, _reason} ->
            %{signal | data: %{__channel_decryption_failed__: true}}
        end

      {:error, _reason} ->
        %{signal | data: %{__channel_decryption_failed__: true}}
    end
  end
end
