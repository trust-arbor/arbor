defmodule Arbor.Agent.RuntimeAdmission.IntentCore do
  @moduledoc """
  Pure decision core for ordinary runtime-admission intents (Phase 4C C3C1a0).

  No IO, no GenServer, no Process. Shells gather facts and interpret effects.
  """

  @type phase ::
          :admitted
          | :owner_launching
          | :owner_live
          | :worker_running
          | :outcome_unknown
          | :settling
          | :terminal

  @type intent :: %{
          required(:intent_id) => String.t(),
          required(:target_agent_id) => String.t(),
          required(:kind) => :ordinary_start,
          required(:fingerprint) => String.t(),
          required(:phase) => phase(),
          optional(:owner_pid) => pid() | nil,
          optional(:worker_pid) => pid() | nil,
          optional(:terminal) => term()
        }

  @type fence_map :: %{optional(String.t()) => String.t()}
  @type intent_map :: %{optional(String.t()) => intent()}

  @doc """
  Decide ordinary-start admission for one target.

  Effects (as data): `{:launch_owner, intent}` | `:none`
  """
  @spec admit(
          intent_map(),
          fence_map(),
          boolean(),
          boolean(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:ok, :joined, intent(), intent_map(), list()}
          | {:ok, :admitted, intent(), intent_map(), list()}
          | {:error, atom()}
  def admit(
        intents,
        fences,
        fence_ready?,
        admission_ready?,
        target,
        fingerprint,
        intent_id,
        intent_count,
        max_intents
      )
      when is_map(intents) and is_map(fences) and is_binary(target) and is_binary(fingerprint) and
             is_binary(intent_id) and is_integer(intent_count) and is_integer(max_intents) do
    cond do
      fence_ready? != true ->
        {:error, :fence_not_ready}

      admission_ready? != true ->
        {:error, :runtime_admission_not_ready}

      Map.has_key?(fences, target) ->
        {:error, :target_fenced}

      true ->
        case Map.get(intents, target) do
          %{phase: phase, fingerprint: ^fingerprint} = intent
          when phase != :terminal ->
            {:ok, :joined, intent, intents, []}

          %{phase: phase} when phase != :terminal ->
            {:error, :conflict}

          _idle ->
            if intent_count >= max_intents do
              {:error, :busy}
            else
              intent = %{
                intent_id: intent_id,
                target_agent_id: target,
                kind: :ordinary_start,
                fingerprint: fingerprint,
                phase: :admitted,
                owner_pid: nil,
                worker_pid: nil,
                terminal: nil
              }

              new_intents = Map.put(intents, target, intent)
              {:ok, :admitted, intent, new_intents, [{:launch_owner, intent}]}
            end
        end
    end
  end

  @doc "Adopt a live owner into the intent map against current fence/readiness."
  @spec adopt_owner(
          intent_map(),
          fence_map(),
          boolean(),
          boolean(),
          String.t(),
          String.t(),
          String.t(),
          pid()
        ) ::
          {:ok, :adopted, intent(), intent_map()}
          | {:error, atom()}
  def adopt_owner(
        intents,
        fences,
        fence_ready?,
        admission_ready?,
        target,
        intent_id,
        fingerprint,
        owner_pid
      )
      when is_pid(owner_pid) do
    cond do
      admission_ready? != true ->
        {:error, :runtime_admission_not_ready}

      fence_ready? != true ->
        {:error, :fence_not_ready}

      Map.has_key?(fences, target) ->
        {:error, :target_fenced}

      true ->
        case Map.get(intents, target) do
          %{intent_id: ^intent_id, fingerprint: ^fingerprint, phase: phase} = intent
          when phase in [:admitted, :owner_launching, :owner_live, :worker_running, :outcome_unknown] ->
            updated = %{intent | phase: :owner_live, owner_pid: owner_pid}
            {:ok, :adopted, updated, Map.put(intents, target, updated)}

          %{phase: phase} when phase != :terminal ->
            {:error, :conflict}

          nil ->
            intent = %{
              intent_id: intent_id,
              target_agent_id: target,
              kind: :ordinary_start,
              fingerprint: fingerprint,
              phase: :owner_live,
              owner_pid: owner_pid,
              worker_pid: nil,
              terminal: nil
            }

            {:ok, :adopted, intent, Map.put(intents, target, intent)}

          _ ->
            {:error, :conflict}
        end
    end
  end

  @doc """
  Bind an exact worker PID against an adopted intent (owner-authenticated).

  Requires:
  - exact `intent_id` + `fingerprint`
  - phase `:owner_live`
  - `caller_owner_pid == intent.owner_pid` (authenticated IntentOwner only)
  - no other worker bound

  Same owner rebinding the same worker is idempotent. A foreign caller or
  mismatched owner/fingerprint/id → `:not_owner` / `:conflict` / `:not_found`.
  """
  @spec bind_worker(
          intent_map(),
          String.t(),
          String.t(),
          String.t(),
          pid(),
          pid()
        ) ::
          {:ok, intent_map()} | {:error, :not_found | :conflict | :not_owner}
  def bind_worker(intents, target, intent_id, fingerprint, caller_owner_pid, worker_pid)
      when is_binary(intent_id) and is_binary(fingerprint) and is_pid(caller_owner_pid) and
             is_pid(worker_pid) do
    case Map.get(intents, target) do
      %{
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        phase: :owner_live,
        owner_pid: ^caller_owner_pid,
        worker_pid: nil
      } = intent ->
        updated = %{intent | phase: :worker_running, worker_pid: worker_pid}
        {:ok, Map.put(intents, target, updated)}

      %{
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        phase: :worker_running,
        owner_pid: ^caller_owner_pid,
        worker_pid: ^worker_pid
      } ->
        {:ok, intents}

      %{owner_pid: owner_pid} when owner_pid != caller_owner_pid ->
        {:error, :not_owner}

      %{intent_id: ^intent_id} ->
        {:error, :conflict}

      %{phase: _} ->
        {:error, :conflict}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Authenticate the calling process as the bound worker for target+intent+fingerprint.
  """
  @spec authenticate_worker(intent_map(), String.t(), String.t(), String.t(), pid()) ::
          :ok | {:error, :not_found | :not_owner | :conflict}
  def authenticate_worker(intents, target, intent_id, fingerprint, caller_pid)
      when is_binary(intent_id) and is_binary(fingerprint) and is_pid(caller_pid) do
    case Map.get(intents, target) do
      %{
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        phase: :worker_running,
        worker_pid: ^caller_pid
      } ->
        :ok

      %{intent_id: ^intent_id, fingerprint: ^fingerprint, worker_pid: other}
      when is_pid(other) and other != caller_pid ->
        {:error, :not_owner}

      %{intent_id: ^intent_id} ->
        {:error, :conflict}

      %{phase: _} ->
        {:error, :conflict}

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Transition to outcome_unknown (worker death around start)."
  @spec mark_outcome_unknown(intent_map(), String.t()) :: {:ok, intent_map()} | {:error, atom()}
  def mark_outcome_unknown(intents, target) do
    case Map.get(intents, target) do
      %{phase: phase} = intent when phase != :terminal ->
        {:ok, Map.put(intents, target, %{intent | phase: :outcome_unknown, worker_pid: nil})}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Classify unknown-start recovery from a live branch witness fact.

  `witness_fact`: `{:exact, intent_id}` | `:bare` | `{:other, intent_id}` | `:not_running`
  """
  @spec classify_unknown_start(String.t(), :not_running | :bare | {:exact, String.t()} | {:other, String.t()}) ::
          :not_applied | :applied | :conflict
  def classify_unknown_start(_intent_id, :not_running), do: :not_applied
  def classify_unknown_start(intent_id, {:exact, intent_id}), do: :applied
  def classify_unknown_start(_intent_id, :bare), do: :conflict
  def classify_unknown_start(_intent_id, {:other, _}), do: :conflict
  def classify_unknown_start(_intent_id, _), do: :conflict

  @doc "Settle terminal outcome for exact intent_id and drop from the map."
  @spec settle(intent_map(), String.t(), String.t(), term()) ::
          {:ok, intent(), intent_map()} | {:error, :not_found | :conflict}
  def settle(intents, target, intent_id, terminal) when is_binary(intent_id) do
    case Map.get(intents, target) do
      %{intent_id: ^intent_id, phase: phase} = intent when phase != :terminal ->
        done = %{intent | phase: :terminal, terminal: terminal, worker_pid: nil}
        {:ok, done, Map.delete(intents, target)}

      %{intent_id: _other, phase: phase} when phase != :terminal ->
        {:error, :conflict}

      _ ->
        {:error, :not_found}
    end
  end

  # Compatibility for internal callers that already verified intent_id.
  @doc false
  def settle(intents, target, terminal) do
    case Map.get(intents, target) do
      %{intent_id: id} -> settle(intents, target, id, terminal)
      _ -> {:error, :not_found}
    end
  end

  @doc "True when a non-terminal intent exists for the target (barrier non-idle)."
  @spec non_idle?(intent_map(), String.t()) :: boolean()
  def non_idle?(intents, target) do
    case Map.get(intents, target) do
      %{phase: :terminal} -> false
      %{phase: _} -> true
      _ -> false
    end
  end

  # Restart inventory bounds (fail closed on overflow / malformation).
  @max_rebind_snapshots 256
  @max_target_bytes 256
  @max_intent_id_bytes 64
  @max_fingerprint_bytes 80
  @target_re ~r/\Aagent_[A-Za-z0-9_-]+\z/
  @intent_id_re ~r/\Arai_[A-Za-z0-9_-]+\z/
  @fingerprint_re ~r/\Afp_[0-9a-f]+\z/

  @type rebind_error ::
          :invalid_snapshot
          | :duplicate_target
          | :duplicate_intent_id
          | :inventory_overflow
          | :invalid_inventory

  @doc """
  Fail-closed rebind of owner snapshots into an intent map (restart reconcile).

  Returns `{:ok, intents}` only when the entire inventory is bounded and every
  snapshot is fully valid with unique `target_agent_id` and `intent_id`.
  Malformed, conflicting, or oversized inventories return a bounded error —
  callers must keep runtime admission not-ready (never silently skip/overwrite).
  """
  @spec rebind_owners(intent_map(), term()) ::
          {:ok, intent_map()} | {:error, rebind_error()}
  def rebind_owners(base_intents, snapshots)
      when is_map(base_intents) and is_list(snapshots) do
    cond do
      length(snapshots) > @max_rebind_snapshots ->
        {:error, :inventory_overflow}

      base_intents != %{} ->
        # Restart rebind replaces the volatile map from inventory only.
        {:error, :invalid_inventory}

      true ->
        rebind_all(snapshots, %{}, MapSet.new(), MapSet.new())
    end
  end

  def rebind_owners(_base_intents, _snapshots), do: {:error, :invalid_inventory}

  defp rebind_all([], intents, _targets, _ids), do: {:ok, intents}

  defp rebind_all([snap | rest], intents, targets, ids) do
    case validate_snapshot(snap) do
      {:ok, intent} ->
        cond do
          MapSet.member?(targets, intent.target_agent_id) ->
            {:error, :duplicate_target}

          MapSet.member?(ids, intent.intent_id) ->
            {:error, :duplicate_intent_id}

          true ->
            rebind_all(
              rest,
              Map.put(intents, intent.target_agent_id, intent),
              MapSet.put(targets, intent.target_agent_id),
              MapSet.put(ids, intent.intent_id)
            )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_snapshot(snap) when is_map(snap) do
    target = Map.get(snap, :target_agent_id, Map.get(snap, "target_agent_id"))
    intent_id = Map.get(snap, :intent_id, Map.get(snap, "intent_id"))
    fingerprint = Map.get(snap, :fingerprint, Map.get(snap, "fingerprint"))
    owner_pid = Map.get(snap, :owner_pid, Map.get(snap, "owner_pid"))

    with :ok <- validate_target(target),
         :ok <- validate_intent_id(intent_id),
         :ok <- validate_fingerprint(fingerprint),
         :ok <- validate_owner_pid(owner_pid) do
      {:ok,
       %{
         intent_id: intent_id,
         target_agent_id: target,
         kind: :ordinary_start,
         fingerprint: fingerprint,
         phase: :outcome_unknown,
         owner_pid: owner_pid,
         worker_pid: nil,
         terminal: nil
       }}
    end
  end

  defp validate_snapshot(_), do: {:error, :invalid_snapshot}

  defp validate_target(target)
       when is_binary(target) and byte_size(target) <= @max_target_bytes and
              byte_size(target) > 0 do
    if String.valid?(target) and Regex.match?(@target_re, target),
      do: :ok,
      else: {:error, :invalid_snapshot}
  end

  defp validate_target(_), do: {:error, :invalid_snapshot}

  defp validate_intent_id(id)
       when is_binary(id) and byte_size(id) <= @max_intent_id_bytes and byte_size(id) > 0 do
    if String.valid?(id) and Regex.match?(@intent_id_re, id),
      do: :ok,
      else: {:error, :invalid_snapshot}
  end

  defp validate_intent_id(_), do: {:error, :invalid_snapshot}

  defp validate_fingerprint(fp)
       when is_binary(fp) and byte_size(fp) <= @max_fingerprint_bytes and byte_size(fp) > 0 do
    if String.valid?(fp) and Regex.match?(@fingerprint_re, fp),
      do: :ok,
      else: {:error, :invalid_snapshot}
  end

  defp validate_fingerprint(_), do: {:error, :invalid_snapshot}

  defp validate_owner_pid(pid) when is_pid(pid), do: :ok
  defp validate_owner_pid(_), do: {:error, :invalid_snapshot}
end
