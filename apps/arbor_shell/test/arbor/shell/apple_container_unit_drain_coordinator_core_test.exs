defmodule Arbor.Shell.AppleContainerUnitDrainCoordinatorCoreTest do
  @moduledoc """
  Pure tests for durable drain-coordinator reconstruction matching.

  No applications, GenServers, or live process ownership — PIDs are static
  Erlang fixtures used only as opaque map values.
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell.AppleContainerUnitDrainCoordinatorCore, as: Core
  alias Arbor.Shell.AppleContainerUnitJournalCore, as: JournalCore

  @moduletag :fast

  @hex_a String.duplicate("a", 32)
  @hex_b String.duplicate("b", 32)
  @hex_c String.duplicate("c", 32)

  @token_a String.duplicate("1", 64)
  @token_b String.duplicate("2", 64)
  @token_c String.duplicate("3", 64)

  @unit_a "arbor-v1-#{@hex_a}"
  @unit_b "arbor-v1-#{@hex_b}"
  @unit_c "arbor-v1-#{@hex_c}"

  @exec_a "exec-alpha-1"
  @exec_b "exec-beta-2"
  @exec_c "exec-gamma-3"

  # Static PID fixtures — not live processes (built at runtime, not attributes).
  defp pid_1, do: :c.pid(0, 101, 0)
  defp pid_2, do: :c.pid(0, 102, 0)
  defp pid_3, do: :c.pid(0, 103, 0)
  defp pid_4, do: :c.pid(0, 104, 0)

  defp record(opts) do
    %{
      unit_name: Keyword.fetch!(opts, :unit_name),
      execution_id: Keyword.fetch!(opts, :execution_id),
      token: Keyword.fetch!(opts, :token),
      reserved_at_ms: Keyword.get(opts, :reserved_at_ms, 1_700_000_000_000)
    }
  end

  defp hint(pid, execution_id) do
    %{worker_pid: pid, execution_id: execution_id}
  end

  defp normalize!(attrs) do
    assert {:ok, empty} = JournalCore.new()
    assert {:ok, journal, _} = JournalCore.reserve(empty, attrs)
    assert [normalized] = JournalCore.recovery_entries(journal)
    normalized
  end

  describe "reconstruction_plan/2 empty and full match" do
    test "empty records and empty hints yield empty partition" do
      assert {:ok, plan} = Core.reconstruction_plan([], [])

      assert plan == %{
               verification_candidates: [],
               orphan_records: [],
               unmatched_workers: []
             }
    end

    test "all records match all hints one-to-one" do
      records = [
        record(unit_name: @unit_a, execution_id: @exec_a, token: @token_a),
        record(unit_name: @unit_b, execution_id: @exec_b, token: @token_b)
      ]

      hints = [
        hint(pid_2(), @exec_b),
        hint(pid_1(), @exec_a)
      ]

      assert {:ok, plan} = Core.reconstruction_plan(records, hints)

      assert plan.orphan_records == []
      assert plan.unmatched_workers == []

      assert plan.verification_candidates == [
               %{worker_pid: pid_1(), journal_record: normalize!(hd(records))},
               %{
                 worker_pid: pid_2(),
                 journal_record: normalize!(Enum.at(records, 1))
               }
             ]
    end
  end

  describe "reconstruction_plan/2 mixed partitions" do
    test "splits matched, orphan records, and unmatched workers" do
      records = [
        record(unit_name: @unit_c, execution_id: @exec_c, token: @token_c),
        record(unit_name: @unit_a, execution_id: @exec_a, token: @token_a),
        record(unit_name: @unit_b, execution_id: @exec_b, token: @token_b)
      ]

      hints = [
        hint(pid_3(), "exec-unknown"),
        hint(pid_1(), @exec_a)
      ]

      assert {:ok, plan} = Core.reconstruction_plan(records, hints)

      assert plan.verification_candidates == [
               %{
                 worker_pid: pid_1(),
                 journal_record:
                   normalize!(record(unit_name: @unit_a, execution_id: @exec_a, token: @token_a))
               }
             ]

      assert plan.orphan_records == [
               normalize!(record(unit_name: @unit_b, execution_id: @exec_b, token: @token_b)),
               normalize!(record(unit_name: @unit_c, execution_id: @exec_c, token: @token_c))
             ]

      assert plan.unmatched_workers == [
               %{worker_pid: pid_3(), execution_id: "exec-unknown"}
             ]
    end

    test "sorts candidates and orphans by unit_name and unmatched by execution_id" do
      records = [
        record(unit_name: @unit_c, execution_id: @exec_c, token: @token_c),
        record(unit_name: @unit_a, execution_id: @exec_a, token: @token_a),
        record(unit_name: @unit_b, execution_id: @exec_b, token: @token_b)
      ]

      hints = [
        hint(pid_2(), @exec_c),
        hint(pid_1(), @exec_a),
        hint(pid_3(), "z-unmatched"),
        hint(pid_4(), "a-unmatched")
      ]

      assert {:ok, plan} = Core.reconstruction_plan(records, hints)

      assert Enum.map(plan.verification_candidates, & &1.journal_record.unit_name) == [
               @unit_a,
               @unit_c
             ]

      assert Enum.map(plan.orphan_records, & &1.unit_name) == [@unit_b]

      assert Enum.map(plan.unmatched_workers, & &1.execution_id) == [
               "a-unmatched",
               "z-unmatched"
             ]
    end

    test "returns exact JournalCore-normalized records not input aliases" do
      raw = %{
        "unit_name" => @unit_a,
        "execution_id" => @exec_a,
        "token" => @token_a,
        "reserved_at_ms" => 1_700_000_000_123
      }

      expected = normalize!(raw)

      assert {:ok, plan} =
               Core.reconstruction_plan([raw], [hint(pid_1(), @exec_a)])

      assert [candidate] = plan.verification_candidates
      assert candidate.journal_record == expected

      assert Map.keys(candidate.journal_record) |> Enum.sort() ==
               [:execution_id, :reserved_at_ms, :token, :unit_name]
    end
  end

  describe "reconstruction_plan/2 fail-closed inputs" do
    test "rejects malformed and string-key hints with no partial plan" do
      records = [record(unit_name: @unit_a, execution_id: @exec_a, token: @token_a)]

      assert {:error, :invalid_worker_hint} =
               Core.reconstruction_plan(records, [
                 %{"worker_pid" => pid_1(), "execution_id" => @exec_a}
               ])

      assert {:error, :invalid_worker_hint} =
               Core.reconstruction_plan(records, [
                 %{worker_pid: pid_1(), execution_id: @exec_a, extra: true}
               ])

      assert {:error, :invalid_worker_hint} =
               Core.reconstruction_plan(records, [%{worker_pid: pid_1()}])

      assert {:error, :invalid_worker_hint} =
               Core.reconstruction_plan(records, [
                 %{worker_pid: "not-a-pid", execution_id: @exec_a}
               ])

      assert {:error, :invalid_worker_hints} = Core.reconstruction_plan(records, :not_a_list)
    end

    test "rejects invalid execution ids in hints" do
      records = [record(unit_name: @unit_a, execution_id: @exec_a, token: @token_a)]

      assert {:error, :invalid_execution_id} =
               Core.reconstruction_plan(records, [hint(pid_1(), "")])

      assert {:error, :invalid_execution_id} =
               Core.reconstruction_plan(records, [hint(pid_1(), "  spaced  ")])

      assert {:error, :invalid_execution_id} =
               Core.reconstruction_plan(records, [hint(pid_1(), "internal space")])

      assert {:error, :invalid_execution_id} =
               Core.reconstruction_plan(records, [hint(pid_1(), "internal\tspace")])

      assert {:error, :invalid_execution_id} =
               Core.reconstruction_plan(records, [hint(pid_1(), "control" <> <<127>>)])

      assert {:error, :invalid_execution_id} =
               Core.reconstruction_plan(records, [hint(pid_1(), "has/slash")])

      assert {:error, :invalid_execution_id} =
               Core.reconstruction_plan(records, [hint(pid_1(), String.duplicate("x", 257))])
    end

    test "rejects duplicate worker_pid and duplicate hinted execution_id" do
      records = [
        record(unit_name: @unit_a, execution_id: @exec_a, token: @token_a),
        record(unit_name: @unit_b, execution_id: @exec_b, token: @token_b)
      ]

      assert {:error, :duplicate_worker_pid} =
               Core.reconstruction_plan(records, [
                 hint(pid_1(), @exec_a),
                 hint(pid_1(), @exec_b)
               ])

      assert {:error, :duplicate_hint_execution_id} =
               Core.reconstruction_plan(records, [
                 hint(pid_1(), @exec_a),
                 hint(pid_2(), @exec_a)
               ])
    end

    test "rejects malformed and duplicate journal records" do
      assert {:error, reason} =
               Core.reconstruction_plan([%{unit_name: @unit_a}], [hint(pid_1(), @exec_a)])

      assert reason in [
               :missing_execution_id,
               :missing_token,
               :missing_reserved_at_ms,
               :invalid_record
             ]

      assert {:error, _} =
               Core.reconstruction_plan(
                 [
                   record(unit_name: @unit_a, execution_id: @exec_a, token: @token_a),
                   record(unit_name: @unit_a, execution_id: @exec_b, token: @token_b)
                 ],
                 []
               )

      assert {:error, _} =
               Core.reconstruction_plan(
                 [
                   record(unit_name: @unit_a, execution_id: @exec_a, token: @token_a),
                   record(unit_name: @unit_b, execution_id: @exec_a, token: @token_b)
                 ],
                 []
               )

      assert {:error, :invalid_records} = Core.reconstruction_plan(:not_a_list, [])
    end

    test "one-to-one matching never pairs two hints to one record when ids differ" do
      records = [record(unit_name: @unit_a, execution_id: @exec_a, token: @token_a)]

      assert {:ok, plan} =
               Core.reconstruction_plan(records, [
                 hint(pid_1(), @exec_a),
                 hint(pid_2(), @exec_b)
               ])

      assert length(plan.verification_candidates) == 1
      assert hd(plan.verification_candidates).worker_pid == pid_1()
      assert plan.unmatched_workers == [%{worker_pid: pid_2(), execution_id: @exec_b}]
      assert plan.orphan_records == []
    end
  end
end
