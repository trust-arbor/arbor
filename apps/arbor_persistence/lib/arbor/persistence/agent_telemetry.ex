defmodule Arbor.Persistence.AgentTelemetry do
  @moduledoc """
  Durable telemetry events behind the `Arbor.Persistence` public facade.

  Owns repository availability, event attribute construction, adapter detection,
  SQL, row mapping, and placeholder construction. The Common store calls this
  only through `Arbor.Persistence`.
  """

  require Logger

  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.TelemetryEvent, as: TelemetryEventSchema

  @type adapter_kind :: :postgres | :sqlite | :unknown

  @doc """
  Insert one telemetry event.

  Returns `{:error, :repo_unavailable}` when the Repo process is not running.
  """
  @spec persist_event(String.t(), atom(), map()) ::
          :ok | {:error, :repo_unavailable | term()}
  def persist_event(agent_id, event_type, data)
      when is_binary(agent_id) and is_atom(event_type) and is_map(data) do
    with {:ok, _repo} <- available_repo() do
      attrs = %{
        id: generate_id(),
        agent_id: agent_id,
        event_type: to_string(event_type),
        timestamp: DateTime.utc_now(),
        data: stringify_data(data)
      }

      changeset = TelemetryEventSchema.changeset(%TelemetryEventSchema{}, attrs)

      case Repo.insert(changeset) do
        {:ok, _row} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Load lifetime aggregates for one agent.

  Returns a map of lifetime metrics or `nil` when the Repo is unavailable
  or the query does not produce a usable row.
  """
  @spec load_lifetime(String.t()) :: map() | nil
  def load_lifetime(agent_id) when is_binary(agent_id) do
    with {:ok, repo} <- available_repo() do
      {sql, _params} = lifetime_sql(adapter_kind(repo))

      case repo.query(sql, [agent_id]) do
        {:ok, %{rows: [[tc, ti, to_, tca, tco, cc]]}} ->
          %{
            turn_count: tc,
            lifetime_input_tokens: ti,
            lifetime_output_tokens: to_,
            lifetime_cached_tokens: tca,
            lifetime_cost: tco,
            compaction_count: cc
          }

        _ ->
          nil
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Query historical telemetry events for an agent.

  Options: `:event_type`, `:since`, `:until`, `:limit` (default 100),
  `:order` (`:asc` or `:desc`, default `:desc`).
  """
  @spec query_events(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :repo_unavailable | term()}
  def query_events(agent_id, opts \\ []) when is_binary(agent_id) do
    with {:ok, repo} <- available_repo() do
      kind = adapter_kind(repo)
      limit_val = normalize_limit(Keyword.get(opts, :limit, 100))
      order = if Keyword.get(opts, :order, :desc) == :asc, do: "ASC", else: "DESC"
      {where_clauses, params, _idx} = build_query_conditions(kind, agent_id, opts)

      sql = """
      SELECT id, agent_id, event_type, timestamp, data
      FROM telemetry_events
      WHERE #{Enum.join(where_clauses, " AND ")}
      ORDER BY timestamp #{order}
      LIMIT #{limit_val}
      """

      case repo.query(sql, params) do
        {:ok, %{rows: rows}} ->
          {:ok, Enum.map(rows, &map_event_row/1)}

        {:error, reason} ->
          Logger.warning("[Persistence.AgentTelemetry] Event query failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc false
  @spec adapter_kind(term()) :: adapter_kind()
  def adapter_kind(kind) when kind in [:postgres, :sqlite, :unknown], do: kind
  def adapter_kind(Ecto.Adapters.Postgres), do: :postgres
  def adapter_kind(Ecto.Adapters.SQLite3), do: :sqlite

  def adapter_kind(repo) when is_atom(repo) do
    adapter_kind(repo.__adapter__())
  rescue
    _ -> :unknown
  end

  def adapter_kind(_), do: :unknown

  @doc false
  @spec placeholder(adapter_kind() | term(), pos_integer()) :: String.t()
  def placeholder(:postgres, idx) when is_integer(idx) and idx > 0, do: "$#{idx}"
  def placeholder(_kind, _idx), do: "?"

  @doc false
  @spec build_query_conditions(adapter_kind() | term(), String.t(), keyword()) ::
          {[String.t()], [term()], pos_integer()}
  def build_query_conditions(adapter_kind, agent_id, opts)
      when is_binary(agent_id) and is_list(opts) do
    kind = adapter_kind(adapter_kind)
    clauses = ["agent_id = #{placeholder(kind, 1)}"]
    params = [agent_id]
    idx = 2

    {clauses, params, idx} =
      case Keyword.get(opts, :event_type) do
        nil ->
          {clauses, params, idx}

        type ->
          {clauses ++ ["event_type = #{placeholder(kind, idx)}"], params ++ [to_string(type)],
           idx + 1}
      end

    {clauses, params, idx} =
      case Keyword.get(opts, :since) do
        nil ->
          {clauses, params, idx}

        since ->
          {clauses ++ ["timestamp >= #{placeholder(kind, idx)}"], params ++ [since], idx + 1}
      end

    {clauses, params, idx} =
      case Keyword.get(opts, :until) do
        nil ->
          {clauses, params, idx}

        until_dt ->
          {clauses ++ ["timestamp <= #{placeholder(kind, idx)}"], params ++ [until_dt], idx + 1}
      end

    {clauses, params, idx}
  end

  @doc false
  @spec lifetime_sql(adapter_kind() | term()) :: {String.t(), [String.t()]}
  def lifetime_sql(adapter_kind) do
    kind = adapter_kind(adapter_kind)
    ph = placeholder(kind, 1)

    sql =
      case kind do
        :postgres -> postgres_lifetime_sql(ph)
        _ -> sqlite_lifetime_sql(ph)
      end

    {sql, [ph]}
  end

  defp postgres_lifetime_sql(ph) do
    """
    SELECT
      COUNT(*) FILTER (WHERE event_type = 'turn_completed') AS turn_count,
      COALESCE(SUM((data->>'input_tokens')::bigint) FILTER (WHERE event_type = 'turn_completed'), 0) AS total_input,
      COALESCE(SUM((data->>'output_tokens')::bigint) FILTER (WHERE event_type = 'turn_completed'), 0) AS total_output,
      COALESCE(SUM((data->>'cached_tokens')::bigint) FILTER (WHERE event_type = 'turn_completed'), 0) AS total_cached,
      COALESCE(SUM((data->>'cost')::float) FILTER (WHERE event_type = 'turn_completed'), 0.0) AS total_cost,
      COUNT(*) FILTER (WHERE event_type = 'compaction') AS compaction_count
    FROM telemetry_events
    WHERE agent_id = #{ph}
    """
  end

  defp sqlite_lifetime_sql(ph) do
    """
    SELECT
      SUM(CASE WHEN event_type = 'turn_completed' THEN 1 ELSE 0 END) AS turn_count,
      COALESCE(SUM(CASE WHEN event_type = 'turn_completed' THEN CAST(json_extract(data, '$.input_tokens') AS INTEGER) ELSE 0 END), 0) AS total_input,
      COALESCE(SUM(CASE WHEN event_type = 'turn_completed' THEN CAST(json_extract(data, '$.output_tokens') AS INTEGER) ELSE 0 END), 0) AS total_output,
      COALESCE(SUM(CASE WHEN event_type = 'turn_completed' THEN CAST(json_extract(data, '$.cached_tokens') AS INTEGER) ELSE 0 END), 0) AS total_cached,
      COALESCE(SUM(CASE WHEN event_type = 'turn_completed' THEN CAST(json_extract(data, '$.cost') AS REAL) ELSE 0 END), 0.0) AS total_cost,
      SUM(CASE WHEN event_type = 'compaction' THEN 1 ELSE 0 END) AS compaction_count
    FROM telemetry_events
    WHERE agent_id = #{ph}
    """
  end

  defp available_repo do
    if Process.whereis(Repo) do
      {:ok, Repo}
    else
      {:error, :repo_unavailable}
    end
  end

  defp normalize_limit(n) when is_integer(n) and n > 0, do: n
  defp normalize_limit(_), do: 100

  defp map_event_row([id, aid, etype, ts, data]) do
    %{
      id: id,
      agent_id: aid,
      event_type: etype,
      timestamp: ts,
      data: normalize_data(data)
    }
  end

  defp normalize_data(data) when is_map(data), do: data

  defp normalize_data(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp normalize_data(_), do: %{}

  defp generate_id do
    "tevt_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # Ensure all keys and atom values are strings for JSON serialization.
  defp stringify_data(data) when is_map(data) do
    Map.new(data, fn
      {key, value} when is_atom(value) -> {to_string(key), to_string(value)}
      {key, value} when is_map(value) -> {to_string(key), stringify_data(value)}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_data(other), do: other
end
