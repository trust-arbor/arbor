defmodule Arbor.Memory.Events.ContentCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.Events.ContentCore

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C4D"

  describe "admit/2 agent_id" do
    test "accepts nonempty UTF-8 up to 248 bytes and derives stream id" do
      agent = String.duplicate("a", 248)
      assert {:ok, admitted} = ContentCore.admit(agent, [])
      assert admitted.agent_id == agent
      assert admitted.stream_id == "memory:" <> agent
      assert byte_size(admitted.stream_id) == 255
      assert admitted.timeout_ms == 5_000
    end

    test "rejects empty, 249-byte, non-binary, invalid UTF-8, and NUL" do
      assert {:error, :invalid_agent_id} = ContentCore.admit("", [])
      assert {:error, :invalid_agent_id} = ContentCore.admit(String.duplicate("b", 249), [])
      assert {:error, :invalid_agent_id} = ContentCore.admit(123, [])
      assert {:error, :invalid_agent_id} = ContentCore.admit(<<0xFF, 0xFE>>, [])
      assert {:error, :invalid_agent_id} = ContentCore.admit("ab\0c", [])
    end
  end

  describe "admit/2 options" do
    test "defaults and closed keyword surface" do
      assert {:ok, %{timeout_ms: 5_000}} = ContentCore.admit("agent", [])
      assert {:ok, %{timeout_ms: 1}} = ContentCore.admit("agent", timeout_ms: 1)
      assert {:ok, %{timeout_ms: 60_000}} = ContentCore.admit("agent", timeout_ms: 60_000)
    end

    test "rejects malformed, duplicate, unknown, and out-of-range options" do
      assert {:error, :invalid_precondition} = ContentCore.admit("agent", timeout_ms: 0)
      assert {:error, :invalid_precondition} = ContentCore.admit("agent", timeout_ms: 60_001)
      assert {:error, :invalid_precondition} = ContentCore.admit("agent", timeout_ms: 1.5)
      assert {:error, :invalid_precondition} = ContentCore.admit("agent", repo: true)
      assert {:error, :invalid_precondition} = ContentCore.admit("agent", [{"timeout_ms", 1_000}])
      assert {:error, :invalid_precondition} = ContentCore.admit("agent", [:timeout_ms, 1_000])
      assert {:error, :invalid_precondition} = ContentCore.admit("agent", %{timeout_ms: 1_000})
      assert {:error, :invalid_precondition} = ContentCore.admit("agent", nil)

      assert {:error, :invalid_precondition} =
               ContentCore.admit("agent", timeout_ms: 1_000, timeout_ms: 2_000)
    end
  end

  describe "remaining_ms/2 and budgets" do
    test "propagates positive remaining and exhausts at zero" do
      assert {:ok, 40} = ContentCore.remaining_ms(100, 60)
      assert :exhausted = ContentCore.remaining_ms(100, 100)
      assert :exhausted = ContentCore.remaining_ms(100, 101)
      assert {:ok, 60_000} = ContentCore.remaining_ms(200_000, 100_000)
    end

    test "persistence budget keys and facade timeout opts" do
      assert [purge_timeout_ms: 12] = ContentCore.put_persistence_budget([], :purge, 12)
      assert [absence_timeout_ms: 9] = ContentCore.put_persistence_budget([], :absence, 9)

      # Keyword.put/3 prepends; assert by key rather than list order.
      budget = ContentCore.put_persistence_budget([repo: :r], :purge, 5)
      assert Keyword.get(budget, :repo) == :r
      assert Keyword.get(budget, :purge_timeout_ms) == 5

      assert [timeout_ms: 7] = ContentCore.facade_timeout_opts(7)
    end
  end

  describe "report transitions and finalize" do
    test "authority order and exact four keys" do
      assert ContentCore.authority_order() == [
               :signals,
               :local_event_log,
               :historian,
               :maintenance_archive
             ]

      report = ContentCore.init_delete_report()

      assert Map.keys(report) |> Enum.sort() ==
               [:historian, :local_event_log, :maintenance_archive, :signals]
    end

    test "init reports seed not_attempted_deadline; exception reports never do" do
      init = ContentCore.init_delete_report()
      assert Enum.all?(Map.values(init), &(&1 == :not_attempted_deadline))
      assert ContentCore.init_absence_report() == init

      delete_ex = ContentCore.exception_delete_report()
      absence_ex = ContentCore.exception_absence_report()

      assert Map.keys(delete_ex) |> Enum.sort() ==
               [:historian, :local_event_log, :maintenance_archive, :signals]

      assert Map.keys(absence_ex) |> Enum.sort() ==
               [:historian, :local_event_log, :maintenance_archive, :signals]

      assert Enum.all?(Map.values(delete_ex), &(&1 == :delete_indeterminate))
      assert Enum.all?(Map.values(absence_ex), &(&1 == :absence_indeterminate))
      refute Enum.any?(Map.values(delete_ex), &(&1 == :not_attempted_deadline))
      refute Enum.any?(Map.values(absence_ex), &(&1 == :not_attempted_deadline))
    end

    test "verify replaces uncertain delete status with authoritative results" do
      report =
        ContentCore.init_delete_report()
        |> ContentCore.put_status(:signals, :delete_succeeded_unverified)
        |> ContentCore.put_status(:local_event_log, :delete_failed)
        |> ContentCore.put_status(:historian, :delete_indeterminate)
        |> ContentCore.put_status(:maintenance_archive, :not_attempted_deadline)

      report =
        report
        |> ContentCore.apply_verify_result(:signals, :absent)
        |> ContentCore.apply_verify_result(:local_event_log, :present)
        |> ContentCore.apply_verify_result(:historian, :uncertain)
        |> ContentCore.apply_verify_result(:maintenance_archive, :uncertain)

      assert report.signals == :absent
      assert report.local_event_log == :present
      assert report.historian == :absence_indeterminate
      assert report.maintenance_archive == :absence_indeterminate
    end

    test "finalize_delete requires all absent" do
      full =
        ContentCore.init_delete_report()
        |> ContentCore.put_status(:signals, :absent)
        |> ContentCore.put_status(:local_event_log, :absent)
        |> ContentCore.put_status(:historian, :absent)
        |> ContentCore.put_status(:maintenance_archive, :absent)

      assert :ok = ContentCore.finalize_delete("agent", full)

      partial = ContentCore.put_status(full, :historian, :present)

      assert {:error, {:cleanup_incomplete, "agent", ^partial}} =
               ContentCore.finalize_delete("agent", partial)
    end

    test "finalize_absence: present wins, all absent true, else indeterminate" do
      present =
        ContentCore.init_absence_report()
        |> ContentCore.put_status(:signals, :present)
        |> ContentCore.put_status(:local_event_log, :absent)
        |> ContentCore.put_status(:historian, :absence_indeterminate)
        |> ContentCore.put_status(:maintenance_archive, :not_attempted_deadline)

      assert {:ok, false} = ContentCore.finalize_absence("agent", present)

      absent =
        ContentCore.init_absence_report()
        |> ContentCore.put_status(:signals, :absent)
        |> ContentCore.put_status(:local_event_log, :absent)
        |> ContentCore.put_status(:historian, :absent)
        |> ContentCore.put_status(:maintenance_archive, :absent)

      assert {:ok, true} = ContentCore.finalize_absence("agent", absent)

      uncertain =
        ContentCore.init_absence_report()
        |> ContentCore.put_status(:signals, :absent)
        |> ContentCore.put_status(:local_event_log, :absence_indeterminate)
        |> ContentCore.put_status(:historian, :absent)
        |> ContentCore.put_status(:maintenance_archive, :absent)

      assert {:error, {:absence_indeterminate, "agent", ^uncertain}} =
               ContentCore.finalize_absence("agent", uncertain)
    end

    test "absence continues after authoritative presence while budget remains" do
      # Shell visits all four authorities; present on signals still records later keys.
      continued =
        ContentCore.init_absence_report()
        |> ContentCore.put_status(:signals, :present)
        |> ContentCore.put_status(:local_event_log, :absent)
        |> ContentCore.put_status(:historian, :absent)
        |> ContentCore.put_status(:maintenance_archive, :absent)

      assert {:ok, false} = ContentCore.finalize_absence("agent", continued)
      assert continued.local_event_log == :absent
      assert continued.historian == :absent
      assert continued.maintenance_archive == :absent
      refute continued.local_event_log == :not_attempted_deadline
    end

    test "delete continues after deterministic failure statuses" do
      partial =
        ContentCore.init_delete_report()
        |> ContentCore.put_status(:signals, :absent)
        |> ContentCore.put_status(:local_event_log, :delete_failed)
        |> ContentCore.put_status(:historian, :delete_succeeded_unverified)
        |> ContentCore.put_status(:maintenance_archive, :absent)

      assert {:error, {:cleanup_incomplete, "agent", ^partial}} =
               ContentCore.finalize_delete("agent", partial)

      assert partial.signals == :absent
      assert partial.local_event_log == :delete_failed
      assert partial.historian == :delete_succeeded_unverified
    end
  end

  describe "classify replies" do
    test "delete classification maps nested successes and failures" do
      assert :delete_succeeded_unverified = ContentCore.classify_delete_reply(:signals, :ok)

      assert :delete_failed =
               ContentCore.classify_delete_reply(:signals, {:error, :store_unavailable})

      assert :delete_failed =
               ContentCore.classify_delete_reply(:historian, {:error, :durable_unavailable})

      assert :delete_indeterminate =
               ContentCore.classify_delete_reply(
                 :local_event_log,
                 {:error, {:purge_indeterminate, "s"}}
               )

      assert :delete_indeterminate =
               ContentCore.classify_delete_reply(
                 :historian,
                 {:error, {:delete_incomplete, "s", :durable_delete, :none_proven_absent}}
               )

      assert :delete_indeterminate = ContentCore.classify_delete_reply(:signals, :weird)
    end

    test "absence classification maps proofs and uncertainty" do
      assert :absent = ContentCore.classify_absence_reply(:signals, {:ok, true})
      assert :present = ContentCore.classify_absence_reply(:historian, {:ok, false})

      assert :uncertain =
               ContentCore.classify_absence_reply(:signals, {:error, :store_unavailable})

      assert :uncertain = ContentCore.classify_absence_reply(:signals, :malformed)
    end
  end
end
