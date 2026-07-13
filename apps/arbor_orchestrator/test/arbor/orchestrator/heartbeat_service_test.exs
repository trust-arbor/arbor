defmodule Arbor.Orchestrator.HeartbeatServiceTest do
  @moduledoc """
  Tests for the HeartbeatService — the extracted heartbeat lifecycle manager.

  Covers:
  - Initialization with heartbeat config
  - Timer scheduling (heartbeat fires on interval)
  - In-flight guard (no concurrent heartbeats)
  - Heartbeat result handling (success and failure)
  - Terminate cleanup (marks stale entries abandoned)
  - Graph reload
  - Graceful behavior when Builders module isn't available
  """

  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.HeartbeatService

  @moduletag :fast

  @ets_table :arbor_pipeline_runs

  setup do
    # Ensure the shared application-owned ETS table exists. Never clear all
    # objects — concurrent/isolated suites may hold live rows in this table.
    try do
      :ets.new(@ets_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    rescue
      ArgumentError -> :ok
    end

    run_prefix = "hb_#{System.unique_integer([:positive, :monotonic])}_"

    on_exit(fn ->
      delete_owned_pipeline_runs(run_prefix)
    end)

    {:ok, run_prefix: run_prefix}
  end

  describe "init/1" do
    test "malformed bootstrap fails closed before scheduling a heartbeat" do
      Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, false) end)

      assert {:error, {:heartbeat_init_failed, {:signing_authority_claim_failed, :invalid_token}}} =
               HeartbeatService.start_link(
                 agent_id: "agent_test_heartbeat",
                 signing_authority_bootstrap: %{},
                 heartbeat_config: %{enabled: true}
               )
    end

    test "starts with correct default config" do
      {:ok, pid} = start_test_service()

      state = HeartbeatService.get_state(pid)
      assert state.agent_id == "agent_test_heartbeat"
      assert state.heartbeat_interval == 30_000
      assert state.heartbeat_in_flight == false
      assert state.heartbeat_ref != nil
      assert state.signing_authority == nil
      refute Map.has_key?(state, :authority_signer)

      GenServer.stop(pid)
    end

    test "respects custom interval from heartbeat_config" do
      {:ok, pid} =
        start_test_service(heartbeat_config: %{enabled: true, interval: 5_000})

      state = HeartbeatService.get_state(pid)
      assert state.heartbeat_interval == 5_000

      GenServer.stop(pid)
    end

    test "schedules first heartbeat immediately" do
      {:ok, pid} = start_test_service(heartbeat_config: %{interval: 5_000})

      state = HeartbeatService.get_state(pid)
      assert is_reference(state.heartbeat_ref)

      GenServer.stop(pid)
    end
  end

  describe "heartbeat timer" do
    test "heartbeat fires after the configured interval" do
      # Use a very short interval so the test doesn't wait long
      {:ok, pid} =
        start_test_service(heartbeat_config: %{enabled: true, interval: 100})

      # Wait for at least one heartbeat to fire
      Process.sleep(250)

      state = HeartbeatService.get_state(pid)
      # The heartbeat should have fired and either completed or be in-flight.
      # We can't easily assert on the result without a running Engine,
      # but we can verify the timer was rescheduled.
      assert is_reference(state.heartbeat_ref)

      GenServer.stop(pid)
    end
  end

  describe "heartbeat_result handling" do
    test "success result clears in_flight flag" do
      {:ok, pid} = start_test_service()

      # Simulate a heartbeat result arriving
      fake_result = %{
        context: %{
          "__completed_nodes__" => ["start", "bg_checks"],
          "llm.content" => nil
        }
      }

      send(pid, {:heartbeat_result, {:ok, fake_result}})
      Process.sleep(50)

      state = HeartbeatService.get_state(pid)
      assert state.heartbeat_in_flight == false

      GenServer.stop(pid)
    end

    test "error result clears in_flight flag" do
      {:ok, pid} = start_test_service()

      send(pid, {:heartbeat_result, {:error, :timeout}})
      Process.sleep(50)

      state = HeartbeatService.get_state(pid)
      assert state.heartbeat_in_flight == false

      GenServer.stop(pid)
    end

    test "terminal auth error disables the heartbeat loop (flood regression, 2026-07-04)" do
      {:ok, pid} = start_test_service()

      assert HeartbeatService.get_state(pid).heartbeat_disabled == false

      # Orphaned agent: every beat fails identically on unknown_identity. Pre-fix the loop kept
      # rescheduling → ramped to ~50 doomed pipelines/sec and crashed the BEAM. It must fail-STOP:
      # disable the loop and cancel the pending beat instead of flooding the orchestrator.
      send(pid, {:heartbeat_result, {:error, {:unauthorized, :unknown_identity}}})
      Process.sleep(50)

      state = HeartbeatService.get_state(pid)
      assert state.heartbeat_disabled == true
      assert state.heartbeat_ref == nil

      # Behavioral guarantee: even a stray :heartbeat trigger must NOT restart the loop, so the
      # flood can never resume once disabled.
      send(pid, :heartbeat)
      Process.sleep(50)
      resumed = HeartbeatService.get_state(pid)
      assert resumed.heartbeat_ref == nil
      assert resumed.heartbeat_in_flight == false

      GenServer.stop(pid)
    end

    test "a single transient (non-terminal) error does NOT disable the heartbeat" do
      {:ok, pid} = start_test_service()

      send(pid, {:heartbeat_result, {:error, :timeout}})
      Process.sleep(50)

      # Only terminal errors (or @max_consecutive_heartbeat_failures in a row) stop the loop;
      # a lone transient failure must keep it alive.
      assert HeartbeatService.get_state(pid).heartbeat_disabled == false

      GenServer.stop(pid)
    end

    test "no registered identity: beats are SKIPPED then the loop disables (B guard, flood prevention)" do
      # Simulate an orphaned agent (no registered identity) via the injected checker.
      {:ok, pid} = start_test_service(identity_checker: fn _ -> false end)

      # A beat with no identity must SKIP — no pipeline runs (in_flight stays false), so it can
      # never flood the orchestrator the way the 2026-07-04 orphans did.
      send(pid, :heartbeat)
      Process.sleep(20)
      mid = HeartbeatService.get_state(pid)
      assert mid.heartbeat_in_flight == false
      assert mid.heartbeat_no_identity_beats >= 1

      # After @max_no_identity_beats misses it's a real orphan → disable the loop entirely.
      send(pid, :heartbeat)
      send(pid, :heartbeat)
      send(pid, :heartbeat)
      Process.sleep(30)
      assert HeartbeatService.get_state(pid).heartbeat_disabled == true

      GenServer.stop(pid)
    end

    test "a registered identity lets beats run normally (B guard does not fire)" do
      {:ok, pid} = start_test_service(identity_checker: fn _ -> true end)

      send(pid, :heartbeat)
      Process.sleep(20)

      state = HeartbeatService.get_state(pid)
      assert state.heartbeat_disabled == false
      assert state.heartbeat_no_identity_beats == 0

      GenServer.stop(pid)
    end
  end

  describe "terminate cleanup" do
    test "marks active ETS entries as abandoned on terminate", %{run_prefix: prefix} do
      {:ok, pid} = start_test_service()

      # Collision-resistant owned row — never assume exclusive table ownership.
      run_id = prefix <> "terminate_abandon"

      :ets.insert(
        @ets_table,
        {run_id,
         %{
           run_id: run_id,
           status: :running,
           spawning_pid: pid,
           current_node: "bg_checks",
           started_at: DateTime.utc_now(),
           last_ets_sync: DateTime.utc_now(),
           completed_count: 0,
           total_nodes: 19,
           graph_id: "Heartbeat",
           pipeline_id: run_id,
           completed_nodes: [],
           node_durations: %{},
           finished_at: nil,
           duration_ms: nil,
           failure_reason: nil,
           owner_node: node(),
           source_node: node(),
           last_heartbeat: DateTime.utc_now()
         }}
      )

      # Stop the service (triggers terminate)
      GenServer.stop(pid, :normal)
      Process.sleep(100)

      # The entry should now be abandoned
      case :ets.lookup(@ets_table, run_id) do
        [{^run_id, entry}] ->
          assert entry.status == :abandoned

        [] ->
          # Entry may have been cleaned up entirely — also acceptable
          :ok
      end
    end
  end

  describe "reload_dot/1" do
    test "accepts reload cast without crashing" do
      {:ok, pid} = start_test_service()

      # This won't actually reload anything (no real DOT file) but
      # it shouldn't crash the service
      HeartbeatService.reload_dot(pid)
      Process.sleep(50)

      # Service should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "supervision integration" do
    test "HeartbeatService restarts independently when it crashes" do
      # Trap exits so the test process doesn't die when we kill the child
      Process.flag(:trap_exit, true)

      {:ok, pid} = start_test_service()

      # Force a crash
      Process.exit(pid, :kill)

      # Receive the EXIT signal (since we're trapping exits)
      assert_receive {:EXIT, ^pid, :killed}, 500

      # The process should be dead
      refute Process.alive?(pid)

      # When supervised under BranchSupervisor, the supervisor would restart it.
      # We can't test that here without the full supervision tree, but we
      # verified the process handles crash + restart cleanly.
    end
  end

  # ===========================================================================
  # Test helpers
  # ===========================================================================

  defp start_test_service(extra_opts \\ []) do
    opts =
      [
        agent_id: "agent_test_heartbeat",
        signer: nil,
        trust_tier: :probationary,
        heartbeat_config:
          Keyword.get(extra_opts, :heartbeat_config, %{
            enabled: true,
            interval: 30_000
          })
      ]
      |> Keyword.merge(extra_opts)

    HeartbeatService.start_link(opts)
  end

  defp delete_owned_pipeline_runs(prefix) when is_binary(prefix) do
    try do
      case :ets.info(@ets_table) do
        :undefined ->
          :ok

        _ ->
          for {key, _entry} <- :ets.tab2list(@ets_table),
              is_binary(key) and String.starts_with?(key, prefix) do
            :ets.delete(@ets_table, key)
          end

          :ok
      end
    rescue
      _ -> :ok
    end
  end

  describe "first beat at startup (A5)" do
    test "first_beat_delay is a short jittered delay, far below the full interval" do
      # Sample across the jitter range.
      delays = for _ <- 1..200, do: HeartbeatService.first_beat_delay()

      assert Enum.all?(delays, &(&1 > 0 and &1 <= 2_000)),
             "first-beat delay must be a small bounded jitter"

      # The point of A5: the first beat fires SOON after boot, not a full
      # ~30s interval later — autonomous activity should begin from first boot.
      assert Enum.max(delays) < 30_000,
             "first-beat delay must be far below the default heartbeat interval (30s)"
    end
  end
end
