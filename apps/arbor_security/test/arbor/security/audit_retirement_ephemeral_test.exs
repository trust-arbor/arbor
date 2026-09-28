defmodule Arbor.Security.AuditRetirementEphemeralTest do
  @moduledoc """
  Ephemeral operational journals retire delivered identities in memory
  (Floor-and-Ledger v3, slice 4a, decision H11).

  An ephemeral journal (the test default and a production-reachable mode) has
  no file and no ledger. T2 (after an acknowledgement) and T3 (capacity
  relief) run the same core compaction a durable publication would rename
  into place, over the genesis source with the unchanged genesis ledger
  binding.

  The two lifecycle lanes are exact-parent regressions: they drive the
  registered owner through the arity-1 production API with intents built by
  the sole producer (`CapabilityAuditCore.intent/6`, v2 on the parent, v3
  here), so on 52a2cc3fa they fail for the capacity reason: the prepare of
  lifecycle ~1024 is refused `:soft_capacity_exhausted` once delivered
  identities fill the entry budget.

  The no-consumer refusal-cost test pins a branch-internal regression: the
  first slice-4 T3 re-decoded the whole backlog on every capacity refusal
  (it fails on 57ec0939e). The parent's ephemeral refusal ran no relief
  predicate at all, so it passes there.

  Foreign journal traffic: the owner under test is registered under the
  production name, so real Security mutations from other processes of the
  test node (grants and revocations by CapabilityStore callers that earlier
  modules left running) are journaled into it too. The tests account for
  them exactly instead of assuming a private journal:

  - this process is the registered consumer, so `full_lifecycle!/1` finds
    its own item in each delivery batch by operation id and acknowledges
    every item, counting the foreign ones (`foreign_acked/0`). Only this
    process delivers, so delivered identities are conserved:
    `retired_operation_total + retirable_operation_count == own +
    foreign_acked`, and each T2 retires exactly one batch of 512;
  - hot operations this process did not deliver (foreign pending or
    rejected) are attributed by a census of the owner's operations taken
    from the same state snapshot the status is computed from
    (`settled/1`); own operations are told apart by their principal.

  The lifecycle lanes assert their hot-set samples after the run, so on a
  journal that never retires the refused prepare stays the failure.

  `async: false`: the tests swap the registered journal owner and the
  configured audit consumer.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.AuditJournalCore, as: Core
  alias Arbor.Security.AuditJournalOwner, as: Owner
  alias Arbor.Security.CapabilityAuditCore
  alias Arbor.Security.Contracts.AuditJournal

  @time "2026-09-28T12:00:00Z"
  @principal "agent_ephemeral_retirement"
  @retired_event [:arbor, :security, :audit_journal, :retired]
  @failed_event [:arbor, :security, :audit_journal, :publication_failed]
  # Every in-memory retirement runs inside the owner's mailbox; a caller
  # waits at most the 5 s journal call timeout.
  @call_timeout_ms 5_000
  @foreign_acked {__MODULE__, :foreign_acked}

  setup do
    handler = "audit-retire-ephemeral-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler,
        [@retired_event, @failed_event],
        &__MODULE__.forward_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  @doc false
  def forward_event(event, measurements, metadata, pid),
    do: send(pid, {:audit_event, event, measurements, metadata})

  @tag timeout: 300_000
  test "ephemeral operational journal admits 1500 full lifecycles with in-process ACKs" do
    register_consumer!()
    pid = start_registered_ephemeral!()

    max_hot_delivered =
      Enum.reduce(1..1500, 0, fn n, max_hot_delivered ->
        full_lifecycle!(n)
        {:ok, status} = Owner.status(pid)
        max(max_hot_delivered, status["capacity"]["retirable_operation_count"])
      end)

    # Only this process delivers: its 1500 identities plus every foreign one
    # it acknowledged. In-memory T2 retires each batch of 512 (at 512 and
    # 1024 delivered identities when nothing foreign was delivered).
    delivered = 1500 + foreign_acked()
    publications = drain(@retired_event)
    assert length(publications) == div(delivered, 512)

    assert Enum.all?(publications, fn {m, meta} ->
             m.count == 512 and meta.trigger == :acknowledge and meta.ledger_state == :none and
               meta.ledger_frames == 0
           end)

    assert_within_call_timeout(publications)
    # The hot set never holds a full batch of delivered identities.
    assert max_hot_delivered < 512

    {status, census} = settled(pid)
    capacity = status["capacity"]
    assert status["mode"] == "ephemeral"
    # Every own lifecycle was delivered: whatever is pending is foreign.
    assert Map.drop(census.own, ["delivered"]) == %{}
    assert status["pending_count"] == foreign_pending(census)
    assert capacity["retired_operation_total"] == 512 * length(publications)

    assert capacity["retired_operation_total"] + capacity["retirable_operation_count"] ==
             delivered

    assert capacity["retained_operation_count"] ==
             capacity["retirable_operation_count"] + foreign_undelivered(census)

    assert status["last_refusal"] == "none"
    assert status["admission_open"] == true
    # The first in-memory retirement installed a v3 snapshot: floor 3, and
    # no ledger exists or is claimed.
    assert status["retirement"]["floor"] == 3
    assert status["retirement"]["ledger_state"] == "none"
    assert status["retirement"]["ledger_frames"] == 0
    assert status["retirement"]["last_error"] == "none"
    # Real retirement headroom: the retirable identities count as free; only
    # undelivered (foreign) operations occupy the retained dimension.
    assert capacity["remaining_increase_admissions"] == 3072 - foreign_undelivered(census)
  end

  @tag :slow
  @tag timeout: 600_000
  test "ephemeral operational journal sustains distinct lifecycles past 4096 identities" do
    register_consumer!()
    pid = start_registered_ephemeral!()
    total = 4096 + 904

    samples =
      Enum.reduce(1..total, [], fn n, samples ->
        full_lifecycle!(n)
        if rem(n, 250) == 0, do: [{n, settled(pid)} | samples], else: samples
      end)

    delivered = total + foreign_acked()
    publications = drain(@retired_event)
    durations = publications |> Enum.map(fn {m, _meta} -> m.duration_ms end) |> Enum.sort()

    IO.puts(
      "\n[audit retirement ephemeral] lifecycles=#{total} foreign_acked=#{foreign_acked()} " <>
        "publications=#{length(publications)} in_memory_retirement_ms=#{inspect(durations)}"
    )

    assert length(publications) == div(delivered, 512)

    assert Enum.all?(publications, fn {m, meta} ->
             m.count == 512 and meta.trigger == :acknowledge
           end)

    assert_within_call_timeout(publications)

    # Every 250 lifecycles: fewer than one batch of delivered identities is
    # hot, every other hot operation is foreign and undelivered, and the
    # entry budget is never approached.
    for {n, {status, census}} <- Enum.reverse(samples) do
      capacity = status["capacity"]
      assert capacity["retirable_operation_count"] < 512, "lifecycle #{n}: #{inspect(capacity)}"
      assert Map.drop(census.own, ["delivered"]) == %{}, "lifecycle #{n}: #{inspect(census)}"

      assert capacity["retained_operation_count"] ==
               capacity["retirable_operation_count"] + foreign_undelivered(census),
             "lifecycle #{n}: #{inspect(capacity)} #{inspect(census)}"

      assert capacity["used_entries"] < 3072, "lifecycle #{n}: #{inspect(capacity)}"
    end

    {status, census} = settled(pid)
    capacity = status["capacity"]
    assert capacity["retired_operation_total"] == 512 * length(publications)

    assert capacity["retired_operation_total"] + capacity["retirable_operation_count"] ==
             delivered

    assert capacity["retained_operation_count"] ==
             capacity["retirable_operation_count"] + foreign_undelivered(census)

    assert status["last_refusal"] == "none"
    assert status["admission_open"] == true
  end

  @tag timeout: 300_000
  test "T3 retires in memory and admits the caller's exact record when T2 never ran" do
    register_consumer!()
    pid = start_registered_ephemeral!()
    # Disable T2 so the entry budget fills with delivered identities.
    :sys.replace_state(pid, fn state -> %{state | t2_armed_at: 1_000_000} end)
    {own, intent, before} = fill_entry_budget!(pid)

    # The entry clause refused `intent`, and nothing retired while the budget
    # filled: every delivered identity, own or foreign, is still hot.
    assert own > 0
    assert entry_slack(before) < 3
    assert before["retirement"]["floor"] == 1
    assert before["capacity"]["retired_operation_total"] == 0
    retirable = before["capacity"]["retirable_operation_count"]
    assert retirable == own + foreign_acked()

    # With retirement re-armed the same increase is refused by the entry
    # clause again, so T3 retires in memory and retries the SAME raw record:
    # its id is the caller's.
    rearm_retirement!(pid)
    assert {:ok, admitted, "prepared"} = Owner.prepare(intent)
    assert admitted["operation_id"] == intent["operation_id"]

    assert [{%{count: ^retirable}, %{trigger: :capacity, ledger_state: :none}}] =
             t3 = drain(@retired_event)

    assert_within_call_timeout(t3)

    {status, census} = settled(pid)
    # The caller's record is the only own operation left hot, and it is
    # pending; every other hot operation is foreign and undelivered.
    assert census.own == %{"prepared" => 1}
    assert status["pending_count"] == 1 + foreign_pending(census)
    assert status["capacity"]["retirable_operation_count"] == 0
    assert status["capacity"]["retained_operation_count"] == 1 + foreign_undelivered(census)
    assert status["capacity"]["retired_operation_total"] == retirable
    assert status["retirement"]["floor"] == 3
    assert status["last_refusal"] == "none"

    # Retired identities are refused, never admitted as new: the v2 twin of a
    # retired lifecycle is below the floor.
    v2 = intent(2, 1)

    assert {:error, :retired_version} = Owner.append(pid, prepared_record(v2))
  end

  @tag capture_log: true
  @tag timeout: 300_000
  test "a failed in-memory retirement keeps the state, reports it and backs off" do
    register_consumer!()
    pid = start_registered_ephemeral!()
    :sys.replace_state(pid, fn state -> %{state | t2_armed_at: 1_000_000} end)
    {own, intent, _full} = fill_entry_budget!(pid)

    # A core state the compaction must refuse (an unclassifiable operation)
    # stands in for any in-memory compaction error.
    :sys.replace_state(pid, fn state ->
      bad = %{"status" => "delivered", "effect_class" => "nonsense", "records" => %{}}
      %{state | core: put_in(state.core, ["operations", String.duplicate("f", 64)], bad)}
    end)

    {before, before_census} = settled(pid)
    # Nothing is compacted yet: each own lifecycle holds its three records,
    # and every delivered identity (own, foreign, the injected one) is hot.
    assert own_entries(before, before_census) == 3 * own
    assert before["capacity"]["retirable_operation_count"] == own + foreign_acked() + 1

    rearm_retirement!(pid)
    assert {:error, :soft_capacity_exhausted} = Owner.prepare(intent)
    assert drain(@retired_event) == []

    assert [{_m, %{trigger: :capacity, outcome: :not_published, reason: :malformed}}] =
             drain(@failed_event)

    {status, census} = settled(pid)
    assert status["retirement"]["last_error"] == "malformed"
    assert status["last_refusal"] == "soft_capacity_exhausted"
    # No retirement headroom is claimed while the last attempt failed.
    assert status["capacity"]["remaining_increase_admissions"] ==
             max(0, 3072 - status["capacity"]["retained_operation_count"])

    assert status["admission_open"] == false
    # The failed compaction kept the state: nothing retired, the same
    # delivered identities hot, the own records untouched (only foreign
    # appends may have landed since).
    assert status["capacity"]["retired_operation_total"] == 0

    assert status["capacity"]["retirable_operation_count"] ==
             before["capacity"]["retirable_operation_count"]

    assert census.own == before_census.own
    assert own_entries(status, census) == own_entries(before, before_census)
    backoff_until = :sys.get_state(pid).publication_backoff_until
    assert is_integer(backoff_until)

    # Inside the 5 s backoff a further capacity refusal answers the same
    # error without another in-memory compaction attempt.
    assert System.monotonic_time(:millisecond) < backoff_until
    assert {:error, :soft_capacity_exhausted} = Owner.prepare(producer_grant(own + 2))
    assert System.monotonic_time(:millisecond) < backoff_until
    assert drain(@failed_event) == []
    assert drain(@retired_event) == []
    assert :sys.get_state(pid).publication_backoff_until == backoff_until
    {still, still_census} = settled(pid)
    assert own_entries(still, still_census) == own_entries(before, before_census)
    assert still["retirement"]["last_error"] == "malformed"
  end

  # A no-consumer backlog (the test default and any ephemeral journal whose
  # sink stalls) refuses every further increase. Nothing is retirable, so T3
  # must decline without re-decoding the retained records: the refusal path
  # runs inside the single-writer owner, and a 5 s caller timeout turns a slow
  # refusal into `{:commit_uncertain, :timeout}` and an unjournaled revoke.
  # Before the count-based filter each refusal re-decoded the whole backlog
  # (~0.8 s for 1024 pending grants).
  test "a capacity refusal with nothing retirable answers without decoding the backlog" do
    pid = start_registered_ephemeral!()

    # Pending effect_applied grants cost 3 entries each (2 written, 1
    # reserved): 1024 of them fill the 3072-entry soft budget, fewer when
    # foreign operations share it, so grants are applied until the entry
    # clause refuses one.
    admitted =
      Enum.reduce_while(1..1100, 0, fn n, admitted ->
        intent = producer_grant(n)

        case Owner.prepare(intent) do
          {:ok, _intent, "prepared"} ->
            expect!(
              n,
              :observe,
              {:ok, :committed},
              Owner.observe(intent["operation_id"], :applied)
            )

            {:cont, admitted + 1}

          {:error, :soft_capacity_exhausted} ->
            {:halt, admitted}

          other ->
            flunk("lifecycle #{n} prepare: #{inspect(other)}")
        end
      end)

    {elapsed_us, replies} =
      :timer.tc(fn ->
        for n <- (admitted + 1)..(admitted + 20), do: Owner.prepare(producer_grant(n))
      end)

    assert Enum.uniq(replies) == [{:error, :soft_capacity_exhausted}]
    # 20 refusals; the decoding predicate needed ~16 s here.
    assert elapsed_us < 3_000_000, "20 refusals took #{div(elapsed_us, 1000)} ms"

    # Declining T3 is not a failed publication: nothing retired, no backoff.
    # Only a foreign rejected operation's records are reclaimable here, and a
    # compaction relieving a refusal by them retires nothing.
    compactions = drain(@retired_event)
    assert :sys.get_state(pid).publication_backoff_until == nil
    {status, census} = settled(pid)
    capacity = status["capacity"]
    assert Enum.all?(compactions, fn {m, _meta} -> m.count == 0 end)
    assert compactions == [] or Map.has_key?(census.foreign, "effect_rejected")
    # Every own grant is pending; any other pending operation is foreign.
    assert census.own == %{"effect_applied" => admitted}
    assert status["pending_count"] == admitted + foreign_pending(census)
    assert capacity["retirable_operation_count"] == 0
    # Each own grant wrote two records (beside a snapshot, if such a
    # compaction ran). The entry clause closed the budget (one more increase
    # needs 3 entries; foreign reductions are admitted past it against the
    # hard cap), and 1024 own grants filled it unless foreign operations
    # shared it.
    snapshot_entries = if compactions == [], do: 0, else: 1
    assert capacity["used_entries"] == 2 * admitted + census.foreign_records + snapshot_entries
    assert capacity["remaining_soft_entries"] - capacity["reserved_entries"] < 3
    assert admitted == 1024 or census.foreign != %{}
    assert admitted <= 1024
    assert status["last_refusal"] == "soft_capacity_exhausted"
    assert status["retirement"]["last_error"] == "none"
  end

  test "ephemeral journals retire in memory with real headroom; small journals never retire" do
    {:ok, eph} =
      Owner.start_link(
        mode: :ephemeral,
        capacity_profile: :operational,
        name: :audit_retire_eph_status
      )

    Process.unlink(eph)
    on_exit(fn -> stop(eph) end)
    {:ok, status} = Owner.status(eph)
    assert status["retirement"]["ledger_state"] == "none"
    assert status["retirement"]["floor"] == 1
    assert status["capacity"]["retire_batch"] == 512
    assert status["capacity"]["remaining_increase_admissions"] == 3072

    # Delivered-but-unretired identities count as headroom on an ephemeral
    # operational journal (a retiring compaction is reachable in memory).
    register_consumer!()
    swap_registered(eph)

    for n <- 1..3, do: full_lifecycle!(n)
    {status, census} = settled(eph)
    delivered = 3 + foreign_acked()
    assert status["capacity"]["retirable_operation_count"] == delivered

    assert status["capacity"]["retained_operation_count"] ==
             delivered + foreign_undelivered(census)

    assert status["capacity"]["remaining_increase_admissions"] ==
             3072 - foreign_undelivered(census)

    {:ok, small} = Owner.start_link(mode: :ephemeral, name: :audit_retire_eph_small)
    Process.unlink(small)
    on_exit(fn -> stop(small) end)
    {:ok, small_status} = Owner.status(small)
    assert small_status["retirement"]["ledger_state"] == "none"
    assert small_status["capacity"]["retire_batch"] == 0
  end

  # ---------------------------------------------------------------------------

  # One full lifecycle through the arity-1 production API of the registered
  # owner, acknowledged by this process as the registered consumer. Foreign
  # operations journaled into the registered owner can share the delivery
  # batch: the own item is found by operation id, and every item is
  # acknowledged (a foreign effect_applied operation left undelivered would
  # stay hot and skew the retirement accounting), the foreign ones counted
  # in `foreign_acked/0`.
  defp full_lifecycle!(n) do
    intent = producer_grant(n)
    expect!(n, :prepare, {:ok, :_, "prepared"}, Owner.prepare(intent))
    finish_lifecycle!(n, intent["operation_id"])
  end

  defp finish_lifecycle!(n, id) do
    expect!(n, :observe, {:ok, :committed}, Owner.observe(id, :applied))
    assert {:ok, batch} = Owner.delivery_batch()

    assert Enum.any?(batch, &(&1["operation_id"] == id)),
           "lifecycle #{n}: own operation #{id} missing from the delivery batch"

    Enum.each(batch, fn item ->
      item_id = item["operation_id"]
      step = if item_id == id, do: :acknowledge, else: "acknowledge foreign #{item_id}"

      expect!(
        n,
        step,
        {:ok, :committed},
        Owner.acknowledge_delivery(item_id, item["intent_sha256"])
      )

      if item_id != id, do: Process.put(@foreign_acked, foreign_acked() + 1)
    end)
  end

  defp foreign_acked, do: Process.get(@foreign_acked, 0)

  defp expect!(_n, _step, {:ok, :_, status}, {:ok, _intent, status}) when is_binary(status),
    do: :ok

  defp expect!(_n, _step, expected, expected), do: :ok

  defp expect!(n, step, expected, actual),
    do: flunk("lifecycle #{n} #{step}: expected #{inspect(expected)}, got #{inspect(actual)}")

  defp assert_within_call_timeout(publications) do
    durations = Enum.map(publications, fn {m, _meta} -> m.duration_ms end)

    assert Enum.all?(durations, &(&1 < @call_timeout_ms)),
           "in-memory retirement durations #{inspect(durations)} reach the #{@call_timeout_ms} ms call timeout"
  end

  # Full lifecycles until the entry clause refuses an increase, wherever
  # foreign operations sharing the budget put that point. A publication
  # backoff is armed for the fill, so that refusal runs no T3 and changes no
  # state beyond `last_refusal`: the boundary is the refusal itself, not a
  # status read a foreign append could overtake. Returns the own lifecycles
  # driven, the refused intent and the status of the full budget; the tests
  # call `rearm_retirement!/1` right before the increase under test.
  defp fill_entry_budget!(pid) do
    :sys.replace_state(pid, fn state ->
      %{state | publication_backoff_until: System.monotonic_time(:millisecond) + 3_600_000}
    end)

    outcome =
      Enum.reduce_while(1..2000, 0, fn n, own ->
        intent = producer_grant(n)

        case Owner.prepare(intent) do
          {:ok, _intent, "prepared"} ->
            finish_lifecycle!(n, intent["operation_id"])
            {:cont, n}

          {:error, :soft_capacity_exhausted} ->
            {:halt, {:refused, own, intent}}

          other ->
            flunk("lifecycle #{n} prepare: #{inspect(other)}")
        end
      end)

    assert {:refused, own, intent} = outcome
    {:ok, full} = Owner.status(pid)
    {own, intent, full}
  end

  # Ends the fill's publication backoff (and forgets its refusal), so the
  # next refused increase runs T3.
  defp rearm_retirement!(pid) do
    :sys.replace_state(pid, fn state ->
      %{state | publication_backoff_until: nil, last_refusal: :none}
    end)

    :ok
  end

  defp entry_slack(status),
    do: status["capacity"]["remaining_soft_entries"] - status["capacity"]["reserved_entries"]

  # The status of one owner state and the census of that same state. Foreign
  # appends can land between any two calls, so both come from a single state
  # snapshot: the status is the owner's own `:status` reply for it.
  defp settled(pid) do
    state = :sys.get_state(pid)

    assert {:reply, {:ok, status}, _state} =
             Owner.handle_call(:status, {self(), make_ref()}, state)

    {status, census(state)}
  end

  # The owner's hot operations counted by status, own (this module's
  # principal) and foreign, with the records the foreign ones hold.
  defp census(state) do
    empty = %{own: %{}, foreign: %{}, foreign_records: 0}

    Enum.reduce(state.core["operations"], empty, fn {_id, op}, acc ->
      side =
        if get_in(op, ["intent", "audit", "data", "principal_id"]) == @principal,
          do: :own,
          else: :foreign

      acc = Map.update!(acc, side, &Map.update(&1, op["status"], 1, fn c -> c + 1 end))

      if side == :foreign,
        do: %{acc | foreign_records: acc.foreign_records + record_count(op)},
        else: acc
    end)
  end

  defp record_count(%{"records" => records}) when is_map(records), do: map_size(records)
  defp record_count(_op), do: 0

  defp foreign_pending(census),
    do: Map.get(census.foreign, "prepared", 0) + Map.get(census.foreign, "effect_applied", 0)

  defp foreign_undelivered(census),
    do: census.foreign |> Map.delete("delivered") |> Map.values() |> Enum.sum()

  # Entries not held by foreign operations: the own records (and, after a
  # compaction, the snapshot).
  defp own_entries(status, census), do: status["entry_count"] - census.foreign_records

  # The sole production producer: v3 here, v2 on the parent.
  defp producer_grant(n) do
    capability_id = "cap_" <> String.pad_leading(Integer.to_string(n), 32, "0")

    data = %{
      "id" => capability_id,
      "principal_id" => @principal,
      "resource_uri" => "arbor://memory/read/ephemeral"
    }

    after_entry = CapabilityAuditCore.replacement(Record.new(capability_id, data), :absent)
    {:ok, intent} = CapabilityAuditCore.intent(:grant, :absent, after_entry, data, @time)
    intent
  end

  defp intent(version, n) do
    id = "cap_" <> String.pad_leading(Integer.to_string(n), 32, "0")

    {:ok, intent} =
      AuditJournal.admit_intent(%{
        "version" => version,
        "kind" => "arbor.security.authority_mutation_intent.v#{version}",
        "operation" => "capability_grant",
        "effect_class" => "authority_increase",
        "authority_namespace" => "capability",
        "authority_key" => id,
        "before_fence" => %{"kind" => "absent"},
        "after_fingerprint" => %{
          "kind" => "live",
          "record_id" => "record-#{n}",
          "generation" => 1,
          "revision" => 1,
          "capability_digest" => String.duplicate("ab", 32)
        },
        "audit" => %{
          "event_type" => "capability_granted",
          "data" => %{
            "capability_id" => id,
            "principal_id" => "agent_fixture",
            "resource_uri" => "arbor://memory/read"
          }
        },
        "prepared_at" => @time
      })

    intent
  end

  defp prepared_record(intent) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "prepared",
      "operation_id" => intent["operation_id"],
      "occurred_at" => intent["prepared_at"],
      "intent" => intent
    }
  end

  # A fresh ephemeral operational owner registered under the production name
  # for the rest of the test; the original owner is restored on exit.
  defp start_registered_ephemeral! do
    name = :"audit_retire_eph_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Owner.start_link(mode: :ephemeral, capacity_profile: :operational, name: name)

    Process.unlink(pid)
    on_exit(fn -> stop(pid) end)
    {:ok, status} = Owner.status(pid)
    assert status["mode"] == "ephemeral"
    assert Core.profile(:sys.get_state(pid).core) == :operational
    swap_registered(pid)
    pid
  end

  defp swap_registered(pid) do
    original = Process.whereis(Owner)
    if original, do: true = Process.unregister(Owner)

    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> true = Process.unregister(name)
      _ -> :ok
    end

    true = Process.register(pid, Owner)

    on_exit(fn ->
      if Process.whereis(Owner) == pid, do: Process.unregister(Owner)
      if original && Process.alive?(original), do: Process.register(original, Owner)
    end)
  end

  defp register_consumer! do
    name = :"audit_retire_eph_consumer_#{System.unique_integer([:positive])}"
    true = Process.register(self(), name)
    previous = Application.fetch_env(:arbor_security, :authority_audit_consumer_name)
    Application.put_env(:arbor_security, :authority_audit_consumer_name, name)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:arbor_security, :authority_audit_consumer_name, value)

        :error ->
          Application.delete_env(:arbor_security, :authority_audit_consumer_name)
      end
    end)

    name
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp drain(event, acc \\ []) do
    receive do
      {:audit_event, ^event, measurements, metadata} ->
        drain(event, [{measurements, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
