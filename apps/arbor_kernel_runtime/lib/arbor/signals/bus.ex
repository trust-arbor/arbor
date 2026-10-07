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

  alias Arbor.Common.AuthenticatedCall
  alias Arbor.Identifiers
  alias Arbor.Signals.Config
  alias Arbor.Signals.Relay
  alias Arbor.Signals.Signal
  alias Arbor.Signals.SubscriptionRegistry
  alias Arbor.Signals.TopicKeys

  @subscriber_callback_timeout_ms 100
  @subscription_restore_retry_ms 25
  # Ownership proof traverses two supervisors. A short scheduler-scale timeout
  # turns ordinary mailbox pressure into a false authorization denial, so use
  # the same bounded window as Arbor.Common.SupervisedOwner.
  @supervision_lookup_timeout_ms 1_000
  @relay_proof_bytes 32
  @signals_supervisor_path [Arbor.Signals.Application]
  @subscription_custody_anchor {__MODULE__, :subscription_custody}
  @test_env Application.compile_env(:arbor_kernel_runtime, :expose_test_fixtures, false)

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
  @spec publish(Signal.t()) :: :ok | {:error, term()}
  def publish(%Signal{} = signal) do
    case publish_canonical(signal) do
      {:ok, _canonical} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec publish_canonical(Signal.t()) :: {:ok, Signal.t()} | {:error, term()}
  def publish_canonical(%Signal{} = signal) do
    authenticated_bus_call({:publish_local, signal})
  end

  @doc false
  @spec publish_remote(Signal.t()) :: :ok | {:error, :unauthorized}
  def publish_remote(%Signal{}), do: {:error, :unauthorized}

  @doc false
  @spec publish_remote(Signal.t(), binary()) :: :ok | {:error, :unauthorized}
  def publish_remote(%Signal{} = signal, proof)
      when is_binary(proof) and byte_size(proof) == @relay_proof_bytes do
    trusted_bus_call({:publish_remote, signal, proof})
  end

  def publish_remote(%Signal{}, _invalid_proof), do: {:error, :unauthorized}

  @doc false
  @spec register_relay() :: {:ok, pid()} | {:error, :unauthorized}
  def register_relay, do: {:error, :unauthorized}

  @doc false
  @spec register_relay(binary()) :: {:ok, pid()} | {:error, :unauthorized}
  def register_relay(proof)
      when is_binary(proof) and byte_size(proof) == @relay_proof_bytes,
      do: trusted_bus_call({:register_relay, proof})

  def register_relay(_invalid_proof), do: {:error, :unauthorized}

  @doc false
  @spec registered_relay_pid() :: pid() | nil | {:error, :unauthorized}
  def registered_relay_pid do
    trusted_bus_call(:registered_relay_pid)
  end

  @doc """
  Subscribe to signals matching a pattern.

  ## Options

  - `:async` - Deliver signals asynchronously (default: true)
  - `:filter` - Additional filter function `(signal -> boolean)`
  - `:principal_id` - Agent ID for authorization (required for restricted topics)
  - `:auth_context` - executor-issued principal envelope required to decrypt
    channel payloads; its principal must match `:principal_id` when both exist

  ## Returns

  `{:ok, subscription_id}` on success.
  `{:error, :unauthorized}` if the principal lacks capability for a restricted topic.
  """
  @spec subscribe(String.t(), (Signal.t() -> :ok | {:error, term()}), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def subscribe(pattern, handler, opts \\ []) when is_function(handler, 1) do
    authenticated_bus_call({:subscribe, pattern, handler, opts})
  end

  @doc false
  @spec subscribe_security_sync(atom(), atom()) ::
          {:ok, String.t(), pid(), reference()} | {:error, :unauthorized}
  def subscribe_security_sync(role, event) do
    authenticated_bus_call({:subscribe_security_sync, role, event})
  end

  @doc """
  Unsubscribe from signals.
  """
  @spec unsubscribe(String.t()) :: :ok | {:error, :not_found}
  def unsubscribe(subscription_handle) do
    authenticated_bus_call({:unsubscribe, subscription_handle})
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

  if Application.compile_env(:arbor_kernel_runtime, :expose_test_fixtures, false) do
    @doc false
    def reset do
      authenticated_bus_call(:reset)
    end
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)
    relay_custody = :ets.new(__MODULE__, [:set, :private])
    authenticated_calls = AuthenticatedCall.new_custody()
    subscription_custody = :ets.new(__MODULE__, [:set, :private])
    Process.put(@subscription_custody_anchor, subscription_custody)

    {:ok,
     %{
       subscriptions: %{},
       ordinary_owner_monitors: %{},
       security_sync_monitors: %{},
       security_sync_subscribers: Config.security_sync_subscribers_snapshot(),
       subscription_registry_ready?: false,
       relay_pid: nil,
       relay_monitor_ref: nil,
       relay_custody: relay_custody,
       authenticated_calls: authenticated_calls,
       subscription_custody: subscription_custody,
       stats: %{
         total_published: 0,
         total_delivered: 0,
         total_errors: 0,
         total_auth_denied: 0
       }
     }, {:continue, :restore_subscriptions}}
  end

  @impl true
  def handle_continue(:restore_subscriptions, state) do
    {:noreply, restore_ordinary_subscriptions(state)}
  end

  @impl true
  # Casts carry no trustworthy caller metadata. Retire the legacy publication
  # wire shape instead of laundering arbitrary input through the Bus identity.
  def handle_cast({:publish, _signal}, state), do: {:noreply, state}

  def handle_cast(_unknown, state), do: {:noreply, state}

  @impl true
  def handle_call({:publish_local, %Signal{}}, _from, state),
    do: {:reply, {:error, :unauthorized}, state}

  def handle_call(
        {:publish_remote, %Signal{} = signal, proof},
        {caller_pid, _tag},
        state
      ) do
    if state.relay_pid == caller_pid and
         relay_custody_matches?(state, proof) and
         Process.alive?(caller_pid) do
      canonical = canonical_remote_signal(signal, caller_pid)
      {:reply, :ok, publish_signal(canonical, state)}
    else
      {:reply, {:error, :unauthorized}, state}
    end
  end

  def handle_call(:registered_relay_pid, _from, state) do
    relay_pid =
      if is_pid(state.relay_pid) and Process.alive?(state.relay_pid),
        do: state.relay_pid,
        else: nil

    {:reply, relay_pid, state}
  end

  def handle_call({:register_relay, proof}, {caller_pid, _tag}, state)
      when is_binary(proof) and byte_size(proof) == @relay_proof_bytes do
    cond do
      not valid_relay_custody?(caller_pid, proof) ->
        {:reply, {:error, :unauthorized}, state}

      is_pid(state.relay_pid) and state.relay_pid != caller_pid and
          Process.alive?(state.relay_pid) ->
        {:reply, {:error, :unauthorized}, state}

      true ->
        if is_reference(state.relay_monitor_ref) do
          Process.demonitor(state.relay_monitor_ref, [:flush])
        end

        case put_relay_custody(state, proof) do
          :ok ->
            {:reply, {:ok, self()},
             %{
               state
               | relay_pid: caller_pid,
                 relay_monitor_ref: Process.monitor(caller_pid)
             }}

          :error ->
            {:reply, {:error, :unauthorized}, clear_relay_registration(state)}
        end
    end
  end

  def handle_call({:subscribe, _pattern, _handler, _opts}, _from, state),
    do: {:reply, {:error, :unauthorized}, state}

  def handle_call({:subscribe_security_sync, _role, _event}, _from, state),
    do: {:reply, {:error, :unauthorized}, state}

  @impl true
  def handle_call({:unsubscribe, _subscription_handle}, _from, state),
    do: {:reply, {:error, :not_found}, state}

  @impl true
  def handle_call(:list_subscriptions, _from, state) do
    subs =
      state.subscriptions
      |> Map.values()
      |> Enum.map(
        &Map.take(&1, [
          :pattern,
          :async,
          :principal_id,
          :security_sync_owner,
          :created_at
        ])
      )

    {:reply, subs, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = Map.put(state.stats, :active_subscriptions, map_size(state.subscriptions))
    {:reply, stats, state}
  end

  if Application.compile_env(:arbor_kernel_runtime, :expose_test_fixtures, false) do
    def handle_call(:reset, _from, state) do
      {:reply, {:error, :unauthorized}, state}
    end
  end

  def handle_call(_unknown, _from, state), do: {:reply, {:error, :unsupported_request}, state}

  @impl true
  def handle_info(
        {:DOWN, ref, :process, relay_pid, _reason},
        %{relay_monitor_ref: ref, relay_pid: relay_pid} = state
      ) do
    {:noreply, clear_relay_registration(state)}
  end

  def handle_info({:DOWN, ref, :process, owner_pid, _reason}, state) do
    case Map.get(state.security_sync_monitors, owner_pid) do
      ^ref ->
        subscription_ids =
          state.subscriptions
          |> Enum.flat_map(fn
            {id, subscription} ->
              if Map.get(subscription, :security_sync_owner) == owner_pid, do: [id], else: []
          end)

        subscriptions =
          Map.reject(state.subscriptions, fn {_id, subscription} ->
            Map.get(subscription, :security_sync_owner) == owner_pid
          end)

        state = drop_subscription_custody(state, subscription_ids)

        {:noreply,
         %{
           state
           | subscriptions: subscriptions,
             security_sync_monitors: Map.delete(state.security_sync_monitors, owner_pid)
         }}

      _other ->
        case Map.get(state.ordinary_owner_monitors, owner_pid) do
          ^ref ->
            subscription_ids =
              state.subscriptions
              |> Enum.flat_map(fn
                {id, %{owner_pid: ^owner_pid} = subscription} ->
                  if Map.has_key?(subscription, :security_sync_owner), do: [], else: [id]

                _other ->
                  []
              end)

            _ = delete_persisted_subscription_ids(subscription_ids)

            {:noreply,
             state
             |> drop_subscription_custody(subscription_ids)
             |> update_in([:subscriptions], &Map.drop(&1, subscription_ids))
             |> reconcile_ordinary_owner_monitors()}

          _other ->
            {:noreply, state}
        end
    end
  end

  def handle_info(:restore_subscriptions, state) do
    {:noreply, restore_ordinary_subscriptions(state)}
  end

  def handle_info(message, state) do
    case AuthenticatedCall.handle(message, state.authenticated_calls) do
      {:authenticated, caller_pid, request, reply_to} ->
        {reply, state} = dispatch_authenticated(request, caller_pid, state)
        :ok = AuthenticatedCall.reply(reply_to, reply)
        {:noreply, state}

      result when result in [:pending, :expired, :rejected] ->
        {:noreply, state}

      :unrecognized ->
        {:noreply, state}
    end
  end

  defp dispatch_authenticated({:publish_local, %Signal{} = signal}, caller_pid, state) do
    canonical = canonical_local_signal(signal, caller_pid)

    case authorize_signal_publisher(canonical, caller_pid, state) do
      :ok -> {{:ok, canonical}, publish_signal(canonical, state)}
      {:error, :unauthorized} = error -> {error, state}
    end
  end

  defp dispatch_authenticated({:subscribe, pattern, handler, opts}, caller_pid, state)
       when is_binary(pattern) and is_function(handler, 1) and is_list(opts) do
    {principal_id, auth_context, identity_valid?} = subscription_identity(opts)
    restricted_topics = Config.restricted_topics()
    overlapping_topics = restricted_topics_for_pattern(pattern, restricted_topics)

    case identity_valid? && authorize_subscription(principal_id, overlapping_topics, opts) do
      {:ok, authorized_topics} ->
        sub_id = generate_subscription_id()
        {subscription_handle, unsubscribe_digest} = new_subscription_handle()

        subscription = %{
          id: sub_id,
          pattern: pattern,
          handler: handler,
          async: Keyword.get(opts, :async, true),
          filter: Keyword.get(opts, :filter),
          principal_id: principal_id,
          auth_context: auth_context,
          authorized_topics: authorized_topics,
          owner_pid: caller_pid,
          unsubscribe_digest: unsubscribe_digest,
          created_at: DateTime.utc_now()
        }

        with :ok <- persist_ordinary_subscription(subscription),
             :ok <-
               put_subscription_custody(
                 state,
                 sub_id,
                 caller_pid,
                 subscription_handle,
                 unsubscribe_digest
               ) do
          state =
            state
            |> put_in([:subscriptions, sub_id], subscription)
            |> reconcile_ordinary_owner_monitors()

          {{:ok, subscription_handle}, state}
        else
          {:error, reason} ->
            _ = delete_persisted_subscription(subscription)
            state = update_in(state, [:stats, :total_errors], &(&1 + 1))
            {{:error, reason}, state}
        end

      false ->
        state = update_in(state, [:stats, :total_auth_denied], &(&1 + 1))
        {{:error, :unauthorized}, state}

      {:error, _reason} = error ->
        state = update_in(state, [:stats, :total_auth_denied], &(&1 + 1))
        {error, state}
    end
  end

  defp dispatch_authenticated({:subscribe_security_sync, role, event}, caller_pid, state) do
    case existing_security_sync_subscription(state, role, event) do
      %{
        security_sync_owner: ^caller_pid,
        id: sub_id
      } ->
        with {:ok, subscription_handle} <- subscription_handle(state, sub_id),
             {:ok, delivery_ref} <-
               security_sync_delivery_ref(state, sub_id, caller_pid) do
          {{:ok, subscription_handle, self(), delivery_ref}, state}
        else
          :error -> {{:error, :unauthorized}, state}
        end

      %{security_sync_owner: pinned_owner} when is_pid(pinned_owner) ->
        state = update_in(state, [:stats, :total_auth_denied], &(&1 + 1))
        {{:error, :unauthorized}, state}

      nil ->
        establish_security_sync_subscription(state, role, event, caller_pid)
    end
  end

  defp dispatch_authenticated({:unsubscribe, subscription_handle}, caller_pid, state) do
    unsubscribe_with_custody(state, subscription_handle, caller_pid)
  end

  if Application.compile_env(:arbor_kernel_runtime, :expose_test_fixtures, false) do
    defp dispatch_authenticated(:reset, _caller_pid, state) do
      {:ok, reset_preserving_security_sync(state)}
    end
  end

  defp dispatch_authenticated(_unknown, _caller_pid, state),
    do: {{:error, :unsupported_request}, state}

  defp establish_security_sync_subscription(state, role, event, caller_pid) do
    case security_sync_owner(role, event, caller_pid, state) do
      {:ok, owner_pid} ->
        sub_id = generate_subscription_id()
        delivery_ref = make_ref()
        {subscription_handle, unsubscribe_digest} = new_subscription_handle()

        subscription = %{
          id: sub_id,
          pattern: "security.#{event}",
          async: true,
          filter: nil,
          principal_id: {:internal_security_sync, role},
          authorized_topics: MapSet.new([:security]),
          security_sync_owner: owner_pid,
          security_sync_role: role,
          security_sync_event: event,
          unsubscribe_digest: unsubscribe_digest,
          created_at: DateTime.utc_now()
        }

        case put_security_sync_subscription_custody(
               state,
               sub_id,
               owner_pid,
               subscription_handle,
               unsubscribe_digest,
               delivery_ref
             ) do
          :ok ->
            state =
              state
              |> put_in([:subscriptions, sub_id], subscription)
              |> monitor_security_sync_owner(owner_pid)

            {{:ok, subscription_handle, self(), delivery_ref}, state}

          :error ->
            {{:error, :unauthorized}, state}
        end

      :error ->
        state = update_in(state, [:stats, :total_auth_denied], &(&1 + 1))
        {{:error, :unauthorized}, state}
    end
  end

  defp existing_security_sync_subscription(state, role, event) do
    Enum.find_value(state.subscriptions, fn {_id, subscription} ->
      if Map.get(subscription, :security_sync_role) == role and
           Map.get(subscription, :security_sync_event) == event and
           security_sync_owner_alive?(subscription) do
        subscription
      end
    end)
  end

  defp security_sync_owner_alive?(subscription) do
    case Map.get(subscription, :security_sync_owner) do
      owner_pid when is_pid(owner_pid) -> Process.alive?(owner_pid)
      _other -> false
    end
  end

  defp publish_signal(signal, state) do
    signal = maybe_encrypt_signal(signal)
    state = deliver_to_subscribers(signal, state)

    # Signals arriving through publish_remote/1 have scope :local, preventing
    # relay loops. Locally emitted cluster events keep their requested scope.
    if signal.scope == :cluster do
      with {:ok, proof} <- relay_custody_proof(state) do
        Relay.relay(signal, proof)
      end
    end

    state
  end

  defp canonical_local_signal(%Signal{} = signal, emitter_pid) do
    rebuild_signal(signal)
    |> Map.put(:emitter_pid, emitter_pid)
    |> Map.put(:origin_node, node())
  end

  defp canonical_remote_signal(%Signal{} = signal, relay_pid) do
    rebuild_signal(signal)
    |> Map.put(:emitter_pid, relay_pid)
    |> Map.put(:origin_node, signal.origin_node)
  end

  defp rebuild_signal(%Signal{} = signal) do
    Signal.new(signal.category, signal.type, signal.data,
      source: signal.source,
      cause_id: signal.cause_id,
      correlation_id: signal.correlation_id,
      metadata: signal.metadata,
      scope: signal.scope
    )
  end

  defp authorize_signal_publisher(
         %Signal{category: category, type: type} = signal,
         caller_pid,
         state
       )
       when category in [:security, :identity] do
    case Config.security_sync_publisher(type, security_sync_subscribers(state)) do
      {:ok, _configured_owner} ->
        pinned_owner? =
          Enum.any?(state.subscriptions, fn {_id, subscription} ->
            Map.get(subscription, :security_sync_event) == type and
              Map.get(subscription, :security_sync_owner) == caller_pid and
              Process.alive?(caller_pid)
          end)

        if pinned_owner?,
          do: :ok,
          else: {:error, :unauthorized}

      :error ->
        if portable_security_sync_signal?(signal) do
          {:error, :unauthorized}
        else
          :ok
        end
    end
  end

  defp authorize_signal_publisher(_signal, _caller_pid, _state), do: :ok

  # Private functions — Authorization

  defp security_sync_owner(role, event, caller_pid, state) do
    with {:ok, provenance} <-
           Config.security_sync_owner_provenance(
             role,
             event,
             security_sync_subscribers(state)
           ),
         %{owner: owner_name, supervisor: supervisor_root, child_id: child_id} <- provenance,
         ^caller_pid <-
           supervised_registered_child_pid(supervisor_root, [child_id], owner_name) do
      {:ok, caller_pid}
    else
      _ -> :error
    end
  end

  defp new_subscription_handle do
    handle = Identifiers.generate_id("subh_")
    {handle, subscription_handle_digest(handle)}
  end

  defp put_subscription_custody(
         %{subscription_custody: custody} = state,
         subscription_id,
         owner_pid,
         subscription_handle,
         digest
       )
       when is_binary(subscription_id) and is_pid(owner_pid) and
              is_binary(subscription_handle) and is_binary(digest) do
    if subscription_custody_owned?(state) do
      true =
        :ets.insert(custody, [
          {{:handle_digest, digest}, subscription_id, owner_pid},
          {{:subscription_id, subscription_id}, subscription_handle, digest, owner_pid}
        ])

      :ok
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  defp put_security_sync_subscription_custody(
         %{subscription_custody: custody} = state,
         subscription_id,
         owner_pid,
         subscription_handle,
         digest,
         delivery_ref
       )
       when is_binary(subscription_id) and is_pid(owner_pid) and
              is_binary(subscription_handle) and is_binary(digest) and
              is_reference(delivery_ref) do
    if subscription_custody_owned?(state) do
      true =
        :ets.insert(custody, [
          {{:handle_digest, digest}, subscription_id, owner_pid},
          {{:subscription_id, subscription_id}, subscription_handle, digest, owner_pid},
          {{:security_sync_delivery, subscription_id}, owner_pid, delivery_ref}
        ])

      :ok
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  defp put_restored_subscription_custody(
         %{subscription_custody: custody} = state,
         %{id: subscription_id, owner_pid: owner_pid, unsubscribe_digest: digest}
       )
       when is_binary(subscription_id) and is_pid(owner_pid) and is_binary(digest) do
    if subscription_custody_owned?(state) do
      true = :ets.insert(custody, {{:handle_digest, digest}, subscription_id, owner_pid})
      :ok
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  defp put_restored_subscription_custody(_state, _subscription), do: :error

  defp subscription_handle(%{subscription_custody: custody} = state, subscription_id) do
    if subscription_custody_owned?(state) do
      case :ets.lookup(custody, {:subscription_id, subscription_id}) do
        [{{:subscription_id, ^subscription_id}, handle, _digest, _owner_pid}]
        when is_binary(handle) ->
          {:ok, handle}

        _missing ->
          :error
      end
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  defp security_sync_delivery_ref(
         %{subscription_custody: custody} = state,
         subscription_id,
         owner_pid
       ) do
    if subscription_custody_owned?(state) do
      case :ets.lookup(custody, {:security_sync_delivery, subscription_id}) do
        [{{:security_sync_delivery, ^subscription_id}, ^owner_pid, delivery_ref}]
        when is_reference(delivery_ref) ->
          {:ok, delivery_ref}

        _missing_or_mismatched ->
          :error
      end
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  defp unsubscribe_with_custody(state, subscription_handle, caller_pid)
       when is_binary(subscription_handle) and is_pid(caller_pid) do
    digest = subscription_handle_digest(subscription_handle)

    case lookup_subscription_custody(state, digest) do
      {:ok, subscription_id, ^caller_pid} ->
        case Map.fetch(state.subscriptions, subscription_id) do
          :error ->
            delete_subscription_custody(state, subscription_id, digest)
            {{:error, :not_found}, state}

          {:ok, subscription} ->
            case delete_persisted_subscription(subscription) do
              :ok ->
                delete_subscription_custody(state, subscription_id, digest)

                state =
                  state
                  |> update_in([:subscriptions], &Map.delete(&1, subscription_id))
                  |> maybe_demonitor_security_sync_owner(subscription)
                  |> reconcile_ordinary_owner_monitors()

                {:ok, state}

              {:error, reason} ->
                {{:error, reason}, state}
            end
        end

      {:ok, _subscription_id, _different_owner} ->
        state = update_in(state, [:stats, :total_auth_denied], &(&1 + 1))
        {{:error, :not_found}, state}

      :error ->
        {{:error, :not_found}, state}
    end
  end

  defp unsubscribe_with_custody(state, _subscription_handle, _caller_pid),
    do: {{:error, :not_found}, state}

  defp lookup_subscription_custody(%{subscription_custody: custody} = state, digest) do
    if subscription_custody_owned?(state) do
      case :ets.lookup(custody, {:handle_digest, digest}) do
        [{{:handle_digest, ^digest}, subscription_id, owner_pid}] ->
          {:ok, subscription_id, owner_pid}

        _missing ->
          :error
      end
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  defp delete_subscription_custody(
         %{subscription_custody: custody} = state,
         subscription_id,
         digest
       ) do
    if subscription_custody_owned?(state) do
      :ets.delete(custody, {:subscription_id, subscription_id})
      :ets.delete(custody, {:handle_digest, digest})
      :ets.delete(custody, {:security_sync_delivery, subscription_id})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp drop_subscription_custody(state, subscription_ids) do
    Enum.each(subscription_ids, fn subscription_id ->
      case Map.get(state.subscriptions, subscription_id) do
        %{unsubscribe_digest: digest} ->
          delete_subscription_custody(state, subscription_id, digest)

        _missing_or_legacy ->
          :ok
      end
    end)

    state
  end

  defp subscription_custody_owned?(%{subscription_custody: custody}) do
    Process.get(@subscription_custody_anchor) == custody and
      :ets.info(custody, :owner) == self() and
      :ets.info(custody, :protection) == :private
  rescue
    ArgumentError -> false
  end

  defp subscription_handle_digest(subscription_handle) do
    :crypto.hash(:sha256, subscription_handle)
  end

  defp authenticated_bus_call(message) do
    with bus_pid when is_pid(bus_pid) <-
           supervised_registered_child_pid(
             {:application, :arbor_kernel_runtime},
             @signals_supervisor_path ++ [__MODULE__],
             __MODULE__
           ) do
      AuthenticatedCall.call(bus_pid, message)
    else
      _other -> {:error, :unauthorized}
    end
  catch
    :exit, _reason -> {:error, :unauthorized}
  end

  defp trusted_bus_call(message) do
    with bus_pid when is_pid(bus_pid) <-
           supervised_registered_child_pid(
             {:application, :arbor_kernel_runtime},
             @signals_supervisor_path ++ [__MODULE__],
             __MODULE__
           ) do
      GenServer.call(bus_pid, message)
    else
      _other -> {:error, :unauthorized}
    end
  catch
    :exit, _reason -> {:error, :unauthorized}
  end

  defp supervised_relay_pid do
    supervised_registered_child_pid(
      {:application, :arbor_kernel_runtime},
      @signals_supervisor_path ++ [Relay],
      Relay
    )
  end

  defp valid_relay_custody?(caller_pid, proof) do
    expected_digest = :crypto.hash(:sha256, proof)
    directory = Relay.custody_directory()

    supervised_relay_pid() == caller_pid and
      Process.whereis(Relay) == caller_pid and
      Process.alive?(caller_pid) and
      :ets.info(directory, :owner) == caller_pid and
      case :ets.lookup(directory, :relay) do
        [{:relay, ^caller_pid, digest}] -> secure_equal?(digest, expected_digest)
        _other -> false
      end
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp put_relay_custody(state, proof) do
    if relay_custody_owned?(state) do
      true = :ets.insert(state.relay_custody, {:relay_proof, proof})
      :ok
    else
      :error
    end
  rescue
    _error -> :error
  end

  defp relay_custody_proof(state) do
    if relay_custody_owned?(state) do
      case :ets.lookup(state.relay_custody, :relay_proof) do
        [{:relay_proof, proof}]
        when is_binary(proof) and byte_size(proof) == @relay_proof_bytes ->
          {:ok, proof}

        _other ->
          :error
      end
    else
      :error
    end
  rescue
    _error -> :error
  end

  defp relay_custody_matches?(state, proof)
       when is_binary(proof) and byte_size(proof) == @relay_proof_bytes do
    case relay_custody_proof(state) do
      {:ok, expected} -> secure_equal?(proof, expected)
      :error -> false
    end
  end

  defp relay_custody_matches?(_state, _proof), do: false

  defp relay_custody_owned?(%{relay_custody: table}), do: :ets.info(table, :owner) == self()

  defp clear_relay_registration(state) do
    if relay_custody_owned?(state), do: :ets.delete(state.relay_custody, :relay_proof)

    %{state | relay_pid: nil, relay_monitor_ref: nil}
  rescue
    _error -> %{state | relay_pid: nil, relay_monitor_ref: nil}
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {a, b}, acc -> Bitwise.bor(acc, Bitwise.bxor(a, b)) end)
    |> Kernel.==(0)
  end

  defp secure_equal?(_left, _right), do: false

  defp supervised_registered_child_pid(supervisor_root, child_path, registered_name) do
    task =
      Task.async(fn ->
        find_supervised_registered_child_pid(supervisor_root, child_path, registered_name)
      end)

    case Task.yield(task, @supervision_lookup_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, child_pid} -> child_pid
      _timeout_or_exit -> nil
    end
  end

  defp find_supervised_registered_child_pid(supervisor_root, child_path, registered_name) do
    with root_pid when is_pid(root_pid) <- resolve_supervisor_root(supervisor_root),
         true <- Process.alive?(root_pid),
         child_pid when is_pid(child_pid) <- supervised_descendant_pid(root_pid, child_path),
         true <- Process.alive?(child_pid),
         ^child_pid <- Process.whereis(registered_name) do
      child_pid
    else
      _other -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp supervised_descendant_pid(root_pid, child_path) do
    Enum.reduce_while(child_path, root_pid, fn child_id, supervisor_pid ->
      case supervised_child_pid(supervisor_pid, child_id) do
        child_pid when is_pid(child_pid) -> {:cont, child_pid}
        _other -> {:halt, nil}
      end
    end)
  end

  defp supervised_child_pid(supervisor_pid, child_id) do
    Enum.find_value(Supervisor.which_children(supervisor_pid), fn
      {^child_id, child_pid, _type, _modules} when is_pid(child_pid) -> child_pid
      _other -> nil
    end)
  end

  defp resolve_supervisor_root({:application, application}) when is_atom(application) do
    # application_master.get_child/1 assumes the application callback has
    # already returned a child pid. Calling it from a child continuation while
    # the application is still starting passes :undefined into the OTP master
    # and terminates the application master. Security provenance checks are
    # therefore admitted only after the controller publishes the application
    # as running; startup callers fail closed and retry from their owners.
    with true <- application_running?(application),
         master when is_pid(master) <- :application_controller.get_master(application),
         {root_pid, _application_module} when is_pid(root_pid) <-
           :application_master.get_child(master),
         true <- Process.alive?(root_pid) do
      root_pid
    else
      _other -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp resolve_supervisor_root(pid) when is_pid(pid), do: pid
  defp resolve_supervisor_root(_other), do: nil

  defp application_running?(application) do
    Enum.any?(Application.started_applications(), fn
      {^application, _description, _version} -> true
      _other -> false
    end)
  end

  if Application.compile_env(:arbor_kernel_runtime, :expose_test_fixtures, false) do
    defp security_sync_subscribers(_state), do: Config.security_sync_subscribers_snapshot()
  else
    defp security_sync_subscribers(state), do: state.security_sync_subscribers
  end

  defp monitor_security_sync_owner(state, owner_pid) do
    case Map.has_key?(state.security_sync_monitors, owner_pid) do
      true ->
        state

      false ->
        put_in(state, [:security_sync_monitors, owner_pid], Process.monitor(owner_pid))
    end
  end

  defp maybe_demonitor_security_sync_owner(state, subscription) do
    case Map.get(subscription, :security_sync_owner) do
      nil ->
        state

      owner_pid ->
        owner_still_subscribed? =
          Enum.any?(state.subscriptions, fn {_id, other_subscription} ->
            Map.get(other_subscription, :security_sync_owner) == owner_pid
          end)

        if owner_still_subscribed? do
          state
        else
          case Map.pop(state.security_sync_monitors, owner_pid) do
            {nil, _monitors} ->
              state

            {ref, monitors} ->
              Process.demonitor(ref, [:flush])
              %{state | security_sync_monitors: monitors}
          end
        end
    end
  end

  if Application.compile_env(:arbor_kernel_runtime, :expose_test_fixtures, false) do
    defp reset_preserving_security_sync(state) do
      _ = clear_persisted_subscriptions()

      subscriptions =
        Map.filter(state.subscriptions, fn {_id, subscription} ->
          case Map.get(subscription, :security_sync_owner) do
            owner_pid when is_pid(owner_pid) -> Process.alive?(owner_pid)
            _other -> false
          end
        end)

      removed_ids = Map.keys(state.subscriptions) -- Map.keys(subscriptions)
      state = drop_subscription_custody(state, removed_ids)

      owner_pids =
        subscriptions
        |> Map.values()
        |> Enum.map(&Map.fetch!(&1, :security_sync_owner))
        |> Enum.uniq()

      {monitors, stale_monitors} = Map.split(state.security_sync_monitors, owner_pids)
      demonitor_security_sync_owners(stale_monitors)
      demonitor_ordinary_owners(state.ordinary_owner_monitors)

      monitors =
        Enum.reduce(owner_pids, monitors, fn owner_pid, acc ->
          Map.put_new_lazy(acc, owner_pid, fn -> Process.monitor(owner_pid) end)
        end)

      %{
        subscriptions: subscriptions,
        ordinary_owner_monitors: %{},
        security_sync_monitors: monitors,
        security_sync_subscribers: Config.security_sync_subscribers_snapshot(),
        subscription_registry_ready?: registry_available?(),
        relay_pid: state.relay_pid,
        relay_monitor_ref: state.relay_monitor_ref,
        relay_custody: state.relay_custody,
        authenticated_calls: state.authenticated_calls,
        subscription_custody: state.subscription_custody,
        stats: %{
          total_published: 0,
          total_delivered: 0,
          total_errors: 0,
          total_auth_denied: 0
        }
      }
    end

    defp demonitor_security_sync_owners(monitors) do
      Enum.each(monitors, fn {_owner_pid, ref} ->
        Process.demonitor(ref, [:flush])
      end)
    end

    defp clear_persisted_subscriptions do
      if function_exported?(SubscriptionRegistry, :clear, 0) do
        SubscriptionRegistry.clear()
      else
        {:error, :unsupported_request}
      end
    end

    defp registry_available? do
      case Process.whereis(SubscriptionRegistry) do
        pid when is_pid(pid) -> Process.alive?(pid)
        _missing -> false
      end
    end
  end

  defp restore_ordinary_subscriptions(state) do
    case SubscriptionRegistry.snapshot() do
      {:ok, subscriptions} when is_map(subscriptions) ->
        {restorable, invalid_ids} =
          Enum.reduce(subscriptions, {%{}, []}, fn {id, subscription}, {valid, invalid} ->
            case put_restored_subscription_custody(state, subscription) do
              :ok -> {Map.put(valid, id, subscription), invalid}
              :error -> {valid, [id | invalid]}
            end
          end)

        _ = delete_persisted_subscription_ids(invalid_ids)

        state
        |> Map.update!(:subscriptions, &Map.merge(restorable, &1))
        |> Map.put(:subscription_registry_ready?, true)
        |> reconcile_ordinary_owner_monitors()

      {:error, _reason} ->
        maybe_retry_subscription_restore(state)
    end
  end

  defp maybe_retry_subscription_restore(state) do
    unless @test_env do
      Process.send_after(self(), :restore_subscriptions, @subscription_restore_retry_ms)
    end

    %{state | subscription_registry_ready?: false}
  end

  defp persist_ordinary_subscription(subscription) do
    case SubscriptionRegistry.put(subscription) do
      :ok -> :ok
      {:error, :subscription_registry_unavailable} when @test_env -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp delete_persisted_subscription(%{security_sync_owner: _owner_pid}), do: :ok

  defp delete_persisted_subscription(%{id: subscription_id}) do
    delete_persisted_subscription_ids([subscription_id])
  end

  defp delete_persisted_subscription_ids([]), do: :ok

  defp delete_persisted_subscription_ids(subscription_ids) do
    case SubscriptionRegistry.delete_many(subscription_ids) do
      :ok -> :ok
      {:error, :subscription_registry_unavailable} when @test_env -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp drop_invalid_subscriptions(state, []), do: state

  defp drop_invalid_subscriptions(state, invalid_ids) do
    {ordinary_ids, transient_ids} =
      Enum.split_with(invalid_ids, fn id ->
        case Map.get(state.subscriptions, id) do
          %{security_sync_owner: _owner_pid} -> false
          %{owner_pid: owner_pid} when is_pid(owner_pid) -> true
          _missing -> false
        end
      end)

    removable_ordinary_ids =
      case delete_persisted_subscription_ids(ordinary_ids) do
        :ok -> ordinary_ids
        {:error, _reason} -> []
      end

    state
    |> drop_subscription_custody(removable_ordinary_ids ++ transient_ids)
    |> update_in([:subscriptions], &Map.drop(&1, removable_ordinary_ids ++ transient_ids))
    |> reconcile_ordinary_owner_monitors()
  end

  defp reconcile_ordinary_owner_monitors(state) do
    live_owners =
      state.subscriptions
      |> Map.values()
      |> Enum.flat_map(fn
        %{owner_pid: owner_pid} = subscription when is_pid(owner_pid) ->
          if Map.has_key?(subscription, :security_sync_owner), do: [], else: [owner_pid]

        _other ->
          []
      end)
      |> MapSet.new()

    {kept_monitors, stale_monitors} =
      Map.split(state.ordinary_owner_monitors, MapSet.to_list(live_owners))

    demonitor_ordinary_owners(stale_monitors)

    monitors =
      Enum.reduce(live_owners, kept_monitors, fn owner_pid, acc ->
        Map.put_new_lazy(acc, owner_pid, fn -> Process.monitor(owner_pid) end)
      end)

    %{state | ordinary_owner_monitors: monitors}
  end

  defp demonitor_ordinary_owners(monitors) do
    Enum.each(monitors, fn {_owner_pid, ref} ->
      Process.demonitor(ref, [:flush])
    end)
  end

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

  defp subscription_identity(opts) do
    asserted = Keyword.get(opts, :principal_id)
    auth_context = Keyword.get(opts, :auth_context)

    case auth_context do
      %Arbor.Contracts.Security.AuthContext{principal_id: principal_id}
      when is_binary(principal_id) and principal_id != "" ->
        {principal_id, auth_context, is_nil(asserted) or asserted == principal_id}

      nil ->
        {asserted, nil, true}

      _invalid ->
        {asserted, nil, false}
    end
  end

  # No restricted topics overlap — no auth needed
  defp authorize_subscription(_principal_id, [], _opts) do
    {:ok, MapSet.new()}
  end

  # Restricted topics overlap but no principal — deny
  defp authorize_subscription(nil, _restricted_topics, _opts) do
    {:error, :unauthorized}
  end

  # Check authorization for each restricted topic
  defp authorize_subscription(principal_id, restricted_topics, opts) do
    authorizer = Config.authorizer()

    results =
      Enum.map(restricted_topics, fn topic ->
        if function_exported?(authorizer, :authorize_subscription, 3) do
          {topic, authorizer.authorize_subscription(principal_id, topic, opts)}
        else
          {topic, authorizer.authorize_subscription(principal_id, topic)}
        end
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

    {matching_subs, invalid_filter_ids} =
      select_matching_subscriptions(
        state.subscriptions,
        signal,
        signal_topic,
        signal_restricted?
      )

    stats =
      state.stats
      |> Map.update!(:total_published, &(&1 + 1))
      |> Map.update!(:total_errors, &(&1 + length(invalid_filter_ids)))

    {delivered, errors, invalid_handler_ids} =
      Enum.reduce(matching_subs, {0, 0, []}, fn sub, {d, e, invalid_ids} ->
        case deliver_signal(signal, sub, state) do
          :ok -> {d + 1, e, invalid_ids}
          {:error, _} -> {d, e + 1, [sub.id | invalid_ids]}
        end
      end)

    stats =
      stats
      |> Map.update!(:total_delivered, &(&1 + delivered))
      |> Map.update!(:total_errors, &(&1 + errors))

    invalid_ids = invalid_filter_ids ++ invalid_handler_ids

    state
    |> Map.put(:stats, stats)
    |> drop_invalid_subscriptions(invalid_ids)
  end

  defp select_matching_subscriptions(subscriptions, signal, signal_topic, restricted?) do
    Enum.reduce(subscriptions, {[], []}, fn {_id, sub}, {matching, invalid_ids} ->
      if matches_pattern?(sub.pattern, signal) and
           authorized_for_signal?(sub, signal_topic, restricted?) do
        case passes_filter?(sub.filter, signal) do
          :pass -> {[sub | matching], invalid_ids}
          :skip -> {matching, invalid_ids}
          :invalid -> {matching, [sub.id | invalid_ids]}
        end
      else
        {matching, invalid_ids}
      end
    end)
  end

  # Delivery-time authorization filter.
  # Non-restricted signals: always delivered.
  # Restricted signals: only delivered if subscriber is authorized for that topic.
  defp authorized_for_signal?(_sub, _topic, false), do: true

  defp authorized_for_signal?(%{authorized_topics: authorized_topics}, topic, true) do
    MapSet.member?(authorized_topics, topic)
  end

  defp deliver_signal(
         signal,
         %{async: true, id: subscription_id, security_sync_owner: owner_pid} = sub,
         state
       ) do
    with %Signal{} = decrypted_signal <- prepare_signal_for_delivery(signal, sub),
         {:ok, delivery_ref} <-
           security_sync_delivery_ref(state, subscription_id, owner_pid),
         true <- Process.alive?(owner_pid) do
      send(owner_pid, {:signal_received, delivery_ref, decrypted_signal})
      :ok
    else
      nil -> {:error, :delivery_skipped}
      _invalid_custody_or_owner -> {:error, :invalid_security_sync_delivery}
    end
  end

  defp deliver_signal(signal, %{async: true, handler: handler} = sub, _state) do
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

  defp deliver_signal(signal, %{async: false, handler: handler} = sub, _state) do
    case prepare_signal_for_delivery(signal, sub) do
      nil ->
        {:error, :delivery_skipped}

      decrypted_signal ->
        case invoke_bounded(fn -> handler.(decrypted_signal) end) do
          {:ok, :ok} -> :ok
          {:ok, {:error, reason}} -> {:error, reason}
          {:ok, other} -> {:error, {:invalid_handler_result, other}}
          {:error, reason} -> {:error, reason}
        end
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
        maybe_decrypt_signal(signal, sub)
      else
        # Not authorized - don't deliver encrypted signals
        nil
      end
    else
      # OQ-7: even non-restricted signals may carry a channel-encrypted
      # payload (the __channel_encrypted__ envelope). Pass the subscriber
      # through so the channel branch can use the subscriber's identity
      # for decryption authorization instead of the sender's.
      maybe_decrypt_signal(signal, sub)
    end
  end

  defp safe_invoke(handler, signal) do
    try do
      handler.(signal)
    rescue
      _error -> :error
    catch
      _kind, _reason -> :error
    end
  end

  defp matches_pattern?("*", _signal), do: true

  defp matches_pattern?(pattern, %Signal{category: category, type: type}) do
    pattern_segments = String.split(pattern, ".")
    # Build signal topic from category.type - this is the minimum topic
    # Signals can match deeper patterns via their category/type combo
    signal_segments = safe_to_segments(category) ++ safe_to_segments(type)

    match_segments?(pattern_segments, signal_segments)
  end

  # Convert category/type to string segments safely.
  # Tuples are flattened (e.g. {:agent, :started} → ["agent", "started"]).
  # Maps, pids, and other non-printable values yield a placeholder.
  defp safe_to_segments(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&safe_segment/1)
  end

  defp safe_to_segments(value), do: [safe_segment(value)]

  defp safe_segment(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_segment(value) when is_binary(value), do: value
  defp safe_segment(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_segment(_value), do: "_"

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

  defp passes_filter?(nil, _signal), do: :pass

  defp passes_filter?(filter, signal) when is_function(filter, 1) do
    case invoke_bounded(fn -> filter.(signal) end) do
      {:ok, true} -> :pass
      {:ok, false} -> :skip
      _error_or_invalid -> :invalid
    end
  end

  defp invoke_bounded(fun) when is_function(fun, 0) do
    caller = self()
    result_ref = make_ref()

    {worker, monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, fun.()}
          rescue
            error -> {:error, {:exception, error}}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(caller, {result_ref, result})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^worker, reason} ->
        receive do
          {^result_ref, result} -> result
        after
          0 -> {:error, {:callback_exit, reason}}
        end
    after
      @subscriber_callback_timeout_ms ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^worker, _reason} -> :ok
        after
          10 -> Process.demonitor(monitor_ref, [:flush])
        end

        {:error, :callback_timeout}
    end
  end

  defp generate_subscription_id do
    Identifiers.generate_id("sub_")
  end

  # Private functions — Encryption

  # Encrypt signal data for restricted topics.
  # Skips if already encrypted (e.g., pre-encrypted by emit_preconstructed_signal).
  defp maybe_encrypt_signal(%Signal{category: category, data: data} = signal) do
    restricted_topics = Config.restricted_topics()

    if category in restricted_topics and data != %{} and
         not portable_security_sync_signal?(signal) and
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

  defp portable_security_sync_signal?(%Signal{category: category, type: type}) do
    category in [:security, :identity] and
      (type == :nonce_seen or type in Config.authority_reducing_security_mutations())
  end

  # Decrypt signal data for authorized subscribers
  defp maybe_decrypt_signal(%Signal{category: category, data: data} = signal, sub) do
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
        # Not topic-encrypted; may be channel-encrypted
        maybe_decrypt_channel_signal(signal, sub)
    end
  end

  # Decrypt channel-encrypted signal data
  #
  # OQ-7: pre-fix this called Channels.get_key(channel_id, signal.source) —
  # keyed on the SENDER. That meant decryption succeeded based on whether
  # the sender was a member, not whether the SUBSCRIBER was. Anyone whose
  # subscription matched the topic received plaintext, regardless of their
  # own channel membership.
  #
  # The fix routes through Channels.decrypt_for_member/3 using the subscriber's
  # executor-issued AuthContext. The symmetric key never leaves the Channels
  # GenServer, and membership is verified for the authenticated subscriber,
  # not the sender. A bare caller-asserted principal_id cannot decrypt.
  defp maybe_decrypt_channel_signal(%Signal{data: data} = signal, sub) do
    case data do
      %{
        __channel_encrypted__: true,
        channel_id: channel_id,
        sender_id: _sender_id,
        payload: payload
      } ->
        case subscriber_auth_context(sub) do
          nil ->
            # No subscriber identity ⇒ no decryption.
            %{signal | data: %{__decryption_failed__: true}}

          auth_context ->
            channels_module = Config.channels_module()

            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            case apply(channels_module, :decrypt_for_member, [
                   channel_id,
                   auth_context,
                   normalize_channel_payload(payload)
                 ]) do
              {:ok, plaintext} ->
                replace_channel_payload(signal, plaintext)

              {:error, _reason} ->
                %{signal | data: %{__decryption_failed__: true}}
            end
        end

      _ ->
        # Not channel-encrypted, return as-is
        signal
    end
  end

  defp subscriber_auth_context(%{
         auth_context: %Arbor.Contracts.Security.AuthContext{} = context
       }),
       do: context

  defp subscriber_auth_context(_), do: nil

  # The channel sender writes %{ciphertext: ..., iv: ..., tag: ...} into the
  # signal's payload field. Channels.decrypt_for_member/3 expects the same
  # shape; this normalizer just lifts it from a wrapper if there is one.
  defp normalize_channel_payload(%{ciphertext: _, iv: _, tag: _} = m), do: m
  defp normalize_channel_payload(%{payload: inner}), do: normalize_channel_payload(inner)
  defp normalize_channel_payload(other), do: other

  defp replace_channel_payload(%Signal{} = signal, plaintext) when is_binary(plaintext) do
    case Jason.decode(plaintext) do
      {:ok, decoded} -> %{signal | data: decoded}
      _ -> %{signal | data: %{__plaintext__: plaintext}}
    end
  end

  defp replace_channel_payload(signal, _other) do
    %{signal | data: %{__decryption_failed__: true}}
  end
end
