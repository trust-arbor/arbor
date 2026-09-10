defmodule Arbor.Scheduler.RoutineStore do
  @moduledoc false
  import Ecto.Query
  alias Arbor.Scheduler.Config
  alias Arbor.Scheduler.Cores.RoutineCore
  alias Arbor.Scheduler.Workers.OwnedRoutineRunner
  alias Ecto.Adapters.SQL

  @worker "Arbor.Scheduler.Workers.OwnedRoutineRunner"
  @claim_key "routine_attempt_claim"
  @request_index "oban_owned_routine_request_key_unique"

  def insert(envelope, request_key, at) do
    with :ok <- require_request_index() do
      changeset =
        OwnedRoutineRunner.new(%{"owned_routine" => envelope, "request_key" => request_key},
          scheduled_at: at,
          unique: [
            period: :infinity,
            fields: [:worker, :args],
            keys: [:request_key],
            states: Oban.Job.states()
          ]
        )
        |> Ecto.Changeset.unique_constraint(:args, name: @request_index)

      case Oban.insert(Config.oban_name(), changeset) do
        {:ok, %Oban.Job{}} ->
          persisted_request(request_key)

        {:error, %Ecto.Changeset{errors: errors}} = error ->
          if Enum.any?(errors, fn {_field, {_message, detail}} ->
               detail[:constraint] == :unique and detail[:constraint_name] == @request_index
             end) do
            persisted_request(request_key)
          else
            error
          end

        {:error, _} = error ->
          error

        _ ->
          {:error, :routine_store_unavailable}
      end
    end
  end

  # Basic's advisory-lock loser and INSERT ... DO NOTHING may return an
  # unpersisted Job. Success means observing the actual committed SQL row;
  # the facade then verifies its retained signature and complete exact intent.
  defp persisted_request(request_key) do
    case Config.repo().one(
           from(j in Oban.Job,
             where: j.worker == @worker and j.args["request_key"] == ^request_key
           )
         ) do
      %Oban.Job{id: id} = job when is_integer(id) and id > 0 -> {:ok, job}
      _ -> {:error, :routine_enqueue_not_committed}
    end
  end

  defp require_request_index do
    sql =
      case Config.repo().__adapter__() do
        Ecto.Adapters.SQLite3 ->
          "SELECT 1 FROM sqlite_master WHERE type = 'index' AND tbl_name = 'oban_jobs' AND name = ?"

        Ecto.Adapters.Postgres ->
          "SELECT 1 FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'oban_jobs' AND indexname = $1"
      end

    case SQL.query(Config.repo(), sql, [@request_index]) do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, _} -> {:error, :routine_store_migration_required}
      {:error, _} -> {:error, :routine_store_unavailable}
    end
  end

  def get(id) when is_integer(id) and id > 0 do
    case Config.repo().get(Oban.Job, id) do
      %Oban.Job{worker: @worker} = job -> {:ok, job}
      _ -> {:error, :routine_not_found}
    end
  end

  def get(_), do: {:error, :routine_not_found}

  # Bounded scan; owner hints are never authority. The facade verifies every
  # returned envelope before projection, including rows written outside it.
  def list(%{"limit" => limit, "before_id" => before_id}, principal) do
    query =
      from(j in Oban.Job,
        where: j.worker == @worker and j.args["owned_routine"]["proof"]["agent_id"] == ^principal,
        order_by: [desc: j.id],
        limit: ^limit
      )

    query = if before_id, do: where(query, [j], j.id < ^before_id), else: query
    {:ok, Config.repo().all(query)}
  end

  def cancel(%Oban.Job{} = job) do
    # Oban owns cancellation and its executing-worker notification. Its SQL
    # state change is checked again by the effect gate, independent of signals.
    query = exact_query(job)

    case Oban.cancel_all_jobs(Config.oban_name(), query) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :routine_state_changed}
      _ -> {:error, :routine_store_unavailable}
    end
  end

  def claim(%Oban.Job{} = job, token) do
    digest = RoutineCore.digest(token)
    existing = Map.get(job.meta, @claim_key)

    with :ok <- executing(job),
         true <- is_nil(existing) or (is_map(existing) and existing["attempt"] != job.attempt),
         claim = %{"attempt" => job.attempt, "token_digest" => digest},
         meta = Map.put(job.meta, @claim_key, claim),
         query =
           where(
             exact_query(job),
             [j],
             j.attempted_at == ^job.attempted_at and j.attempted_by == ^job.attempted_by and
               j.queue == ^job.queue and j.max_attempts == ^job.max_attempts
           ),
         {1, _} <- Config.repo().update_all(query, set: [meta: meta]) do
      {:ok, %{job | meta: meta}}
    else
      _ -> {:error, :routine_attempt_already_claimed}
    end
  end

  def current?(%Oban.Job{} = expected, token) do
    with {:ok, current} <- get(expected.id),
         :ok <- executing(current),
         true <- current.attempt == expected.attempt,
         true <- current.attempted_by == expected.attempted_by,
         true <- current.attempted_at == expected.attempted_at,
         true <- current.args == expected.args and current.scheduled_at == expected.scheduled_at,
         %{"attempt" => attempt, "token_digest" => digest} <- Map.get(current.meta, @claim_key),
         true <- attempt == expected.attempt and digest == RoutineCore.digest(token) do
      :ok
    else
      _ -> {:error, :routine_execution_no_longer_current}
    end
  end

  def executing(%Oban.Job{
        state: "executing",
        queue: "pipelines",
        max_attempts: 3,
        attempt: attempt,
        attempted_at: %DateTime{},
        attempted_by: [_ | _],
        scheduled_at: %DateTime{} = at
      })
      when attempt in 1..3 do
    if DateTime.compare(at, DateTime.utc_now()) != :gt, do: :ok, else: {:error, :routine_not_due}
  end

  def executing(_), do: {:error, :routine_not_executing}

  defp exact_query(job) do
    query =
      from(j in Oban.Job,
        where:
          j.id == ^job.id and j.worker == ^job.worker and j.state == ^job.state and
            j.attempt == ^job.attempt and j.args == ^job.args and j.meta == ^job.meta and
            j.scheduled_at == ^job.scheduled_at
      )

    query =
      if is_nil(job.attempted_at),
        do: where(query, [j], is_nil(j.attempted_at)),
        else: where(query, [j], j.attempted_at == ^job.attempted_at)

    if is_nil(job.attempted_by),
      do: where(query, [j], is_nil(j.attempted_by)),
      else: where(query, [j], j.attempted_by == ^job.attempted_by)
  end
end
