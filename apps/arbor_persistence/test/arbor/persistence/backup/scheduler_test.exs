defmodule Arbor.Persistence.Backup.SchedulerTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Backup.Scheduler

  @moduletag :fast

  describe "init/1" do
    setup do
      # Stop any existing scheduler
      if pid = Process.whereis(Scheduler) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      # Clear any existing config
      Application.delete_env(:arbor_persistence, :backup)

      on_exit(fn ->
        if pid = Process.whereis(Scheduler) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end

        Application.delete_env(:arbor_persistence, :backup)
      end)

      :ok
    end

    test "starts disabled when enabled: false" do
      Application.put_env(:arbor_persistence, :backup, enabled: false)

      {:ok, pid} = Scheduler.start_link([])
      assert Process.alive?(pid)

      # Should return nil for next_backup_time when disabled
      assert Scheduler.next_backup_time() == nil
    end

    test "calculates next run time when enabled" do
      # Set schedule to a time that hasn't passed today
      future_hour = rem(DateTime.utc_now().hour + 2, 24)

      Application.put_env(:arbor_persistence, :backup,
        enabled: true,
        schedule: {future_hour, 30}
      )

      {:ok, _pid} = Scheduler.start_link([])

      next_time = Scheduler.next_backup_time()
      assert %DateTime{} = next_time
      assert next_time.hour == future_hour
      assert next_time.minute == 30
    end

    test "schedules for next day if time already passed" do
      # Use an hour that is definitely in the past: current hour minus 2
      # (wrapping around midnight). The minute is set to 0 so even if we're
      # at the same hour, the time has passed.
      now = DateTime.utc_now()
      past_hour = rem(now.hour + 22, 24)
      # Use a minute that guarantees it's in the past even if same hour
      past_minute = max(now.minute - 2, 0)

      Application.put_env(:arbor_persistence, :backup,
        enabled: true,
        schedule: {past_hour, past_minute}
      )

      {:ok, _pid} = Scheduler.start_link([])

      next_time = Scheduler.next_backup_time()

      # Should be scheduled for the future (tomorrow at that time)
      assert DateTime.compare(next_time, now) == :gt
    end
  end
end
