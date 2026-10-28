defmodule Arbor.Persistence.SQLiteBusyTimeout do
  @moduledoc false

  # Exqlite 0.42 stores the busy timeout on the NIF connection. Reading or
  # writing `PRAGMA busy_timeout` reports 0 and replaces the custom busy
  # handler, so later lock waits cannot be cancelled. The last value set on a
  # checked-out holder is recorded in that holder's ETS table because the NIF
  # has no getter.

  alias Ecto.Adapters.SQL

  @default_ms 2_000
  @tracker :arbor_busy_timeout

  @spec get(module()) :: non_neg_integer()
  def get(repo) when is_atom(repo) do
    with_holder(repo, fn holder -> read(holder, repo) end)
  end

  @spec set(module(), non_neg_integer()) :: :ok
  def set(repo, timeout) when is_atom(repo) and is_integer(timeout) and timeout >= 0 do
    with_holder(repo, fn holder ->
      case Exqlite.Sqlite3.set_busy_timeout(db!(holder), timeout) do
        :ok ->
          true = :ets.insert(holder, {@tracker, timeout})
          :ok

        {:error, reason} ->
          raise "sqlite busy timeout update failed: #{inspect(reason)}"
      end
    end)
  end

  @spec restore(module(), non_neg_integer()) :: :ok
  def restore(repo, timeout) when is_atom(repo) and is_integer(timeout) and timeout >= 0 do
    set(repo, timeout)
  rescue
    ArgumentError -> :ok
  catch
    :exit, reason ->
      if connection_gone?(reason), do: :ok, else: exit(reason)
  end

  defp with_holder(repo, fun) do
    meta = repo.get_dynamic_repo() |> Ecto.Adapter.lookup_meta()

    if SQL.checked_out?(meta) do
      fun.(holder!(meta))
    else
      SQL.checkout(meta, [timeout: 5_000], fn -> fun.(holder!(meta)) end)
    end
  end

  defp holder!(%{pid: pool}) do
    require DBConnection.Holder

    case Process.get({SQL, pool}) do
      %DBConnection{pool_ref: pool_ref} ->
        DBConnection.Holder.pool_ref(pool_ref, :holder)

      other ->
        raise "sqlite busy timeout requires a checked-out connection, got: #{inspect(other)}"
    end
  end

  defp db!(holder) do
    require DBConnection.Holder

    case :ets.lookup(holder, :conn) do
      [row] ->
        case row |> DBConnection.Holder.conn(:state) |> exqlite_db() do
          db when not is_nil(db) ->
            db

          _ ->
            raise "sqlite busy timeout requires an Exqlite connection"
        end

      _ ->
        raise "sqlite busy timeout connection holder is empty"
    end
  end

  # The SQL sandbox stores `{Exqlite.Connection, %Exqlite.Connection{}, in_transaction?}`
  # as the holder state. A direct struct match misses that wrapper and the
  # raised message contains "timeout", which session acquisition treats as a
  # retryable pool failure until its deadline.
  defp exqlite_db(%Exqlite.Connection{db: db}), do: db
  defp exqlite_db({_module, state, _in_transaction?}), do: exqlite_db(state)
  defp exqlite_db(_state), do: nil

  defp read(holder, _repo) do
    case :ets.lookup(holder, @tracker) do
      [{@tracker, timeout}] when is_integer(timeout) and timeout >= 0 ->
        timeout

      _ ->
        # `Repo.config/0` ignores start_link options, and Exqlite 0.42 has no
        # getter for the NIF timeout. The connection process keeps the options
        # it used at connect, which is the value SQLite is actually using.
        configured_from_holder(holder)
    end
  end

  defp configured_from_holder(holder) do
    require DBConnection.Holder

    case :ets.lookup(holder, :conn) do
      [row] ->
        row
        |> DBConnection.Holder.conn(:connection)
        |> timeout_from_connection()

      _ ->
        @default_ms
    end
  end

  defp timeout_from_connection(pid) when is_pid(pid) do
    pid
    |> :sys.get_state()
    |> connection_opts()
    |> keyword_timeout()
  rescue
    _ -> @default_ms
  end

  defp timeout_from_connection(_pid), do: @default_ms

  defp connection_opts({_status, %{opts: opts}}), do: unwrap_opts(opts)
  defp connection_opts(%{opts: opts}), do: unwrap_opts(opts)
  defp connection_opts(_state), do: []

  # DBConnection 2.10 wraps the keyword in this struct when the options cross
  # a process boundary. Reading the wrapped value as a keyword misses
  # `:busy_timeout` and reports the 2000 ms fallback.
  defp unwrap_opts(%DBConnection.SensitiveData{data: data}), do: unwrap_opts(data)
  defp unwrap_opts(opts) when is_list(opts), do: opts
  defp unwrap_opts(_opts), do: []

  defp keyword_timeout(opts) do
    case Keyword.get(opts, :busy_timeout) do
      timeout when is_integer(timeout) and timeout >= 0 -> timeout
      _ -> @default_ms
    end
  end

  defp connection_gone?(reason) do
    reason == :noproc or nested_noproc?(reason) or closed_message?(reason)
  end

  defp nested_noproc?(reason) when is_tuple(reason),
    do: Enum.any?(Tuple.to_list(reason), &nested_noproc?/1)

  defp nested_noproc?(reason) when is_list(reason), do: Enum.any?(reason, &nested_noproc?/1)
  defp nested_noproc?(reason), do: reason == :noproc

  defp closed_message?(reason) when is_binary(reason),
    do: String.contains?(String.downcase(reason), "connection is closed")

  defp closed_message?(%{__exception__: true} = error),
    do: error |> Exception.message() |> closed_message?()

  defp closed_message?(reason) when is_tuple(reason),
    do: Enum.any?(Tuple.to_list(reason), &closed_message?/1)

  defp closed_message?(reason) when is_list(reason), do: Enum.any?(reason, &closed_message?/1)
  defp closed_message?(_reason), do: false
end
