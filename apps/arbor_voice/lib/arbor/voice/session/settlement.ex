defmodule Arbor.Voice.Session.Settlement do
  @moduledoc """
  Crash-safe budget settlement primitive shared by `Arbor.Voice.Session` and its
  `Arbor.Voice.ResourceOwner` cleanup (VP-04D1 — VOICE-24 prerequisite).

  This is a **data primitive, not a process**: an immutable struct wrapping a
  `Arbor.Voice.BudgetLedger.Reservation`, an injected ledger module + closed
  `opts`, a captured monotonic start time, and private `:atomics` refs
  (permanent effect selection, phase, frozen elapsed). It is deliberately not
  a GenServer, Agent, ETS owner, supervised child, or registered process: a
  `ResourceOwner` cleanup closure retains this struct directly, so the
  atomics — ordinary reference-counted Erlang resources, not process state —
  outlive the `Session` that constructed it.

  Effect selection is a permanent, owner-independent decision among
  `undecided`, `release`, and `consume`. It is never an in-progress claim and
  is never cleared: a caller that dies immediately after selection leaves the
  next caller able to replay the same selected effect. `arm_consume/1`
  selects consume before publishing `:consume_pending`. `settle/2` selects
  the effect before any ledger IO and follows whichever selection won, even
  when a concurrent arm raced a release-intent settler.

  There is no `settling`/`in_progress` phase. Every settlement starts
  `:release_pending` (the default outcome — return the reservation unused),
  can be armed once into `:consume_pending` (the session actually used the
  budget), and ends `:done` only after the injected ledger call returns `:ok`.
  Until `:done`, `settle/2` is a safe, idempotent replay point: a caller
  (typically a `Task`) can die at any point up to and including durable ledger
  acceptance, and the next caller sees the same pending phase and — for
  consume — the exact same frozen elapsed value, because that value is
  written to its atomics ref *before* the ledger call, not after.

  `settle/2` never catches exits or errors from the injected ledger call: an
  uncertain outcome (the calling process died, or the ledger raised) must not
  be converted into `:done`. Only an explicit `:ok` return advances the phase.
  Every `:ok` from `settle/2` corresponds to `phase/1 == :done`.
  """

  alias Arbor.Voice.BudgetLedger.Reservation

  @enforce_keys [
    :reservation,
    :ledger,
    :ledger_opts,
    :start_ms,
    :effect_ref,
    :phase_ref,
    :elapsed_ref
  ]
  defstruct [
    :reservation,
    :ledger,
    :ledger_opts,
    :start_ms,
    :effect_ref,
    :phase_ref,
    :elapsed_ref
  ]

  @type phase :: :release_pending | :consume_pending | :done

  @type t :: %__MODULE__{
          reservation: Reservation.t(),
          ledger: module(),
          ledger_opts: keyword(),
          start_ms: integer(),
          effect_ref: :atomics.atomics_ref(),
          phase_ref: :atomics.atomics_ref(),
          elapsed_ref: :atomics.atomics_ref()
        }

  # Permanent effect selection — never cleared, never an in-progress claim.
  @effect_undecided 0
  @effect_release 1
  @effect_consume 2

  @phase_release_pending 0
  @phase_consume_pending 1
  @phase_done 2

  @elapsed_unset -1

  @doc """
  Construct a settlement for `reservation`, defaulting to `:release_pending`.

  `ledger` is an injected module exposing `consume/3` and `release/2` with
  the same contract as `Arbor.Voice.BudgetLedger` — never hardcoded.
  `ledger_opts` is a closed keyword list passed verbatim to every ledger call.
  `start_ms` is the caller's captured monotonic start time (`System.monotonic_time/1`
  at the shell boundary — this module never reads the clock).

  Rejects malformed input without raising.
  """
  @spec new(Reservation.t(), module(), keyword(), integer()) :: {:ok, t()} | {:error, atom()}
  def new(reservation, ledger, ledger_opts, start_ms) do
    cond do
      not valid_reservation?(reservation) ->
        {:error, :invalid_reservation}

      not valid_ledger?(ledger) ->
        {:error, :invalid_ledger}

      not valid_ledger_opts?(ledger_opts) ->
        {:error, :invalid_ledger_opts}

      not is_integer(start_ms) ->
        {:error, :invalid_start_ms}

      true ->
        effect_ref = :atomics.new(1, signed: false)
        phase_ref = :atomics.new(1, signed: false)
        elapsed_ref = :atomics.new(1, signed: true)
        :atomics.put(effect_ref, 1, @effect_undecided)
        :atomics.put(phase_ref, 1, @phase_release_pending)
        :atomics.put(elapsed_ref, 1, @elapsed_unset)

        {:ok,
         %__MODULE__{
           reservation: reservation,
           ledger: ledger,
           ledger_opts: ledger_opts,
           start_ms: start_ms,
           effect_ref: effect_ref,
           phase_ref: phase_ref,
           elapsed_ref: elapsed_ref
         }}
    end
  end

  @doc """
  Arm consume mode: the session actually used budget and `settle/2` should
  call `ledger.consume/3` instead of `ledger.release/2`.

  Atomically selects the permanent consume effect before publishing
  `:consume_pending`. Idempotent while consume is already selected and the
  cell is not yet done. Fails when release has already been selected (a
  settler won the linearizable effect race) or when the settlement is
  already `:done`.
  """
  @spec arm_consume(t()) :: :ok | {:error, :already_done | :release_selected}
  def arm_consume(%__MODULE__{effect_ref: effect_ref, phase_ref: phase_ref}) do
    case :atomics.get(phase_ref, 1) do
      @phase_done ->
        {:error, :already_done}

      _pending ->
        case select_consume(effect_ref) do
          :ok ->
            _ = publish_consume_pending(phase_ref)

            case :atomics.get(phase_ref, 1) do
              @phase_done -> {:error, :already_done}
              _ -> :ok
            end

          {:error, _reason} = error ->
            error
        end
    end
  end

  @doc """
  Settle: perform the pending effect (release or consume) against the
  injected ledger, using the explicit monotonic `now_ms` supplied by the
  caller (this module never reads the clock).

  Atomically selects the permanent effect before any ledger IO. If release
  selection wins, later arming fails and every replay releases. If consume
  selection wins, every settler follows consume — even a settler that first
  observed `:release_pending` before losing the selection CAS.

  Returns `:ok` once the settlement reaches `:done` — including when it was
  already `:done` on entry (idempotent). Returns the ledger's `{:error, _}`
  unchanged when the ledger call fails; the phase stays pending so a later
  `settle/2` call replays with identical arguments. Does not catch exits —
  an uncertain ledger outcome (this process dies mid-call) must remain
  replayable, never `:done`. Every successful `:ok` corresponds to
  `phase/1 == :done`.
  """
  @spec settle(t(), integer()) :: :ok | {:error, term()}
  def settle(%__MODULE__{} = settlement, now_ms) when is_integer(now_ms) do
    case phase(settlement) do
      :done -> :ok
      observed -> settle_pending(settlement, now_ms, observed)
    end
  end

  def settle(%__MODULE__{}, _now_ms), do: {:error, :invalid_now_ms}

  @doc """
  Bounded phase observation for tests/status.

  Reconciles a permanent consume selection that has not yet published
  `:consume_pending` so caller death between selection and phase publication
  cannot expose a contradictory durable mode.
  """
  @spec phase(t()) :: phase()
  def phase(%__MODULE__{phase_ref: phase_ref, effect_ref: effect_ref}) do
    case :atomics.get(phase_ref, 1) do
      @phase_done ->
        :done

      @phase_consume_pending ->
        :consume_pending

      @phase_release_pending ->
        case :atomics.get(effect_ref, 1) do
          @effect_consume -> :consume_pending
          _ -> :release_pending
        end
    end
  end

  @doc """
  Bounded frozen-elapsed observation for tests/status. `nil` until the first
  `settle/2` call in consume mode has frozen a value; a stable non-negative
  integer clamped to `reservation.requested_ms` thereafter.
  """
  @spec frozen_elapsed(t()) :: non_neg_integer() | nil
  def frozen_elapsed(%__MODULE__{elapsed_ref: ref}) do
    case :atomics.get(ref, 1) do
      @elapsed_unset -> nil
      value -> value
    end
  end

  # ---------------------------------------------------------------------------
  # Effect selection + dispatch
  # ---------------------------------------------------------------------------

  defp settle_pending(settlement, now_ms, observed) do
    desired =
      case observed do
        :consume_pending -> @effect_consume
        :release_pending -> @effect_release
      end

    case select_or_follow(settlement.effect_ref, desired) do
      @effect_release -> do_release(settlement)
      @effect_consume -> do_consume(settlement, now_ms)
    end
  end

  # Select `desired` if still undecided; otherwise follow the permanent winner.
  defp select_or_follow(effect_ref, desired) do
    case :atomics.compare_exchange(effect_ref, 1, @effect_undecided, desired) do
      :ok -> desired
      @effect_release -> @effect_release
      @effect_consume -> @effect_consume
    end
  end

  defp select_consume(effect_ref) do
    case :atomics.compare_exchange(effect_ref, 1, @effect_undecided, @effect_consume) do
      :ok -> :ok
      @effect_consume -> :ok
      @effect_release -> {:error, :release_selected}
    end
  end

  defp publish_consume_pending(phase_ref) do
    case :atomics.compare_exchange(
           phase_ref,
           1,
           @phase_release_pending,
           @phase_consume_pending
         ) do
      :ok -> :ok
      @phase_consume_pending -> :ok
      @phase_done -> :done
    end
  end

  defp do_release(settlement) do
    case settlement.ledger.release(settlement.reservation, settlement.ledger_opts) do
      :ok -> mark_done(settlement, @phase_release_pending)
      {:error, _reason} = error -> error
    end
  end

  defp do_consume(settlement, now_ms) do
    case publish_consume_pending(settlement.phase_ref) do
      :done ->
        :ok

      :ok ->
        frozen_elapsed_ms = freeze_elapsed(settlement, now_ms)

        case settlement.ledger.consume(
               settlement.reservation,
               frozen_elapsed_ms,
               settlement.ledger_opts
             ) do
          :ok -> mark_done(settlement, @phase_consume_pending)
          {:error, _reason} = error -> error
        end
    end
  end

  # Atomically freeze the elapsed value exactly once, before ledger IO. Every
  # caller — original or replay — that reaches ledger IO uses this exact
  # frozen integer, never a value recomputed from a later `now_ms`.
  defp freeze_elapsed(settlement, now_ms) do
    candidate =
      now_ms
      |> Kernel.-(settlement.start_ms)
      |> max(0)
      |> min(settlement.reservation.requested_ms)

    case :atomics.compare_exchange(settlement.elapsed_ref, 1, @elapsed_unset, candidate) do
      :ok -> candidate
      existing when is_integer(existing) -> existing
    end
  end

  # Marks done only after the ledger call above returned an explicit :ok. A
  # failed completion CAS is success only when another caller already
  # published :done; any other mismatch is an invariant error so settle/2
  # never reports :ok while the cell remains pending.
  defp mark_done(settlement, from_phase) do
    case :atomics.compare_exchange(settlement.phase_ref, 1, from_phase, @phase_done) do
      :ok ->
        :ok

      @phase_done ->
        :ok

      _other ->
        case :atomics.get(settlement.phase_ref, 1) do
          @phase_done -> :ok
          _ -> {:error, :invariant_violation}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Validation — reject malformed input without raising
  # ---------------------------------------------------------------------------

  defp valid_reservation?(%Reservation{
         id: id,
         key: key,
         utc_day: utc_day,
         requested_ms: requested_ms,
         reserved_at_ms: reserved_at_ms,
         expires_at_ms: expires_at_ms
       }) do
    is_binary(id) and is_binary(key) and is_binary(utc_day) and
      is_integer(requested_ms) and requested_ms > 0 and
      is_integer(reserved_at_ms) and reserved_at_ms >= 0 and
      is_integer(expires_at_ms) and expires_at_ms >= 0
  end

  defp valid_reservation?(_), do: false

  defp valid_ledger?(ledger) when is_atom(ledger) and not is_nil(ledger) do
    function_exported?(ledger, :consume, 3) and function_exported?(ledger, :release, 2)
  end

  defp valid_ledger?(_), do: false

  defp valid_ledger_opts?(opts), do: Keyword.keyword?(opts)
end
