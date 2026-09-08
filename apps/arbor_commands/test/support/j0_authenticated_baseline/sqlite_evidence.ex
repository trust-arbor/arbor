defmodule Arbor.Commands.J0AuthenticatedBaseline.SqliteEvidence do
  @moduledoc false

  import ExUnit.Assertions

  alias Arbor.Persistence
  alias Arbor.Persistence.Repo

  @max_attempts 40
  @interval_ms 25

  def start_owned_repo!(database) when is_binary(database) do
    File.mkdir_p!(Path.dirname(database))
    File.rm(database)

    if repo_alive?() do
      flunk("""
      J0 baseline requires an exclusive test-owned SQLite Repo.
      Arbor.Persistence.Repo is already running; refuse to hijack it.
      """)
    end

    # Suite restoration: stop_owned_repo/1 calls restore_repo_config(previous);
    # start_suite!/1 @env_keys already includes {:arbor_persistence, Repo}.
    previous = Application.fetch_env(:arbor_persistence, Repo)

    Application.put_env(
      :arbor_persistence,
      Repo,
      database: database,
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 5_000,
      journal_mode: :wal
    )

    {:ok, pid} =
      Repo.start_link(
        database: database,
        pool: DBConnection.ConnectionPool,
        pool_size: 4,
        busy_timeout: 5_000,
        journal_mode: :wal
      )

    migrations = migrations_path!()
    assert [_ | _] = Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)

    %{pid: pid, database: database, previous_config: previous}
  end

  def stop_owned_repo(%{pid: pid, previous_config: previous}) do
    if is_pid(pid) and Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    restore_repo_config(previous)
    :ok
  end

  def stop_owned_repo(_), do: :ok

  def await_committed_pair!(session_id, engagement_id, marker) do
    await_committed_pair!(session_id, engagement_id, marker, @max_attempts)
  end

  defp await_committed_pair!(_session_id, engagement_id, marker, 0) do
    flunk("""
    timed out waiting for a committed SQLite user/assistant pair \
    scoped to engagement #{inspect(engagement_id)} containing #{inspect(marker)}
    """)
  end

  defp await_committed_pair!(session_id, engagement_id, marker, attempts) do
    loaded =
      Persistence.load_recent_session_messages(session_id,
        engagement_id: engagement_id,
        limit: 50
      )

    case loaded do
      messages when is_list(messages) ->
        case pair_for(messages, marker) do
          {:ok, pair} ->
            pair

          :miss ->
            Process.sleep(@interval_ms)
            await_committed_pair!(session_id, engagement_id, marker, attempts - 1)
        end

      {:error, reason} ->
        flunk(
          "persistence error while polling engagement #{inspect(engagement_id)}: #{inspect(reason)}"
        )

      other ->
        flunk(
          "unexpected persistence shape while polling engagement #{inspect(engagement_id)}: #{inspect(other)}"
        )
    end
  end

  defp pair_for(messages, marker) when is_list(messages) do
    rendered =
      Enum.map(messages, fn message ->
        {Map.get(message, :role), content_text(Map.get(message, :content))}
      end)

    has_user? =
      Enum.any?(rendered, fn {role, text} ->
        role in [:user, "user"] and String.contains?(text, marker)
      end)

    has_assistant? =
      Enum.any?(rendered, fn {role, text} ->
        role in [:assistant, "assistant"] and String.trim(text) != ""
      end)

    if has_user? and has_assistant? do
      {:ok, rendered}
    else
      :miss
    end
  end

  defp content_text(text) when is_binary(text), do: text
  defp content_text(other), do: inspect(other)

  defp restore_repo_config({:ok, value}), do: Application.put_env(:arbor_persistence, Repo, value)
  defp restore_repo_config(:error), do: Application.delete_env(:arbor_persistence, Repo)

  defp repo_alive? do
    case Process.whereis(Repo) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp migrations_path! do
    case :code.priv_dir(:arbor_persistence) do
      {:error, reason} ->
        flunk("arbor_persistence priv dir unavailable: #{inspect(reason)}")

      priv when is_list(priv) or is_binary(priv) ->
        path = Path.join([to_string(priv), "repo", "migrations"])
        assert File.dir?(path), "missing migrations at #{path}"
        path
    end
  end
end
