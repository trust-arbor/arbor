defmodule Arbor.Agent.RuntimeAdmission.IntentCore do
  @moduledoc """
  Pure decision core for ordinary runtime-admission intents (Phase 4C C3C1a0).

  No IO, no GenServer, no Process. Shells gather facts and interpret effects.

  Settlement is two-phase: `begin_settling/4` retains a non-idle intent (and
  waiters in the shell) until the exact monitor DOWN barrier; `finalize_settled/3`
  or ownerless delete releases the row. Live worker-death never parks forever.
  """

  @open_phases [:admitted, :owner_launching, :owner_live, :worker_running]

  @type phase ::
          :admitted
          | :owner_launching
          | :owner_live
          | :worker_running
          | :outcome_unknown
          | :settling
          | :terminal

  @type retire_barrier :: :none | :await_owner_down | :await_worker_down

  @type intent :: %{
          required(:intent_id) => String.t(),
          required(:target_agent_id) => String.t(),
          required(:kind) => :ordinary_start,
          required(:fingerprint) => String.t(),
          required(:phase) => phase(),
          optional(:owner_pid) => pid() | nil,
          optional(:worker_pid) => pid() | nil,
          optional(:terminal) => term(),
          optional(:retire_barrier) => retire_barrier()
        }

  @type fence_map :: %{optional(String.t()) => String.t()}
  @type intent_map :: %{optional(String.t()) => intent()}

  @doc """
  Decide ordinary-start admission for one target.

  Effects (as data): `{:launch_owner, intent}` | `:none`

  Join only on open phases. `:settling` and await-worker barriers reject without
  waiter append (shell must not park callers).
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
          %{phase: :settling, fingerprint: ^fingerprint} ->
            {:error, :settling}

          %{phase: :settling} ->
            {:error, :settling}

          %{
            phase: :outcome_unknown,
            retire_barrier: :await_worker_down,
            fingerprint: ^fingerprint
          } ->
            {:error, :settling}

          %{phase: :outcome_unknown, retire_barrier: :await_worker_down} ->
            {:error, :conflict}

          %{phase: phase, fingerprint: ^fingerprint} = intent
          when phase in @open_phases ->
            {:ok, :joined, intent, intents, []}

          %{phase: phase, fingerprint: ^fingerprint} = intent
          when phase == :outcome_unknown ->
            # Restart-inventory outcome_unknown (barrier :none) may rejoin.
            if Map.get(intent, :retire_barrier, :none) == :none do
              {:ok, :joined, intent, intents, []}
            else
              {:error, :settling}
            end

          %{phase: phase} when phase in @open_phases or phase == :outcome_unknown ->
            {:error, :conflict}

          %{phase: :terminal} ->
            admit_fresh(intents, target, fingerprint, intent_id, intent_count, max_intents)

          nil ->
            admit_fresh(intents, target, fingerprint, intent_id, intent_count, max_intents)

          _ ->
            {:error, :conflict}
        end
    end
  end

  defp admit_fresh(intents, target, fingerprint, intent_id, intent_count, max_intents) do
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
        terminal: nil,
        retire_barrier: :none
      }

      new_intents = Map.put(intents, target, intent)
      {:ok, :admitted, intent, new_intents, [{:launch_owner, intent}]}
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
          %{phase: :settling} ->
            {:error, :conflict}

          %{phase: :outcome_unknown, retire_barrier: :await_worker_down} ->
            {:error, :conflict}

          %{intent_id: ^intent_id, fingerprint: ^fingerprint, phase: phase} = intent
          when phase in [
                 :admitted,
                 :owner_launching,
                 :owner_live,
                 :worker_running,
                 :outcome_unknown
               ] ->
            updated = %{
              intent
              | phase: :owner_live,
                owner_pid: owner_pid,
                retire_barrier: Map.get(intent, :retire_barrier, :none)
            }

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
              terminal: nil,
              retire_barrier: :none
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

  Same owner rebinding the same worker is idempotent.

  Atom taxonomy:
  - `:conflict` before any owner is adopted (nil owner / pre-live phases)
  - `:not_owner` only when a different **live adopted** owner holds the row
  - `:conflict` for wrong fingerprint/phase/worker shape on the same intent
  - `:not_found` when no intent exists for the target
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
      %{phase: :settling} ->
        {:error, :conflict}

      %{phase: :outcome_unknown, retire_barrier: :await_worker_down} ->
        {:error, :conflict}

      %{
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        phase: :owner_live,
        owner_pid: ^caller_owner_pid,
        worker_pid: nil
      } = intent ->
        updated = %{
          intent
          | phase: :worker_running,
            worker_pid: worker_pid,
            retire_barrier: Map.get(intent, :retire_barrier, :none)
        }

        {:ok, Map.put(intents, target, updated)}

      %{
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        phase: :worker_running,
        owner_pid: ^caller_owner_pid,
        worker_pid: ^worker_pid
      } ->
        {:ok, intents}

      # Live adopted owner differs — only then is the caller "not owner".
      # Never treat owner_pid == nil (pre-adoption) as :not_owner.
      %{phase: phase, owner_pid: owner_pid}
      when phase in [:owner_live, :worker_running] and is_pid(owner_pid) and
             owner_pid != caller_owner_pid ->
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

  Accepts classic `:worker_running` and the exact-worker late-terminal path
  (`:outcome_unknown` + `:await_worker_down`) so a still-bound worker may finish
  effects and submit settle after unexpected owner death.
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

      %{
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        phase: :outcome_unknown,
        retire_barrier: :await_worker_down,
        worker_pid: ^caller_pid
      } ->
        :ok

      %{phase: :settling, intent_id: ^intent_id} ->
        {:error, :conflict}

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

  @doc """
  True when the exact bound worker may submit a terminal (open worker or late await).
  """
  @spec settle_eligible_worker?(intent(), pid()) :: boolean()
  def settle_eligible_worker?(
        %{
          phase: :worker_running,
          worker_pid: worker_pid
        },
        caller_pid
      )
      when is_pid(worker_pid) and worker_pid == caller_pid,
      do: true

  def settle_eligible_worker?(
        %{
          phase: :outcome_unknown,
          retire_barrier: :await_worker_down,
          worker_pid: worker_pid
        },
        caller_pid
      )
      when is_pid(worker_pid) and worker_pid == caller_pid,
      do: true

  def settle_eligible_worker?(_, _), do: false

  @doc "Transition to outcome_unknown (restart inventory / non-live park seed)."
  @spec mark_outcome_unknown(intent_map(), String.t()) :: {:ok, intent_map()} | {:error, atom()}
  def mark_outcome_unknown(intents, target) do
    case Map.get(intents, target) do
      %{phase: phase} = intent when phase not in [:terminal, :settling] ->
        updated = %{
          intent
          | phase: :outcome_unknown,
            worker_pid: nil,
            retire_barrier: Map.get(intent, :retire_barrier, :none)
        }

        {:ok, Map.put(intents, target, updated)}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Classify unknown-start recovery from a live branch witness fact.

  `witness_fact`: `{:exact, intent_id}` | `:bare` | `{:other, intent_id}` | `:not_running`
  """
  @spec classify_unknown_start(
          String.t(),
          :not_running | :bare | {:exact, String.t()} | {:other, String.t()}
        ) ::
          :not_applied | :applied | :conflict
  def classify_unknown_start(_intent_id, :not_running), do: :not_applied
  def classify_unknown_start(intent_id, {:exact, intent_id}), do: :applied
  def classify_unknown_start(_intent_id, :bare), do: :conflict
  def classify_unknown_start(_intent_id, {:other, _}), do: :conflict
  def classify_unknown_start(_intent_id, _), do: :conflict

  @doc """
  Pure live-DOWN classification. Never parks forever for ordinary-start.

  Shell supplies `branch_pid` when class is `:applied` after whereis.
  `source` is `:worker` or `:owner` for not_running error atom.
  """
  @spec classify_live_down(
          String.t(),
          :not_running | :bare | {:exact, String.t()} | {:other, String.t()},
          :worker | :owner,
          pid() | nil
        ) :: {:settle, term()}
  def classify_live_down(intent_id, witness_fact, source, branch_pid \\ nil)

  def classify_live_down(intent_id, {:exact, intent_id}, _source, branch_pid)
      when is_pid(branch_pid) do
    {:settle, {:applied, branch_pid}}
  end

  def classify_live_down(intent_id, {:exact, intent_id}, _source, _branch_pid) do
    {:settle, {:error, :branch_missing_after_witness}}
  end

  def classify_live_down(_intent_id, :bare, _source, _branch_pid) do
    {:settle, {:conflict, :witness_mismatch}}
  end

  def classify_live_down(_intent_id, {:other, _}, _source, _branch_pid) do
    {:settle, {:conflict, :witness_mismatch}}
  end

  def classify_live_down(_intent_id, :not_running, :worker, _branch_pid) do
    {:settle, {:error, :worker_down}}
  end

  def classify_live_down(_intent_id, :not_running, :owner, _branch_pid) do
    {:settle, {:error, :owner_down}}
  end

  def classify_live_down(_intent_id, _fact, :worker, _branch_pid) do
    {:settle, {:error, :worker_down}}
  end

  def classify_live_down(_intent_id, _fact, :owner, _branch_pid) do
    {:settle, {:error, :owner_down}}
  end

  @doc """
  Begin two-phase settlement: retain non-idle intent with terminal when owner
  must retire; ownerless returns finalize-now.
  """
  @spec begin_settling(intent_map(), String.t(), String.t(), term()) ::
          {:ok, :begin, intent(), intent_map(), list()}
          | {:ok, :already_settling, intent(), intent_map(), list()}
          | {:ok, :ownerless_finalize, intent(), intent_map(), list()}
          | {:error, :not_found | :conflict}
  def begin_settling(intents, target, intent_id, outcome) when is_binary(intent_id) do
    case Map.get(intents, target) do
      %{intent_id: ^intent_id, phase: :settling} = intent ->
        # First terminal wins — do not overwrite.
        {:ok, :already_settling, intent, intents, []}

      %{intent_id: ^intent_id, phase: phase} = intent when phase != :terminal ->
        owner_pid = Map.get(intent, :owner_pid)

        if is_pid(owner_pid) do
          updated = %{
            intent
            | phase: :settling,
              terminal: outcome,
              retire_barrier: :await_owner_down,
              owner_pid: owner_pid
          }

          {:ok, :begin, updated, Map.put(intents, target, updated),
           [{:shutdown_owner, owner_pid}]}
        else
          done = %{
            intent
            | phase: :settling,
              terminal: outcome,
              retire_barrier: :none,
              owner_pid: nil
          }

          {:ok, :ownerless_finalize, done, Map.put(intents, target, done),
           [{:finalize_now, outcome}]}
        end

      %{intent_id: _other, phase: phase} when phase != :terminal ->
        {:error, :conflict}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Finalize after authentic owner DOWN with `:await_owner_down` barrier.

  Requires phase `:settling`, barrier `:await_owner_down`, a stored terminal, and
  (when `expected_owner_pid` is given) exact match against `intent.owner_pid` so
  a stale DOWN cannot retire a rebound owner.
  """
  @spec finalize_settled(intent_map(), String.t(), String.t()) ::
          {:ok, intent(), intent_map()}
          | {:error, :not_found | :conflict | :not_settling | :barrier_mismatch | :stale_owner}
  def finalize_settled(intents, target, intent_id) when is_binary(intent_id) do
    finalize_settled(intents, target, intent_id, :any_owner)
  end

  @spec finalize_settled(intent_map(), String.t(), String.t(), pid() | :any_owner) ::
          {:ok, intent(), intent_map()}
          | {:error, :not_found | :conflict | :not_settling | :barrier_mismatch | :stale_owner}
  def finalize_settled(intents, target, intent_id, expected_owner_pid)
      when is_binary(intent_id) and
             (is_pid(expected_owner_pid) or expected_owner_pid == :any_owner) do
    case Map.get(intents, target) do
      %{
        intent_id: ^intent_id,
        phase: :settling,
        retire_barrier: :await_owner_down,
        owner_pid: owner_pid
      } = intent ->
        cond do
          not Map.has_key?(intent, :terminal) ->
            {:error, :not_settling}

          expected_owner_pid != :any_owner and owner_pid != expected_owner_pid ->
            {:error, :stale_owner}

          true ->
            done = %{intent | phase: :terminal, worker_pid: nil, retire_barrier: :none}
            {:ok, done, Map.delete(intents, target)}
        end

      %{intent_id: ^intent_id, phase: :settling} ->
        {:error, :barrier_mismatch}

      %{intent_id: ^intent_id} ->
        {:error, :not_settling}

      %{intent_id: _other} ->
        {:error, :conflict}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Finalize an ownerless terminal (never adopted, or owner already cleared).

  Requires phase `:settling`, `owner_pid` nil, and a stored terminal. Used after
  `begin_settling` returns `:ownerless_finalize` — never while a live owner
  barrier is outstanding.
  """
  @spec finalize_ownerless(intent_map(), String.t(), String.t()) ::
          {:ok, intent(), intent_map()}
          | {:error, :not_found | :conflict | :not_settling | :owner_barrier_outstanding}
  def finalize_ownerless(intents, target, intent_id) when is_binary(intent_id) do
    case Map.get(intents, target) do
      %{
        intent_id: ^intent_id,
        phase: :settling,
        owner_pid: owner_pid,
        terminal: _terminal
      } = intent
      when not is_pid(owner_pid) ->
        done = %{
          intent
          | phase: :terminal,
            worker_pid: nil,
            retire_barrier: :none,
            owner_pid: nil
        }

        {:ok, done, Map.delete(intents, target)}

      %{intent_id: ^intent_id, phase: :settling, owner_pid: owner_pid}
      when is_pid(owner_pid) ->
        {:error, :owner_barrier_outstanding}

      %{intent_id: ^intent_id} ->
        {:error, :not_settling}

      %{intent_id: _other} ->
        {:error, :conflict}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Unexpected owner DOWN with indeterminate result: retain non-idle intent and
  await authentic worker DOWN (or late worker settle).

  `expected_owner_pid` is the monitored owner from TaskStore's owner monitor
  entry. A stale DOWN (rebound owner) returns `{:error, :stale_owner}` and must
  not clear or retire the live intent.
  """
  @spec note_owner_gone_await_worker(intent_map(), String.t(), String.t(), pid()) ::
          {:ok, intent(), intent_map(), list()}
          | {:ok, :already_awaiting, intent(), intent_map(), list()}
          | {:error, :not_found | :conflict | :already_settling | :stale_owner}
  def note_owner_gone_await_worker(intents, target, intent_id, expected_owner_pid)
      when is_binary(intent_id) and is_pid(expected_owner_pid) do
    case Map.get(intents, target) do
      %{intent_id: ^intent_id, phase: :settling} ->
        {:error, :already_settling}

      %{
        intent_id: ^intent_id,
        phase: :outcome_unknown,
        retire_barrier: :await_worker_down
      } = intent ->
        # Already owner-gone via a prior authentic transition; idempotent.
        effects =
          case Map.get(intent, :worker_pid) do
            pid when is_pid(pid) -> [{:kill_worker, pid}]
            _ -> []
          end

        {:ok, :already_awaiting, intent, intents, effects}

      %{
        intent_id: ^intent_id,
        owner_pid: ^expected_owner_pid,
        phase: phase
      } = intent
      when phase not in [:terminal] ->
        worker_pid = Map.get(intent, :worker_pid)

        updated = %{
          intent
          | phase: :outcome_unknown,
            owner_pid: nil,
            retire_barrier: :await_worker_down,
            worker_pid: worker_pid
        }

        effects =
          if is_pid(worker_pid), do: [{:kill_worker, worker_pid}], else: []

        {:ok, updated, Map.put(intents, target, updated), effects}

      %{intent_id: ^intent_id, owner_pid: other}
      when is_pid(other) and other != expected_owner_pid ->
        {:error, :stale_owner}

      %{intent_id: ^intent_id, owner_pid: nil} ->
        {:error, :stale_owner}

      %{intent_id: _other} ->
        {:error, :conflict}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Exact monitored owner is gone with a determinate terminal (e.g. exact applied
  witness, or no worker left). Purely clears owner and commits terminal for
  ownerless finalization — shell must not mutate `owner_pid` directly.
  """
  @spec commit_terminal_owner_gone(intent_map(), String.t(), String.t(), pid(), term()) ::
          {:ok, intent(), intent_map()}
          | {:error, :not_found | :conflict | :already_settling | :stale_owner}
  def commit_terminal_owner_gone(intents, target, intent_id, expected_owner_pid, terminal)
      when is_binary(intent_id) and is_pid(expected_owner_pid) do
    case Map.get(intents, target) do
      %{
        intent_id: ^intent_id,
        owner_pid: ^expected_owner_pid,
        phase: :settling,
        retire_barrier: :await_owner_down
      } ->
        # Terminal already committed under owner barrier — use finalize_settled.
        {:error, :already_settling}

      %{
        intent_id: ^intent_id,
        owner_pid: ^expected_owner_pid,
        phase: phase
      } = intent
      when phase not in [:terminal] ->
        updated = %{
          intent
          | phase: :settling,
            owner_pid: nil,
            terminal: terminal,
            retire_barrier: :none
        }

        {:ok, updated, Map.put(intents, target, updated)}

      %{intent_id: ^intent_id, owner_pid: other}
      when is_pid(other) and other != expected_owner_pid ->
        {:error, :stale_owner}

      %{intent_id: ^intent_id, owner_pid: nil} ->
        {:error, :stale_owner}

      %{intent_id: _other} ->
        {:error, :conflict}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Ownerless begin+finalize combo only. Never deletes while a live owner barrier
  is outstanding — callers must use `begin_settling` + owner DOWN +
  `finalize_settled` for owned intents.
  """
  @spec settle(intent_map(), String.t(), String.t(), term()) ::
          {:ok, intent(), intent_map()}
          | {:error, :not_found | :conflict | :owner_barrier_outstanding | :not_settling}
  def settle(intents, target, intent_id, terminal) when is_binary(intent_id) do
    case begin_settling(intents, target, intent_id, terminal) do
      {:ok, :ownerless_finalize, _intent, mid, _effects} ->
        finalize_ownerless(mid, target, intent_id)

      {:ok, :begin, _intent, _mid, _effects} ->
        # Live owner barrier must not be bypassed by legacy settle.
        {:error, :owner_barrier_outstanding}

      {:ok, :already_settling, intent, mid, _} ->
        cond do
          is_pid(Map.get(intent, :owner_pid)) and
              Map.get(intent, :retire_barrier) == :await_owner_down ->
            {:error, :owner_barrier_outstanding}

          not is_pid(Map.get(intent, :owner_pid)) ->
            finalize_ownerless(mid, target, intent_id)

          true ->
            {:error, :owner_barrier_outstanding}
        end

      {:error, _} = err ->
        err
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

  @doc "Pure retry allowlist for IntentOwner adopt errors."
  @spec retryable_adopt_error?(term()) :: boolean()
  def retryable_adopt_error?(:runtime_admission_not_ready), do: true
  def retryable_adopt_error?(:fence_not_ready), do: true
  def retryable_adopt_error?(:store_restart), do: true
  def retryable_adopt_error?(_), do: false

  # Closed launch-retry allowlist only — never "any start_child error".
  @retryable_start_child_reasons [:max_children, :timeout]

  @doc """
  Pure retry allowlist for IntentOwner launch failures.

  Only store restart and an explicit closed set of Task.Supervisor pressure
  reasons retry. Bind auth errors, unknown shapes, and redacted exceptions do not.
  """
  @spec retryable_launch_failure?(term()) :: boolean()
  def retryable_launch_failure?(:store_restart), do: true
  def retryable_launch_failure?(reason) when reason in @retryable_start_child_reasons, do: true

  def retryable_launch_failure?({:task_supervisor_transient, reason})
      when reason in @retryable_start_child_reasons,
      do: true

  def retryable_launch_failure?(_), do: false

  @doc "Classify a Task.Supervisor.start_child error into a bounded atom or redacted tag."
  @spec classify_start_child_error(term()) :: term()
  def classify_start_child_error(:max_children), do: :max_children
  def classify_start_child_error(:timeout), do: :timeout
  def classify_start_child_error({:timeout, _}), do: :timeout
  def classify_start_child_error(:temporary), do: :temporary
  def classify_start_child_error({:already_started, _}), do: :already_started

  def classify_start_child_error(other),
    do: {:launch_failed, redact_error_reason(other)}

  @doc "Bound and redact exception/error reasons for public/typed stops."
  @spec redact_error_reason(term()) :: atom() | String.t()
  def redact_error_reason(reason) when is_atom(reason), do: reason

  def redact_error_reason(reason) when is_binary(reason) do
    trimmed = String.slice(reason, 0, 64)
    if String.valid?(trimmed), do: trimmed, else: :invalid_error_text
  end

  def redact_error_reason({tag, _}) when is_atom(tag), do: tag
  def redact_error_reason(_), do: :launch_error

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
         terminal: nil,
         retire_barrier: :none
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
