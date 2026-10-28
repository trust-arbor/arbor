defmodule Arbor.Persistence.Test.SessionCreationContentionFixture do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks
  alias Arbor.Persistence.Repo
  @names [Repo, :session_creation_peer_one, :session_creation_peer_two]

  def start_peers!(database) do
    for name <- tl(@names) do
      start_supervised!(
        Supervisor.child_spec(
          {Repo,
           database: database,
           name: name,
           pool: DBConnection.ConnectionPool,
           pool_size: 4,
           busy_timeout: 5_000,
           journal_mode: :wal},
          id: name
        )
      )
    end

    warm!()
  end

  def warm! do
    observer = self()

    tasks =
      for name <- @names, _ <- 1..4 do
        Task.async(fn ->
          Repo.put_dynamic_repo(name)

          Repo.checkout(fn ->
            assert Arbor.Persistence.SQLiteBusyTimeout.get(Repo) == 5_000
            send(observer, {:connection_warm, self()})

            receive do
              :release -> :ok
            after
              5_000 -> raise "warm release missing"
            end
          end)
        end)
      end

    for _ <- tasks, do: assert_receive({:connection_warm, _}, 5_000)
    Enum.each(tasks, &send(&1.pid, :release))
    Enum.each(tasks, &Task.await(&1, 5_000))
    :ok
  end

  def hold_writer! do
    observer = self()

    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("UPDATE sessions SET status = status")
          send(observer, {:physical_writer_held, self()})

          receive do
            :release -> :ok
          after
            15_000 -> raise "writer release missing"
          end
        end)
      end)

    assert_receive {:physical_writer_held, _}, 5_000
    task
  end

  def observe_lookups! do
    observer = self()
    handler = "session-creation-lookups-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, metadata, _config ->
          if String.starts_with?(metadata.query, "SELECT") and
               String.contains?(metadata.query, "FROM \"sessions\"") do
            send(observer, {:creation_lookup_complete, self()})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  def start_creators!(opts \\ []) do
    handler = Keyword.get_lazy(opts, :handler, &observe_lookups!/0)
    unique = System.unique_integer([:positive])

    tasks =
      for {name, index} <- Enum.with_index(@names),
          n <- 1..if(index == 0, do: Keyword.get(opts, :canonical_count, 4), else: 4) do
        Task.async(fn ->
          Repo.put_dynamic_repo(name)

          try do
            Arbor.Persistence.ensure_session(
              "contender-#{unique}-#{index}-#{n}",
              "agent_contender"
            )
          rescue
            exception -> {:raised, exception.__struct__}
          catch
            kind, _reason -> {:raised, kind}
          end
        end)
      end

    %{tasks: tasks, handler: handler}
  end

  def release_after_lookups!(writer, creators, lookup_count \\ 10) do
    # Ten native IO threads are the pinned default. Do not alter schedulers,
    # pool sizes, busy waits or deadlines to create or conceal contention.
    assert :erlang.system_info(:dirty_io_schedulers) == 10
    for _ <- 1..lookup_count, do: assert_receive({:creation_lookup_complete, _}, 3_000)
    Process.sleep(50)
    before_release = System.monotonic_time(:millisecond)
    send(writer.pid, :release)
    assert {:ok, :ok} = Task.await(writer, 15_000)
    duration = System.monotonic_time(:millisecond) - before_release
    :telemetry.detach(creators.handler)
    %{writer_release_ms: duration, results: Enum.map(creators.tasks, &Task.await(&1, 15_000))}
  end
end
