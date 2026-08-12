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
          required(:kind) => :ordinary_start | :guarded_restore,
          required(:fingerprint) => String.t(),
          required(:phase) => phase(),
          optional(:owner_pid) => pid() | nil,
          optional(:worker_pid) => pid() | nil,
          optional(:terminal) => term(),
          optional(:retire_barrier) => retire_barrier(),
          optional(:launch_ref) => reference() | nil,
          optional(:launcher_pid) => pid() | nil,
          optional(:launcher_mon) => reference() | nil,
          optional(:launcher_attempt_index) => non_neg_integer(),
          optional(:operation_id) => String.t(),
          optional(:restore_token) => String.t(),
          optional(:effect_handoff?) => boolean()
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
        retire_barrier: :none,
        launch_ref: nil,
        launcher_pid: nil,
        launcher_mon: nil,
        launcher_attempt_index: 0,
        effect_handoff?: false
      }

      new_intents = Map.put(intents, target, intent)
      {:ok, :admitted, intent, new_intents, [{:launch_owner, intent}]}
    end
  end

  @doc """
  Decide guarded-restore admission **before** minting intent_id/fingerprint.

  Join first on exact `(operation_id, restore_token)`. On join, the existing
  fingerprint must recompute from the existing intent_id (fail closed on
  corruption). Returns `{:fresh, ...}` only when a new slot may be minted.
  """
  @spec decide_guarded_admit(
          intent_map(),
          fence_map(),
          boolean(),
          boolean(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, :joined, intent()}
          | {:ok, :fresh}
          | {:error, atom()}
  def decide_guarded_admit(
        intents,
        fences,
        fence_ready?,
        admission_ready?,
        target,
        operation_id,
        restore_token
      )
      when is_map(intents) and is_map(fences) and is_binary(target) and is_binary(operation_id) and
             is_binary(restore_token) do
    cond do
      fence_ready? != true ->
        {:error, :fence_not_ready}

      admission_ready? != true ->
        {:error, :runtime_admission_not_ready}

      not Map.has_key?(fences, target) ->
        # Authoritative pre-effect rejection when no fence and no live intent for
        # this exact op/token — admit never started effects. Public shell may
        # settle+clear only this typed result (not arbitrary caller errors).
        case Map.get(intents, target) do
          nil ->
            {:error, :restore_pre_effect_aborted}

          %{
            kind: :guarded_restore,
            operation_id: ^operation_id,
            restore_token: ^restore_token,
            phase: phase
          }
          when phase in @open_phases or phase == :outcome_unknown ->
            {:error, :conflict}

          _ ->
            {:error, :restore_fence_required}
        end

      Map.get(fences, target) != operation_id ->
        {:error, :not_owner}

      true ->
        case Map.get(intents, target) do
          %{phase: :settling} ->
            {:error, :settling}

          %{
            kind: :guarded_restore,
            operation_id: ^operation_id,
            restore_token: ^restore_token,
            intent_id: existing_intent_id,
            fingerprint: existing_fp,
            phase: phase
          } = intent
          when (phase in @open_phases or phase == :outcome_unknown) and
                 is_binary(existing_intent_id) and
                 is_binary(existing_fp) ->
            # Join only after fingerprint recomputes from store-owned intent_id.
            expected =
              Arbor.Agent.RuntimeRestoreAdmissionClaimCore.fingerprint(
                operation_id,
                target,
                operation_id,
                restore_token,
                existing_intent_id
              )

            if existing_fp == expected do
              {:ok, :joined, intent}
            else
              {:error, :conflict}
            end

          %{phase: phase} when phase in @open_phases or phase == :outcome_unknown ->
            {:error, :conflict}

          %{phase: :terminal} ->
            {:ok, :fresh}

          nil ->
            {:ok, :fresh}

          _ ->
            {:error, :conflict}
        end
    end
  end

  @doc """
  Install a fresh guarded-restore intent after `decide_guarded_admit` returned `:fresh`.

  Caller must mint intent_id and fingerprint only for this path.
  """
  @spec admit_guarded_fresh(
          intent_map(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:ok, :admitted, intent(), intent_map(), list()} | {:error, atom()}
  def admit_guarded_fresh(
        intents,
        target,
        operation_id,
        restore_token,
        fingerprint,
        intent_id,
        intent_count,
        max_intents
      )
      when is_map(intents) and is_binary(target) and is_binary(operation_id) and
             is_binary(restore_token) and is_binary(fingerprint) and is_binary(intent_id) and
             is_integer(intent_count) and is_integer(max_intents) do
    # Refuse if a concurrent admit already filled the slot.
    case Map.get(intents, target) do
      %{phase: phase} when phase in @open_phases or phase in [:outcome_unknown, :settling] ->
        {:error, :conflict}

      _ ->
        if intent_count >= max_intents do
          {:error, :busy}
        else
          intent = %{
            intent_id: intent_id,
            target_agent_id: target,
            kind: :guarded_restore,
            fingerprint: fingerprint,
            operation_id: operation_id,
            restore_token: restore_token,
            phase: :admitted,
            owner_pid: nil,
            worker_pid: nil,
            terminal: nil,
            retire_barrier: :none,
            launch_ref: nil,
            launcher_pid: nil,
            launcher_mon: nil,
            launcher_attempt_index: 0,
            effect_handoff?: false
          }

          new_intents = Map.put(intents, target, intent)
          {:ok, :admitted, intent, new_intents, [{:launch_owner, intent}]}
        end
    end
  end

  @doc """
  True when a non-terminal guarded_restore intent holds the target.

  Includes outcome_unknown parks (post-handoff or pre-handoff bound-hold after
  durable claim join) so fence removal stays blocked until determinate retirement.
  """
  @spec non_idle_guarded_restore?(intent_map(), String.t()) :: boolean()
  def non_idle_guarded_restore?(intents, target) when is_map(intents) and is_binary(target) do
    case Map.get(intents, target) do
      %{kind: :guarded_restore, phase: :terminal} -> false
      %{kind: :guarded_restore, phase: _} -> true
      _ -> false
    end
  end

  @doc """
  Begin a TaskStore-owned owner launch attempt (pure).

  Requires no outstanding `launch_ref` and phase `:admitted` or retrying
  `:owner_launching` without a bound owner.
  """
  @spec begin_owner_launch(intent_map(), String.t(), reference(), non_neg_integer()) ::
          {:ok, intent(), intent_map()} | {:error, atom()}
  def begin_owner_launch(intents, target, launch_ref, attempt_index)
      when is_map(intents) and is_binary(target) and is_reference(launch_ref) and
             is_integer(attempt_index) and attempt_index > 0 do
    case Map.get(intents, target) do
      %{phase: phase, owner_pid: owner_pid} = intent
      when phase in [:admitted, :owner_launching] and not is_pid(owner_pid) ->
        if is_reference(Map.get(intent, :launch_ref)) do
          {:error, :launch_attempt_outstanding}
        else
          # Fields are explicit on admit_fresh/rebind constructors; Map.put keeps
          # partial test fixtures and older in-memory rows safe.
          updated =
            intent
            |> Map.put(:phase, :owner_launching)
            |> Map.put(:launch_ref, launch_ref)
            |> Map.put(:launcher_pid, nil)
            |> Map.put(:launcher_mon, nil)
            |> Map.put(:launcher_attempt_index, attempt_index)

          {:ok, updated, Map.put(intents, target, updated)}
        end

      _ ->
        {:error, :conflict}
    end
  end

  @doc """
  Attach monitored launcher identity to the current launch attempt (pure).
  """
  @spec attach_launcher(intent_map(), String.t(), reference(), pid(), reference()) ::
          {:ok, intent_map()} | {:error, atom()}
  def attach_launcher(intents, target, launch_ref, launcher_pid, launcher_mon)
      when is_reference(launch_ref) and is_pid(launcher_pid) and is_reference(launcher_mon) do
    case Map.get(intents, target) do
      %{phase: :owner_launching, launch_ref: ^launch_ref, owner_pid: owner_pid} = intent
      when not is_pid(owner_pid) ->
        updated =
          intent
          |> Map.put(:launcher_pid, launcher_pid)
          |> Map.put(:launcher_mon, launcher_mon)

        {:ok, Map.put(intents, target, updated)}

      _ ->
        {:error, :stale_launch}
    end
  end

  @doc """
  Authenticated launch bind: caller PID becomes expected owner only when the
  current unforgeable `launch_ref` matches and no owner is bound yet.
  """
  @spec bind_launch_owner(
          intent_map(),
          String.t(),
          String.t(),
          String.t(),
          reference(),
          pid()
        ) ::
          {:ok, intent(), intent_map()} | {:error, atom()}
  def bind_launch_owner(intents, target, intent_id, fingerprint, launch_ref, caller_pid)
      when is_binary(intent_id) and is_binary(fingerprint) and is_reference(launch_ref) and
             is_pid(caller_pid) do
    case Map.get(intents, target) do
      %{
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        phase: :owner_launching,
        launch_ref: ^launch_ref,
        owner_pid: owner_pid
      } = intent
      when not is_pid(owner_pid) ->
        updated =
          intent
          |> Map.put(:owner_pid, caller_pid)
          |> clear_launch_attempt_fields()

        {:ok, updated, Map.put(intents, target, updated)}

      %{
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        owner_pid: ^caller_pid,
        launch_ref: nil
      } = intent ->
        # Idempotent re-bind by the already-bound owner after consume.
        {:ok, intent, intents}

      %{
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        owner_pid: ^caller_pid,
        launch_ref: ^launch_ref
      } = intent ->
        updated = clear_launch_attempt_fields(intent)
        {:ok, updated, Map.put(intents, target, updated)}

      %{intent_id: ^intent_id, owner_pid: other} when is_pid(other) and other != caller_pid ->
        {:error, :already_bound}

      %{intent_id: ^intent_id, launch_ref: other_ref}
      when is_reference(other_ref) and other_ref != launch_ref ->
        {:error, :stale_launch}

      %{intent_id: ^intent_id} ->
        {:error, :stale_launch}

      %{phase: _} ->
        {:error, :conflict}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Consume a matching unbound launch attempt after authenticated failure/DOWN.

  Returns the prior launcher_mon (if any) so the shell can demonitor.
  """
  @spec consume_launch_failure(intent_map(), String.t(), String.t(), reference()) ::
          {:ok, intent_map(), reference() | nil} | {:error, atom()}
  def consume_launch_failure(intents, target, intent_id, launch_ref)
      when is_binary(intent_id) and is_reference(launch_ref) do
    case Map.get(intents, target) do
      %{
        intent_id: ^intent_id,
        phase: :owner_launching,
        launch_ref: ^launch_ref,
        owner_pid: owner_pid
      } = intent
      when not is_pid(owner_pid) ->
        mon = Map.get(intent, :launcher_mon)
        updated = clear_launch_attempt_fields(intent)
        {:ok, Map.put(intents, target, updated), mon}

      %{intent_id: ^intent_id, owner_pid: owner_pid} when is_pid(owner_pid) ->
        # Bind already won — failure is stale.
        {:error, :already_bound}

      %{intent_id: ^intent_id} ->
        {:error, :stale_launch}

      nil ->
        {:error, :not_found}

      _ ->
        {:error, :stale_launch}
    end
  end

  defp clear_launch_attempt_fields(intent) when is_map(intent) do
    intent
    |> Map.put(:launch_ref, nil)
    |> Map.put(:launcher_pid, nil)
    |> Map.put(:launcher_mon, nil)
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
        caller_pid
      )
      when is_pid(caller_pid) do
    cond do
      admission_ready? != true ->
        {:error, :runtime_admission_not_ready}

      fence_ready? != true ->
        {:error, :fence_not_ready}

      true ->
        case Map.get(intents, target) do
          %{kind: :guarded_restore, operation_id: op_id} = _intent
          when is_binary(op_id) ->
            cond do
              not Map.has_key?(fences, target) ->
                {:error, :restore_fence_required}

              Map.get(fences, target) != op_id ->
                {:error, :not_owner}

              true ->
                adopt_ready_owner(intents, target, intent_id, fingerprint, caller_pid)
            end

          _ ->
            if Map.has_key?(fences, target) do
              {:error, :target_fenced}
            else
              adopt_ready_owner(intents, target, intent_id, fingerprint, caller_pid)
            end
        end
    end
  end

  @doc """
  Source-authenticated effect-handoff ack. Must run before gate release.

  Requires guarded kind, bound worker, exact owner caller, exact intent identity.
  """
  @spec ack_effect_handoff(intent_map(), String.t(), String.t(), String.t(), pid()) ::
          {:ok, intent_map()} | {:error, atom()}
  def ack_effect_handoff(intents, target, intent_id, fingerprint, caller_pid)
      when is_binary(intent_id) and is_binary(fingerprint) and is_pid(caller_pid) do
    case Map.get(intents, target) do
      %{
        kind: :guarded_restore,
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        phase: phase,
        owner_pid: ^caller_pid,
        worker_pid: worker_pid,
        effect_handoff?: true
      } = intent
      when phase in [:owner_live, :worker_running] and is_pid(worker_pid) ->
        {:ok, Map.put(intents, target, intent)}

      %{
        kind: :guarded_restore,
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        phase: phase,
        owner_pid: ^caller_pid,
        worker_pid: worker_pid
      } = intent
      when phase in [:owner_live, :worker_running] and is_pid(worker_pid) ->
        updated = Map.put(intent, :effect_handoff?, true)
        {:ok, Map.put(intents, target, updated)}

      %{
        kind: :guarded_restore,
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        owner_pid: other
      }
      when is_pid(other) and other != caller_pid ->
        {:error, :not_owner}

      %{intent_id: ^intent_id} ->
        {:error, :conflict}

      %{phase: _} ->
        {:error, :conflict}

      nil ->
        {:error, :not_found}
    end
  end

  @max_claim_inventory 256
  @max_rebind_snapshots 256

  @doc """
  Pure merge of durable restore claims with live owner snapshots for restart inventory.

  Materializes blocking unknown intents for bound/outcome_unknown claims lacking
  exact live owner/worker. Join identity is exact
  target+intent_id+fingerprint+operation_id+token. A live guarded snapshot with
  no corresponding claim (or claim with no restored row after live match) is an
  error — never silent `{:ok, intents}`. Bounded and fail-closed.
  """
  @spec merge_restore_claim_inventory(intent_map(), list(), list()) ::
          {:ok, intent_map()} | {:error, atom()}
  def merge_restore_claim_inventory(_prior_intents, owner_snapshots, claims)
      when is_list(owner_snapshots) and is_list(claims) do
    cond do
      length(owner_snapshots) > @max_rebind_snapshots ->
        {:error, :inventory_overflow}

      length(claims) > @max_claim_inventory ->
        {:error, :inventory_overflow}

      true ->
        with {:ok, base} <- rebind_owners(%{}, owner_snapshots),
             {:ok, merged} <- reduce_claim_materializations(base, claims, owner_snapshots),
             :ok <- assert_guarded_snapshots_covered(merged, owner_snapshots, claims) do
          {:ok, merged}
        end
    end
  end

  def merge_restore_claim_inventory(_, _, _), do: {:error, :invalid_inventory}

  defp reduce_claim_materializations(intents, claims, snapshots) do
    Enum.reduce_while(claims, {:ok, intents}, fn claim, {:ok, acc} ->
      case materialize_claim_intent(acc, claim, snapshots) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp claim_identity(claim) when is_map(claim) do
    target = Map.get(claim, "target_agent_id") || Map.get(claim, :target_agent_id)
    intent_id = Map.get(claim, "intent_id") || Map.get(claim, :intent_id)
    fingerprint = Map.get(claim, "fingerprint") || Map.get(claim, :fingerprint)
    operation_id = Map.get(claim, "operation_id") || Map.get(claim, :operation_id)
    token = Map.get(claim, "token") || Map.get(claim, :token)
    phase = Map.get(claim, "claim_phase") || Map.get(claim, :claim_phase)

    %{
      target: target,
      intent_id: intent_id,
      fingerprint: fingerprint,
      operation_id: operation_id,
      token: token,
      phase: phase
    }
  end

  defp exact_live_match?(snap, id) when is_map(snap) and is_map(id) do
    Map.get(snap, :target_agent_id) == id.target and
      Map.get(snap, :intent_id) == id.intent_id and
      Map.get(snap, :fingerprint) == id.fingerprint and
      Map.get(snap, :operation_id) == id.operation_id and
      Map.get(snap, :restore_token) == id.token
  end

  defp exact_live_match?(_, _), do: false

  defp exact_intent_match?(intent, id) when is_map(intent) and is_map(id) do
    intent.target_agent_id == id.target and
      intent.intent_id == id.intent_id and
      intent.fingerprint == id.fingerprint and
      Map.get(intent, :operation_id) == id.operation_id and
      Map.get(intent, :restore_token) == id.token and
      intent.kind == :guarded_restore
  end

  defp exact_intent_match?(_, _), do: false

  defp materialize_claim_intent(intents, claim, snapshots) when is_map(claim) do
    id = claim_identity(claim)

    cond do
      id.phase == "settled" ->
        {:ok, intents}

      id.phase == "minted" and is_binary(id.target) and is_binary(id.token) and
        is_binary(id.operation_id) and is_nil(id.intent_id) and is_nil(id.fingerprint) ->
        # Pre-bind: live owners must not claim this identity yet; no row required.
        {:ok, intents}

      id.phase in ["bound", "outcome_unknown"] and is_binary(id.target) and
        is_binary(id.intent_id) and is_binary(id.fingerprint) and is_binary(id.operation_id) and
          is_binary(id.token) ->
        live? =
          Enum.any?(snapshots, fn snap ->
            exact_live_match?(snap, id) and
              (is_pid(Map.get(snap, :owner_pid) || Map.get(snap, :child_pid)) or
                 is_pid(Map.get(snap, :worker_pid)))
          end)

        if live? do
          # Live exact match must already have a restored intent row from rebind.
          case Map.get(intents, id.target) do
            intent when is_map(intent) ->
              if exact_intent_match?(intent, id) do
                updated =
                  intent
                  |> Map.put(:kind, :guarded_restore)
                  |> Map.put(:operation_id, id.operation_id)
                  |> Map.put(:restore_token, id.token)
                  |> Map.put(:effect_handoff?, true)

                {:ok, Map.put(intents, id.target, updated)}
              else
                {:error, :invalid_inventory}
              end

            nil ->
              # Live snapshot predicate without a corresponding restored row.
              {:error, :invalid_inventory}
          end
        else
          case Map.get(intents, id.target) do
            nil ->
              blocking = %{
                intent_id: id.intent_id,
                target_agent_id: id.target,
                kind: :guarded_restore,
                fingerprint: id.fingerprint,
                operation_id: id.operation_id,
                restore_token: id.token,
                phase: :outcome_unknown,
                owner_pid: nil,
                worker_pid: nil,
                terminal: nil,
                retire_barrier: :none,
                launch_ref: nil,
                launcher_pid: nil,
                launcher_mon: nil,
                launcher_attempt_index: 0,
                effect_handoff?: true
              }

              {:ok, Map.put(intents, id.target, blocking)}

            intent when is_map(intent) ->
              if exact_intent_match?(intent, id) do
                updated =
                  intent
                  |> Map.put(:phase, :outcome_unknown)
                  |> Map.put(:effect_handoff?, true)

                {:ok, Map.put(intents, id.target, updated)}
              else
                {:error, :duplicate_target}
              end

            _ ->
              {:error, :invalid_inventory}
          end
        end

      true ->
        {:error, :invalid_inventory}
    end
  end

  defp materialize_claim_intent(_, _, _), do: {:error, :invalid_inventory}

  # Every live guarded snapshot must have an exact durable claim and a restored row.
  defp assert_guarded_snapshots_covered(intents, snapshots, claims)
       when is_map(intents) and is_list(snapshots) and is_list(claims) do
    Enum.reduce_while(snapshots, :ok, fn snap, :ok ->
      case guarded_snapshot_identity(snap) do
        :ordinary ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}

        {:ok, id} ->
          claim_ok? =
            Enum.any?(claims, fn claim ->
              cid = claim_identity(claim)

              cid.target == id.target and cid.intent_id == id.intent_id and
                cid.fingerprint == id.fingerprint and cid.operation_id == id.operation_id and
                cid.token == id.token and cid.phase in ["bound", "outcome_unknown"]
            end)

          row = Map.get(intents, id.target)

          cond do
            not claim_ok? ->
              {:halt, {:error, :invalid_inventory}}

            not is_map(row) ->
              {:halt, {:error, :invalid_inventory}}

            not exact_intent_match?(row, id) ->
              {:halt, {:error, :invalid_inventory}}

            true ->
              {:cont, :ok}
          end
      end
    end)
  end

  defp guarded_snapshot_identity(snap) when is_map(snap) do
    kind = Map.get(snap, :kind, Map.get(snap, "kind", :ordinary_start))

    case normalize_snapshot_kind(kind) do
      {:ok, :ordinary_start} ->
        :ordinary

      {:ok, :guarded_restore} ->
        id = %{
          target: Map.get(snap, :target_agent_id, Map.get(snap, "target_agent_id")),
          intent_id: Map.get(snap, :intent_id, Map.get(snap, "intent_id")),
          fingerprint: Map.get(snap, :fingerprint, Map.get(snap, "fingerprint")),
          operation_id: Map.get(snap, :operation_id, Map.get(snap, "operation_id")),
          token: Map.get(snap, :restore_token, Map.get(snap, "restore_token"))
        }

        if is_binary(id.target) and is_binary(id.intent_id) and is_binary(id.fingerprint) and
             is_binary(id.operation_id) and is_binary(id.token) do
          {:ok, id}
        else
          {:error, :invalid_snapshot}
        end

      {:error, _} ->
        {:error, :invalid_snapshot}
    end
  end

  defp guarded_snapshot_identity(_), do: {:error, :invalid_snapshot}

  defp adopt_ready_owner(intents, target, intent_id, fingerprint, caller_pid) do
    case Map.get(intents, target) do
      %{phase: :settling} ->
        {:error, :conflict}

      %{phase: :outcome_unknown, retire_barrier: :await_worker_down} ->
        {:error, :conflict}

      # Exact bound owner, worker already running — never downgrade phase.
      %{
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        phase: :worker_running,
        owner_pid: ^caller_pid
      } = intent ->
        {:ok, :adopted, intent, intents}

      # Exact bound owner, already live — idempotent.
      %{
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        phase: :owner_live,
        owner_pid: ^caller_pid
      } = intent ->
        {:ok, :adopted, intent, intents}

      # Launch-bound or restart-rebound owner advancing to live.
      %{
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        phase: phase,
        owner_pid: ^caller_pid
      } = intent
      when phase in [:owner_launching, :outcome_unknown] and is_pid(caller_pid) ->
        updated = %{
          intent
          | phase: :owner_live,
            retire_barrier: Map.get(intent, :retire_barrier, :none)
        }

        {:ok, :adopted, updated, Map.put(intents, target, updated)}

      %{
        intent_id: ^intent_id,
        fingerprint: ^fingerprint,
        owner_pid: other
      }
      when is_pid(other) and other != caller_pid ->
        {:error, :not_owner}

      %{intent_id: ^intent_id, fingerprint: ^fingerprint, owner_pid: owner_pid}
      when not is_pid(owner_pid) ->
        {:error, :owner_not_bound}

      %{intent_id: ^intent_id} ->
        {:error, :conflict}

      %{phase: phase} when phase != :terminal ->
        {:error, :conflict}

      nil ->
        {:error, :not_found}

      _ ->
        {:error, :conflict}
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

  `witness_fact`:
  - `{:exact, intent_id}` | `:bare` | `{:other, intent_id}` | `:not_running` — observed facts
  - `:observe_failed` — observation shell failure; **never** proves absence or applied
  """
  @spec classify_unknown_start(
          String.t(),
          :not_running
          | :bare
          | :observe_failed
          | {:exact, String.t()}
          | {:other, String.t()}
        ) ::
          :not_applied | :applied | :conflict | :observation_failed
  def classify_unknown_start(_intent_id, :not_running), do: :not_applied
  def classify_unknown_start(intent_id, {:exact, intent_id}), do: :applied
  def classify_unknown_start(_intent_id, :bare), do: :conflict
  def classify_unknown_start(_intent_id, {:other, _}), do: :conflict
  def classify_unknown_start(_intent_id, :observe_failed), do: :observation_failed
  def classify_unknown_start(_intent_id, _), do: :observation_failed

  @doc """
  Pure live-DOWN classification. Never parks forever for ordinary-start.

  Shell supplies `branch_pid` when class is `:applied` from the same atomic
  `observe_admission/1` lookup. `source` is `:worker` or `:owner` for
  not_running error atom.

  `:observe_failed` is a bare-conflict class — never proves absence or applied.
  """
  @spec classify_live_down(
          String.t(),
          :not_running
          | :bare
          | :observe_failed
          | {:exact, String.t()}
          | {:other, String.t()},
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

  def classify_live_down(_intent_id, :observe_failed, _source, _branch_pid) do
    {:settle, {:conflict, :observation_failed}}
  end

  def classify_live_down(_intent_id, :not_running, :worker, _branch_pid) do
    {:settle, {:error, :worker_down}}
  end

  def classify_live_down(_intent_id, :not_running, :owner, _branch_pid) do
    {:settle, {:error, :owner_down}}
  end

  def classify_live_down(_intent_id, _fact, :worker, _branch_pid) do
    {:settle, {:conflict, :observation_failed}}
  end

  def classify_live_down(_intent_id, _fact, :owner, _branch_pid) do
    {:settle, {:conflict, :observation_failed}}
  end

  @doc """
  Revalidate that a delayed witness observation still targets the live intent.

  Exact identity: kind + target + intent_id + fingerprint + operation_id + token
  plus expected owner/worker identity for the observe reason. Stale → false
  (shell must treat as inert or reobserve; never apply to changed state).
  """
  @spec observe_request_current?(map() | nil, map()) :: boolean()
  def observe_request_current?(intent, request)
      when is_map(intent) and is_map(request) do
    kind = Map.get(request, :kind, :ordinary_start)
    target = Map.get(request, :target)
    intent_id = Map.get(request, :intent_id)
    fingerprint = Map.get(request, :fingerprint)
    operation_id = Map.get(request, :operation_id)
    token = Map.get(request, :restore_token)

    base_match? =
      Map.get(intent, :kind, :ordinary_start) == kind and
        intent.target_agent_id == target and
        intent.intent_id == intent_id and
        Map.get(intent, :fingerprint) == fingerprint and
        Map.get(intent, :operation_id) == operation_id and
        Map.get(intent, :restore_token) == token

    base_match? and observe_identity_phase_current?(intent, request)
  end

  def observe_request_current?(_, _), do: false

  defp observe_identity_phase_current?(intent, %{reason: :unexpected_owner_down} = request) do
    monitored = Map.get(request, :monitored_owner_pid)
    owner = Map.get(intent, :owner_pid)
    phase = Map.get(intent, :phase)

    cond do
      # Still the same live owner this observation was launched for.
      is_pid(monitored) and owner == monitored ->
        true

      # Owner already cleared by a concurrent path but intent not rebound.
      is_nil(owner) and phase in [:owner_live, :worker_running, :outcome_unknown, :settling] ->
        true

      true ->
        false
    end
  end

  defp observe_identity_phase_current?(intent, %{reason: :worker_down_classify} = request) do
    expected_worker = Map.get(request, :worker_pid)
    expected_owner = Map.get(request, :owner_pid)
    worker = Map.get(intent, :worker_pid)
    owner = Map.get(intent, :owner_pid)
    phase = Map.get(intent, :phase)
    barrier = Map.get(intent, :retire_barrier, :none)

    worker_ok? =
      (is_pid(expected_worker) and worker == expected_worker) or
        (is_nil(worker) and barrier == :await_worker_down) or
        (is_nil(worker) and phase in [:outcome_unknown, :settling])

    owner_ok? =
      expected_owner == owner or
        (is_nil(owner) and phase in [:outcome_unknown, :settling, :worker_running])

    worker_ok? and owner_ok? and phase != :terminal
  end

  defp observe_identity_phase_current?(_intent, _request), do: false

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
  def retryable_adopt_error?(:owner_not_bound), do: true
  def retryable_adopt_error?(_), do: false

  # Closed launch-retry allowlist only — never "any start_child error".
  @retryable_start_child_reasons [:max_children, :timeout]

  @doc """
  Pure retry allowlist for IntentOwner post-adopt worker launch failures.

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

  @doc """
  Pure retry allowlist for TaskStore pre-owner launcher failures.

  Distinct from IntentOwner worker-launch retries. Closed transient set only.
  Includes nested init-bind shapes (`{:launch_bind_failed, _}`) for store
  restart / timeout so a blocked bind call does not permanently exhaust.
  """
  @spec retryable_launcher_failure?(term()) :: boolean()
  def retryable_launcher_failure?(:max_children), do: true
  def retryable_launcher_failure?(:timeout), do: true
  def retryable_launcher_failure?({:timeout, _}), do: true
  def retryable_launcher_failure?(:launcher_exit), do: true
  def retryable_launcher_failure?(:store_restart), do: true
  def retryable_launcher_failure?(:bind_exit), do: true

  def retryable_launcher_failure?({:launch_bind_failed, reason}),
    do: retryable_launcher_failure?(reason)

  def retryable_launcher_failure?({:error, reason}), do: retryable_launcher_failure?(reason)
  def retryable_launcher_failure?(_), do: false

  @doc "Classify a Task.Supervisor.start_child error into a bounded atom or redacted tag."
  @spec classify_start_child_error(term()) :: term()
  def classify_start_child_error(:max_children), do: :max_children
  def classify_start_child_error(:timeout), do: :timeout
  def classify_start_child_error({:timeout, _}), do: :timeout
  def classify_start_child_error(:temporary), do: :temporary
  def classify_start_child_error({:already_started, _}), do: :already_started

  def classify_start_child_error(other),
    do: {:launch_failed, redact_error_reason(other)}

  # Closed allowlist of public/terminal error atoms. Never pass through raw
  # binaries, exception messages, or arbitrary atom/binary prefixes that may
  # embed restore_token / fingerprint / operation_id material.
  @safe_error_atoms MapSet.new([
                      :timeout,
                      :max_children,
                      :temporary,
                      :already_started,
                      :not_owner,
                      :not_found,
                      :conflict,
                      :busy,
                      :settling,
                      :witness_mismatch,
                      :branch_missing_after_witness,
                      :owner_down,
                      :worker_down,
                      :worker_failed,
                      :pre_effect_abort,
                      :launch_error,
                      :launch_failed,
                      :launch_exception,
                      :bind_failed,
                      :invalid_error_text,
                      :invalid_worker_payload,
                      :guarded_restore_exception,
                      :guarded_restore_exit,
                      :guarded_restore_failure,
                      :unexpected_result,
                      :outcome_unknown,
                      :claim_settled_non_applied,
                      :error,
                      :noproc,
                      :normal,
                      :shutdown,
                      :killed
                    ])

  @doc """
  Map external/binary/tuple reasons to a closed typed atom set before TaskStore
  settlement, waiter replies, logs, or durable reason_code derivation.

  Never returns a binary (invalid UTF-8 / oversized / secret-bearing text is
  collapsed to `:error`). Only documented safe atoms are retained.
  """
  @spec redact_error_reason(term()) :: atom()
  def redact_error_reason(reason) when is_atom(reason) do
    if MapSet.member?(@safe_error_atoms, reason), do: reason, else: :error
  end

  def redact_error_reason(reason) when is_binary(reason), do: :error

  def redact_error_reason({tag, _detail}) when is_atom(tag) do
    if MapSet.member?(@safe_error_atoms, tag), do: tag, else: :error
  end

  def redact_error_reason({tag, _, _}) when is_atom(tag) do
    if MapSet.member?(@safe_error_atoms, tag), do: tag, else: :error
  end

  def redact_error_reason([tag | _]) when is_atom(tag) do
    if MapSet.member?(@safe_error_atoms, tag), do: tag, else: :error
  end

  def redact_error_reason(_), do: :error

  # Restart inventory bounds (fail closed on overflow / malformation).
  @max_target_bytes 256
  @max_intent_id_bytes 64
  @max_fingerprint_bytes 80
  @target_re ~r/\Aagent_[A-Za-z0-9_-]+\z/
  # Owner inventory must remain compatible with already-running C3C1a0 owners.
  # Guarded snapshots are additionally bound to the strict durable claim during
  # merge, so accepting the established bounded owner grammar here cannot mint
  # or widen durable restore authority.
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
    # Authoritative owner is only the enumerated fixed-supervisor child PID.
    child_pid = Map.get(snap, :child_pid, Map.get(snap, "child_pid"))
    snap_owner = Map.get(snap, :owner_pid, Map.get(snap, "owner_pid"))
    snap_worker = Map.get(snap, :worker_pid, Map.get(snap, "worker_pid"))
    kind = Map.get(snap, :kind, Map.get(snap, "kind", :ordinary_start))
    operation_id = Map.get(snap, :operation_id, Map.get(snap, "operation_id"))
    restore_token = Map.get(snap, :restore_token, Map.get(snap, "restore_token"))

    with :ok <- validate_target(target),
         :ok <- validate_intent_id(intent_id),
         :ok <- validate_fingerprint(fingerprint),
         {:ok, kind} <- normalize_snapshot_kind(kind),
         {:ok, owner_pid} <- resolve_rebind_owner_pid(child_pid, snap_owner),
         {:ok, worker_pid} <- resolve_rebind_worker_pid(snap_worker, owner_pid) do
      base = %{
        intent_id: intent_id,
        target_agent_id: target,
        kind: kind,
        fingerprint: fingerprint,
        phase: if(is_pid(worker_pid), do: :worker_running, else: :outcome_unknown),
        owner_pid: owner_pid,
        worker_pid: worker_pid,
        terminal: nil,
        retire_barrier: :none,
        launch_ref: nil,
        launcher_pid: nil,
        launcher_mon: nil,
        launcher_attempt_index: 0,
        # Bound/live worker after restart without pre-handoff proof is post-handoff.
        effect_handoff?: kind == :guarded_restore and is_pid(worker_pid)
      }

      intent =
        if kind == :guarded_restore do
          base
          |> Map.put(:operation_id, operation_id)
          |> Map.put(:restore_token, restore_token)
        else
          base
        end

      if kind == :guarded_restore and
           (not is_binary(operation_id) or not is_binary(restore_token)) do
        {:error, :invalid_snapshot}
      else
        {:ok, intent}
      end
    end
  end

  defp validate_snapshot(_), do: {:error, :invalid_snapshot}

  defp normalize_snapshot_kind(:ordinary_start), do: {:ok, :ordinary_start}
  defp normalize_snapshot_kind(:guarded_restore), do: {:ok, :guarded_restore}
  defp normalize_snapshot_kind("ordinary_start"), do: {:ok, :ordinary_start}
  defp normalize_snapshot_kind("guarded_restore"), do: {:ok, :guarded_restore}
  defp normalize_snapshot_kind(_), do: {:error, :invalid_snapshot}

  # Restart authority is only the enumerated fixed-supervisor child PID.
  # Snapshot owner_pid, if present, must equal child_pid; never an independent source.
  defp resolve_rebind_owner_pid(child_pid, snap_owner)
       when is_pid(child_pid) and is_pid(snap_owner) and child_pid != snap_owner do
    {:error, :invalid_snapshot}
  end

  defp resolve_rebind_owner_pid(child_pid, snap_owner)
       when is_pid(child_pid) and (is_pid(snap_owner) or is_nil(snap_owner)),
       do: {:ok, child_pid}

  defp resolve_rebind_owner_pid(_child_pid, _snap_owner), do: {:error, :invalid_snapshot}

  # Worker authority comes only from the enumerated fixed owner's snapshot.
  # A dead PID is still safe: the shell's new monitor immediately delivers DOWN.
  defp resolve_rebind_worker_pid(nil, _owner_pid), do: {:ok, nil}

  defp resolve_rebind_worker_pid(worker_pid, owner_pid)
       when is_pid(worker_pid) and worker_pid != owner_pid,
       do: {:ok, worker_pid}

  defp resolve_rebind_worker_pid(_worker_pid, _owner_pid), do: {:error, :invalid_snapshot}

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
end
