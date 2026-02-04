defmodule Arbor.Persistence.Backup.SchedulerTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Backup.Scheduler

  @moduletag :fast

  describe "init/1" do
    setup do
      stop_scheduler()

      # Clear any existing config
      Application.delete_env(:arbor_persistence, :backup)

      on_exit(fn ->
        stop_scheduler()

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
      # Set schedule to a time that has definitely passed today
      past_hour = rem(DateTime.utc_now().hour + 22, 24)

      Application.put_env(:arbor_persistence, :backup,
        enabled: true,
        schedule: {past_hour, 0}
      )

      {:ok, _pid} = Scheduler.start_link([])

      next_time = Scheduler.next_backup_time()
      now = DateTime.utc_now()

      # Should be scheduled for the future
      assert DateTime.compare(next_time, now) == :gt
    end
  end

  defp stop_scheduler do
    case Process.whereis(Scheduler) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          GenServer.stop(pid)
        else
          :ok
        end

      _ ->
        :ok
    end
  end
end
