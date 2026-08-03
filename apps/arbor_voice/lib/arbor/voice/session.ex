defmodule Arbor.Voice.Session do
  @moduledoc false
  # Internal supervised voice session (VP-04D2B). Not part of the public
  # Arbor.Voice facade — callers use start_session/session_status/stop_session
  # with the `{user_id, agent_id}` tuple key only. Never exposes a pid.

  use GenServer

  alias Arbor.Voice.Session.Settlement

  @cleanup_key :budget_settlement
  @registry Arbor.Voice.Registry
  # Must outlive ResourceOwner close (max close timeout + cleanup grace).
  @stop_call_timeout_ms 70_000

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
        # Before cleanup registration succeeds: close owner + settle release
        # directly. Never both after registration.
        _ = config.resource_owner.close(owner)
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
        _ = config.resource_owner.close(owner)
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
          monotonic_clock: config.monotonic_clock,
          closing: false
        }

        # Success signals only after every readiness step succeeds.
        safe_emit(state, :start)
        safe_emit(state, :backend_connected)
        {:ok, state}

      {:error, _reason} ->
        _ = Process.cancel_timer(timer_ref)
        # After registration: close owner only; do not settle independently.
        _ = config.resource_owner.close(owner)
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
    wall = config.wall_clock.()

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
    # Contract: wall clock is UTC. Prefer unix arithmetic so we never depend on
    # tzdata for the Etc/UTC zone database at the session boundary.
    unix_ms = DateTime.to_unix(wall, :millisecond)

    if is_integer(unix_ms) do
      ms_into_day = rem(unix_ms, 86_400_000)
      ms_into_day = if ms_into_day < 0, do: ms_into_day + 86_400_000, else: ms_into_day
      ms_to_midnight = 86_400_000 - ms_into_day

      # Calendar UTC day from the wall DateTime's date component when already UTC;
      # fall back to unix-derived date for non-UTC injects.
      date =
        if wall.time_zone in ["Etc/UTC", "UTC"] do
          DateTime.to_date(wall)
        else
          unix_ms
          |> DateTime.from_unix!(:millisecond)
          |> DateTime.to_date()
        end

      utc_day = Date.to_iso8601(date)

      if ms_to_midnight > 0 do
        {:ok, utc_day, ms_to_midnight}
      else
        # Exactly on a midnight boundary → full next UTC day.
        {:ok, utc_day, 86_400_000}
      end
    else
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
    state = %{state | closing: true}
    state = cancel_hard_timer(state)
    {state, _settled?} = settle_and_close(state, :stop)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:stop, _from, state) do
    {:reply, {:error, :not_found}, state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported}, state}
  end

  # ---------------------------------------------------------------------------
  # Hard timeout
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:hard_timeout, %{lifecycle: :ready, closing: false} = state) do
    state = %{state | closing: true, timer_ref: nil}
    {state, _settled?} = settle_and_close(state, :budget_exhausted)
    {:stop, :normal, state}
  end

  def handle_info(:hard_timeout, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

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
    try do
      state.resource_owner.close(state.owner)
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
