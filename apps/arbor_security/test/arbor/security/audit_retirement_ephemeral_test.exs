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
  @retired_event [:arbor, :security, :audit_journal, :retired]

  setup do
    handler = "audit-retire-ephemeral-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        @retired_event,
        &__MODULE__.forward_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  @doc false
  def forward_event(event, measurements, metadata, pid),
    do: send(pid, {:audit_event, event, measurements, metadata})

  test "ephemeral operational journal admits 1500 full lifecycles with in-process ACKs" do
    register_consumer!()
    pid = start_registered_ephemeral!()

    max_retained =
      Enum.reduce(1..1500, 0, fn n, max_retained ->
        full_lifecycle!(n)
        {:ok, status} = Owner.status(pid)
        max(max_retained, status["capacity"]["retained_operation_count"])
      end)

    # Two in-memory T2 retirements (at 512 and 1024 delivered identities).
    publications = drain(@retired_event)
    assert length(publications) == 2

    assert Enum.all?(publications, fn {m, meta} ->
             m.count == 512 and meta.trigger == :acknowledge and meta.ledger_state == :none and
               meta.ledger_frames == 0
           end)

    assert max_retained <= 512

    {:ok, status} = Owner.status(pid)
    assert status["mode"] == "ephemeral"
    assert status["pending_count"] == 0
    assert status["capacity"]["retained_operation_count"] == 1500 - 1024
    assert status["capacity"]["retired_operation_total"] == 1024
    assert status["capacity"]["retirable_operation_count"] == 1500 - 1024
    assert status["last_refusal"] == "none"
    assert status["admission_open"] == true
    # The first in-memory retirement installed a v3 snapshot: floor 3, and
    # no ledger exists or is claimed.
    assert status["retirement"]["floor"] == 3
    assert status["retirement"]["ledger_state"] == "none"
    assert status["retirement"]["ledger_frames"] == 0
    assert status["retirement"]["last_error"] == "none"
    # Real retirement headroom: the retirable identities count as free.
    assert status["capacity"]["remaining_increase_admissions"] == 3072
  end

  @tag :slow
  @tag timeout: 600_000
  test "ephemeral operational journal sustains distinct lifecycles past 4096 identities" do
    register_consumer!()
    pid = start_registered_ephemeral!()
    total = 4096 + 904

    Enum.each(1..total, fn n ->
      full_lifecycle!(n)

      if rem(n, 250) == 0 do
        {:ok, status} = Owner.status(pid)
        assert status["capacity"]["retained_operation_count"] <= 512
        assert status["capacity"]["used_entries"] < 3072
      end
    end)

    publications = drain(@retired_event)
    durations = publications |> Enum.map(fn {m, _meta} -> m.duration_ms end) |> Enum.sort()

    IO.puts(
      "\n[audit retirement ephemeral] lifecycles=#{total} publications=#{length(publications)} " <>
        "in_memory_retirement_ms=#{inspect(durations)}"
    )

    assert length(publications) == div(total, 512)
    assert Enum.all?(publications, fn {m, _meta} -> m.count == 512 end)

    {:ok, status} = Owner.status(pid)
    assert status["capacity"]["retired_operation_total"] == div(total, 512) * 512
    assert status["capacity"]["retained_operation_count"] == rem(total, 512)
    assert status["last_refusal"] == "none"
    assert status["admission_open"] == true
  end

  test "T3 retires in memory and admits the caller's exact record when T2 never ran" do
    register_consumer!()
    pid = start_registered_ephemeral!()
    # Disable T2 so the entry budget fills with delivered identities.
    :sys.replace_state(pid, fn state -> %{state | t2_armed_at: 1_000_000} end)

    refused_at =
      Enum.reduce_while(1..2000, nil, fn n, _ ->
        {:ok, status} = Owner.status(pid)

        if status["capacity"]["remaining_soft_entries"] - status["capacity"]["reserved_entries"] <
             3 do
          {:halt, n}
        else
          full_lifecycle!(n)
          {:cont, nil}
        end
      end)

    assert is_integer(refused_at)
    assert drain(@retired_event) == []
    {:ok, before} = Owner.status(pid)
    assert before["retirement"]["floor"] == 1
    retirable = before["capacity"]["retirable_operation_count"]
    assert retirable == refused_at - 1

    # The next increase is refused by the entry clause, so T3 retires in
    # memory and retries the SAME raw record: its id is the caller's.
    intent = producer_grant(refused_at)
    assert {:ok, admitted, "prepared"} = Owner.prepare(intent)
    assert admitted["operation_id"] == intent["operation_id"]

    assert [{%{count: ^retirable}, %{trigger: :capacity, ledger_state: :none}}] =
             drain(@retired_event)

    {:ok, status} = Owner.status(pid)
    assert status["pending_count"] == 1
    assert status["capacity"]["retained_operation_count"] == 1
    assert status["capacity"]["retired_operation_total"] == retirable
    assert status["retirement"]["floor"] == 3
    assert status["last_refusal"] == "none"

    # Retired identities are refused, never admitted as new: the v2 twin of a
    # retired lifecycle is below the floor.
    v2 = intent(2, 1)

    assert {:error, :retired_version} = Owner.append(pid, prepared_record(v2))
  end

  @tag capture_log: true
  test "a failed in-memory retirement keeps the state, reports it and backs off" do
    register_consumer!()
    pid = start_registered_ephemeral!()
    :sys.replace_state(pid, fn state -> %{state | t2_armed_at: 1_000_000} end)
    lifecycle_count = fill_entry_budget!(pid)

    # A core state the compaction must refuse (an unclassifiable operation)
    # stands in for any in-memory compaction error.
    :sys.replace_state(pid, fn state ->
      bad = %{"status" => "delivered", "effect_class" => "nonsense", "records" => %{}}
      %{state | core: put_in(state.core, ["operations", String.duplicate("f", 64)], bad)}
    end)

    {:ok, before} = Owner.status(pid)
    intent = producer_grant(lifecycle_count + 1)
    assert {:error, :soft_capacity_exhausted} = Owner.prepare(intent)
    assert drain(@retired_event) == []

    {:ok, status} = Owner.status(pid)
    assert status["retirement"]["last_error"] == "malformed"
    assert status["last_refusal"] == "soft_capacity_exhausted"
    # No retirement headroom is claimed while the last attempt failed.
    assert status["capacity"]["remaining_increase_admissions"] ==
             max(0, 3072 - status["capacity"]["retained_operation_count"])

    assert status["admission_open"] == false
    assert status["entry_count"] == before["entry_count"]
    assert is_integer(:sys.get_state(pid).publication_backoff_until)
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
    {:ok, status} = Owner.status(eph)
    assert status["capacity"]["retirable_operation_count"] == 3
    assert status["capacity"]["retained_operation_count"] == 3
    assert status["capacity"]["remaining_increase_admissions"] == 3072

    {:ok, small} = Owner.start_link(mode: :ephemeral, name: :audit_retire_eph_small)
    Process.unlink(small)
    on_exit(fn -> stop(small) end)
    {:ok, small_status} = Owner.status(small)
    assert small_status["retirement"]["ledger_state"] == "none"
    assert small_status["capacity"]["retire_batch"] == 0
  end

  # ---------------------------------------------------------------------------

  # One full lifecycle through the arity-1 production API of the registered
  # owner, acknowledged by this process as the registered consumer.
  defp full_lifecycle!(n) do
    intent = producer_grant(n)
    id = intent["operation_id"]
    expect!(n, :prepare, {:ok, :_, "prepared"}, Owner.prepare(intent))
    expect!(n, :observe, {:ok, :committed}, Owner.observe(id, :applied))
    assert {:ok, [item]} = Owner.delivery_batch()
    assert item["operation_id"] == id

    expect!(
      n,
      :acknowledge,
      {:ok, :committed},
      Owner.acknowledge_delivery(id, item["intent_sha256"])
    )
  end

  defp expect!(n, step, {:ok, :_, status}, {:ok, _intent, status}) when is_binary(status),
    do: :ok

  defp expect!(_n, _step, expected, expected), do: :ok

  defp expect!(n, step, expected, actual),
    do: flunk("lifecycle #{n} #{step}: expected #{inspect(expected)}, got #{inspect(actual)}")

  defp fill_entry_budget!(pid) do
    Enum.reduce_while(1..2000, 0, fn n, done ->
      {:ok, status} = Owner.status(pid)

      if status["capacity"]["remaining_soft_entries"] - status["capacity"]["reserved_entries"] <
           3 do
        {:halt, done}
      else
        full_lifecycle!(n)
        {:cont, n}
      end
    end)
  end

  # The sole production producer: v3 here, v2 on the parent.
  defp producer_grant(n) do
    capability_id = "cap_" <> String.pad_leading(Integer.to_string(n), 32, "0")

    data = %{
      "id" => capability_id,
      "principal_id" => "agent_ephemeral_retirement",
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
