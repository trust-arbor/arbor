defmodule Arbor.Memory.IndexSupervisor do
  @moduledoc """
  Dynamic supervisor for per-agent memory indexes.

  Manages the lifecycle of memory indexes, ensuring each agent gets its own
  isolated index. Indexes are started on demand and can be stopped when
  no longer needed.

  ## Features

  - Per-agent isolation via Registry
  - Dynamic supervision (indexes started/stopped at runtime)
  - Index lookup by agent_id

  ## Examples

      # Start an index for an agent
      {:ok, pid} = Arbor.Memory.IndexSupervisor.start_index("agent_001")

      # Get the index for an agent
      {:ok, pid} = Arbor.Memory.IndexSupervisor.get_index("agent_001")

      # Stop an agent's index
      :ok = Arbor.Memory.IndexSupervisor.stop_index("agent_001")
  """

  use DynamicSupervisor

  alias Arbor.Contracts.Persistence.VectorRecord
  alias Arbor.Memory.IndexProcessEvidence

  require Logger

  @default_timeout_ms 5_000
  @max_timeout_ms 30_000
  @poll_quantum_ms 5

  @type ownership_error ::
          :invalid_agent_id
          | :invalid_options
          | :absence_uncertain
          | :registry_unavailable
          | :supervisor_unavailable
          | :conflict
          | :timeout
          | :outcome_unknown
          | :delete_failed

  @doc """
  Start the IndexSupervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start an index for an agent.

  If an index already exists for this agent, returns the existing pid.

  ## Options

  - `:max_entries` - Max entries before LRU eviction
  - `:threshold` - Default similarity threshold for recall

  ## Examples

      {:ok, pid} = Arbor.Memory.IndexSupervisor.start_index("agent_001")
      {:ok, pid} = Arbor.Memory.IndexSupervisor.start_index("agent_001", max_entries: 5000)
  """
  @spec start_index(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_index(agent_id, opts \\ []) do
    case get_index(agent_id) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          # Stale Registry entry — wait for cleanup and start fresh
          wait_for_registry_cleanup(agent_id)
          do_start_child(agent_id, opts)
        end

      {:error, :not_found} ->
        do_start_child(agent_id, opts)
    end
  end

  defp do_start_child(agent_id, opts) do
    child_spec = {Arbor.Memory.Index, Keyword.put(opts, :agent_id, agent_id)}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.debug("Started memory index for agent #{agent_id}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("Failed to start memory index for agent #{agent_id}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  # Registry monitors processes and removes entries on death, but the
  # DOWN message processing is async. Wait briefly for it to complete.
  defp wait_for_registry_cleanup(agent_id, attempts \\ 5) do
    case Registry.lookup(Arbor.Memory.Registry, {:index, agent_id}) do
      [] ->
        :ok

      [{pid, _}] when attempts > 0 ->
        if Process.alive?(pid) do
          # Process is actually alive, nothing to wait for
          :ok
        else
          Process.sleep(5)
          wait_for_registry_cleanup(agent_id, attempts - 1)
        end

      _ ->
        # Give up waiting — start_child will handle the conflict
        :ok
    end
  end

  @doc """
  Stop an agent's index.

  ## Examples

      :ok = Arbor.Memory.IndexSupervisor.stop_index("agent_001")
  """
  @spec stop_index(String.t()) :: :ok | {:error, :not_found}
  def stop_index(agent_id) do
    case get_index(agent_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        Logger.debug("Stopped memory index for agent #{agent_id}")
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Get the index pid for an agent.

  Returns `{:error, :not_found}` if no index exists for this agent.

  ## Examples

      {:ok, pid} = Arbor.Memory.IndexSupervisor.get_index("agent_001")
      {:error, :not_found} = Arbor.Memory.IndexSupervisor.get_index("unknown_agent")
  """
  @spec get_index(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_index(agent_id) do
    case Registry.lookup(Arbor.Memory.Registry, {:index, agent_id}) do
      [{pid, _}] ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Check if an agent has an active index.

  ## Examples

      true = Arbor.Memory.IndexSupervisor.has_index?("agent_001")
      false = Arbor.Memory.IndexSupervisor.has_index?("unknown_agent")
  """
  @spec has_index?(String.t()) :: boolean()
  def has_index?(agent_id) do
    case get_index(agent_id) do
      {:ok, pid} -> Process.alive?(pid)
      {:error, :not_found} -> false
    end
  end

  @doc """
  List all agent IDs with active indexes.

  ## Examples

      agent_ids = Arbor.Memory.IndexSupervisor.list_agents()
      #=> ["agent_001", "agent_002"]
  """
  @spec list_agents() :: [String.t()]
  def list_agents do
    Registry.select(Arbor.Memory.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(fn
      {:index, _agent_id} -> true
      _ -> false
    end)
    |> Enum.map(fn {:index, agent_id} -> agent_id end)
  end

  @doc """
  Get the count of active indexes.

  ## Examples

      count = Arbor.Memory.IndexSupervisor.count()
      #=> 2
  """
  @spec count() :: non_neg_integer()
  def count do
    DynamicSupervisor.count_children(__MODULE__)[:active]
  end

  @doc """
  Terminate exact-agent Index ownership and prove Registry/supervisor absence.

  Uses one validated Registry inventory snapshot that must form a bijection with
  the complete supervisor live-child set. Target pid is derived only from that
  inventory. Post-termination proof uses a fresh snapshot under one absolute
  deadline. Never inspects survivor child state.

  C3I1B mutation lease/drain is a future caller-owned precondition — this
  primitive does not stop concurrent writers.
  """
  @spec terminate_index_ownership(String.t(), keyword()) :: :ok | {:error, ownership_error()}
  def terminate_index_ownership(agent_id, opts \\ []) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, evidence, deadline} <- normalize_ownership_opts(opts) do
      do_terminate_index_ownership(agent_id, evidence, deadline, _effect_attempted? = false)
    end
  end

  @doc """
  Authoritative Index ownership absence under inventory/supervisor bijection.

  Returns `{:ok, true}` only when the target is missing from a clean inventory
  that exactly equals the supervisor live-child pid set in both directions.
  """
  @spec index_ownership_absent?(String.t(), keyword()) ::
          {:ok, boolean()} | {:error, ownership_error()}
  def index_ownership_absent?(agent_id, opts \\ []) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, evidence, deadline} <- normalize_ownership_opts(opts) do
      do_index_ownership_absent?(agent_id, evidence, deadline)
    end
  end

  # Internal composition seam: preserve an already-minted absolute deadline from
  # Embedding cleanup admission. Not a public opts key — rejects far-future
  # deadlines that would bypass the 30s ceiling; expired deadlines time out.
  @doc false
  @spec terminate_index_ownership_until(String.t(), keyword(), integer()) ::
          :ok | {:error, ownership_error()}
  def terminate_index_ownership_until(agent_id, opts, deadline_ms) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, evidence} <- normalize_until_opts(opts),
         :ok <- admit_deadline(deadline_ms) do
      do_terminate_index_ownership(agent_id, evidence, deadline_ms, _effect_attempted? = false)
    end
  end

  @doc false
  @spec index_ownership_absent_until?(String.t(), keyword(), integer()) ::
          {:ok, boolean()} | {:error, ownership_error()}
  def index_ownership_absent_until?(agent_id, opts, deadline_ms) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, evidence} <- normalize_until_opts(opts),
         :ok <- admit_deadline(deadline_ms) do
      do_index_ownership_absent?(agent_id, evidence, deadline_ms)
    end
  end

  defp do_terminate_index_ownership(agent_id, evidence, deadline, effect_attempted?) do
    remaining = remaining_ms(deadline)

    if remaining <= 0 do
      if effect_attempted?, do: {:error, :outcome_unknown}, else: {:error, :timeout}
    else
      case clean_snapshot(evidence, deadline) do
        {:ok, inventory} ->
          case Map.fetch(inventory, agent_id) do
            :error ->
              :ok

            {:ok, pid} when is_pid(pid) ->
              terminate_and_prove(agent_id, evidence, deadline, pid)

            _malformed ->
              map_snapshot_error(:conflict, effect_attempted?)
          end

        {:error, reason} ->
          map_snapshot_error(reason, effect_attempted?)
      end
    end
  rescue
    _ -> map_snapshot_error(:absence_uncertain, effect_attempted?)
  catch
    _, _ -> map_snapshot_error(:absence_uncertain, effect_attempted?)
  end

  defp terminate_and_prove(agent_id, evidence, deadline, pid) do
    remaining = remaining_ms(deadline)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case normalize_terminate_result(safe_terminate_child(evidence, pid, remaining)) do
        :ok ->
          prove_after_effect(agent_id, evidence, deadline)

        {:error, :not_found} ->
          prove_after_effect(agent_id, evidence, deadline)

        {:error, :timeout} ->
          {:error, :outcome_unknown}

        {:error, :exit} ->
          {:error, :outcome_unknown}

        {:error, :failed} ->
          {:error, :outcome_unknown}
      end
    end
  end

  defp safe_terminate_child(evidence, pid, remaining) do
    evidence.terminate_child(pid, remaining)
  rescue
    _ -> {:error, :failed}
  catch
    :exit, _ -> {:error, :exit}
    _, _ -> {:error, :failed}
  end

  defp prove_after_effect(agent_id, evidence, deadline) do
    case await_absent(agent_id, evidence, deadline) do
      :ok -> :ok
      {:error, :timeout} -> {:error, :outcome_unknown}
      {:error, reason} -> map_snapshot_error(reason, true)
    end
  end

  defp await_absent(agent_id, evidence, deadline) do
    remaining = remaining_ms(deadline)

    cond do
      remaining <= 0 ->
        {:error, :timeout}

      true ->
        case do_index_ownership_absent?(agent_id, evidence, deadline) do
          {:ok, true} ->
            :ok

          {:ok, false} ->
            sleep_budget = min(@poll_quantum_ms, remaining_ms(deadline))
            if sleep_budget > 0, do: Process.sleep(sleep_budget)
            await_absent(agent_id, evidence, deadline)

          {:error, :timeout} ->
            {:error, :timeout}

          {:error, reason} ->
            # Transient unavailability while waiting for DOWN: retry until deadline.
            if retryable_absence_error?(reason) and remaining_ms(deadline) > 0 do
              sleep_budget = min(@poll_quantum_ms, remaining_ms(deadline))
              if sleep_budget > 0, do: Process.sleep(sleep_budget)
              await_absent(agent_id, evidence, deadline)
            else
              {:error, reason}
            end
        end
    end
  end

  # After terminate, Registry DOWN cleanup is async: a just-killed pid may still
  # appear as dead/duplicate-shaped inventory evidence for a few milliseconds.
  # Poll until the absolute deadline rather than failing the first conflict frame.
  defp retryable_absence_error?(reason)
       when reason in [
              :absence_uncertain,
              :registry_unavailable,
              :supervisor_unavailable,
              :conflict
            ],
       do: true

  defp retryable_absence_error?(_), do: false

  defp do_index_ownership_absent?(agent_id, evidence, deadline) do
    remaining = remaining_ms(deadline)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case clean_snapshot(evidence, deadline) do
        {:ok, inventory} ->
          {:ok, not Map.has_key?(inventory, agent_id)}

        {:error, reason} ->
          map_snapshot_error(reason, false)
      end
    end
  rescue
    _ -> {:error, :absence_uncertain}
  catch
    _, _ -> {:error, :absence_uncertain}
  end

  # Recalculate remaining before every wait; never reuse a stale budget slice.
  defp clean_snapshot(evidence, deadline) do
    r1 = remaining_ms(deadline)

    if r1 <= 0 do
      {:error, :timeout}
    else
      case normalize_inventory_result(safe_registry_inventory(evidence, r1)) do
        {:ok, inventory} ->
          r2 = remaining_ms(deadline)

          if r2 <= 0 do
            {:error, :timeout}
          else
            case normalize_supervisor_result(safe_supervisor_live_pids(evidence, r2)) do
              {:ok, supervisor_pids} ->
                case assert_bijection(inventory, supervisor_pids) do
                  :ok -> {:ok, inventory}
                  {:error, reason} -> {:error, reason}
                end

              {:error, reason} ->
                {:error, tag_supervisor_error(reason)}
            end
          end

        {:error, reason} ->
          {:error, tag_registry_error(reason)}
      end
    end
  end

  defp safe_registry_inventory(evidence, remaining) do
    evidence.registry_inventory(remaining)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp safe_supervisor_live_pids(evidence, remaining) do
    evidence.supervisor_live_pids(remaining)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp normalize_inventory_result({:ok, inventory}) when is_map(inventory) do
    admit_inventory_map(inventory)
  end

  defp normalize_inventory_result({:error, reason})
       when reason in [
              :unavailable,
              :timeout,
              :malformed,
              :conflict,
              :dead,
              :duplicate_agent,
              :duplicate_pid
            ],
       do: {:error, reason}

  defp normalize_inventory_result(_), do: {:error, :malformed}

  # Consumer trust boundary: validate every injected inventory key as a valid
  # agent identity and every pid as currently alive before bijection. Production
  # adapters also validate; injected fakes must not establish absence via shape alone.
  defp admit_inventory_map(inventory) do
    Enum.reduce_while(inventory, {:ok, inventory}, fn
      {agent_id, pid}, acc when is_binary(agent_id) and is_pid(pid) ->
        case VectorRecord.validate_identity(agent_id, "legacy", "legacy") do
          {:ok, _} ->
            if Process.alive?(pid) do
              {:cont, acc}
            else
              {:halt, {:error, :dead}}
            end

          {:error, :invalid_vector_identity} ->
            {:halt, {:error, :malformed}}
        end

      _other, _acc ->
        {:halt, {:error, :malformed}}
    end)
  end

  defp normalize_supervisor_result({:ok, %MapSet{} = set}) do
    cond do
      not Enum.all?(set, &is_pid/1) -> {:error, :malformed}
      not Enum.all?(set, &Process.alive?/1) -> {:error, :malformed}
      true -> {:ok, set}
    end
  end

  defp normalize_supervisor_result({:error, reason})
       when reason in [:unavailable, :restarting_present, :timeout, :malformed],
       do: {:error, reason}

  defp normalize_supervisor_result(_), do: {:error, :malformed}

  defp normalize_terminate_result(:ok), do: :ok

  defp normalize_terminate_result({:error, reason})
       when reason in [:timeout, :not_found, :failed, :exit],
       do: {:error, reason}

  defp normalize_terminate_result(_), do: {:error, :failed}

  defp assert_bijection(inventory, supervisor_pids) do
    inventory_pids = MapSet.new(Map.values(inventory))

    if MapSet.equal?(inventory_pids, supervisor_pids) do
      :ok
    else
      {:error, :absence_uncertain}
    end
  end

  defp tag_registry_error(:unavailable), do: :registry_unavailable
  defp tag_registry_error(:timeout), do: :timeout
  defp tag_registry_error(:malformed), do: :conflict
  defp tag_registry_error(:conflict), do: :conflict
  defp tag_registry_error(:dead), do: :conflict
  defp tag_registry_error(:duplicate_agent), do: :conflict
  defp tag_registry_error(:duplicate_pid), do: :conflict
  defp tag_registry_error(other), do: other

  defp tag_supervisor_error(:unavailable), do: :supervisor_unavailable
  defp tag_supervisor_error(:timeout), do: :timeout
  defp tag_supervisor_error(:restarting_present), do: :absence_uncertain
  defp tag_supervisor_error(:malformed), do: :absence_uncertain
  defp tag_supervisor_error(other), do: other

  defp map_snapshot_error(:timeout, true), do: {:error, :outcome_unknown}
  defp map_snapshot_error(:timeout, false), do: {:error, :timeout}
  defp map_snapshot_error(:registry_unavailable, true), do: {:error, :outcome_unknown}
  defp map_snapshot_error(:registry_unavailable, false), do: {:error, :registry_unavailable}
  defp map_snapshot_error(:supervisor_unavailable, true), do: {:error, :outcome_unknown}
  defp map_snapshot_error(:supervisor_unavailable, false), do: {:error, :supervisor_unavailable}
  defp map_snapshot_error(:conflict, _), do: {:error, :conflict}
  defp map_snapshot_error(:absence_uncertain, _), do: {:error, :absence_uncertain}
  defp map_snapshot_error(_reason, true), do: {:error, :outcome_unknown}
  defp map_snapshot_error(_reason, false), do: {:error, :absence_uncertain}

  defp normalize_ownership_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      allowed = [:process_evidence, :timeout_ms]
      keys = Keyword.keys(opts)

      cond do
        keys != Enum.uniq(keys) ->
          {:error, :invalid_options}

        Enum.any?(keys, &(&1 not in allowed)) ->
          {:error, :invalid_options}

        true ->
          with {:ok, evidence} <- resolve_evidence(Keyword.get(opts, :process_evidence)),
               {:ok, timeout_ms} <- resolve_timeout(Keyword.get(opts, :timeout_ms)) do
            {:ok, evidence, absolute_deadline(timeout_ms)}
          end
      end
    else
      {:error, :invalid_options}
    end
  end

  defp normalize_ownership_opts(_opts), do: {:error, :invalid_options}

  # Internal opts for *_until: evidence only. No timeout_ms / deadline_ms keys.
  defp normalize_until_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      allowed = [:process_evidence]
      keys = Keyword.keys(opts)

      cond do
        keys != Enum.uniq(keys) ->
          {:error, :invalid_options}

        Enum.any?(keys, &(&1 not in allowed)) ->
          {:error, :invalid_options}

        true ->
          resolve_evidence(Keyword.get(opts, :process_evidence))
      end
    else
      {:error, :invalid_options}
    end
  end

  defp normalize_until_opts(_opts), do: {:error, :invalid_options}

  # Far-future absolute deadlines bypass the public 30s ceiling → reject.
  # Expired deadlines (deadline <= now) remain valid and immediately time out.
  defp admit_deadline(deadline_ms) when is_integer(deadline_ms) do
    now = System.monotonic_time(:millisecond)

    if deadline_ms > now + @max_timeout_ms do
      {:error, :invalid_options}
    else
      :ok
    end
  end

  defp admit_deadline(_), do: {:error, :invalid_options}

  defp resolve_evidence(nil), do: {:ok, IndexProcessEvidence}

  defp resolve_evidence(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and evidence_callbacks?(module) do
      {:ok, module}
    else
      {:error, :invalid_options}
    end
  end

  defp resolve_evidence(_), do: {:error, :invalid_options}

  defp evidence_callbacks?(module) do
    function_exported?(module, :registry_inventory, 1) and
      function_exported?(module, :supervisor_live_pids, 1) and
      function_exported?(module, :terminate_child, 2)
  end

  defp resolve_timeout(nil), do: {:ok, @default_timeout_ms}

  defp resolve_timeout(timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= @max_timeout_ms,
       do: {:ok, timeout_ms}

  defp resolve_timeout(_), do: {:error, :invalid_options}

  defp absolute_deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp remaining_ms(deadline) do
    max(0, deadline - System.monotonic_time(:millisecond))
  end

  defp validate_agent_id(agent_id) do
    case VectorRecord.validate_identity(agent_id, "legacy", "legacy") do
      {:ok, _identity} -> :ok
      {:error, :invalid_vector_identity} -> {:error, :invalid_agent_id}
    end
  end
end
