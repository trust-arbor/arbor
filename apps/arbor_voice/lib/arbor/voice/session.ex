defmodule Arbor.Voice.Session do
  @moduledoc false
  # Internal supervised voice session (VP-04D2B + VP-04E1 text turns). Not part
  # of the public Arbor.Voice facade — callers use start_session /
  # session_status / stop_session / text_turn with the `{user_id, agent_id}`
  # tuple key only. Never exposes a pid.

  use GenServer

  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Voice.Session.Settlement
  alias Arbor.Voice.Session.TurnCore

  @cleanup_key :budget_settlement
  @registry Arbor.Voice.Registry
  # Must outlive ResourceOwner close (max close timeout + cleanup grace).
  @stop_call_timeout_ms 70_000
  # Upper bound on backend poll window (packet: no greater than 100 ms).
  @max_poll_window_ms 100
  # Mirror ResourceOwner's default when resource_owner_opts omit the key.
  @default_owner_max_recv_ms 1_000
  # Text turns can run until hard budget; reply path clears the caller.
  @turn_call_timeout_ms :infinity

  # ---------------------------------------------------------------------------
  # Internal start / call API (facade only)
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(config) when is_map(config) do
    GenServer.start_link(__MODULE__, config, name: via(config.session_key))
  end

  @doc false
  def status(pid) when is_pid(pid) do
    GenServer.call(pid, :status)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, _ -> {:error, :not_found}
  end

  @doc false
  def stop(pid) when is_pid(pid) do
    GenServer.call(pid, :stop, @stop_call_timeout_ms)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:normal, _} -> :ok
    :exit, _ -> {:error, :not_found}
  end

  @doc false
  def text_turn(pid, user_text) when is_pid(pid) and is_binary(user_text) do
    GenServer.call(pid, {:text_turn, user_text}, @turn_call_timeout_ms)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:normal, _} -> {:error, :session_stopped}
    :exit, _ -> {:error, :not_found}
  end

  defp via(session_key), do: {:via, Registry, {@registry, session_key}}

  # ---------------------------------------------------------------------------
  # Init — transactional readiness with exclusive unwind
  # ---------------------------------------------------------------------------

  @impl true
  def init(config) do
    case start_transaction(config) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp start_transaction(config) do
    case resolve_engagement(config) do
      {:ok, engagement_id} ->
        after_engagement(config, engagement_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp after_engagement(config, engagement_id) do
    case reserve_budget(config) do
      {:ok, _reservation, reserved_ms, start_ms, settlement} ->
        after_reservation(config, engagement_id, reserved_ms, start_ms, settlement)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp after_reservation(config, engagement_id, reserved_ms, start_ms, settlement) do
    case start_resource_owner(config) do
      {:ok, owner} ->
        after_owner(config, engagement_id, reserved_ms, start_ms, settlement, owner)

      {:error, reason} ->
        # No owner started — settle release directly (pre-registration path).
        _ = settle_release(settlement, config)
        {:error, reason}
    end
  end

  defp after_owner(config, engagement_id, reserved_ms, start_ms, settlement, owner) do
    case register_settlement_cleanup(config, owner, settlement) do
      :ok ->
        after_cleanup_registered(
          config,
          engagement_id,
          reserved_ms,
          start_ms,
          settlement,
          owner
        )

      {:error, reason} ->
        # Before cleanup registration succeeds: close owner (catch-safe) then
        # always settle release directly. A raise/throw/exit from close must
        # not skip release — no cleanup was registered, so direct release is
        # the only settlement authority. Never both after registration.
        _ = safe_close_resource_owner(config.resource_owner, owner)
        _ = settle_release(settlement, config)
        {:error, reason}
    end
  end

  defp after_cleanup_registered(
         config,
         engagement_id,
         reserved_ms,
         start_ms,
         settlement,
         owner
       ) do
    case configure_and_read_meta(config, owner) do
      {:ok, backend, mode} ->
        after_backend_ready(
          config,
          engagement_id,
          reserved_ms,
          start_ms,
          settlement,
          owner,
          backend,
          mode
        )

      {:error, reason} ->
        # After registration: close owner; cleanup is sole settlement authority.
        _ = safe_close_resource_owner(config.resource_owner, owner)
        {:error, reason}
    end
  end

  defp after_backend_ready(
         config,
         engagement_id,
         reserved_ms,
         start_ms,
         settlement,
         owner,
         backend,
         mode
       ) do
    timer_ref = Process.send_after(self(), :hard_timeout, reserved_ms)

    case Settlement.arm_consume(settlement) do
      :ok ->
        state = %{
          lifecycle: :ready,
          user_id: config.user_id,
          agent_id: config.agent_id,
          session_key: config.session_key,
          engagement_id: engagement_id,
          owner: owner,
          settlement: settlement,
          reserved_ms: reserved_ms,
          start_ms: start_ms,
          backend: backend,
          mode: mode,
          timer_ref: timer_ref,
          resource_owner: config.resource_owner,
          signals: config.signals,
          wall_clock: config.wall_clock,
          monotonic_clock: config.monotonic_clock,
          comms: config.comms,
          transcript_recorder: config.transcript_recorder,
          transcript_opts: config.transcript_opts,
          # min(100, owner max_recv) so recv never exceeds a tighter owner cap.
          poll_window_ms: derive_poll_window_ms(config.resource_owner_opts),
          turn: nil,
          turn_generation: 0,
          closing: false
        }

        # Success signals only after every readiness step succeeds.
        safe_emit(state, :start)
        safe_emit(state, :backend_connected)
        {:ok, state}

      {:error, _reason} ->
        _ = Process.cancel_timer(timer_ref)
        # After registration: close owner only; do not settle independently.
        _ = safe_close_resource_owner(config.resource_owner, owner)
        {:error, :start_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Startup steps
  # ---------------------------------------------------------------------------

  defp resolve_engagement(config) do
    comms_opts =
      case config.engagement_store do
        nil -> []
        store -> [engagement_store: store]
      end

    try do
      case config.comms.resolve_user_engagement(config.agent_id, config.user_id, comms_opts) do
        {:ok, engagement} ->
          case engagement_id(engagement) do
            {:ok, id} -> {:ok, id}
            :error -> {:error, :engagement_unavailable}
          end

        {:error, _reason} ->
          {:error, :engagement_unavailable}

        _other ->
          {:error, :engagement_unavailable}
      end
    catch
      _kind, _reason ->
        {:error, :engagement_unavailable}
    end
  end

  defp engagement_id(%{id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp engagement_id(%{id: id}) when is_binary(id), do: :error
  defp engagement_id(%{id: id}) when is_atom(id), do: :error
  defp engagement_id(_), do: :error

  defp reserve_budget(config) do
    # Wall clock is an injected collaborator: invoke inside catch/normalization
    # so raise/throw/exit/malformed values never leak past the public facade.
    # Accept only a valid UTC DateTime; never reserve or emit on failure.
    case read_wall_clock_utc(config.wall_clock) do
      {:ok, wall} ->
        case utc_day_and_ms_to_midnight(wall) do
          {:ok, utc_day, ms_to_midnight} ->
            requested_ms = min(config.session_budget_ms, ms_to_midnight)

            if not is_integer(requested_ms) or requested_ms < 1 do
              {:error, :start_failed}
            else
              case safe_reserve(config, utc_day, requested_ms) do
                {:ok, reservation} ->
                  # Once reserve succeeds, every later failure MUST release this
                  # exact reservation — never let an outer catch swallow it.
                  after_successful_reserve(config, reservation)

                {:error, reason} ->
                  {:error, reason}
              end
            end

          :error ->
            {:error, :start_failed}
        end

      {:error, :invalid_clock} ->
        {:error, :start_failed}
    end
  end

  # Injected wall clocks must return a valid UTC DateTime. Mirror the monotonic
  # clock boundary: catch raise/throw/exit and reject non-UTC/malformed values
  # without falling through to System time or reserving budget.
  defp read_wall_clock_utc(clock) when is_function(clock, 0) do
    try do
      case clock.() do
        %DateTime{} = wall ->
          if utc_datetime?(wall), do: {:ok, wall}, else: {:error, :invalid_clock}

        _other ->
          {:error, :invalid_clock}
      end
    catch
      _kind, _reason ->
        {:error, :invalid_clock}
    end
  end

  defp read_wall_clock_utc(_), do: {:error, :invalid_clock}

  # Full UTC contract: ISO calendar, UTC zone name, zero offsets, and
  # semantically valid date/time fields. Rejects zone/offset inconsistencies
  # (e.g. Etc/UTC with utc_offset: 3600) and impossible calendar values
  # (e.g. day 32, microsecond out of range).
  defp utc_datetime?(%DateTime{
         calendar: Calendar.ISO,
         time_zone: tz,
         zone_abbr: "UTC",
         utc_offset: 0,
         std_offset: 0,
         year: year,
         month: month,
         day: day,
         hour: hour,
         minute: minute,
         second: second,
         microsecond: microsecond
       })
       when tz in ["Etc/UTC", "UTC"] do
    valid_iso_date?(year, month, day) and
      valid_iso_time?(hour, minute, second, microsecond)
  end

  defp utc_datetime?(_), do: false

  defp valid_iso_date?(year, month, day) do
    try do
      Calendar.ISO.valid_date?(year, month, day)
    catch
      _kind, _reason -> false
    end
  end

  defp valid_iso_time?(hour, minute, second, microsecond) do
    # Calendar.ISO.valid_time?/4 returns false for out-of-range components;
    # wrap so a hostile inject never escapes the boundary.
    try do
      Calendar.ISO.valid_time?(hour, minute, second, microsecond)
    catch
      _kind, _reason -> false
    end
  end

  defp safe_reserve(config, utc_day, requested_ms) do
    try do
      case config.ledger.reserve(
             config.user_id,
             utc_day,
             requested_ms,
             config.daily_budget_ms,
             config.ledger_opts
           ) do
        {:ok, reservation} ->
          {:ok, reservation}

        {:error, :budget_exhausted} ->
          {:error, :budget_exhausted}

        {:error, _reason} ->
          {:error, :start_failed}
      end
    catch
      _kind, _reason ->
        {:error, :start_failed}
    end
  end

  # Post-reserve: clock read, Settlement.new, and reservation field access are
  # all inside a catch that releases `reservation` before returning error.
  defp after_successful_reserve(config, reservation) do
    try do
      with {:ok, start_ms} <- read_monotonic_ms(config.monotonic_clock),
           {:ok, settlement} <-
             Settlement.new(reservation, config.ledger, config.ledger_opts, start_ms),
           requested_ms when is_integer(requested_ms) and requested_ms > 0 <-
             reservation.requested_ms do
        {:ok, reservation, requested_ms, start_ms, settlement}
      else
        {:error, :invalid_clock} ->
          _ = safe_ledger_release(config, reservation)
          {:error, :start_failed}

        {:error, _reason} ->
          _ = safe_ledger_release(config, reservation)
          {:error, :start_failed}

        _malformed_requested ->
          _ = safe_ledger_release(config, reservation)
          {:error, :start_failed}
      end
    catch
      _kind, _reason ->
        _ = safe_ledger_release(config, reservation)
        {:error, :start_failed}
    end
  end

  defp utc_day_and_ms_to_midnight(%DateTime{} = wall) do
    # Caller already validated UTC DateTime. Prefer unix arithmetic so we never
    # depend on tzdata for the Etc/UTC zone database at the session boundary.
    try do
      unix_ms = DateTime.to_unix(wall, :millisecond)

      if is_integer(unix_ms) do
        ms_into_day = rem(unix_ms, 86_400_000)
        ms_into_day = if ms_into_day < 0, do: ms_into_day + 86_400_000, else: ms_into_day
        ms_to_midnight = 86_400_000 - ms_into_day
        utc_day = wall |> DateTime.to_date() |> Date.to_iso8601()

        if ms_to_midnight > 0 do
          {:ok, utc_day, ms_to_midnight}
        else
          # Exactly on a midnight boundary → full next UTC day.
          {:ok, utc_day, 86_400_000}
        end
      else
        :error
      end
    catch
      _kind, _reason ->
        :error
    end
  end

  defp utc_day_and_ms_to_midnight(_), do: :error

  defp start_resource_owner(config) do
    try do
      case config.resource_owner.start(
             self(),
             config.backend,
             config.backend_opts,
             config.resource_owner_opts
           ) do
        {:ok, owner} when is_pid(owner) ->
          {:ok, owner}

        {:error, _reason} ->
          {:error, :start_failed}

        _other ->
          {:error, :start_failed}
      end
    catch
      _kind, _reason ->
        {:error, :start_failed}
    end
  end

  defp register_settlement_cleanup(config, owner, settlement) do
    monotonic_clock = config.monotonic_clock

    # Return Settlement.settle/2 unchanged. ResourceOwner treats `{:error, _}`
    # as a retriable soft failure and never logs the raw reason from here.
    cleanup = fn ->
      case read_monotonic_ms(monotonic_clock) do
        {:ok, now_ms} ->
          Settlement.settle(settlement, now_ms)

        {:error, _reason} ->
          {:error, :invalid_clock}
      end
    end

    try do
      case config.resource_owner.register_cleanup(owner, @cleanup_key, cleanup) do
        :ok -> :ok
        {:error, _reason} -> {:error, :start_failed}
        _other -> {:error, :start_failed}
      end
    catch
      _kind, _reason ->
        {:error, :start_failed}
    end
  end

  defp configure_and_read_meta(config, owner) do
    try do
      case config.resource_owner.configure(owner, %{tools: []}) do
        :ok ->
          case config.resource_owner.meta(owner) do
            {:ok, meta} ->
              reduce_backend_meta(meta)

            {:error, _reason} ->
              {:error, :start_failed}

            _other ->
              {:error, :start_failed}
          end

        {:error, _reason} ->
          {:error, :start_failed}

        _other ->
          {:error, :start_failed}
      end
    catch
      _kind, _reason ->
        {:error, :start_failed}
    end
  end

  defp reduce_backend_meta(%{backend: backend, mode: mode})
       when is_atom(backend) and not is_nil(backend) and mode in [:cloud, :local] do
    {:ok, backend, mode}
  end

  defp reduce_backend_meta(_), do: {:error, :start_failed}

  defp settle_release(settlement, config) do
    now_ms =
      case read_monotonic_ms(config.monotonic_clock) do
        {:ok, ms} ->
          ms

        {:error, _reason} ->
          # No system-clock fallback (epochs may differ). Pre-registration
          # unwind is always release_pending, so the retained construction
          # start_ms is a safe integer for Settlement.settle/2.
          settlement.start_ms
      end

    try do
      Settlement.settle(settlement, now_ms)
    catch
      _kind, _reason ->
        # Last resort: release the exact reservation directly so budget cannot
        # leak if Settlement itself raises.
        safe_ledger_release(config, settlement.reservation)
    end
  end

  defp safe_ledger_release(config, reservation) do
    try do
      config.ledger.release(reservation, config.ledger_opts)
    catch
      _kind, _reason -> :error
    end
  end

  # Injected monotonic clocks must return an integer. Never fall back to
  # System.monotonic_time — fake and system epochs can differ and silently
  # clamp elapsed to a full reservation charge.
  defp read_monotonic_ms(clock) when is_function(clock, 0) do
    try do
      case clock.() do
        ms when is_integer(ms) -> {:ok, ms}
        _other -> {:error, :invalid_clock}
      end
    catch
      _kind, _reason ->
        {:error, :invalid_clock}
    end
  end

  defp read_monotonic_ms(_), do: {:error, :invalid_clock}

  # ---------------------------------------------------------------------------
  # Call handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call(:status, _from, %{lifecycle: :ready} = state) do
    {:reply, {:ok, redacted_status(state)}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, {:error, :not_found}, state}
  end

  def handle_call(:stop, _from, %{lifecycle: :ready, closing: false} = state) do
    state = reply_turn_caller(state, {:error, :session_stopped})
    state = %{state | closing: true}
    state = cancel_hard_timer(state)
    {state, _settled?} = settle_and_close(state, :stop)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:stop, _from, state) do
    {:reply, {:error, :not_found}, state}
  end

  def handle_call({:text_turn, user_text}, from, %{lifecycle: :ready, closing: false} = state)
      when is_binary(user_text) do
    cond do
      match?(%{}, state.turn) ->
        {:reply, {:error, :busy}, state}

      true ->
        case begin_text_turn(state, from, user_text) do
          {:ok, next_state} ->
            # Poll asynchronously so stop / hard timeout remain serviceable.
            {:noreply, next_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:text_turn, _user_text}, _from, state) do
    {:reply, {:error, :not_found}, state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported}, state}
  end

  # ---------------------------------------------------------------------------
  # Hard timeout + turn polling
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:hard_timeout, %{lifecycle: :ready, closing: false} = state) do
    state = reply_turn_caller(state, {:error, :budget_exhausted})
    state = %{state | closing: true, timer_ref: nil}
    {state, _settled?} = settle_and_close(state, :budget_exhausted)
    {:stop, :normal, state}
  end

  def handle_info(:hard_timeout, state), do: {:noreply, state}

  def handle_info({:turn_poll, generation}, %{lifecycle: :ready, closing: false} = state) do
    case state.turn do
      %{generation: ^generation} = turn ->
        {:noreply, poll_turn(state, turn)}

      _stale_or_absent ->
        {:noreply, state}
    end
  end

  def handle_info({:turn_poll, _generation}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Text turn — intake in handle_call, poll in handle_info
  # ---------------------------------------------------------------------------

  defp begin_text_turn(state, from, user_text) do
    with {:ok, wall} <- read_wall_clock_utc(state.wall_clock),
         {:ok, started_ms} <- read_monotonic_ms(state.monotonic_clock) do
      user_message =
        user_text
        |> UserMessage.from_voice(sent_at: wall, sender_id: state.user_id)
        |> UserMessage.with_engagement(state.engagement_id)

      case safe_send_text(state, user_text) do
        :ok ->
          generation = state.turn_generation + 1

          turn = %{
            generation: generation,
            from: from,
            user_message: user_message,
            core: TurnCore.new(),
            started_ms: started_ms
          }

          next = %{state | turn: turn, turn_generation: generation}
          _ = Process.send(self(), {:turn_poll, generation}, [])
          {:ok, next}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_clock} ->
        {:error, :turn_failed}
    end
  end

  defp safe_send_text(state, user_text) do
    try do
      case state.resource_owner.send_text(state.owner, user_text) do
        :ok -> :ok
        {:error, _reason} -> {:error, :turn_failed}
        _other -> {:error, :turn_failed}
      end
    catch
      _kind, _reason ->
        {:error, :turn_failed}
    end
  end

  defp poll_turn(state, turn) do
    case safe_recv(state) do
      {:ok, event} ->
        apply_turn_event(state, turn, event)

      {:error, :timeout} ->
        # Normal empty window — schedule another poll without ending the turn.
        enqueue_poll(state, turn.generation)

      {:error, _reason} ->
        finish_turn_error(state, turn, :turn_failed)
    end
  end

  defp safe_recv(state) do
    window_ms = state.poll_window_ms

    try do
      case state.resource_owner.recv(state.owner, window_ms) do
        {:ok, event} -> {:ok, event}
        {:error, :timeout} -> {:error, :timeout}
        {:error, _reason} -> {:error, :turn_failed}
        _other -> {:error, :turn_failed}
      end
    catch
      _kind, _reason ->
        {:error, :turn_failed}
    end
  end

  # Packet ceiling is 100 ms; never request more than the owner's configured
  # max_recv_timeout_ms (ResourceOwner rejects oversized recv with :invalid_timeout).
  defp derive_poll_window_ms(resource_owner_opts) when is_list(resource_owner_opts) do
    owner_cap =
      case Keyword.get(resource_owner_opts, :max_recv_timeout_ms) do
        ms when is_integer(ms) and ms > 0 -> ms
        _ -> @default_owner_max_recv_ms
      end

    min(@max_poll_window_ms, owner_cap)
  end

  defp derive_poll_window_ms(_), do: @max_poll_window_ms

  defp apply_turn_event(state, turn, event) do
    case TurnCore.reduce(turn.core, event) do
      {:continue, core} ->
        next_turn = %{turn | core: core}
        enqueue_poll(%{state | turn: next_turn}, turn.generation)

      {:done, raw_text} ->
        complete_turn(state, turn, raw_text)

      {:reject_tool, core, call_id} ->
        next_turn = %{turn | core: core}
        next_state = %{state | turn: next_turn}

        case safe_send_tool_result(next_state, call_id, TurnCore.no_tools_installed_output()) do
          :ok ->
            enqueue_poll(next_state, turn.generation)

          {:error, _reason} ->
            finish_turn_error(next_state, next_turn, :turn_failed)
        end

      {:error, :protocol_error} ->
        finish_turn_error(state, turn, :turn_failed)
    end
  end

  defp safe_send_tool_result(state, call_id, output) do
    try do
      case state.resource_owner.send_tool_result(state.owner, call_id, output) do
        :ok -> :ok
        {:error, _reason} -> {:error, :turn_failed}
        _other -> {:error, :turn_failed}
      end
    catch
      _kind, _reason ->
        {:error, :turn_failed}
    end
  end

  defp complete_turn(state, turn, raw_text) do
    case record_transcript(state, turn, raw_text) do
      :ok ->
        duration_ms = turn_duration_ms(state, turn)
        safe_emit_turn_completed(state, duration_ms)
        reply_and_clear_turn(state, turn, {:ok, raw_text})

      {:error, :transcript_record_failed} ->
        safe_emit(state, :"transcript.record_failed")
        reply_and_clear_turn(state, turn, {:error, :transcript_record_failed})
    end
  end

  defp record_transcript(state, turn, raw_text) do
    case read_wall_clock_utc(state.wall_clock) do
      {:ok, completed_at} ->
        opts =
          state.transcript_opts
          |> Keyword.put(:comms, state.comms)
          |> Keyword.put(:backend, state.backend)
          |> Keyword.put(:mode, state.mode)

        try do
          case state.transcript_recorder.record(
                 state.agent_id,
                 turn.user_message,
                 raw_text,
                 completed_at,
                 opts
               ) do
            {:ok, _n} -> :ok
            {:error, _reason} -> {:error, :transcript_record_failed}
            _other -> {:error, :transcript_record_failed}
          end
        catch
          _kind, _reason ->
            {:error, :transcript_record_failed}
        end

      {:error, :invalid_clock} ->
        {:error, :transcript_record_failed}
    end
  end

  defp turn_duration_ms(state, turn) do
    case read_monotonic_ms(state.monotonic_clock) do
      {:ok, now_ms} when is_integer(turn.started_ms) and now_ms >= turn.started_ms ->
        now_ms - turn.started_ms

      {:ok, _now_ms} ->
        0

      {:error, _} ->
        0
    end
  end

  defp finish_turn_error(state, turn, reason) do
    reply_and_clear_turn(state, turn, {:error, reason})
  end

  defp reply_and_clear_turn(state, turn, reply) do
    safe_reply(turn.from, reply)
    clear_turn(state)
  end

  # Reply any retained turn caller, then bump generation so stale polls die.
  defp reply_turn_caller(%{turn: %{from: from}} = state, reply) do
    safe_reply(from, reply)
    clear_turn(state)
  end

  defp reply_turn_caller(state, _reply), do: state

  defp clear_turn(state) do
    # Increment generation so any queued {:turn_poll, old} is rejected.
    generation = state.turn_generation + 1
    %{state | turn: nil, turn_generation: generation}
  end

  defp enqueue_poll(state, generation) do
    _ = Process.send(self(), {:turn_poll, generation}, [])
    state
  end

  defp safe_reply(from, reply) do
    try do
      GenServer.reply(from, reply)
    catch
      _kind, _reason -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Close path — exclusive settlement authority
  # ---------------------------------------------------------------------------

  # Normal stop / hard timeout: try direct settle first. On confirmed :done,
  # remove the cleanup then close the owner. On uncertain/failed settle, leave
  # the cleanup installed and close the owner so its bounded replay remains
  # authoritative. Never both remove cleanup and independently release.
  defp settle_and_close(state, signal_type) do
    settle_result =
      case read_monotonic_ms(state.monotonic_clock) do
        {:ok, now_ms} ->
          try do
            Settlement.settle(state.settlement, now_ms)
          catch
            _kind, _reason -> {:error, :uncertain}
          end

        {:error, _reason} ->
          # Clock invalid — do not invent a System epoch. Leave cleanup installed.
          {:error, :invalid_clock}
      end

    case settle_result do
      :ok ->
        # Confirmed done — remove cleanup so owner close does not double-settle.
        # Settlement.settle/2 is idempotent at :done, but exclusive authority
        # still prefers a single path once :done is observed.
        _ = safe_remove_cleanup(state)
        _ = safe_close_owner(state)
        safe_emit(state, signal_type)
        {state, true}

      {:error, _reason} ->
        # Leave cleanup installed; owner close is the sole settlement authority.
        _ = safe_close_owner(state)
        safe_emit(state, signal_type)
        {state, false}
    end
  end

  defp cancel_hard_timer(%{timer_ref: ref} = state) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    # Flush a timer message already in the mailbox so it cannot re-enter.
    receive do
      :hard_timeout -> :ok
    after
      0 -> :ok
    end

    %{state | timer_ref: nil}
  end

  defp cancel_hard_timer(state), do: state

  defp safe_remove_cleanup(state) do
    try do
      state.resource_owner.remove_cleanup(state.owner, @cleanup_key)
    catch
      _kind, _reason -> :error
    end
  end

  defp safe_close_owner(state) do
    safe_close_resource_owner(state.resource_owner, state.owner)
  end

  # Catch-safe owner close used by both ready-path settle_and_close and
  # pre-registration unwind. Never lets close raise/throw/exit skip a
  # subsequent direct settle_release on the pre-registration path.
  defp safe_close_resource_owner(resource_owner, owner) do
    try do
      resource_owner.close(owner)
    catch
      _kind, _reason -> :error
    end
  end

  defp redacted_status(state) do
    %{
      state: :ready,
      user_id: state.user_id,
      agent_id: state.agent_id,
      backend: state.backend,
      mode: state.mode,
      reserved_ms: state.reserved_ms
    }
  end

  # ---------------------------------------------------------------------------
  # Signals — best-effort, never crash a ready/closing session
  # ---------------------------------------------------------------------------

  defp safe_emit(state, type) do
    payload = %{
      user_id: state.user_id,
      agent_id: state.agent_id,
      backend: state.backend,
      mode: state.mode
    }

    # Public Signals shape is emit/4 with a closed opts list.
    try do
      _ = state.signals.emit(:voice, type, payload, [])
      :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp safe_emit_turn_completed(state, duration_ms)
       when is_integer(duration_ms) and duration_ms >= 0 do
    payload = %{
      user_id: state.user_id,
      agent_id: state.agent_id,
      engagement_id: state.engagement_id,
      backend: state.backend,
      mode: state.mode,
      duration_ms: duration_ms
    }

    try do
      _ = state.signals.emit(:voice, :turn_completed, payload, [])
      :ok
    catch
      _kind, _reason -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Status redaction for crash reports
  # ---------------------------------------------------------------------------

  @impl true
  def format_status(status) do
    case status do
      %{state: state} when is_map(state) ->
        %{status | state: redacted_genserver_state(state)}

      other ->
        other
    end
  end

  # Never expose raw transcript, audio, backend events, persistence errors,
  # opaque handles, caller refs, or collaborator closures. Private live turn
  # state may retain a bounded transcript while a turn is in flight.
  defp redacted_genserver_state(state) when is_map(state) do
    %{
      lifecycle: Map.get(state, :lifecycle),
      user_id: Map.get(state, :user_id),
      agent_id: Map.get(state, :agent_id),
      backend: Map.get(state, :backend),
      mode: Map.get(state, :mode),
      reserved_ms: Map.get(state, :reserved_ms),
      closing: Map.get(state, :closing)
    }
  end

  defp redacted_genserver_state(other), do: other

  # Forced Session death must rely solely on ResourceOwner monitor cleanup.
  # Deliberately no terminate/2 settlement or backend close — VOICE-7.
end
