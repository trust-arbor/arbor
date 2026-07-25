defmodule Arbor.Comms.InteractionRouter do
  @moduledoc """
  Routes agent-to-human interaction requests to whichever channel the
  human is currently active on, and routes responses back to the
  waiting agent.

  Multi-node correct from Phase 1:

  - **Outstanding state** is serialized by the interaction's origin-node
    authority. Phoenix.Tracker mirrors discovery across the cluster, so a
    channel adapter on Node B can route a response by `request_id` without
    holding a PID across nodes.

  - **Response delivery** broadcasts on the per-agent PubSub topic
    `"interaction:agent:" <> agent_id`. The agent's session/executor
    subscribes at startup. PubSub is cluster-aware, so the responding
    adapter doesn't need to know which node hosts the agent.

  - **Presence** uses `Phoenix.Tracker` for cluster-wide channel
    availability per user.

  - **Audit** emits Arbor signals for every request/response. When the
    interaction carries a nonblank `task_id` in metadata/provenance,
    that value is the signal `correlation_id` so task-scoped consumers
    (e.g. coding-benchmark approval accounting) can aggregate history.
    Signal data stays bounded lifecycle observability — never execution control.

  ## Phase 1 scope

  Only the dashboard adapter is wired. Signal/Telegram/Discord/voice
  are additive future channels — no router changes needed when they
  land.
  """

  require Logger

  alias Arbor.Comms.InteractionRegistry
  alias Arbor.Comms.PresenceTracker
  alias Arbor.Contracts.Comms.Interaction

  @owner_clock_recheck_ms 60_000
  @owner_settlement_poll_ms 100

  @typedoc """
  Adapter registry: a map of `channel_atom => module`. Phase 1 only
  populates `:dashboard`; the router falls back to "no adapter, queue
  for later" when no presence is available or no adapter is
  registered for the available channel.

  Configured via Application env:

      config :arbor_comms, :interaction_adapters, %{
        dashboard: Arbor.Dashboard.InteractionAdapter
      }
  """
  @type adapter_map :: %{atom() => module()}

  ## Public API

  @doc """
  Submit a new interaction request. Non-blocking. Returns immediately
  with the `request_id`; the response arrives later on
  `Interaction.response_topic_for_agent(agent_id)`.

  ## Options

  - `:adapter_map` — override the configured adapter map (test-only)
  """
  @spec request(map() | Interaction.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def request(attrs_or_interaction, opts \\ [])

  def request(%Interaction{} = interaction, opts) do
    with {:ok, _durability} <- requested_durability(opts), do: do_request(interaction, opts)
  end

  def request(attrs, opts) when is_map(attrs) or is_list(attrs) do
    with {:ok, _durability} <- requested_durability(opts),
         {:ok, interaction} <- Interaction.new(attrs) do
      do_request(interaction, opts)
    end
  end

  @doc false
  @spec request_durable(Interaction.t(), keyword()) ::
          {:ok, Arbor.Comms.durable_interaction_receipt()} | {:error, term()}
  def request_durable(%Interaction{} = interaction, opts) when is_list(opts) do
    with {:ok, request_opts} <- durable_request_options(opts) do
      case InteractionRegistry.admit_durable(
             interaction,
             request_opts.owner_deadline_unix_ms
           ) do
        {:ok, :existing, %Interaction{}, receipt} ->
          {:ok, receipt}

        {:ok, :inserted, %Interaction{} = stored_interaction, receipt} ->
          dispatch_inserted_durable(stored_interaction, request_opts.adapter_map, receipt)

        {:error, _reason} = error ->
          error
      end
    end
  end

  def request_durable(_interaction, _opts), do: {:error, :invalid_options}

  @doc """
  Submit a response to a previously-requested interaction. Called by
  channel adapters when they recognize an incoming message as a
  response.

  Routes the response back to the waiting agent via PubSub on the
  interaction's `response_topic`. Cluster-aware — works regardless of
  which node hosts the waiting agent.

  The answer is also retained in the authority process
  (`get_response/1`) so waiters that subscribe after publication still
  observe the decision without sleeps or lost-message races. This lookup is
  intentionally in-memory and does not survive authority or node restart.
  """
  @spec respond(String.t(), Interaction.response(), map()) :: :ok | {:error, term()}
  def respond(request_id, response, metadata \\ %{}) when is_binary(request_id) do
    metadata = if is_map(metadata), do: metadata, else: %{}

    case InteractionRegistry.resolve(request_id, response: response, metadata: metadata) do
      {:ok, interaction} ->
        emit_signal(:resolved, interaction, %{response: response, metadata: metadata})
        broadcast_response(interaction, response, metadata)
        :ok

      {:error, {:already_terminal, status}} ->
        Logger.debug("[InteractionRouter] respond/3: request_id #{request_id} already #{status}")

        {:error, {:already_terminal, status}}

      :not_found ->
        Logger.debug(
          "[InteractionRouter] respond/3: unknown request_id #{request_id} (already resolved or expired?)"
        )

        {:error, :not_found}

      {:error, reason} ->
        Logger.warning(
          "[InteractionRouter] respond/3: request_id #{request_id} transition failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Abandon a pending interaction with an explicit lifecycle reason.

  Abandonment is idempotent. If a response already won the terminal
  transition, returns an `:already_terminal` error and leaves that response
  unchanged.
  """
  @spec abandon(String.t(), atom() | String.t()) :: :ok | {:error, term()}
  def abandon(request_id, reason)
      when is_binary(request_id) and (is_atom(reason) or is_binary(reason)) do
    case InteractionRegistry.abandon(request_id, reason) do
      {:ok, %Interaction{} = interaction} ->
        emit_signal(:abandoned, interaction, %{})
        :ok

      {:ok, :already_abandoned} ->
        :ok

      {:error, _reason} = error ->
        error

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  In-memory public lookup for a responded interaction.

  Returns `{:ok, %{response: term(), metadata: map()}}` when the answer is
  still within the registry TTL, otherwise `:not_found`.
  """
  @spec get_response(String.t()) ::
          {:ok, %{response: term(), metadata: map()}} | :not_found
  def get_response(request_id) when is_binary(request_id) do
    case InteractionRegistry.get_resolved(request_id) do
      {:ok, %{response: response, metadata: metadata}} ->
        {:ok, %{response: response, metadata: metadata || %{}}}

      :not_found ->
        :not_found
    end
  end

  @doc """
  Wait for an interaction response without the
  visible-request-before-subscribe race.

  Subscribes to the agent response topic first, then captures and arms the
  origin authority before blocking on PubSub. Always unsubscribes.

  Options:
    * `:timeout` — milliseconds (default 60_000)
    * `:pubsub` — PubSub server (default `Arbor.Comms.PubSub`)
  """
  @spec await_response(String.t(), String.t(), keyword()) ::
          {:ok, term(), map()} | {:error, :timeout | term()}
  def await_response(request_id, agent_id, opts \\ [])
      when is_binary(request_id) and is_binary(agent_id) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    pubsub = Keyword.get(opts, :pubsub, Arbor.Comms.PubSub)
    topic = Interaction.response_topic_for_agent(agent_id)

    # Subscribe before capturing and arming the origin authority so a
    # concurrent response cannot land in the gap before receive/after.
    :ok = Phoenix.PubSub.subscribe(pubsub, topic)

    try do
      case InteractionRegistry.capture_timeout_authority(request_id, timeout) do
        {:ok, _capture, {:terminal, terminal}} ->
          timeout_terminal_result(terminal)

        {:ok, capture, :armed} ->
          await_captured_response(capture, request_id, timeout)

        :not_found ->
          {:error, :timeout}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Phoenix.PubSub.unsubscribe(pubsub, topic)
    end
  end

  @doc false
  @spec await_durable_response(String.t(), String.t(), keyword()) ::
          {:ok, term(), map()} | {:error, :timeout | term()}
  def await_durable_response(request_id, agent_id, opts)
      when is_binary(request_id) and is_binary(agent_id) and is_list(opts) do
    with {:ok, observer} <- durable_observer_options(opts),
         :ok <- subscribe(observer.pubsub, Interaction.response_topic_for_agent(agent_id)) do
      topic = Interaction.response_topic_for_agent(agent_id)

      try do
        case observe_durable(request_id, agent_id, observer) do
          {:ok, :pending} ->
            await_durable_observation(request_id, agent_id, observer)

          {:ok, {:terminal, terminal}} ->
            timeout_terminal_result(terminal)

          :not_found ->
            {:error, :not_found}

          {:error, _reason} = error ->
            error
        end
      after
        unsubscribe(observer.pubsub, topic)
      end
    end
  end

  def await_durable_response(_request_id, _agent_id, _opts),
    do: {:error, :invalid_options}

  @doc """
  List pending interactions (delegates to the registry). Useful for
  dashboard summaries and audit.
  """
  @spec pending() :: [Interaction.t()]
  def pending, do: InteractionRegistry.list_pending()

  defp await_captured_response(capture, request_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_captured_response_until(capture, request_id, deadline)
  end

  defp await_captured_response_until(capture, request_id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:interaction_response, %{request_id: ^request_id, response: response} = payload} ->
        metadata = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}

        case captured_response_result(capture, request_id, response, metadata) do
          {:done, result} -> result
          :continue -> await_captured_response_until(capture, request_id, deadline)
        end
    after
      remaining ->
        finalize_timeout(capture, request_id)
    end
  end

  defp captured_response_result(capture, request_id, response, metadata) do
    if durable_capture?(capture) do
      case InteractionRegistry.reconcile_timeout_capture(capture, request_id) do
        {:ok, {:terminal, terminal}} -> {:done, timeout_terminal_result(terminal)}
        {:error, :stale_operation} -> {:done, {:error, :timeout}}
        _ -> :continue
      end
    else
      {:done, {:ok, response, metadata}}
    end
  end

  defp finalize_timeout(capture, request_id) do
    case InteractionRegistry.finalize_timeout(capture, request_id) do
      {:ok, terminal} ->
        timeout_terminal_result(terminal)

      {:error, reason} when reason in [:authority_unavailable, :stale_timeout_capture] ->
        reconcile_durable_timeout(capture, request_id)

      :not_found ->
        reconcile_durable_timeout(capture, request_id)

      _other ->
        {:error, :timeout}
    end
  end

  defp reconcile_durable_timeout(capture, request_id) do
    if durable_capture?(capture) do
      case InteractionRegistry.capture_timeout_authority(request_id, 0) do
        {:ok, current_capture, outcome} ->
          if same_operation?(capture, current_capture) do
            settle_recaptured_timeout(current_capture, request_id, outcome)
          else
            {:error, :timeout}
          end

        _other ->
          {:error, :timeout}
      end
    else
      {:error, :timeout}
    end
  end

  defp settle_recaptured_timeout(_capture, _request_id, {:terminal, terminal}),
    do: timeout_terminal_result(terminal)

  defp settle_recaptured_timeout(capture, request_id, :armed) do
    case InteractionRegistry.finalize_timeout(capture, request_id) do
      {:ok, terminal} -> timeout_terminal_result(terminal)
      _other -> {:error, :timeout}
    end
  end

  defp durable_capture?(%{operation_id: operation_id, authority_epoch: authority_epoch}),
    do: is_binary(operation_id) and is_binary(authority_epoch)

  defp durable_capture?(_capture), do: false

  defp same_operation?(
         %{operation_id: operation_id},
         %{operation_id: operation_id}
       )
       when is_binary(operation_id),
       do: true

  defp same_operation?(_old_capture, _current_capture), do: false

  defp timeout_terminal_result(%{status: :responded, response: response, metadata: metadata}) do
    {:ok, response, metadata || %{}}
  end

  defp timeout_terminal_result(_terminal), do: {:error, :timeout}

  ## Private — request flow

  defp do_request(%Interaction{} = interaction, opts) do
    adapter_map = Keyword.get(opts, :adapter_map, configured_adapters())
    durability = Keyword.get(opts, :durability, :volatile)

    case InteractionRegistry.admit(interaction, durability: durability) do
      {:ok, :existing, %Interaction{} = stored_interaction} ->
        {:ok, stored_interaction.request_id}

      {:ok, :inserted, %Interaction{} = stored_interaction} ->
        dispatch_inserted(stored_interaction, adapter_map)

      {:error, _reason} = error ->
        error
    end
  end

  defp dispatch_inserted(interaction, adapter_map) do
    case dispatch(interaction, adapter_map) do
      :ok ->
        emit_signal(:requested, interaction, %{})
        {:ok, interaction.request_id}

      :no_channel ->
        # Already persisted; queue for later when presence becomes
        # available. Adapters that come online can pick up pending
        # interactions targeted at their channel via list_pending.
        emit_signal(:queued, interaction, %{})
        {:ok, interaction.request_id}
    end
  end

  defp dispatch_inserted_durable(interaction, adapter_map, receipt) do
    case dispatch(interaction, adapter_map) do
      :ok ->
        emit_signal(:requested, interaction, %{})
        {:ok, receipt}

      :no_channel ->
        emit_signal(:queued, interaction, %{})
        {:ok, receipt}
    end
  end

  defp durable_request_options(opts) do
    allowed = [:owner_deadline_unix_ms, :adapter_map]

    with :ok <- validate_keyword_options(opts, allowed),
         {:ok, deadline} <- required_non_negative_integer(opts, :owner_deadline_unix_ms),
         adapter_map = Keyword.get(opts, :adapter_map, configured_adapters()),
         true <- is_map(adapter_map) do
      {:ok, %{owner_deadline_unix_ms: deadline, adapter_map: adapter_map}}
    else
      false -> {:error, :invalid_options}
      {:error, _reason} = error -> error
    end
  end

  defp durable_observer_options(opts) do
    allowed = [:operation_id, :owner_deadline_unix_ms, :timeout, :pubsub]

    with :ok <- validate_keyword_options(opts, allowed),
         {:ok, operation_id} <- required_identifier(opts, :operation_id),
         {:ok, deadline} <- required_non_negative_integer(opts, :owner_deadline_unix_ms),
         {:ok, timeout, owner_bound?} <- observer_timeout(opts, deadline) do
      {:ok,
       %{
         operation_id: operation_id,
         owner_deadline_unix_ms: deadline,
         timeout: timeout,
         owner_bound?: owner_bound?,
         pubsub: Keyword.get(opts, :pubsub, Arbor.Comms.PubSub)
       }}
    end
  end

  defp validate_keyword_options(opts, allowed) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      if length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in allowed)),
        do: :ok,
        else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp required_identifier(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
        if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_options}

      _ ->
        {:error, :invalid_options}
    end
  end

  defp required_non_negative_integer(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, :invalid_options}
    end
  end

  defp observer_timeout(opts, owner_deadline_unix_ms) do
    owner_remaining = max(owner_deadline_unix_ms - System.system_time(:millisecond), 0)

    case Keyword.fetch(opts, :timeout) do
      :error ->
        {:ok, owner_remaining, true}

      {:ok, timeout} when is_integer(timeout) and timeout >= 0 ->
        {:ok, min(timeout, owner_remaining), timeout >= owner_remaining}

      _ ->
        {:error, :invalid_options}
    end
  end

  defp subscribe(pubsub, topic) do
    Phoenix.PubSub.subscribe(pubsub, topic)
  rescue
    _ -> {:error, :authority_unavailable}
  catch
    :exit, _ -> {:error, :authority_unavailable}
  end

  defp unsubscribe(pubsub, topic) do
    Phoenix.PubSub.unsubscribe(pubsub, topic)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp await_durable_observation(request_id, agent_id, observer) do
    deadline = System.monotonic_time(:millisecond) + observer.timeout
    await_durable_observation_until(request_id, agent_id, observer, deadline)
  end

  defp await_durable_observation_until(request_id, agent_id, observer, deadline) do
    total_remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    wait = min(total_remaining, @owner_clock_recheck_ms)

    receive do
      {:interaction_response, %{request_id: ^request_id}} ->
        continue_durable_observation(request_id, agent_id, observer, deadline)

      {:interaction_terminal, %{request_id: ^request_id}} ->
        continue_durable_observation(request_id, agent_id, observer, deadline)
    after
      wait ->
        case observe_durable(request_id, agent_id, observer) do
          {:ok, {:terminal, terminal}} ->
            timeout_terminal_result(terminal)

          {:ok, :pending} when total_remaining > wait ->
            await_durable_observation_until(request_id, agent_id, observer, deadline)

          {:ok, :pending} ->
            if observer.owner_bound? do
              await_owner_settlement(request_id, agent_id, observer)
            else
              {:error, :timeout}
            end

          :not_found ->
            {:error, :not_found}

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp continue_durable_observation(request_id, agent_id, observer, deadline) do
    case observe_durable(request_id, agent_id, observer) do
      {:ok, :pending} ->
        await_durable_observation_until(request_id, agent_id, observer, deadline)

      {:ok, {:terminal, terminal}} ->
        timeout_terminal_result(terminal)

      :not_found ->
        {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp await_owner_settlement(request_id, agent_id, observer) do
    wall_remaining =
      max(observer.owner_deadline_unix_ms - System.system_time(:millisecond), 0)

    wait =
      if wall_remaining > 0,
        do: min(wall_remaining, @owner_clock_recheck_ms),
        else: @owner_settlement_poll_ms

    receive do
      {:interaction_response, %{request_id: ^request_id}} ->
        observe_owner_settlement(request_id, agent_id, observer)

      {:interaction_terminal, %{request_id: ^request_id}} ->
        observe_owner_settlement(request_id, agent_id, observer)
    after
      wait ->
        observe_owner_settlement(request_id, agent_id, observer)
    end
  end

  defp observe_owner_settlement(request_id, agent_id, observer) do
    case observe_durable(request_id, agent_id, observer) do
      {:ok, :pending} -> await_owner_settlement(request_id, agent_id, observer)
      {:ok, {:terminal, terminal}} -> timeout_terminal_result(terminal)
      :not_found -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp observe_durable(request_id, agent_id, observer) do
    InteractionRegistry.observe_durable(
      request_id,
      agent_id,
      observer.operation_id,
      observer.owner_deadline_unix_ms
    )
  end

  defp requested_durability(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get(opts, :durability, :volatile) do
        :volatile -> {:ok, :volatile}
        :node_restart -> {:ok, :node_restart}
        _ -> {:error, :unsupported_durability}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp requested_durability(_opts), do: {:error, :invalid_options}

  defp dispatch(%Interaction{user_id: user_id} = interaction, adapter_map) do
    case PresenceTracker.primary_channel(user_id) do
      {:ok, channel, meta} ->
        case Map.get(adapter_map, channel) do
          nil ->
            Logger.info(
              "[InteractionRouter] no adapter for channel #{inspect(channel)}; queueing #{interaction.request_id}"
            )

            :no_channel

          adapter when is_atom(adapter) ->
            case safe_send(adapter, meta, interaction) do
              :ok ->
                :ok

              {:error, reason} ->
                # Adapter failed but the interaction IS persisted.
                # Treat as queued — log the failure and return :ok so
                # the caller (agent) gets a non-blocking result.
                # Future adapter health / retry can pick this up.
                Logger.warning(
                  "[InteractionRouter] adapter failed for #{interaction.request_id}: " <>
                    "#{inspect(reason)} — interaction queued"
                )

                :no_channel
            end
        end

      :no_presence ->
        Logger.info(
          "[InteractionRouter] no active presence for user #{user_id}; queueing #{interaction.request_id}"
        )

        :no_channel
    end
  end

  defp safe_send(adapter, channel_meta, interaction) do
    adapter.send_interaction(channel_meta, interaction)
  rescue
    e ->
      Logger.warning(
        "[InteractionRouter] adapter #{inspect(adapter)} crashed: #{Exception.message(e)}"
      )

      {:error, {:adapter_crash, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.warning("[InteractionRouter] adapter #{inspect(adapter)} exited: #{inspect(reason)}")
      {:error, {:adapter_exit, reason}}
  end

  ## Private — response flow

  defp broadcast_response(%Interaction{response_topic: topic} = interaction, response, metadata) do
    payload =
      {:interaction_response,
       %{
         request_id: interaction.request_id,
         response: response,
         metadata: metadata,
         resolved_at: DateTime.utc_now()
       }}

    pubsub = current_pubsub()

    try do
      Phoenix.PubSub.broadcast(pubsub, topic, payload)
    rescue
      e ->
        Logger.warning(
          "[InteractionRouter] broadcast failed for #{interaction.request_id}: #{Exception.message(e)}"
        )
    catch
      :exit, reason ->
        Logger.warning(
          "[InteractionRouter] broadcast exited for #{interaction.request_id}: #{inspect(reason)}"
        )
    end
  end

  # HITL traffic is pinned to Arbor.Comms.PubSub — started by
  # Arbor.Comms.Application, always reachable when arbor_comms is up.
  # See Arbor.Comms.Application for the rationale (the prior discovery
  # cond returned nil at supervisor-init time because no other PubSub
  # existed yet).
  defp current_pubsub, do: Arbor.Comms.PubSub

  defp configured_adapters do
    Application.get_env(:arbor_comms, :interaction_adapters, %{})
  end

  ## Signal emission for audit

  # Observability only — never gates execution. Payload is bounded lifecycle
  # data; do not project approval_context, target, params, previews, or notes.
  @max_task_id_bytes 256

  defp emit_signal(event, %Interaction{} = interaction, extra) do
    data =
      %{
        request_id: interaction.request_id,
        kind: interaction.kind,
        agent_id: interaction.agent_id,
        user_id: interaction.user_id,
        urgency: interaction.urgency,
        event_sequence: System.unique_integer([:monotonic, :positive])
      }
      |> Map.merge(safe_signal_extra(interaction.kind, extra))

    opts =
      case interaction_task_id(interaction) do
        nil -> []
        task_id -> [correlation_id: task_id]
      end

    try do
      # Approval accounting queries these events as soon as the owner action
      # returns. Store synchronously so request/response wake-up cannot race the
      # audit observation; subscriber delivery remains asynchronous.
      Arbor.Signals.emit(:interaction, event, data, Keyword.put(opts, :async, false))
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp safe_signal_extra(:approval, %{response: response} = extra) when is_map(extra) do
    base =
      case response do
        value when value in [:approved, "approved"] -> %{response: :approved}
        value when value in [:rejected, "rejected"] -> %{response: :rejected}
        _other -> %{}
      end

    case rework_flag(Map.get(extra, :metadata) || Map.get(extra, "metadata")) do
      nil -> base
      rework? -> Map.put(base, :rework, rework?)
    end
  end

  defp safe_signal_extra(_kind, _extra), do: %{}

  defp rework_flag(metadata) when is_map(metadata) do
    case map_get(metadata, :rework) || map_get(metadata, :decision) do
      true -> true
      :rework -> true
      "rework" -> true
      _other -> nil
    end
  end

  defp rework_flag(_), do: nil

  defp interaction_task_id(%Interaction{metadata: metadata}) when is_map(metadata) do
    # Prefer provenance (bounded approval provenance), then approval_context,
    # then a top-level task_id if present. Atom and string keys accepted.
    candidates = [
      nested_task_id(map_get(metadata, :provenance)),
      nested_task_id(map_get(metadata, :approval_context)),
      map_get(metadata, :task_id)
    ]

    Enum.find_value(candidates, &bounded_task_id/1)
  end

  defp interaction_task_id(_), do: nil

  defp nested_task_id(map), do: nested_task_id(map, 0)

  defp nested_task_id(map, depth) when is_map(map) and depth < 2,
    do: map_get(map, :task_id) || nested_task_id(map_get(map, :provenance), depth + 1)

  defp nested_task_id(_map, _depth), do: nil

  defp bounded_task_id(value) when is_binary(value) do
    if value != "" and byte_size(value) <= @max_task_id_bytes and String.valid?(value) and
         value == String.trim(value) and not String.contains?(value, <<0>>),
       do: value,
       else: nil
  end

  defp bounded_task_id(_), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_get(_map, _key), do: nil
end
