defmodule Arbor.Voice.Session do
  @moduledoc false
  # Internal supervised voice session (VP-04D2B + VP-04E1 text turns +
  # VP-04E2 speakable-only output). Not part of the public Arbor.Voice
  # facade — callers use start_session / session_status / stop_session /
  # text_turn with the `{user_id, agent_id}` tuple key only. Never exposes a pid.

  use GenServer

  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Identifiers
  alias Arbor.Voice.EgressAuthority
  alias Arbor.Voice.Redacted
  alias Arbor.Voice.ResourceOwner
  alias Arbor.Voice.Session.ManagedDispatchCore
  alias Arbor.Voice.Session.Settlement
  alias Arbor.Voice.Session.ToolTaskCore
  alias Arbor.Voice.Session.TurnCore
  alias Arbor.Voice.ToolCallOwner

  @cleanup_key :budget_settlement
  @registry Arbor.Voice.Registry
  @owner_death_confirmation_timeout_ms 5_000
  @stop_call_scheduling_margin_ms 5_000
  # Covers the owner's maximum close call, positive death confirmation, and
  # scheduler delay at the public caller boundary.
  @stop_call_timeout_ms ResourceOwner.close_call_timeout_ms() +
                          @owner_death_confirmation_timeout_ms +
                          @stop_call_scheduling_margin_ms
  # Upper bound on backend poll window (packet: no greater than 100 ms).
  @max_poll_window_ms 100
  # Mirror ResourceOwner's default when resource_owner_opts omit the key.
  @default_owner_max_recv_ms 1_000
  # Text turns can run until hard budget; reply path clears the caller.
  @turn_call_timeout_ms :infinity
  # Max bytes of a guarded speakable string offered to speech_output.
  @speech_output_max_bytes 8192
  # Dedicated acceptance-seam Task.Supervisor (VP-04E2R1). Not ResourceCleanup.
  @speech_output_task_supervisor Arbor.Voice.SpeechOutputTaskSupervisor
  # Dedicated tool-call owner Task.Supervisor name (VP-04E3). Not speech/cleanup.
  # Registered via Application Supervisor.child_spec — no wrapper module.
  @tool_task_supervisor Arbor.Voice.ToolTaskSupervisor
  @cleanup_pending_stop_reason {:shutdown, :cleanup_pending}
  # A provisional disclosure closure that neither ResourceOwner nor its lease
  # accepted remains Session-owned. Keep the quarantined Session alive and
  # retry at a bounded cadence instead of making capability TTL the backstop.
  @provisional_cleanup_retry_ms 1_000
  # Deterministic non-sensitive hard-timeout notice (VOICE-24).
  @budget_exhaustion_notice "This voice session has reached its time limit. Continue on your screen."
  # Source-owned progress filler (VP-05B / VOICE-11). Not model-authored.
  @progress_working_cue "I'm still working on that."

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
  @spec stop_call_timeout_ms() :: pos_integer()
  def stop_call_timeout_ms, do: @stop_call_timeout_ms

  @doc false
  @spec stop(pid()) :: :ok | {:error, :not_found | :cleanup_pending}
  def stop(pid) when is_pid(pid) do
    GenServer.call(pid, :stop, @stop_call_timeout_ms)
  catch
    :exit, {{:shutdown, :cleanup_pending}, _call} -> {:error, :cleanup_pending}
    :exit, {:shutdown, :cleanup_pending} -> {:error, :cleanup_pending}
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:normal, _} -> :ok
    :exit, _ -> {:error, :not_found}
  end

  @doc false
  @spec text_turn(pid(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def text_turn(pid, user_text) when is_pid(pid) and is_binary(user_text) do
    GenServer.call(pid, {:text_turn, user_text}, @turn_call_timeout_ms)
  catch
    :exit, {{:shutdown, :cleanup_pending}, _call} -> {:error, :cleanup_pending}
    :exit, {:shutdown, :cleanup_pending} -> {:error, :cleanup_pending}
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
    with {:ok, route_context} <-
           EgressAuthority.resolve_backend_route(config.backend, config.ai_module),
         voice_session_id <- Identifiers.generate_session_id(),
         true <- EgressAuthority.canonical_session_id?(voice_session_id),
         :ok <- EgressAuthority.authenticate_human(route_context, config),
         {:ok, engagement_id} <- resolve_engagement(config) do
      after_engagement(config, engagement_id, route_context, voice_session_id)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :start_failed}
    end
  end

  defp after_engagement(config, engagement_id, route_context, voice_session_id) do
    # Fixed tool authority after engagement is known; raw proof stays
    # inside the closure only (VP-05B/VP-05C). Built before resource/backend effects.
    tool_authority = build_tool_authority(config, engagement_id)

    case reserve_budget(config) do
      {:ok, _reservation, reserved_ms, start_ms, settlement} ->
        after_reservation(
          config,
          engagement_id,
          tool_authority,
          route_context,
          voice_session_id,
          reserved_ms,
          start_ms,
          settlement
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp after_reservation(
         config,
         engagement_id,
         tool_authority,
         route_context,
         voice_session_id,
         reserved_ms,
         start_ms,
         settlement
       ) do
    case EgressAuthority.prepare_session_authority(
           route_context,
           config,
           voice_session_id,
           reserved_ms
         ) do
      {:ok, egress_authority} ->
        handoff = owner_handoff(egress_authority, settlement, config.monotonic_clock)

        case start_resource_owner(config, handoff) do
          {:ok, owner} ->
            owner_ref = Process.monitor(owner)

            after_owner(
              config,
              engagement_id,
              tool_authority,
              voice_session_id,
              egress_authority,
              reserved_ms,
              start_ms,
              settlement,
              owner,
              owner_ref
            )

          {:error, {:handoff_accepted, :start_failed}} ->
            # CleanupLease accepted both route and budget obligations before
            # backend start failed. It is now the sole cleanup authority.
            {:error, :start_failed}

          {:error, reason} ->
            # Handoff was not accepted. Session still owns both provisional
            # obligations and unwinds them directly and idempotently.
            _ =
              egress_authority
              |> EgressAuthority.route_cleanup()
              |> run_fallback_cleanup(3)

            _ = settle_release(settlement, config)
            {:error, reason}
        end

      {:error, reason} ->
        _ = settle_release(settlement, config)
        {:error, reason}
    end
  end

  defp after_owner(
         config,
         engagement_id,
         tool_authority,
         voice_session_id,
         egress_authority,
         reserved_ms,
         start_ms,
         settlement,
         owner,
         owner_ref
       ) do
    case configure_and_read_meta(config, owner) do
      {:ok, backend, mode} ->
        after_backend_ready(
          config,
          engagement_id,
          tool_authority,
          voice_session_id,
          egress_authority,
          reserved_ms,
          start_ms,
          settlement,
          owner,
          owner_ref,
          backend,
          mode
        )

      {:error, reason} ->
        # Initial handoff was accepted before owner startup returned. Owner and
        # CleanupLease exclusively own route and budget cleanup from here.
        _ = startup_owner_unwind(config.resource_owner, owner, owner_ref)
        {:error, reason}
    end
  end

  defp after_backend_ready(
         config,
         engagement_id,
         tool_authority,
         voice_session_id,
         egress_authority,
         reserved_ms,
         _start_ms,
         settlement,
         owner,
         owner_ref,
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
          voice_session_id: voice_session_id,
          engagement_id: engagement_id,
          owner: owner,
          owner_ref: owner_ref,
          # Needed only to mint bounded per-turn authority. Lease-owned route
          # cleanup is never replayed by Session after handoff.
          egress_authority: Redacted.new(egress_authority),
          reserved_ms: reserved_ms,
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
          # Private only — never in status/format_status/signals content.
          speakable: config.speakable,
          speech_output: config.speech_output,
          # Source-owned acceptance bound (1..250 ms); never in public status.
          speech_output_timeout_ms: config.speech_output_timeout_ms,
          # Tool router (VP-04E3/VP-05B): private; never in status/signals.
          tool_router: config.tool_router,
          tool_router_timeout_ms: config.tool_router_timeout_ms,
          tool_declarations: config.tool_declarations,
          progress_threshold_ms: config.progress_threshold_ms,
          # Single live retention path for the redacted proof: closed over
          # inside tool_authority only (never a separate Session field).
          tool_authority: tool_authority,
          # min(100, owner max_recv) so recv never exceeds a tighter owner cap.
          poll_window_ms: derive_poll_window_ms(config.resource_owner_opts),
          turn: nil,
          # A disclosure minted before owner registration/activation failed.
          # Retained only until direct cleanup succeeds or authoritative close
          # transfers it to ResourceOwner.
          provisional_turn_authority: nil,
          provisional_cleanup_retry_ref: nil,
          provisional_cleanup_retry_token: nil,
          turn_generation: 0,
          closing: false
        }

        # Success signals only after every readiness step succeeds.
        safe_emit(state, :start)
        safe_emit(state, :backend_connected)
        {:ok, state}

      {:error, _reason} ->
        _ = Process.cancel_timer(timer_ref)
        # Handoff is already accepted; close is the sole cleanup authority.
        _ = startup_owner_unwind(config.resource_owner, owner, owner_ref)

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

  defp start_resource_owner(config, handoff) do
    try do
      case config.resource_owner.start(
             self(),
             config.backend,
             config.backend_opts,
             handoff,
             config.resource_owner_opts
           ) do
        {:ok, owner} when is_pid(owner) ->
          {:ok, owner}

        {:error, {:handoff_accepted, :start_failed}} = error ->
          error

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

  defp owner_handoff(egress_authority, settlement, monotonic_clock) do
    handoff = EgressAuthority.owner_handoff(egress_authority)
    cleanup = settlement_cleanup(settlement, monotonic_clock)
    %{handoff | initial_cleanups: Map.put(handoff.initial_cleanups, @cleanup_key, cleanup)}
  end

  defp settlement_cleanup(settlement, monotonic_clock) do
    fn ->
      case read_monotonic_ms(monotonic_clock) do
        {:ok, now_ms} ->
          Settlement.settle(settlement, now_ms)

        {:error, _reason} ->
          {:error, :invalid_clock}
      end
    end
  end

  defp configure_and_read_meta(config, owner) do
    tools = Map.get(config, :tool_declarations, [])

    try do
      case config.resource_owner.configure(owner, %{tools: tools}) do
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

  # Fixed tool authority: binds caller, target, engagement, timeout, optional
  # redacted proof, and (when catalog requires it) orchestrator roots + policy
  # factory. Router never sees raw credentials or MFA choice.
  defp build_tool_authority(config, engagement_id) do
    user_id = config.user_id
    agent_id = config.agent_id
    tool_timeout_ms = config.tool_router_timeout_ms
    redacted = config.session_token
    agent_module = config.agent_module
    orchestrator_module = Map.get(config, :orchestrator_module)

    base = %{
      consult_agent: fn message when is_binary(message) ->
        {um, opts} =
          case redacted do
            nil ->
              um =
                message
                |> UserMessage.from_voice(sender_id: user_id)
                |> UserMessage.with_engagement(engagement_id)

              {um, [timeout: tool_timeout_ms]}

            %Redacted{} = r ->
              um = UserMessage.from_voice(message, sender_id: user_id)
              {um, [timeout: tool_timeout_ms, session_token: Redacted.value(r)]}
          end

        agent_module.send_message(user_id, agent_id, um, opts)
      end
    }

    case orchestrator_module do
      nil ->
        base

      orch when is_atom(orch) and not is_nil(orch) ->
        Map.put(base, :dispatch_coding_task, fn task_intent when is_binary(task_intent) ->
          dispatch_coding_task(
            task_intent,
            user_id,
            agent_id,
            agent_module,
            orch,
            redacted
          )
        end)
    end
  end

  defp dispatch_coding_task(
         task_intent,
         user_id,
         agent_id,
         agent_module,
         orchestrator_module,
         redacted
       ) do
    try do
      with {:ok, root} <- first_coding_root(orchestrator_module),
           {:ok, task} <- Arbor.Voice.CodingPlanFactory.build(task_intent, root) do
        agent_opts =
          case redacted do
            nil -> []
            %Redacted{} = r -> [session_token: Redacted.value(r)]
          end

        case agent_module.dispatch_task(user_id, agent_id, task, agent_opts) do
          {:ok, task_id} when is_binary(task_id) -> {:ok, task_id}
          {:error, _} -> {:error, :tool_error}
          _ -> {:error, :tool_error}
        end
      else
        {:error, _} -> {:error, :tool_error}
        _ -> {:error, :tool_error}
      end
    rescue
      _ -> {:error, :tool_error}
    catch
      _, _ -> {:error, :tool_error}
    end
  end

  defp first_coding_root(nil), do: {:error, :roots_unavailable}

  defp first_coding_root(orchestrator_module) when is_atom(orchestrator_module) do
    try do
      case orchestrator_module.coding_repo_roots() do
        {:ok, [root | _]} when is_binary(root) and byte_size(root) > 0 ->
          if String.valid?(root) and Path.type(root) == :absolute and
               not String.match?(root, ~r/[\x00-\x1F\x7F]/) and
               byte_size(root) <= 4096 do
            {:ok, root}
          else
            {:error, :roots_unavailable}
          end

        _ ->
          {:error, :roots_unavailable}
      end
    rescue
      _ -> {:error, :roots_unavailable}
    catch
      _, _ -> {:error, :roots_unavailable}
    end
  end

  defp first_coding_root(_), do: {:error, :roots_unavailable}

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
    turn = state.turn
    state = cancel_pending_tools_with_outputs(state)

    if is_map(turn), do: _ = finalize_turn_authority(state, turn)

    state = state |> Map.put(:closing, true) |> cancel_hard_timer()
    {state, cleanup_result} = settle_and_close(state)

    case cleanup_result do
      :ok ->
        state =
          if is_map(turn) do
            safe_reply(turn.from, {:error, :session_stopped})
            clear_turn(state)
          else
            state
          end

        safe_emit(state, :stop)
        {:stop, :normal, :ok, state}

      {:error, _reason} ->
        if is_map(turn), do: safe_reply(turn.from, {:error, :cleanup_pending})
        {:stop, @cleanup_pending_stop_reason, {:error, :cleanup_pending}, state}
    end
  end

  def handle_call(:stop, _from, state) do
    {:reply, {:error, :not_found}, state}
  end

  def handle_call({:text_turn, user_text}, from, %{lifecycle: :ready, closing: false} = state)
      when is_binary(user_text) do
    # In-flight turn is always a map; nil means idle.
    if is_map(state.turn) do
      {:reply, {:error, :busy}, state}
    else
      case begin_text_turn(state, from, user_text) do
        {:ok, next_state} ->
          # Poll asynchronously so stop / hard timeout remain serviceable.
          {:noreply, next_state}

        {:error, reason, next_state} ->
          {:reply, {:error, reason}, next_state}

        {:fatal, :cleanup_pending, next_state} ->
          if session_owned_provisional_cleanup?(next_state) do
            {:reply, {:error, :cleanup_pending}, schedule_provisional_cleanup_retry(next_state)}
          else
            {:stop, @cleanup_pending_stop_reason, {:error, :cleanup_pending}, next_state}
          end

        {:fatal, reason, next_state} ->
          {:stop, :normal, {:error, reason}, next_state}
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
    turn = state.turn
    state = cancel_pending_tools_with_outputs(state)

    if is_map(turn), do: _ = finalize_turn_authority(state, turn)

    state = %{state | closing: true, timer_ref: nil}
    {state, cleanup_result} = settle_and_close(state)

    case cleanup_result do
      :ok ->
        state =
          if is_map(turn) do
            safe_reply(turn.from, {:error, :budget_exhausted})
            clear_turn(state)
          else
            state
          end

        # Presentation and all observable terminal output happen only after the
        # fence, disclosure revocation, route cleanup, settlement, and close.
        speech_output = offer_speech(state, @budget_exhaustion_notice)
        safe_emit(state, :budget_exhausted, %{speech_output: speech_output})
        {:stop, :normal, state}

      {:error, _reason} ->
        if is_map(turn), do: safe_reply(turn.from, {:error, :cleanup_pending})
        {:stop, @cleanup_pending_stop_reason, state}
    end
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

  def handle_info(
        {:retry_provisional_cleanup, token},
        %{provisional_cleanup_retry_token: token} = state
      )
      when is_reference(token) do
    state = clear_provisional_cleanup_retry(state)

    case ensure_provisional_cleanup_owned(state) do
      {:ok, state} ->
        {state, cleanup_result} = settle_and_close(state)

        case cleanup_result do
          :ok ->
            safe_emit(state, :stop)
            {:stop, :normal, %{state | lifecycle: :closed}}

          {:error, _reason} ->
            state =
              state
              |> Map.put(:lifecycle, :closed)
              |> Map.put(:terminal_stop_reason, @cleanup_pending_stop_reason)

            {:stop, @cleanup_pending_stop_reason, state}
        end

      {:error, state} ->
        {:noreply, schedule_provisional_cleanup_retry(state)}
    end
  end

  def handle_info({:retry_provisional_cleanup, _token}, state), do: {:noreply, state}

  def handle_info(:terminate_after_close, state) do
    {:stop, Map.get(state, :terminal_stop_reason, :normal), state}
  end

  def handle_info(
        {:tool_outcome, generation, call_id, token, output},
        %{lifecycle: :ready, closing: false} = state
      )
      when is_integer(generation) and is_binary(call_id) and is_reference(token) and
             is_binary(output) do
    {:noreply, handle_tool_outcome(state, generation, call_id, token, output)}
  end

  def handle_info({:tool_outcome, _gen, _id, _token, _output}, state), do: {:noreply, state}

  def handle_info(
        {:tool_progress, generation, call_id, token},
        %{lifecycle: :ready, closing: false} = state
      )
      when is_integer(generation) and is_binary(call_id) and is_reference(token) do
    {:noreply, handle_tool_progress(state, generation, call_id, token)}
  end

  def handle_info({:tool_progress, _gen, _id, _token}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, ref, :process, owner, _reason},
        %{owner_ref: ref, owner: owner} = state
      ) do
    state = handle_resource_owner_down(state)

    if session_owned_provisional_cleanup?(state) do
      {:noreply, state}
    else
      {:stop, Map.get(state, :terminal_stop_reason, :normal), state}
    end
  end

  def handle_info(
        {:DOWN, mon, :process, _pid, _reason},
        %{lifecycle: :ready, closing: false} = state
      )
      when is_reference(mon) do
    # Any DOWN still matching pending (including :normal/:shutdown when outcome
    # was lost) settles as tool_failed. Outcome-before-exit ordering means a
    # successful propose clears pending before this DOWN is handled.
    {:noreply, handle_tool_owner_down(state, mon)}
  end

  def handle_info({:DOWN, _mon, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_resource_owner_down(state) do
    turn = state.turn

    state =
      state
      |> cancel_pending_tools_without_outputs()
      |> cancel_hard_timer()
      |> Map.put(:closing, true)

    # Route, settlement, and every registered turn cleanup were lease-owned.
    # Owner DOWN is not positive settlement evidence, so Session never replays
    # them and reports the conservative public result. Only a closure that was
    # never accepted by the owner may still be attempted here.
    state =
      case provisional_turn_cleanup_result(state) do
        {:ok, next_state} -> next_state
        {:error, next_state} -> next_state
      end

    state =
      if is_map(turn) do
        safe_reply(turn.from, {:error, :cleanup_pending})
        clear_turn(state)
      else
        state
      end

    state =
      state
      |> Map.put(:lifecycle, :closed)
      |> Map.put(:terminal_stop_reason, @cleanup_pending_stop_reason)

    if session_owned_provisional_cleanup?(state) do
      schedule_provisional_cleanup_retry(state)
    else
      state
    end
  end

  defp run_fallback_cleanup(nil, _attempts), do: :ok

  defp run_fallback_cleanup(cleanup, attempts)
       when is_function(cleanup, 0) and is_integer(attempts) and attempts > 0 do
    case EgressAuthority.run_cleanup(cleanup) do
      :ok -> :ok
      {:error, _} -> run_fallback_cleanup(cleanup, attempts - 1)
    end
  end

  defp run_fallback_cleanup(_cleanup, _attempts), do: {:error, :cleanup_failed}

  defp provisional_turn_cleanup_result(%{provisional_turn_authority: nil} = state),
    do: {:ok, state}

  defp provisional_turn_cleanup_result(
         %{provisional_turn_authority: %Redacted{} = authority} = state
       ) do
    case Redacted.value(authority) do
      %{ownership: :session, cleanup: cleanup} when is_function(cleanup, 0) ->
        complete_provisional_cleanup(state, cleanup)

      _owner_or_complete ->
        {:ok, state}
    end
  catch
    _, _ -> {:error, state}
  end

  defp provisional_turn_cleanup_result(state), do: {:ok, state}

  # ---------------------------------------------------------------------------
  # Text turn — intake in handle_call, poll in handle_info
  # ---------------------------------------------------------------------------

  defp begin_text_turn(state, from, user_text) do
    with {:ok, wall} <- read_wall_clock_utc(state.wall_clock),
         {:ok, started_ms} <- read_monotonic_ms(state.monotonic_clock),
         {:ok, turn_lease} <- prepare_turn_authority(state) do
      user_message =
        user_text
        |> UserMessage.from_voice(sent_at: wall, sender_id: state.user_id)
        |> UserMessage.with_engagement(state.engagement_id)

      generation = state.turn_generation + 1

      turn = %{
        generation: generation,
        from: from,
        user_message: user_message,
        core: TurnCore.new(),
        started_ms: started_ms,
        turn_id: turn_lease.turn_id,
        # Registration permanently transfers any disclosure cleanup. Session
        # retains only the bounded lease needed for turn identity/fencing.
        lease: Redacted.new(turn_lease),
        # Sole outstanding-tool authority (not TurnCore).
        pending: %{},
        # One-dispatch slot + at most one receipt (VP-05D1 / VOICE-10).
        dispatch: ManagedDispatchCore.new()
      }

      active_state = %{state | turn: turn, turn_generation: generation}

      case safe_send_text(active_state, user_text) do
        :ok ->
          _ = Process.send(self(), {:turn_poll, generation}, [])
          {:ok, active_state}

        {:error, _reason} ->
          {next_state, cleanup_result} = close_failed_turn(active_state, turn, :turn_failed)

          case cleanup_result do
            :ok -> {:fatal, :turn_failed, next_state}
            {:error, _reason} -> {:fatal, :cleanup_pending, next_state}
          end
      end
    else
      {:error, :invalid_clock} ->
        {:error, :turn_failed, state}

      {:error, :turn_failed, :recoverable} ->
        {:error, :turn_failed, state}

      {:error, :turn_failed, {:fatal, provisional_turn_authority}} ->
        {next_state, cleanup_result} =
          close_session_without_turn(state, :turn_failed, provisional_turn_authority)

        case cleanup_result do
          :ok -> {:fatal, :turn_failed, next_state}
          {:error, _reason} -> {:fatal, :cleanup_pending, next_state}
        end

      _ ->
        {:error, :turn_failed, state}
    end
  end

  defp prepare_turn_authority(state) do
    session_authority = Redacted.value(state.egress_authority)
    turn_id = Identifiers.generate_id("turn_")

    case EgressAuthority.issue_turn(session_authority, turn_id) do
      {:ok, turn_authority} ->
        case register_turn_cleanup(state, turn_authority) do
          {:ok, turn_lease} ->
            case safe_activate_turn(state, turn_lease) do
              :ok ->
                {:ok, turn_lease}

              {:error, _reason} ->
                unwind_registered_turn(state, turn_lease)
            end

          {:error, _reason} ->
            unwind_unregistered_turn(state, turn_authority)
        end

      {:error, _reason} ->
        {:error, :turn_failed, :recoverable}
    end
  end

  defp register_turn_cleanup(_state, %{kind: :local} = turn_authority),
    do: {:ok, EgressAuthority.turn_lease(turn_authority)}

  defp register_turn_cleanup(state, %{kind: :external} = turn_authority) do
    key = EgressAuthority.turn_cleanup_key(turn_authority)
    cleanup = EgressAuthority.turn_cleanup(turn_authority)

    try do
      case state.resource_owner.register_cleanup(state.owner, key, cleanup) do
        :ok -> {:ok, EgressAuthority.turn_lease(turn_authority)}
        _ -> {:error, :turn_failed}
      end
    catch
      _, _ -> {:error, :turn_failed}
    end
  end

  defp safe_activate_turn(state, lease) do
    try do
      case state.resource_owner.activate_turn(state.owner, lease) do
        :ok -> :ok
        _ -> {:error, :turn_failed}
      end
    catch
      _, _ -> {:error, :turn_failed}
    end
  end

  defp unwind_registered_turn(state, %{turn_id: turn_id}) do
    # Registration transferred exclusive cleanup ownership. The exact turn
    # barrier fences authority and settles the keyed CleanupLease obligation.
    case safe_fence_and_drain(state, turn_id) do
      :ok -> {:error, :turn_failed, :recoverable}
      {:error, _reason} -> {:error, :turn_failed, {:fatal, nil}}
    end
  end

  defp unwind_unregistered_turn(_state, turn_authority) do
    cleanup_key = EgressAuthority.turn_cleanup_key(turn_authority)
    cleanup = EgressAuthority.turn_cleanup(turn_authority)

    # The owner never accepted this closure. Session may complete it directly;
    # a failed direct attempt is retained for adoption during fatal close.
    case EgressAuthority.run_cleanup(cleanup) do
      :ok ->
        {:error, :turn_failed, :recoverable}

      {:error, _reason} ->
        provisional = %{
          cleanup_key: cleanup_key,
          cleanup: cleanup,
          ownership: :session
        }

        {:error, :turn_failed, {:fatal, Redacted.new(provisional)}}
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
        # Only tool_wave=false terminals reach here. If owners still pending,
        # hold post-tool text until the last settle (not intermediate-wave text).
        if map_size(turn.pending) == 0 do
          complete_turn(state, turn, raw_text)
        else
          next_turn = Map.put(turn, :held_terminal, raw_text)
          enqueue_poll(%{state | turn: next_turn}, turn.generation)
        end

      {:cycle_reset, core} ->
        # Intermediate provider boundary: pre-tool text already cleared in core.
        # Never complete from this event regardless of pending emptiness.
        next_turn = turn |> Map.put(:core, core) |> Map.delete(:held_terminal)
        enqueue_poll(%{state | turn: next_turn}, turn.generation)

      {:admit_tool, core, call} ->
        # A new tool wave invalidates any terminal held from an earlier wave.
        next_turn = turn |> Map.put(:core, core) |> Map.delete(:held_terminal)
        admit_and_route_tool(%{state | turn: next_turn}, next_turn, call)

      {:error, :protocol_error} ->
        finish_turn_error(state, turn, :turn_failed)
    end
  end

  # ---------------------------------------------------------------------------
  # Tool routing (VP-04E3) — Session is sole backend-output authority
  # ---------------------------------------------------------------------------

  defp admit_and_route_tool(state, turn, %{id: call_id, name: name, arguments: args} = call) do
    pending = turn.pending || %{}
    dispatch = Map.get(turn, :dispatch) || ManagedDispatchCore.new()

    case ManagedDispatchCore.reserve_dispatch(dispatch, call) do
      {:reject, next_dispatch, reject_json} ->
        next_turn = %{turn | dispatch: next_dispatch}

        case safe_send_tool_result(state, call_id, reject_json) do
          :ok ->
            enqueue_poll(%{state | turn: next_turn}, turn.generation)

          {:error, _} ->
            finish_turn_error(%{state | turn: next_turn}, next_turn, :turn_failed)
        end

      {:admit, next_dispatch, candidate} ->
        next_turn = %{turn | dispatch: next_dispatch}

        maybe_start_tool_under_capacity(
          %{state | turn: next_turn},
          next_turn,
          call_id,
          name,
          args,
          pending,
          candidate
        )

      {:other, next_dispatch} ->
        next_turn = %{turn | dispatch: next_dispatch}

        maybe_start_tool_under_capacity(
          %{state | turn: next_turn},
          next_turn,
          call_id,
          name,
          args,
          pending,
          nil
        )
    end
  end

  # Shared capacity gate for admitted dispatch candidates and ordinary tools.
  # Over-capacity: sync capacity JSON only (no spawn). Under capacity: start owner
  # (dispatch_candidate is the admit candidate or nil for :other tools).
  defp maybe_start_tool_under_capacity(
         state,
         turn,
         call_id,
         name,
         args,
         pending,
         dispatch_candidate
       ) do
    if map_size(pending) >= ToolTaskCore.max_outstanding() do
      # Mark already applied in core; sync capacity output, no spawn.
      case safe_send_tool_result(
             state,
             call_id,
             ToolTaskCore.normalize(:tool_capacity_exceeded)
           ) do
        :ok ->
          enqueue_poll(state, turn.generation)

        {:error, _} ->
          finish_turn_error(state, turn, :turn_failed)
      end
    else
      start_tool_owner(state, turn, call_id, name, args, pending, dispatch_candidate)
    end
  end

  defp start_tool_owner(state, turn, call_id, name, args, pending, dispatch_candidate) do
    # Pre-create fence token before spawn; activation carries the same token.
    token = make_ref()
    generation = turn.generation
    session_pid = self()

    context = %{
      call_id: call_id,
      name: name,
      arguments: args,
      user_id: state.user_id,
      agent_id: state.agent_id,
      engagement_id: state.engagement_id
    }

    owner_opts = %{
      session_pid: session_pid,
      generation: generation,
      call_id: call_id,
      token: token,
      router: state.tool_router,
      context: context,
      authority: state.tool_authority,
      timeout_ms: state.tool_router_timeout_ms
    }

    case start_tool_owner_child(owner_opts) do
      {:ok, owner_pid} when is_pid(owner_pid) ->
        # Locked order (VP-05B): monitor → progress timer → store pending
        # (timer-bearing fence retained) → activate. No router work starts
        # until activation, so every post-activate DOWN is fenced.
        owner_mon = Process.monitor(owner_pid)

        progress_timer_ref =
          Process.send_after(
            self(),
            {:tool_progress, generation, call_id, token},
            state.progress_threshold_ms
          )

        entry = %{
          token: token,
          owner_pid: owner_pid,
          owner_mon: owner_mon,
          progress_timer_ref: progress_timer_ref,
          progress_emitted: false,
          # Bounded dispatch candidate only; never provider/task-id on turn top-level.
          dispatch_candidate: dispatch_candidate
        }

        next_pending = Map.put(pending, call_id, entry)
        next_turn = %{turn | pending: next_pending}
        next_state = %{state | turn: next_turn}

        if Process.alive?(owner_pid) do
          send(owner_pid, {:activate, token})
          enqueue_poll(next_state, generation)
        else
          # Died before activate; DOWN settles via handle_tool_owner_down.
          enqueue_poll(next_state, generation)
        end

      {:error, _reason} ->
        case safe_send_tool_result(
               state,
               call_id,
               ToolTaskCore.normalize(:router_unavailable)
             ) do
          :ok ->
            enqueue_poll(state, turn.generation)

          {:error, _} ->
            finish_turn_error(state, turn, :turn_failed)
        end
    end
  end

  defp start_tool_owner_child(owner_opts) do
    Task.Supervisor.start_child(@tool_task_supervisor, fn ->
      ToolCallOwner.run(owner_opts)
    end)
  rescue
    _ -> {:error, :router_unavailable}
  catch
    _kind, _reason -> {:error, :router_unavailable}
  end

  defp handle_tool_outcome(state, generation, call_id, token, output) do
    case state.turn do
      %{generation: ^generation, pending: pending} = turn when is_map(pending) ->
        entry = Map.get(pending, call_id)

        case ToolTaskCore.authorize(entry, generation, call_id, token, generation) do
          :settle ->
            settle_tool_output(state, turn, call_id, entry, output)

          :ignore ->
            state
        end

      _ ->
        state
    end
  end

  defp handle_tool_owner_down(state, mon) do
    case state.turn do
      %{generation: generation, pending: pending} = turn when is_map(pending) ->
        case find_pending_by_mon(pending, mon) do
          {call_id, entry} ->
            case ToolTaskCore.authorize_down(entry, mon, generation, generation) do
              :settle ->
                output = ToolTaskCore.normalize(:tool_failed)
                settle_tool_output(state, turn, call_id, entry, output)

              :ignore ->
                state
            end

          nil ->
            state
        end

      _ ->
        state
    end
  end

  defp find_pending_by_mon(pending, mon) do
    Enum.find_value(pending, fn {call_id, entry} ->
      if entry.owner_mon == mon, do: {call_id, entry}, else: nil
    end)
  end

  defp settle_tool_output(state, turn, call_id, entry, output) do
    # Cancel progress timer first, then drop from pending before send so a
    # concurrent DOWN cannot double-settle and progress cannot double-cue.
    _ = cancel_and_flush_progress(entry, turn.generation, call_id)
    _ = Process.demonitor(entry.owner_mon, [:flush])
    pending = Map.delete(turn.pending, call_id)

    # Pure provisional receipt only after the same authorize fence that owns
    # backend output. Commit/expose the receipt only after safe_send_tool_result
    # returns :ok so a delivery failure never leaves durable/public provenance.
    dispatch = Map.get(turn, :dispatch) || ManagedDispatchCore.new()
    candidate = Map.get(entry, :dispatch_candidate)
    provisional_dispatch = ManagedDispatchCore.maybe_receipt(dispatch, candidate, output)

    # Pending cleared; dispatch not yet advanced until delivery succeeds.
    base_turn = %{turn | pending: pending}
    base_state = %{state | turn: base_turn}

    case safe_send_tool_result(base_state, call_id, output) do
      :ok ->
        next_turn = %{base_turn | dispatch: provisional_dispatch}
        next_state = %{base_state | turn: next_turn}
        maybe_complete_after_settle(next_state, next_turn)

      {:error, _} ->
        # No receipt commit: keep pre-settlement dispatch (no new receipt).
        finish_turn_error(base_state, base_turn, :turn_failed)
    end
  end

  defp handle_tool_progress(state, generation, call_id, token) do
    case state.turn do
      %{generation: ^generation, pending: pending} = turn when is_map(pending) ->
        entry = Map.get(pending, call_id)

        case ToolTaskCore.authorize_progress(entry, generation, call_id, token, generation) do
          :emit ->
            # Mark emitted before any speech/signal effects (at-most-once).
            marked = %{entry | progress_emitted: true, progress_timer_ref: nil}
            next_pending = Map.put(pending, call_id, marked)
            next_turn = %{turn | pending: next_pending}
            next_state = %{state | turn: next_turn}

            speech_output = offer_speech(next_state, @progress_working_cue)
            safe_emit_tool_progress(next_state, speech_output)
            next_state

          :ignore ->
            state
        end

      _ ->
        state
    end
  end

  defp cancel_and_flush_progress(entry, generation, call_id)
       when is_map(entry) and is_integer(generation) and is_binary(call_id) do
    token = Map.get(entry, :token)
    ref = Map.get(entry, :progress_timer_ref)

    if is_reference(ref) do
      _ = Process.cancel_timer(ref)
    end

    if is_reference(token) do
      receive do
        {:tool_progress, ^generation, ^call_id, ^token} -> :ok
      after
        0 -> :ok
      end
    end

    :ok
  end

  defp cancel_and_flush_progress(_entry, _generation, _call_id), do: :ok

  defp maybe_complete_after_settle(state, turn) do
    cond do
      map_size(turn.pending) > 0 ->
        enqueue_poll(state, turn.generation)

      is_binary(Map.get(turn, :held_terminal)) and String.trim(turn.held_terminal) != "" ->
        complete_turn(state, turn, turn.held_terminal)

      true ->
        enqueue_poll(state, turn.generation)
    end
  end

  # Synchronous send for turn-path settle (need accept/fail for :turn_failed).
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

  # Nonblocking Session-authorized request (:gen_server.send_request). Does not
  # wait for backend completion; same-sender mailbox order places requests
  # before a subsequent close/1 call.
  defp queue_send_tool_result(state, call_id, output) do
    case state.resource_owner.send_tool_result_request(state.owner, call_id, output) do
      {:ok, _req_id} -> :ok
      {:error, _} -> :error
      _other -> :error
    end
  catch
    _kind, _reason -> :error
  end

  # Kill outstanding tool owners, then queue exactly one cancel tool-result
  # request per admitted pending id before any close. Session is the RO owner.
  defp cancel_pending_tools_with_outputs(state) do
    case state.turn do
      %{pending: pending, generation: generation} = turn
      when is_map(pending) and map_size(pending) > 0 ->
        ids = Map.keys(pending)
        _ = cancel_all_progress_timers(pending, generation)
        _ = cancel_all_siblings(pending)
        _ = queue_cancel_outputs(state, ids)
        %{state | turn: %{turn | pending: %{}}}

      _ ->
        state
    end
  end

  # ResourceOwner death is already the physical no-more-effects barrier, so
  # only terminate local tool workers. No backend output can be queued.
  defp cancel_pending_tools_without_outputs(state) do
    case state.turn do
      %{pending: pending, generation: generation} = turn
      when is_map(pending) and map_size(pending) > 0 ->
        _ = cancel_all_progress_timers(pending, generation)
        _ = cancel_all_siblings(pending)
        %{state | turn: %{turn | pending: %{}}}

      _ ->
        state
    end
  end

  defp cancel_all_progress_timers(pending, generation) when is_map(pending) do
    Enum.each(pending, fn {call_id, entry} ->
      _ = cancel_and_flush_progress(entry, generation, call_id)
    end)

    :ok
  end

  defp queue_cancel_outputs(state, ids) when is_list(ids) do
    cancel_json = ToolTaskCore.normalize(:tool_cancelled)

    Enum.each(ids, fn call_id ->
      # Exactly one attempt per id; never skip remaining ids on failure.
      _ = queue_send_tool_result(state, call_id, cancel_json)
    end)

    :ok
  end

  defp cancel_all_siblings(pending) when is_map(pending) do
    Enum.each(pending, fn {_call_id, entry} ->
      owner_pid = Map.get(entry, :owner_pid)
      owner_mon = Map.get(entry, :owner_mon)

      if is_pid(owner_pid) do
        Process.exit(owner_pid, :kill)
      end

      # Flush so stop/exhaust cancel path owns the attempt, not a late DOWN.
      if is_reference(owner_mon) do
        _ = Process.demonitor(owner_mon, [:flush])
      end
    end)

    :ok
  end

  defp complete_turn(state, turn, raw_text) do
    case finalize_turn_authority(state, turn) do
      :healthy ->
        dispatch = Map.get(turn, :dispatch) || ManagedDispatchCore.new()
        presented = ManagedDispatchCore.select_raw_assistant(dispatch, raw_text)

        case record_transcript(state, turn, presented) do
          :ok ->
            # Speech is presentation only: never rewrite durable/public raw text.
            # Rendering runs only after exact transcript success and never falls
            # back to raw when Speakable/output fails.
            speech_output = offer_speech(state, presented)
            duration_ms = turn_duration_ms(state, turn)
            safe_emit_turn_completed(state, duration_ms, speech_output)
            reply_and_clear_turn(state, turn, {:ok, presented})

          {:error, :transcript_record_failed} ->
            # Recorder failure: no render, no output callback.
            safe_emit(state, :"transcript.record_failed")
            reply_and_clear_turn(state, turn, {:error, :transcript_record_failed})
        end

      :owner_down ->
        handle_resource_owner_down(state)

      _quarantine ->
        {state, cleanup_result} = quarantine_turn(state)

        reply =
          if cleanup_result == :ok,
            do: {:error, :turn_failed},
            else: {:error, :cleanup_pending}

        safe_reply(turn.from, reply)
        state
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

        opts =
          case turn do
            %{dispatch: dispatch} ->
              case ManagedDispatchCore.receipt(dispatch) do
                nil -> opts
                receipt when is_map(receipt) -> Keyword.put(opts, :delegation, receipt)
              end

            _ ->
              opts
          end

        try do
          case state.transcript_recorder.record(
                 state.agent_id,
                 turn.user_message,
                 raw_text,
                 completed_at,
                 opts
               ) do
            # Public contract: {:ok, non_neg_integer()}. Reject malformed success.
            {:ok, n} when is_integer(n) and n >= 0 -> :ok
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

  # ---------------------------------------------------------------------------
  # Speakable-only speech output (VP-04E2 + VP-04E2R1 bounded acceptance)
  # ---------------------------------------------------------------------------

  # Returns :disabled | :accepted | :failed. Never returns content, never
  # falls back to raw text, never raises past this boundary. `:accepted` means
  # the callback returned :ok within the source-owned timeout (enqueue only),
  # not that playback completed.
  defp offer_speech(state, source_text) when is_binary(source_text) do
    case state.speech_output do
      nil ->
        :disabled

      callback when is_function(callback, 1) ->
        render_guard_and_offer(
          state.speakable,
          callback,
          source_text,
          state.speech_output_timeout_ms
        )

      _other ->
        # Defensive: invalid callback shape was rejected at start_session.
        :failed
    end
  end

  defp offer_speech(_state, _source_text), do: :failed

  defp render_guard_and_offer(speakable, callback, source_text, timeout_ms) do
    try do
      verdict = speakable.render(source_text, [])
      guarded = speakable.tts_guard!(verdict)

      case accept_guarded_speech(guarded) do
        {:ok, spoken} ->
          invoke_speech_output(callback, spoken, timeout_ms)

        :error ->
          # Malformed/oversized/blank guard output — do not invoke callback,
          # do not fall back to raw.
          :failed
      end
    rescue
      _ -> :failed
    catch
      :exit, _ -> :failed
      _kind, _reason -> :failed
    end
  end

  # Only a valid UTF-8, nonblank, bounded string may reach speech_output.
  defp accept_guarded_speech(text) when is_binary(text) do
    cond do
      byte_size(text) > @speech_output_max_bytes -> :error
      not String.valid?(text) -> :error
      String.trim(text) == "" -> :error
      true -> {:ok, text}
    end
  end

  defp accept_guarded_speech(_), do: :error

  # Run the acceptance callback under SpeechOutputTaskSupervisor with a hard
  # timeout. Failures (return shape, raise, throw, exit, timeout, supervisor
  # unavailability) collapse to :failed. Session never retains the Task, the
  # spoken text, or any callback error term.
  defp invoke_speech_output(callback, spoken, timeout_ms)
       when is_function(callback, 1) and is_binary(spoken) and is_integer(timeout_ms) and
              timeout_ms > 0 do
    try do
      task =
        Task.Supervisor.async_nolink(@speech_output_task_supervisor, fn ->
          # Catch inside the task so exception text never reaches Task logs,
          # Session state, signals, or public errors.
          try do
            case callback.(spoken) do
              :ok -> :accepted
              {:error, _reason} -> :failed
              _other -> :failed
            end
          rescue
            _ -> :failed
          catch
            :exit, _ -> :failed
            _kind, _reason -> :failed
          end
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, :accepted} -> :accepted
        {:ok, :failed} -> :failed
        {:ok, _other} -> :failed
        {:exit, _reason} -> :failed
        nil -> :failed
      end
    rescue
      # Supervisor unavailable / async_nolink failure — durable success unaffected.
      _ -> :failed
    catch
      _kind, _reason -> :failed
    end
  end

  defp invoke_speech_output(_callback, _spoken, _timeout_ms), do: :failed

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
    # Cancel owners + queue one structured cancellation attempt per still-pending
    # sibling (no admitted id silently dropped). Then reply and clear.
    from = Map.get(turn, :from)
    state = cancel_pending_tools_with_outputs(%{state | turn: turn})

    case finalize_turn_authority(state, turn) do
      :healthy ->
        if from, do: safe_reply(from, {:error, reason})
        clear_turn(state)

      :owner_down ->
        handle_resource_owner_down(state)

      _quarantine ->
        {state, cleanup_result} = quarantine_turn(state)

        reply =
          if cleanup_result == :ok,
            do: {:error, reason},
            else: {:error, :cleanup_pending}

        safe_reply(turn.from, reply)
        state
    end
  end

  defp finalize_turn_authority(state, turn) do
    if resource_owner_down?(state) do
      :owner_down
    else
      case safe_fence_and_drain(state, turn.turn_id) do
        :ok ->
          if resource_owner_down?(state), do: :owner_down, else: :healthy

        {:error, :owner_poisoned} ->
          if resource_owner_down?(state), do: :owner_down, else: :poisoned

        {:error, _reason} ->
          if resource_owner_down?(state), do: :owner_down, else: :fatal
      end
    end
  end

  defp safe_fence_and_drain(state, scope) do
    try do
      case state.resource_owner.fence_and_drain(state.owner, scope) do
        :ok -> :ok
        {:error, :owner_poisoned} -> {:error, :owner_poisoned}
        _ -> {:error, :fence_failed}
      end
    catch
      _, _ -> {:error, :fence_failed}
    end
  end

  defp quarantine_turn(state) do
    state =
      state
      |> Map.put(:closing, true)
      |> cancel_hard_timer()

    {state, cleanup_result} = settle_and_close(state)
    _ = Process.send(self(), :terminate_after_close, [])

    next_state =
      case cleanup_result do
        :ok ->
          safe_emit(state, :stop)

          state
          |> clear_turn()
          |> Map.put(:lifecycle, :closed)

        {:error, _reason} ->
          state
          |> Map.put(:lifecycle, :closed)
          |> Map.put(:terminal_stop_reason, @cleanup_pending_stop_reason)
      end

    {next_state, cleanup_result}
  end

  defp close_failed_turn(state, turn, _reason) do
    _ = finalize_turn_authority(state, turn)
    quarantine_turn(state)
  end

  defp close_session_without_turn(state, _reason, provisional_turn_authority) do
    state =
      state
      |> Map.put(:closing, true)
      |> Map.put(:provisional_turn_authority, provisional_turn_authority)
      |> cancel_hard_timer()

    {state, cleanup_result} = settle_and_close(state)

    next_state =
      case cleanup_result do
        :ok ->
          safe_emit(state, :stop)
          %{state | lifecycle: :closed}

        {:error, _reason} ->
          state
          |> Map.put(:lifecycle, :closed)
          |> Map.put(:terminal_stop_reason, @cleanup_pending_stop_reason)
      end

    {next_state, cleanup_result}
  end

  defp reply_and_clear_turn(state, turn, reply) do
    safe_reply(turn.from, reply)
    clear_turn(state)
  end

  defp clear_turn(state) do
    # Increment generation so any queued {:turn_poll, old} / tool_outcome is rejected.
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

  # Every ready-state obligation was handed to ResourceOwner/CleanupLease.
  # Session may transfer one still-provisional turn closure, then uses only the
  # authority barrier and authoritative close result.
  defp settle_and_close(state) do
    case ensure_provisional_cleanup_owned(state) do
      {:ok, state} ->
        _ = safe_fence_and_drain(state, :session)
        {state, close_owner_authoritatively(state)}

      {:error, state} ->
        {state, {:error, :cleanup_pending}}
    end
  end

  defp ensure_provisional_cleanup_owned(%{provisional_turn_authority: nil} = state),
    do: {:ok, state}

  defp ensure_provisional_cleanup_owned(%{provisional_turn_authority: provisional} = state) do
    case Redacted.value(provisional) do
      %{ownership: :session, cleanup_key: key, cleanup: cleanup}
      when is_function(cleanup, 0) ->
        case safe_register_provisional_cleanup(state, key, cleanup) do
          :ok ->
            {:ok, %{state | provisional_turn_authority: nil}}

          _ ->
            # The configured owner facade provides the reserved emergency
            # handoff when ordinary registration capacity/faults block transfer.
            case safe_adopt_provisional_cleanup(state, key, cleanup) do
              :ok ->
                {:ok, %{state | provisional_turn_authority: nil}}

              _ ->
                complete_provisional_cleanup(state, cleanup)
            end
        end

      _malformed ->
        {:error, state}
    end
  catch
    _, _ -> {:error, state}
  end

  defp safe_register_provisional_cleanup(state, key, cleanup) do
    try do
      state.resource_owner.register_cleanup(state.owner, key, cleanup)
    catch
      _, _ -> {:error, :cleanup_registration_failed}
    end
  end

  defp safe_adopt_provisional_cleanup(state, key, cleanup) do
    try do
      state.resource_owner.adopt_provisional_cleanup(state.owner, key, cleanup)
    catch
      _, _ -> {:error, :cleanup_adoption_failed}
    end
  end

  defp complete_provisional_cleanup(state, cleanup) do
    case run_fallback_cleanup(cleanup, 3) do
      :ok ->
        {:ok, %{state | provisional_turn_authority: nil}}

      {:error, _reason} ->
        {:error, state}
    end
  end

  defp session_owned_provisional_cleanup?(%{
         provisional_turn_authority: %Redacted{} = authority
       }) do
    case Redacted.value(authority) do
      %{ownership: :session, cleanup: cleanup} when is_function(cleanup, 0) -> true
      _other -> false
    end
  catch
    _, _ -> false
  end

  defp session_owned_provisional_cleanup?(_state), do: false

  defp schedule_provisional_cleanup_retry(state) do
    cond do
      not session_owned_provisional_cleanup?(state) ->
        state

      is_reference(Map.get(state, :provisional_cleanup_retry_ref)) ->
        state

      true ->
        token = make_ref()

        ref =
          Process.send_after(
            self(),
            {:retry_provisional_cleanup, token},
            @provisional_cleanup_retry_ms
          )

        state
        |> Map.put(:provisional_cleanup_retry_ref, ref)
        |> Map.put(:provisional_cleanup_retry_token, token)
    end
  end

  defp clear_provisional_cleanup_retry(state) do
    ref = Map.get(state, :provisional_cleanup_retry_ref)
    token = Map.get(state, :provisional_cleanup_retry_token)

    if is_reference(ref), do: Process.cancel_timer(ref)

    if is_reference(token) do
      receive do
        {:retry_provisional_cleanup, ^token} -> :ok
      after
        0 -> :ok
      end
    end

    state
    |> Map.put(:provisional_cleanup_retry_ref, nil)
    |> Map.put(:provisional_cleanup_retry_token, nil)
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

  defp safe_close_resource_owner(resource_owner, owner) do
    try do
      case resource_owner.close(owner) do
        :ok -> :ok
        {:error, _bounded_reason} -> {:error, :cleanup_pending}
        _ -> {:error, :cleanup_pending}
      end
    catch
      _kind, _reason -> {:error, :cleanup_pending}
    end
  end

  defp startup_owner_unwind(resource_owner, owner, owner_ref) do
    close_result = safe_close_resource_owner(resource_owner, owner)

    case {close_result, owner_close_outcome(owner, owner_ref, close_result)} do
      {:ok, :dead} -> :ok
      _pending -> {:error, :cleanup_pending}
    end
  end

  defp close_owner_authoritatively(state) do
    if resource_owner_down?(state) do
      {:error, :cleanup_pending}
    else
      close_result = safe_close_resource_owner(state.resource_owner, state.owner)

      case {close_result, owner_close_outcome(state.owner, state.owner_ref, close_result)} do
        {:ok, :dead} -> :ok
        _pending -> {:error, :cleanup_pending}
      end
    end
  end

  defp resource_owner_down?(%{owner: owner}) when is_pid(owner),
    do: not Process.alive?(owner)

  defp resource_owner_down?(_state), do: true

  defp owner_close_outcome(owner, owner_ref, close_result)
       when is_pid(owner) and is_reference(owner_ref) do
    wait_ms = if close_result == :ok, do: @owner_death_confirmation_timeout_ms, else: 0

    if await_owner_down(owner, owner_ref, wait_ms) do
      :dead
    else
      :pending
    end
  end

  defp owner_close_outcome(_owner, _owner_ref, _close_result), do: :pending

  defp await_owner_down(owner, owner_ref, wait_ms) do
    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        true
    after
      wait_ms ->
        if Process.alive?(owner) do
          false
        else
          _ = Process.demonitor(owner_ref, [:flush])
          true
        end
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

  defp safe_emit(state, type, extra_payload \\ %{})

  defp safe_emit(state, type, extra_payload) when is_map(extra_payload) do
    payload =
      %{
        user_id: state.user_id,
        agent_id: state.agent_id,
        backend: state.backend,
        mode: state.mode
      }
      |> Map.merge(bounded_extra_payload(extra_payload))

    # Public Signals shape is emit/4 with a closed opts list.
    try do
      _ = state.signals.emit(:voice, type, payload, [])
      :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp safe_emit_turn_completed(state, duration_ms, speech_output)
       when is_integer(duration_ms) and duration_ms >= 0 and
              speech_output in [:disabled, :accepted, :failed] do
    payload = %{
      user_id: state.user_id,
      agent_id: state.agent_id,
      engagement_id: state.engagement_id,
      backend: state.backend,
      mode: state.mode,
      duration_ms: duration_ms,
      speech_output: speech_output
    }

    try do
      _ = state.signals.emit(:voice, :turn_completed, payload, [])
      :ok
    catch
      _kind, _reason -> :ok
    end
  end

  # Bounded progress cue signal (VP-05B / VOICE-11). Never includes tool name,
  # arguments, call_id, reply, proof, callbacks, pids, refs, or errors.
  defp safe_emit_tool_progress(state, speech_output)
       when speech_output in [:disabled, :accepted, :failed] do
    payload = %{
      user_id: state.user_id,
      agent_id: state.agent_id,
      engagement_id: state.engagement_id,
      backend: state.backend,
      mode: state.mode,
      cue: :working,
      speech_output: speech_output
    }

    try do
      _ = state.signals.emit(:voice, :tool_progress, payload, [])
      :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp safe_emit_tool_progress(_state, _speech_output), do: :ok

  # Only admit the closed speech_output disposition into audit payloads.
  # Never forward content, modules, functions, verdicts, or error terms.
  defp bounded_extra_payload(extra) when is_map(extra) do
    case Map.get(extra, :speech_output) do
      disposition when disposition in [:disabled, :accepted, :failed] ->
        %{speech_output: disposition}

      _ ->
        %{}
    end
  end

  defp bounded_extra_payload(_), do: %{}

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

  # Crash/status output is a closed whitelist only. Live turn fields (caller
  # `from`, engagement-tagged `user_message`, TurnCore text accumulator,
  # lease/capability ids, cleanup closures, tool-id set, pending tool
  # owners/tokens, and owner handles), Speakable module, speech_output callback,
  # tool_router, and any presentation errors stay private — never included here.
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
