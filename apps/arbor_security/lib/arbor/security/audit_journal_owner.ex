defmodule Arbor.Security.AuditJournalOwner do
  @moduledoc """
  Supervised single-writer owner for the v1 Security authority-mutation audit journal.

  Serializes every append over `AuditJournalCore` and, in durable mode,
  `AuditJournalFile`. Reconstructs from the durable log before serving.
  Production callers outside this library use `Arbor.Security` status and
  pending facades only.

  Durable capacity exhaustion may publish one compaction then retry the exact
  record once when the publication relieves the refused record
  (`AuditJournalCore.publication_relieves?/3`). A re-proven
  `{:not_published, _}` keeps the old handle and the original capacity error.
  `{:source_invalid, _}` and `:closed` poison as
  `{:not_committed, :source_invalid}`. `{:publish_uncertain, _}` poisons as
  `{:commit_uncertain, reason}`.

  Terminal-identity retirement (durable operational journals; see
  `Arbor.Security.AuditJournalFile`): delivered identities leave the hot set
  only inside a retiring publication, which first writes them to the cold
  retirement ledger. Three triggers, all through `AuditJournalFile.compact/2`
  with `retire: true`:

  - T1 (boot): `init/1` calls `AuditJournalFile.ensure_retirement_current/1`
    after profile promotion. It never stops the owner: `{:not_published, _}`
    serves with the kept handle (warning, `retirement.last_error`, backoff
    armed); an uncertain outcome serves poisoned exactly like a runtime
    publication fault.
  - T2 (acknowledgement): once `retire_batch` delivered identities are
    retirable, the triggering acknowledgement is replied to first and the
    publication runs in `handle_continue/2`. The next message in the mailbox
    (the next acknowledgement of the same batch, a concurrent prepare) waits
    for it. After every attempt the next T2 is armed at
    `retirable + retire_batch`.
  - T3 (capacity relief): a refused append publishes once when that could
    admit the exact refused record, then retries the same raw record.

  A publication `{:not_published, _}` from T2/T3, and every T2/T3 attempt
  while the ledger is paused, arms a 5 s publication backoff (monotonic
  clock) inside which T2 is skipped and T3 returns the capacity error without
  publishing. The small profile never retires and keeps its historical
  compaction behavior (no backoff).

  A paused ledger (`:mismatch | :ahead`) is logged once (`Logger.error`) and
  reported in status; publications keep running non-retiring and retirement
  headroom counts as zero.

  `prepare` answers `{:error, :operation_terminal}` for every terminal
  identity (compacted or not), continues a pending v1/v2 operation when a v3
  intent of identical facts arrives (only while such an operation is
  pending), and records the last identity/capacity refusal in status.

  Not a generic store. CapabilityStore prepares and observes mutations; the
  registered Historian consumer acknowledges exact durable event content.
  """

  use GenServer

  require Logger

  alias Arbor.Security.AuditJournalCore
  alias Arbor.Security.AuditJournalFile
  alias Arbor.Security.Config
  alias Arbor.Security.Contracts.AuditJournal

  @allowed_opts if(Mix.env() == :test,
                  do: [:mode, :root, :reason, :name, :capacity_profile, :inject],
                  else: [:mode, :root, :reason, :capacity_profile]
                )
  @disabled_reasons [:disabled, :activation_only]
  @pending_statuses ["prepared", "effect_applied"]
  @refusals [:soft_capacity_exhausted, :capacity_exhausted, :retired_version]
  @paused_postures [:mismatch, :ahead]
  @publication_backoff_ms 5_000

  @type append_ok :: {:ok, :committed} | {:ok, :idempotent}
  @type append_error ::
          {:error,
           :journal_disabled
           | :journal_poisoned
           | :journal_unavailable
           | :malformed
           | :out_of_order
           | :illegal_transition
           | :post_terminal
           | :operation_conflict
           | :cross_operation
           | :record_too_large
           | :soft_capacity_exhausted
           | :capacity_exhausted
           | :retired_version
           | {:not_committed, term()}
           | {:commit_uncertain, term()}}

  @spec start_link(keyword()) :: GenServer.on_start() | {:error, :invalid_opts}
  def start_link(opts \\ [])

  def start_link(opts) when is_list(opts) do
    with :ok <- reject_unknown_opts(opts),
         {:ok, boot} <- admit_boot_opts(opts) do
      GenServer.start_link(__MODULE__, boot, name: boot.name)
    end
  end

  def start_link(_opts), do: {:error, :invalid_opts}

  @spec append(term()) :: append_ok() | append_error()
  def append(raw), do: do_append(__MODULE__, raw)

  @spec status() :: {:ok, map()} | {:error, :journal_unavailable}
  def status, do: do_query(__MODULE__, :status)

  @spec pending_operations() :: {:ok, [map()]} | {:error, :journal_unavailable}
  def pending_operations, do: do_query(__MODULE__, :pending_operations)

  @doc false
  def prepare(intent), do: safe_call(__MODULE__, {:prepare, intent}, :append)

  @doc false
  def observe(operation_id, observation),
    do: safe_call(__MODULE__, {:observe, operation_id, observation}, :append)

  @doc false
  def pending_intents, do: do_query(__MODULE__, :pending_intents)

  @doc false
  def delivery_batch, do: do_query(__MODULE__, :delivery_batch)

  @doc false
  def acknowledge_delivery(id, digest),
    do: safe_call(__MODULE__, {:acknowledge_delivery, id, digest}, :append)

  if Mix.env() == :test do
    @doc false
    @spec append(GenServer.server(), term()) :: append_ok() | append_error()
    def append(server, raw), do: do_append(server, raw)

    @doc false
    @spec status(GenServer.server()) :: {:ok, map()} | {:error, :journal_unavailable}
    def status(server), do: do_query(server, :status)

    @doc false
    @spec pending_operations(GenServer.server()) ::
            {:ok, [map()]} | {:error, :journal_unavailable}
    def pending_operations(server), do: do_query(server, :pending_operations)

    @doc false
    def prepare(server, intent), do: safe_call(server, {:prepare, intent}, :append)

    @doc false
    def observe(server, operation_id, observation),
      do: safe_call(server, {:observe, operation_id, observation}, :append)

    @doc false
    def pending_intents(server), do: do_query(server, :pending_intents)

    @doc false
    def delivery_batch(server), do: do_query(server, :delivery_batch)

    @doc false
    def acknowledge_delivery(server, id, digest),
      do: safe_call(server, {:acknowledge_delivery, id, digest}, :append)

    @doc false
    @spec __test_inject__(GenServer.server(), :clear) :: :ok | {:error, :journal_unavailable}
    def __test_inject__(server, :clear) do
      safe_call(server, {:__test_inject__, :clear}, :query)
    end

    @doc false
    @spec __test_inject__(GenServer.server(), atom()) :: :ok | {:error, :journal_unavailable}
    def __test_inject__(server, kind)
        when is_atom(kind) and kind != :clear do
      safe_call(server, {:__test_inject__, kind}, :query)
    end

    @doc false
    @spec __test_inject__(GenServer.server(), atom(), term()) ::
            :ok | {:error, :journal_unavailable}
    def __test_inject__(server, kind, value) do
      safe_call(server, {:__test_inject__, kind, value}, :query)
    end
  end

  @impl true
  def init(%{mode: :disabled, reason: reason}) do
    {:ok, core} = AuditJournalCore.new()

    {:ok,
     owner_state(
       core: core,
       mode: :disabled,
       durability: :dormant,
       availability: :dormant,
       reason: reason,
       last_error: :disabled,
       serving: false
     )}
  end

  def init(%{mode: :ephemeral, capacity_profile: profile}) do
    {:ok, core} = AuditJournalCore.new(profile)

    {:ok,
     owner_state(
       core: core,
       mode: :ephemeral,
       durability: :ephemeral,
       availability: :serving,
       reason: :none,
       last_error: :none,
       serving: true
     )}
  end

  def init(%{mode: :durable, root: root, capacity_profile: profile} = boot) do
    apply_boot_injects(boot)

    opened =
      with {:ok, handle} <- AuditJournalFile.open(root: root),
           do: AuditJournalFile.ensure_capacity_profile(handle, profile)

    case opened do
      {:ok, handle} ->
        torn? = handle.torn_tail != nil

        state =
          owner_state(
            core: handle.core,
            handle: handle,
            committed_frames: handle.frames,
            torn_tail?: torn?,
            mode: :durable,
            durability: :durable,
            availability: if(torn?, do: :degraded, else: :serving),
            reason: if(torn?, do: :torn_tail, else: :none),
            last_error: if(torn?, do: :torn_tail, else: :none),
            serving: not torn?,
            ledger_state: ledger_posture(handle)
          )

        {:ok, state |> note_ledger_posture(:open) |> boot_retirement()}

      {:error, reason} ->
        {:stop, {:journal_open_failed, reason}}
    end
  end

  def init(_boot), do: {:stop, :invalid_opts}

  @impl true
  def handle_call({:append, _raw}, _from, %{mode: :disabled} = state) do
    {:reply, {:error, :journal_disabled}, state}
  end

  def handle_call({:append, _raw}, _from, %{poisoned?: true} = state) do
    {:reply, {:error, :journal_poisoned}, state}
  end

  def handle_call({:append, _raw}, _from, %{torn_tail?: true} = state) do
    {:reply, {:error, {:not_committed, :torn_tail}}, mark_torn(state)}
  end

  def handle_call({:append, raw}, _from, %{mode: :durable} = state) do
    apply_durable_append(state, raw)
  end

  def handle_call({:append, raw}, _from, %{mode: :ephemeral} = state) do
    apply_ephemeral_append(state, raw)
  end

  def handle_call(:status, _from, state) do
    {:reply, build_status(state), state}
  end

  def handle_call(:pending_operations, _from, state) do
    {:reply, build_pending_operations(state), state}
  end

  def handle_call(:pending_intents, _from, state) do
    {:reply, {:ok, AuditJournalCore.pending_intents(state.core)}, state}
  end

  def handle_call(:delivery_batch, from, state) do
    reply =
      if authorized_consumer?(from),
        do: {:ok, AuditJournalCore.delivery_batch(state.core)},
        else: {:error, :unauthorized_audit_consumer}

    {:reply, reply, state}
  end

  def handle_call({:acknowledge_delivery, id, digest}, from, state) do
    cond do
      not authorized_consumer?(from) ->
        {:reply, {:error, :unauthorized_audit_consumer}, state}

      not AuditJournalCore.acknowledgement_matches?(state.core, id, digest) ->
        {:reply, {:error, :audit_content_conflict}, state}

      true ->
        case AuditJournalCore.operation(state.core, id) do
          {:ok, %{"status" => "delivered"}} ->
            {:reply, {:ok, :idempotent}, state}

          _ ->
            {:reply, reply, next} =
              handle_call({:append, mutation_record(id, "delivered", timestamp())}, from, state)

            # T2: the triggering acknowledgement is answered before the
            # publication; the next mailbox message waits for it.
            if t2_due?(next),
              do: {:reply, reply, next, {:continue, :retire}},
              else: {:reply, reply, next}
        end
    end
  end

  def handle_call({:prepare, raw}, from, state) do
    case AuditJournal.admit_intent(raw) do
      {:ok, intent} -> prepare_admitted(intent, from, state)
      _ -> {:reply, {:error, :malformed}, state}
    end
  end

  def handle_call({:observe, operation_id, observation}, from, state)
      when observation == :applied or
             observation in [
               {:rejected, "before_mismatch"},
               {:rejected, "identity_conflict"},
               {:rejected, "not_found"},
               {:rejected, "cas_conflict"}
             ] do
    case AuditJournalCore.operation(state.core, operation_id) do
      {:ok, %{"intent" => intent, "status" => "prepared"}} ->
        {type, data} =
          case observation do
            :applied ->
              {"effect_applied",
               %{"kind" => "applied", "after_fingerprint" => intent["after_fingerprint"]}}

            {:rejected, reason} ->
              {"effect_rejected", %{"kind" => "rejected", "reason" => reason}}
          end

        record = mutation_record(operation_id, type, timestamp()) |> Map.put("observation", data)
        handle_call({:append, record}, from, state)

      {:ok, %{"status" => status}}
      when status in ["effect_applied", "delivered"] and observation == :applied ->
        {:reply, {:ok, :idempotent}, state}

      _ ->
        {:reply, {:error, :out_of_order}, state}
    end
  end

  def handle_call({:observe, _id, _observation}, _from, state),
    do: {:reply, {:error, :malformed}, state}

  if Mix.env() == :test do
    @impl true
    def handle_call({:__test_inject__, :clear}, _from, state) do
      {:reply, AuditJournalFile.__test_inject__(:clear), state}
    end

    def handle_call({:__test_inject__, kind}, _from, state) when is_atom(kind) do
      {:reply, AuditJournalFile.__test_inject__(kind), state}
    end

    def handle_call({:__test_inject__, kind, value}, _from, state) do
      {:reply, AuditJournalFile.__test_inject__(kind, value), state}
    end
  end

  @impl true
  def handle_continue(:retire, state) do
    if publication_ready?(state),
      do: {:noreply, run_t2(state)},
      else: {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{handle: handle}) when not is_nil(handle) do
    AuditJournalFile.close(handle)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def format_status(status) when is_map(status) do
    owner_state = Map.get(status, :state, %{})

    redacted = %{
      mode: Map.get(owner_state, :mode),
      availability: Map.get(owner_state, :availability),
      poisoned: Map.get(owner_state, :poisoned?, false),
      torn_tail: Map.get(owner_state, :torn_tail?, false)
    }

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, redacted)
    |> redact_field(:reason)
    |> redact_field(:log)
  end

  defp apply_durable_append(state, raw) do
    finish_durable_append(AuditJournalFile.append(state.handle, raw), state, raw, :first)
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp authorized_consumer?({pid, _tag}) do
    case Config.authority_audit_consumer_name() do
      name when is_atom(name) and not is_nil(name) -> pid == Process.whereis(name)
      _ -> false
    end
  end

  defp mutation_record(operation_id, type, occurred_at) do
    %{
      "version" => 1,
      "kind" => "arbor.security.authority_mutation_record.v1",
      "record_type" => type,
      "operation_id" => operation_id,
      "occurred_at" => occurred_at
    }
  end

  defp finish_durable_append({:ok, handle}, state, _raw, _phase) do
    {:reply, {:ok, :committed}, commit_handle(state, handle)}
  end

  defp finish_durable_append({:ok, handle, :idempotent}, state, _raw, _phase) do
    {:reply, {:ok, :idempotent}, commit_handle(state, handle)}
  end

  defp finish_durable_append({:error, {:commit_uncertain, _reason} = err}, state, _raw, _phase) do
    {:reply, {:error, err}, poison(state, :commit_uncertain)}
  end

  defp finish_durable_append({:error, {:not_committed, :torn_tail} = err}, state, _raw, _phase) do
    {:reply, {:error, err}, mark_torn(state)}
  end

  defp finish_durable_append({:error, {:not_committed, _reason} = err}, state, _raw, _phase) do
    {:reply, {:error, err}, poison(state, :not_committed)}
  end

  defp finish_durable_append({:error, reason}, state, raw, :first)
       when reason in [:soft_capacity_exhausted, :capacity_exhausted] do
    maybe_compact_and_retry(state, raw, {:error, reason})
  end

  defp finish_durable_append({:error, reason}, state, _raw, _phase) do
    {:reply, {:error, reason}, state}
  end

  # T3. The publication is attempted only when it could admit the exact
  # refused record (`publication_relieves?/3`, with no retirement headroom
  # while the ledger is paused) and no publication backoff is running.
  defp maybe_compact_and_retry(state, raw, cap_err) do
    cond do
      backing_off?(state) ->
        {:reply, cap_err, state}

      AuditJournalCore.publication_relieves?(state.core, raw, effective_retirable(state)) ->
        publish_and_retry(state, raw, cap_err)

      true ->
        {:reply, cap_err, state}
    end
  end

  # No record carries a retirement epoch, so the single retry re-appends the
  # caller's exact raw record.
  defp publish_and_retry(state, raw, cap_err) do
    started = now_ms()
    paused_before? = paused?(state)

    case AuditJournalFile.compact(state.handle, retire: true) do
      {:ok, handle} ->
        adopted =
          state
          |> adopt_publication(handle, :capacity, started)
          |> after_publication_attempt(paused_before?)

        finish_durable_append(AuditJournalFile.append(adopted.handle, raw), adopted, raw, :retry)

      {:error, {:not_published, reason}} ->
        {:reply, cap_err,
         state
         |> publication_not_published(reason, :capacity, started)
         |> after_publication_attempt(paused_before?)}

      {:error, {:publish_uncertain, reason}} ->
        {:reply, {:error, {:commit_uncertain, reason}},
         publication_uncertain(state, {:publish_uncertain, reason}, :capacity, started)}

      {:error, other} ->
        {:reply, {:error, {:not_committed, :source_invalid}},
         publication_uncertain(state, other, :capacity, started)}
    end
  end

  # T1. Never `{:stop, _}`: a persistent post-rename fault must not become a
  # supervisor restart loop. A torn-tail journal is not serving and is left
  # to the file layer's skip; T1 ignores the publication backoff.
  defp boot_retirement(%{serving: true, handle: handle} = state) when not is_nil(handle) do
    started = now_ms()

    case AuditJournalFile.ensure_retirement_current(handle) do
      {:ok, ^handle} ->
        state

      {:ok, published} ->
        state
        |> adopt_publication(published, :boot, started)
        |> rearm_t2()

      {:not_published, reason, kept} ->
        %{state | handle: kept}
        |> publication_not_published(reason, :boot, started)
        |> rearm_t2()

      {:uncertain, reason} ->
        publication_uncertain(state, reason, :boot, started)
    end
  end

  defp boot_retirement(state), do: state

  # T2 body, run from handle_continue after the triggering reply was sent.
  defp run_t2(state) do
    started = now_ms()
    paused_before? = paused?(state)

    case AuditJournalFile.compact(state.handle, retire: true) do
      {:ok, handle} ->
        state
        |> adopt_publication(handle, :acknowledge, started)
        |> after_publication_attempt(paused_before?)

      {:error, {:not_published, reason}} ->
        state
        |> publication_not_published(reason, :acknowledge, started)
        |> after_publication_attempt(paused_before?)

      {:error, other} ->
        publication_uncertain(state, other, :acknowledge, started)
    end
  end

  defp t2_due?(state) do
    publication_ready?(state) and operational?(state) and not backing_off?(state) and
      AuditJournalCore.retirable_count(state.core) >= state.t2_armed_at
  end

  defp publication_ready?(state) do
    state.mode == :durable and state.serving and not state.poisoned? and
      not state.torn_tail? and not is_nil(state.handle)
  end

  defp adopt_publication(state, handle, trigger, started) do
    prior_total = retired_total(state.core)
    adopted = commit_handle(state, handle)

    if operational?(adopted) do
      retired = retired_total(adopted.core) - prior_total
      duration = now_ms() - started
      frames = ledger_frames(adopted.core)

      Logger.info(
        "Security audit journal publication (#{trigger}): retired #{retired} delivered " <>
          "identities, retired_total #{retired_total(adopted.core)}, ledger frames #{frames}, " <>
          "ledger #{adopted.ledger_state}, duration_ms #{duration}"
      )

      :telemetry.execute(
        [:arbor, :security, :audit_journal, :retired],
        %{count: retired, duration_ms: duration},
        %{
          trigger: trigger,
          retired_total: retired_total(adopted.core),
          ledger_frames: frames,
          ledger_state: adopted.ledger_state
        }
      )

      %{adopted | retirement_error: :none}
      |> note_ledger_posture(:publication)
    else
      adopted
    end
  end

  defp publication_not_published(state, reason, trigger, started) do
    if operational?(state) do
      duration = now_ms() - started

      Logger.warning(
        "Security audit journal publication (#{trigger}) was not published: #{reason}; " <>
          "nothing retired, the journal is unchanged; next attempt after " <>
          "#{@publication_backoff_ms} ms"
      )

      :telemetry.execute(
        [:arbor, :security, :audit_journal, :publication_failed],
        %{duration_ms: duration},
        %{trigger: trigger, outcome: :not_published, reason: reason}
      )

      arm_backoff(%{state | retirement_error: reason})
    else
      state
    end
  end

  defp publication_uncertain(state, reason, trigger, started) do
    duration = now_ms() - started
    class = uncertain_class(reason)

    if operational?(state) do
      Logger.error(
        "Security audit journal publication (#{trigger}) is #{class}; the journal owner " <>
          "is poisoned until restart"
      )

      :telemetry.execute(
        [:arbor, :security, :audit_journal, :publication_failed],
        %{duration_ms: duration},
        %{trigger: trigger, outcome: class, reason: uncertain_reason(reason)}
      )
    end

    case class do
      :publish_uncertain -> poison(state, :commit_uncertain)
      :source_invalid -> poison(state, :not_committed)
    end
  end

  defp uncertain_class({:publish_uncertain, _reason}), do: :publish_uncertain
  defp uncertain_class(_other), do: :source_invalid

  defp uncertain_reason({class, reason})
       when class in [:publish_uncertain, :source_invalid] and is_atom(reason),
       do: reason

  defp uncertain_reason(reason) when is_atom(reason), do: reason
  defp uncertain_reason(_reason), do: :unknown

  defp after_publication_attempt(state, paused_before?) do
    if operational?(state) do
      state = rearm_t2(state)
      if paused_before? or paused?(state), do: arm_backoff(state), else: state
    else
      state
    end
  end

  defp rearm_t2(state) do
    %{state | t2_armed_at: AuditJournalCore.retirable_count(state.core) + retire_batch()}
  end

  defp arm_backoff(state),
    do: %{state | publication_backoff_until: now_ms() + @publication_backoff_ms}

  defp backing_off?(%{publication_backoff_until: nil}), do: false
  defp backing_off?(%{publication_backoff_until: until}), do: now_ms() < until

  defp note_ledger_posture(state, occasion) do
    if paused?(state) and not state.ledger_pause_logged? do
      Logger.error(
        "Security audit journal retirement ledger is #{state.ledger_state} (#{occasion}): " <>
          "publications run non-retiring and delivered identities stay hot; increases " <>
          "refuse once 3072 identities are retained and reductions run unjournaled at 4096. " <>
          "Restore the matching journal/ledger pair (never delete either)."
      )

      :telemetry.execute(
        [:arbor, :security, :audit_journal, :ledger_paused],
        %{count: 1},
        %{ledger_state: state.ledger_state, occasion: occasion}
      )

      %{state | ledger_pause_logged?: true}
    else
      state
    end
  end

  # Retirement headroom only exists where a retiring publication is reachable:
  # a durable operational journal whose ledger is not paused.
  defp retiring?(state) do
    state.mode == :durable and operational?(state) and not paused?(state)
  end

  defp effective_retirable(state) do
    if retiring?(state), do: AuditJournalCore.retirable_count(state.core), else: 0
  end

  defp paused?(state), do: state.ledger_state in @paused_postures
  defp operational?(state), do: AuditJournalCore.profile(state.core) == :operational

  defp ledger_posture(handle) do
    if AuditJournalCore.profile(handle.core) == :operational,
      do: AuditJournalFile.ledger_state(handle),
      else: :none
  end

  defp retired_total(core),
    do: AuditJournal.snapshot_retirement(Map.get(core, "snapshot"))["retired_total"]

  defp ledger_frames(core),
    do: AuditJournal.snapshot_retirement(Map.get(core, "snapshot"))["ledger"]["frames"]

  defp retire_batch, do: AuditJournal.limits(:operational).retire_batch
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp apply_ephemeral_append(state, raw) do
    case AuditJournalCore.append(state.core, raw) do
      {:ok, core} ->
        {:reply, {:ok, :committed}, %{state | core: core, last_error: :none}}

      {:ok, core, :idempotent} ->
        {:reply, {:ok, :idempotent}, %{state | core: core, last_error: :none}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp commit_handle(state, handle) do
    %{
      state
      | handle: handle,
        core: handle.core,
        committed_frames: handle.frames,
        last_error: :none,
        torn_tail?: false,
        poisoned?: false,
        availability: :serving,
        reason: :none,
        serving: true,
        ledger_state: ledger_posture(handle)
    }
  end

  defp poison(state, last_error) do
    if state.handle, do: AuditJournalFile.close(state.handle)

    %{
      state
      | handle: nil,
        poisoned?: true,
        serving: false,
        availability: :degraded,
        reason: :poisoned,
        last_error: last_error,
        torn_tail?: false
    }
  end

  defp mark_torn(state) do
    %{
      state
      | torn_tail?: true,
        serving: false,
        availability: :degraded,
        reason: :torn_tail,
        last_error: :torn_tail
    }
  end

  defp prepare_admitted(intent, from, state) do
    case prepare_lookup(state.core, intent) do
      {:pending, original, status} ->
        {:reply, {:ok, original, status}, state}

      :terminal ->
        {:reply, {:error, :operation_terminal}, %{state | last_refusal: :operation_terminal}}

      :unknown ->
        prepared = mutation_record(intent["operation_id"], "prepared", intent["prepared_at"])

        {:reply, reply, next} =
          handle_call({:append, Map.put(prepared, "intent", intent)}, from, state)

        case reply do
          {:ok, _} ->
            {:reply, {:ok, intent, "prepared"}, next}

          {:error, reason} when reason in @refusals ->
            {:reply, reply, %{next | last_refusal: reason}}

          error ->
            {:reply, error, next}
        end
    end
  end

  # Status first: every terminal identity (compacted or not) is refused, only
  # a pending operation is continued.
  defp prepare_lookup(core, intent) do
    case AuditJournalCore.operation(core, intent["operation_id"]) do
      {:ok, %{"status" => status, "intent" => original}} when status in @pending_statuses ->
        {:pending, original, status}

      {:ok, _terminal} ->
        :terminal

      :error ->
        legacy_alias_lookup(core, intent)
    end
  end

  # Cutover continuity: a v1/v2 operation pending before the v3 producer
  # shipped is continued by a v3 intent of identical facts instead of forking
  # a second identity. Gated: no alias is derived unless such an operation is
  # pending. Raw `append/1` has no such path (stated residual).
  defp legacy_alias_lookup(core, %{"version" => 3} = intent) do
    with true <- AuditJournalCore.legacy_pending?(core),
         {:ok, alias_id} <- AuditJournal.legacy_alias_operation_id(intent),
         {:ok, %{"status" => status, "intent" => original}} when status in @pending_statuses <-
           AuditJournalCore.operation(core, alias_id) do
      {:pending, original, status}
    else
      _ -> :unknown
    end
  end

  defp legacy_alias_lookup(_core, _intent), do: :unknown

  defp build_status(state) do
    case core_pending_summary(state) do
      {:ok, summary} ->
        shown = AuditJournalCore.show(state.core)
        availability = state.availability

        {:ok,
         %{
           "version" => 1,
           "mode" => Atom.to_string(state.mode),
           "durability" => Atom.to_string(state.durability),
           "availability" => Atom.to_string(availability),
           "reason" => Atom.to_string(state.reason),
           "serving" => availability == :serving,
           "poisoned" => state.poisoned?,
           "torn_tail" => state.torn_tail?,
           "last_error" => Atom.to_string(state.last_error),
           "entry_count" => shown["entry_count"],
           "byte_count" => shown["byte_count"],
           "pending_count" => summary["pending_count"],
           "oldest_pending_age_seconds" => summary["oldest_pending_age_seconds"],
           "committed_frames" => state.committed_frames,
           "capacity" => AuditJournalCore.capacity(state.core, paused: not retiring?(state)),
           "last_refusal" => Atom.to_string(state.last_refusal),
           "retirement" => %{
             "floor" => AuditJournalCore.admission_floor(state.core),
             "ledger_state" => Atom.to_string(state.ledger_state),
             "ledger_frames" => ledger_frames(state.core),
             "prepared_count" => summary["prepared_count"],
             "oldest_prepared_age_seconds" => summary["oldest_prepared_age_seconds"],
             "last_error" => Atom.to_string(state.retirement_error)
           }
         }}

      {:error, :journal_unavailable} = err ->
        err
    end
  end

  defp build_pending_operations(state) do
    case core_pending_summary(state) do
      {:ok, summary} -> {:ok, summary["operations"]}
      {:error, :journal_unavailable} = err -> err
    end
  end

  defp core_pending_summary(state) do
    case AuditJournalCore.pending_summary(state.core, sampled_wall_clock()) do
      {:ok, summary} -> {:ok, summary}
      {:error, :malformed} -> {:error, :journal_unavailable}
    end
  end

  defp sampled_wall_clock do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  defp owner_state(fields) do
    Enum.into(fields, %{
      handle: nil,
      committed_frames: 0,
      torn_tail?: false,
      poisoned?: false,
      ledger_state: :none,
      ledger_pause_logged?: false,
      last_refusal: :none,
      retirement_error: :none,
      t2_armed_at: retire_batch(),
      publication_backoff_until: nil
    })
  end

  defp do_append(server, raw) do
    safe_call(server, {:append, raw}, :append)
  end

  defp do_query(server, request) do
    safe_call(server, request, :query)
  end

  defp safe_call(server, request, kind) do
    GenServer.call(server, request, Config.audit_journal_call_timeout_ms())
  catch
    :exit, {:timeout, _} when kind == :append ->
      {:error, {:commit_uncertain, :timeout}}

    :exit, {:timeout, _} ->
      {:error, :journal_unavailable}

    :exit, {:noproc, _} ->
      {:error, :journal_unavailable}

    :exit, :noproc ->
      {:error, :journal_unavailable}

    :exit, _reason ->
      {:error, :journal_unavailable}
  end

  defp reject_unknown_opts(opts) do
    unknown = Keyword.keys(opts) -- @allowed_opts

    if unknown == [] do
      :ok
    else
      {:error, :invalid_opts}
    end
  end

  defp admit_boot_opts(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    profile = Keyword.get(opts, :capacity_profile, :small)

    if is_atom(name) and profile in [:small, :operational] do
      case admit_mode(opts, name) do
        {:ok, boot} ->
          {:ok,
           boot |> Map.put(:capacity_profile, profile) |> Map.put(:inject, boot_injects(opts))}

        error ->
          error
      end
    else
      {:error, :invalid_opts}
    end
  end

  if Mix.env() == :test do
    # Test-only: file-layer injects armed in the owner process before the
    # journal opens, so boot-time (T1) faults can be exercised.
    defp boot_injects(opts), do: Keyword.get(opts, :inject, [])

    defp apply_boot_injects(%{inject: injects}) when is_list(injects) do
      Enum.each(injects, fn
        {kind, value} -> AuditJournalFile.__test_inject__(kind, value)
        kind when is_atom(kind) -> AuditJournalFile.__test_inject__(kind)
      end)
    end

    defp apply_boot_injects(_boot), do: :ok
  else
    defp boot_injects(_opts), do: []
    defp apply_boot_injects(_boot), do: :ok
  end

  defp admit_mode(opts, name) do
    case Keyword.get(opts, :mode) do
      :disabled ->
        admit_disabled(opts, name)

      :ephemeral ->
        admit_ephemeral(opts, name)

      :durable ->
        admit_durable(opts, name)

      _other ->
        {:error, :invalid_opts}
    end
  end

  defp admit_disabled(opts, name) do
    reason = Keyword.get(opts, :reason, :disabled)

    if reason in @disabled_reasons and not Keyword.has_key?(opts, :root) do
      {:ok, %{mode: :disabled, reason: reason, name: name}}
    else
      {:error, :invalid_opts}
    end
  end

  defp admit_ephemeral(opts, name) do
    if Keyword.has_key?(opts, :root) or Keyword.has_key?(opts, :reason) do
      {:error, :invalid_opts}
    else
      {:ok, %{mode: :ephemeral, name: name}}
    end
  end

  defp admit_durable(opts, name) do
    root = Keyword.get(opts, :root)

    if is_binary(root) and byte_size(root) > 0 and not Keyword.has_key?(opts, :reason) do
      {:ok, %{mode: :durable, root: root, name: name}}
    else
      {:error, :invalid_opts}
    end
  end

  defp redact_field(status, key) do
    if Map.has_key?(status, key), do: Map.put(status, key, :redacted), else: status
  end
end
