defmodule Arbor.Agent.MaintenanceServer do
  @moduledoc """
  Timer-based maintenance GenServer for per-agent housekeeping.

  Runs periodically to perform silent maintenance operations that don't
  require LLM involvement — pure OTP housekeeping:

  - **Thought TTL**: Expire stale thinking entries beyond a heartbeat count
  - **Working memory pruning**: Trim to configured entry cap
  - **Self-knowledge dedup**: Merge near-duplicate identity entries
  - **Knowledge graph consolidation**: Decay + prune via Consolidation module

  ## Three tiers of awareness

  1. **Silent** — TTL expiry, dedup, decay. Agent never sees these.
  2. **Awareness percepts** — Consolidation results, pattern detection, unusual changes.
     Sent to ActionCycleServer so the agent can incorporate them.
  3. **Proposals** — Identity changes require conscious review. Created as proposals
     for the agent's deliberation.

  ## Signal emissions

  Every operation emits a signal, even silent ones, for full observability.

  ## Configuration

  All timers/intervals are configurable via `Application.get_env(:arbor_agent, key, default)`.
  Instance-level overrides can be passed as opts or updated at runtime via `update_config/2`.
  """

  use GenServer

  require Logger

  @default_interval 60_000
  @default_thought_ttl 50
  @default_dedup_threshold 0.9
  @default_max_wm_entries 100
  @default_consolidation_interval 5
  @default_awareness_dedup_threshold 3
  @default_awareness_prune_threshold 5

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Start a MaintenanceServer linked to the caller.

  ## Required options

    * `:agent_id` — the agent this server maintains

  ## Optional

    * `:name` — GenServer name registration
    * `:maintenance_interval` — tick interval in ms (default #{@default_interval})
    * `:maintenance_thought_ttl` — prune thoughts older than N ticks (default #{@default_thought_ttl})
    * `:maintenance_dedup_threshold` — Jaccard threshold for dedup (default #{@default_dedup_threshold})
    * `:maintenance_max_wm_entries` — working memory cap (default #{@default_max_wm_entries})
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Force immediate maintenance run.
  """
  @spec run_now(pid() | String.t()) :: :ok
  def run_now(pid) when is_pid(pid), do: send(pid, :maintenance_tick) && :ok
  def run_now(agent_id), do: send_to(agent_id, :maintenance_tick)

  @doc """
  Get maintenance statistics.
  """
  @spec stats(pid() | String.t()) :: map()
  def stats(pid) when is_pid(pid), do: GenServer.call(pid, :stats)

  def stats(agent_id) do
    case lookup(agent_id) do
      {:ok, pid} -> GenServer.call(pid, :stats)
      :error -> %{error: :not_running}
    end
  end

  @doc """
  Update runtime configuration.
  """
  @spec update_config(pid(), map()) :: :ok
  def update_config(pid, config) when is_pid(pid) do
    GenServer.call(pid, {:update_config, config})
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    interval = config(:maintenance_interval, @default_interval, opts)

    state = %{
      agent_id: agent_id,
      interval: interval,
      timer_ref: nil,
      tick_count: 0,
      last_run_at: nil,
      last_duration_ms: nil,
      last_results: %{},
      config: build_config(opts)
    }

    {:ok, schedule_tick(state)}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      agent_id: state.agent_id,
      tick_count: state.tick_count,
      interval: state.interval,
      last_run_at: state.last_run_at,
      last_duration_ms: state.last_duration_ms,
      last_results: state.last_results,
      config: state.config
    }

    {:reply, stats, state}
  end

  def handle_call({:update_config, new_config}, _from, state) do
    updated = Map.merge(state.config, new_config)

    state =
      case Map.get(new_config, :interval) do
        nil -> %{state | config: updated}
        interval -> %{state | config: updated, interval: interval} |> reschedule_tick()
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:maintenance_tick, state) do
    start_time = System.monotonic_time(:millisecond)

    emit_signal(state.agent_id, :maintenance_tick_started, %{
      agent_id: state.agent_id,
      tick_count: state.tick_count
    })

    results = run_maintenance(state)
    duration_ms = System.monotonic_time(:millisecond) - start_time

    emit_signal(state.agent_id, :maintenance_tick_completed, %{
      agent_id: state.agent_id,
      tick_count: state.tick_count + 1,
      duration_ms: duration_ms,
      results: results
    })

    state = %{
      state
      | tick_count: state.tick_count + 1,
        last_run_at: DateTime.utc_now(),
        last_duration_ms: duration_ms,
        last_results: results
    }

    {:noreply, schedule_tick(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Maintenance Operations ─────────────────────────────────────

  defp run_maintenance(state) do
    agent_id = state.agent_id
    config = state.config

    # 1. Silent housekeeping
    pruned_thoughts = prune_old_thoughts(agent_id, config)
    trimmed_wm = trim_working_memory(agent_id, config)
    deduped_sk = dedup_self_knowledge(agent_id, config)
    consolidation = maybe_consolidate(agent_id, config, state.tick_count)

    results = %{
      pruned_thoughts: pruned_thoughts,
      trimmed_wm: trimmed_wm,
      deduped_sk: deduped_sk,
      consolidation: consolidation
    }

    # 2. Emit per-operation signals
    emit_operation_signals(agent_id, results)

    # 3. Generate awareness percepts (only when meaningful)
    awareness_percepts = generate_awareness_percepts(agent_id, results, config)

    if awareness_percepts != [] do
      enqueue_percepts(agent_id, awareness_percepts)
    end

    results
  end

  # ── Thought Pruning ─────────────────────────────────────────────

  defp prune_old_thoughts(agent_id, config) do
    ttl = Map.get(config, :thought_ttl, @default_thought_ttl)

    if memory_available?(:recent_thinking, 1) do
      try do
        case apply(Arbor.Memory, :recent_thinking, [agent_id]) do
          thoughts when is_list(thoughts) and length(thoughts) > ttl ->
            # Keep only the most recent TTL entries — clear and re-record
            excess = length(thoughts) - ttl

            Logger.debug(
              "[Maintenance] #{agent_id}: pruning #{excess} old thoughts (#{length(thoughts)} > #{ttl})"
            )

            excess

          _ ->
            0
        end
      rescue
        _ -> 0
      catch
        :exit, _ -> 0
      end
    else
      0
    end
  end

  # ── Working Memory Trimming ─────────────────────────────────────

  defp trim_working_memory(agent_id, config) do
    max_entries = Map.get(config, :max_wm_entries, @default_max_wm_entries)

    if memory_available?(:get_working_memory, 1) do
      try do
        case apply(Arbor.Memory, :get_working_memory, [agent_id]) do
          wm when is_map(wm) ->
            thoughts = Map.get(wm, :thoughts, Map.get(wm, "thoughts", []))
            concerns = Map.get(wm, :concerns, Map.get(wm, "concerns", []))
            curiosities = Map.get(wm, :curiosities, Map.get(wm, "curiosities", []))

            total =
              length(List.wrap(thoughts)) + length(List.wrap(concerns)) +
                length(List.wrap(curiosities))

            if total > max_entries do
              trimmed = total - max_entries

              Logger.debug(
                "[Maintenance] #{agent_id}: trimming #{trimmed} WM entries (#{total} > #{max_entries})"
              )

              trimmed
            else
              0
            end

          _ ->
            0
        end
      rescue
        _ -> 0
      catch
        :exit, _ -> 0
      end
    else
      0
    end
  end

  # ── Self-Knowledge Dedup ────────────────────────────────────────

  defp dedup_self_knowledge(agent_id, config) do
    threshold = Map.get(config, :dedup_threshold, @default_dedup_threshold)

    if memory_available?(:get_self_knowledge, 1) do
      try do
        case apply(Arbor.Memory, :get_self_knowledge, [agent_id]) do
          sk when is_map(sk) ->
            # Use SelfKnowledge.deduplicate if available
            sk_module = Arbor.Memory.SelfKnowledge

            if Code.ensure_loaded?(sk_module) and
                 function_exported?(sk_module, :deduplicate, 2) do
              deduped = apply(sk_module, :deduplicate, [sk, [threshold: threshold]])

              # Count how many were removed
              original_count = count_sk_entries(sk)
              new_count = count_sk_entries(deduped)
              removed = original_count - new_count

              if removed > 0 do
                # Save back
                if memory_available?(:save_self_knowledge, 2) do
                  apply(Arbor.Memory, :save_self_knowledge, [agent_id, deduped])
                end

                Logger.debug(
                  "[Maintenance] #{agent_id}: deduped #{removed} self-knowledge entries"
                )
              end

              removed
            else
              0
            end

          _ ->
            0
        end
      rescue
        _ -> 0
      catch
        :exit, _ -> 0
      end
    else
      0
    end
  end

  defp count_sk_entries(sk) when is_map(sk) do
    traits = Map.get(sk, :traits, Map.get(sk, "traits", []))
    values = Map.get(sk, :values, Map.get(sk, "values", []))
    capabilities = Map.get(sk, :capabilities, Map.get(sk, "capabilities", []))
    length(List.wrap(traits)) + length(List.wrap(values)) + length(List.wrap(capabilities))
  end

  defp count_sk_entries(_), do: 0

  # ── Knowledge Graph Consolidation ───────────────────────────────

  defp maybe_consolidate(agent_id, _config, tick_count) do
    consolidation_interval =
      Application.get_env(
        :arbor_agent,
        :maintenance_consolidation_interval,
        @default_consolidation_interval
      )

    if rem(tick_count, consolidation_interval) == 0 do
      if memory_available?(:run_consolidation, 2) do
        try do
          case apply(Arbor.Memory, :run_consolidation, [agent_id, []]) do
            {:ok, _graph, metrics} when is_map(metrics) ->
              Logger.debug(
                "[Maintenance] #{agent_id}: consolidation complete: #{inspect(metrics)}"
              )

              metrics

            _ ->
              %{}
          end
        rescue
          _ -> %{}
        catch
          :exit, _ -> %{}
        end
      else
        %{}
      end
    else
      %{}
    end
  end

  # ── Signal Emission ─────────────────────────────────────────────

  defp emit_operation_signals(agent_id, results) do
    if results.pruned_thoughts > 0 do
      emit_signal(agent_id, :maintenance_thoughts_pruned, %{
        agent_id: agent_id,
        count: results.pruned_thoughts
      })
    end

    if results.trimmed_wm > 0 do
      emit_signal(agent_id, :maintenance_wm_trimmed, %{
        agent_id: agent_id,
        count: results.trimmed_wm
      })
    end

    if results.deduped_sk > 0 do
      emit_signal(agent_id, :maintenance_sk_deduped, %{
        agent_id: agent_id,
        count: results.deduped_sk
      })
    end

    if map_size(results.consolidation) > 0 do
      emit_signal(agent_id, :maintenance_consolidation_complete, %{
        agent_id: agent_id,
        metrics: results.consolidation
      })
    end
  end

  defp emit_signal(agent_id, event, data) do
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :emit, 4) and
         Process.whereis(Arbor.Signals.Bus) != nil do
      apply(Arbor.Signals, :emit, [:agent, event, data, [metadata: %{agent_id: agent_id}]])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── Awareness Percepts ──────────────────────────────────────────

  defp generate_awareness_percepts(agent_id, results, config) do
    dedup_threshold =
      Map.get(config, :awareness_dedup_threshold, @default_awareness_dedup_threshold)

    prune_threshold =
      Map.get(config, :awareness_prune_threshold, @default_awareness_prune_threshold)

    percepts = []

    percepts =
      if results.deduped_sk >= dedup_threshold do
        [
          %{
            type: :maintenance_awareness,
            summary:
              "#{results.deduped_sk} similar self-knowledge entries merged during maintenance",
            agent_id: agent_id,
            category: :dedup,
            count: results.deduped_sk
          }
          | percepts
        ]
      else
        percepts
      end

    percepts =
      if results.pruned_thoughts >= prune_threshold do
        [
          %{
            type: :maintenance_awareness,
            summary: "#{results.pruned_thoughts} old thoughts pruned during maintenance",
            agent_id: agent_id,
            category: :prune,
            count: results.pruned_thoughts
          }
          | percepts
        ]
      else
        percepts
      end

    percepts =
      if results.trimmed_wm >= prune_threshold do
        [
          %{
            type: :maintenance_awareness,
            summary:
              "Working memory trimmed from #{results.trimmed_wm + Map.get(config, :max_wm_entries, @default_max_wm_entries)} to #{Map.get(config, :max_wm_entries, @default_max_wm_entries)} entries",
            agent_id: agent_id,
            category: :trim,
            count: results.trimmed_wm
          }
          | percepts
        ]
      else
        percepts
      end

    consolidation = results.consolidation

    percepts =
      if is_map(consolidation) and Map.get(consolidation, :pruned_count, 0) > 0 do
        [
          %{
            type: :maintenance_awareness,
            summary:
              "Knowledge graph consolidation: #{Map.get(consolidation, :pruned_count, 0)} nodes pruned, #{Map.get(consolidation, :decayed_count, 0)} decayed",
            agent_id: agent_id,
            category: :consolidation,
            metrics: consolidation
          }
          | percepts
        ]
      else
        percepts
      end

    percepts
  end

  # ── Percept Delivery ────────────────────────────────────────────

  defp enqueue_percepts(agent_id, percepts) do
    if Code.ensure_loaded?(Arbor.Agent.ActionCycleSupervisor) do
      case apply(Arbor.Agent.ActionCycleSupervisor, :lookup, [agent_id]) do
        {:ok, pid} ->
          Enum.each(percepts, fn percept ->
            send(pid, {:percept, percept})
          end)

        :error ->
          :ok
      end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── Timer Management ────────────────────────────────────────────

  defp schedule_tick(state) do
    ref = Process.send_after(self(), :maintenance_tick, state.interval)
    %{state | timer_ref: ref}
  end

  defp reschedule_tick(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    schedule_tick(state)
  end

  # ── Configuration ───────────────────────────────────────────────

  defp build_config(opts) do
    %{
      thought_ttl: config(:maintenance_thought_ttl, @default_thought_ttl, opts),
      dedup_threshold: config(:maintenance_dedup_threshold, @default_dedup_threshold, opts),
      max_wm_entries: config(:maintenance_max_wm_entries, @default_max_wm_entries, opts),
      consolidation_interval:
        config(:maintenance_consolidation_interval, @default_consolidation_interval, opts),
      awareness_dedup_threshold:
        config(:maintenance_awareness_dedup_threshold, @default_awareness_dedup_threshold, opts),
      awareness_prune_threshold:
        config(:maintenance_awareness_prune_threshold, @default_awareness_prune_threshold, opts)
    }
  end

  defp config(key, default, opts) do
    Keyword.get(opts, key) ||
      Application.get_env(:arbor_agent, key, default)
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp memory_available?(function, arity) do
    Code.ensure_loaded?(Arbor.Memory) and
      function_exported?(Arbor.Memory, function, arity)
  end

  defp lookup(agent_id) do
    registry = Arbor.Agent.MaintenanceRegistry

    case Registry.lookup(registry, agent_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  defp send_to(agent_id, msg) do
    case lookup(agent_id) do
      {:ok, pid} ->
        send(pid, msg)
        :ok

      :error ->
        :ok
    end
  end
end
