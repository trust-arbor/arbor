defmodule Arbor.Actions.Jobs do
  @moduledoc """
  Job tracking actions for persistent task management across sessions.

  Jobs represent work the Mind wants done. They survive BEAM restarts
  and context resets, providing cross-session continuity.

  ## Configuration

  Persistence backends are resolved at runtime:

      config :arbor_actions, :persistence,
        queryable_store_backend: Arbor.Persistence.QueryableStore.Postgres,
        event_log_backend: Arbor.Persistence.EventLog.Postgres

  ## Lifecycle

      created ──► active ──► completed
                        ├──► failed
                        └──► cancelled
  """

  alias Arbor.Actions
  alias Arbor.Persistence.{Event, Filter, Record}

  @namespace :jobs
  @event_stream_prefix "jobs"

  @doc false
  def queryable_backend do
    config = Application.get_env(:arbor_actions, :persistence, [])

    Keyword.get(config, :queryable_store_backend,
      Arbor.Persistence.QueryableStore.ETS)
  end

  @doc false
  def event_log_backend do
    config = Application.get_env(:arbor_actions, :persistence, [])

    Keyword.get(config, :event_log_backend,
      Arbor.Persistence.EventLog.ETS)
  end

  @doc false
  def persistence_opts do
    [name: @namespace, repo: Arbor.Persistence.Repo]
  end

  @doc false
  def event_log_opts do
    [name: :event_log, repo: Arbor.Persistence.Repo]
  end

  @doc false
  def job_stream(job_id), do: "#{@event_stream_prefix}-#{job_id}"

  # ============================================================================
  # CreateJob
  # ============================================================================

  defmodule CreateJob do
    @moduledoc """
    Create a new persistent job for cross-session task tracking.

    ## Examples

        Arbor.Actions.Jobs.CreateJob.run(
          %{title: "Refactor comms module", priority: "high", tags: ["refactor"]},
          %{}
        )
    """

    use Jido.Action,
      name: "jobs_create",
      description: "Create a new persistent job for task tracking",
      category: "jobs",
      tags: ["jobs", "tasks", "create"],
      schema: [
        title: [type: :string, required: true, doc: "Job title"],
        description: [type: :string, default: "", doc: "Detailed description"],
        priority: [type: :string, default: "normal", doc: "low, normal, high, critical"],
        tags: [type: {:list, :string}, default: [], doc: "Categorization tags"]
      ]

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)
      jobs = Arbor.Actions.Jobs

      job_id = Arbor.Identifiers.generate_id("job_")

      data = %{
        "status" => "created",
        "title" => params.title,
        "description" => params[:description] || "",
        "priority" => params[:priority] || "normal",
        "tags" => params[:tags] || [],
        "notes" => [],
        "session_ids" => [],
        "result" => nil
      }

      record = Record.new(job_id, data)

      case jobs.queryable_backend().put(job_id, record, jobs.persistence_opts()) do
        :ok ->
          # Append creation event
          event = Event.new(jobs.job_stream(job_id), "job.created", %{
            job_id: job_id,
            title: params.title,
            priority: params[:priority] || "normal",
            tags: params[:tags] || []
          })

          jobs.event_log_backend().append(
            jobs.job_stream(job_id),
            event,
            jobs.event_log_opts()
          )

          result = %{job_id: job_id, status: "created", title: params.title}
          Actions.emit_completed(__MODULE__, result)
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to create job: #{inspect(reason)}"}
      end
    end
  end

  # ============================================================================
  # ListJobs
  # ============================================================================

  defmodule ListJobs do
    @moduledoc """
    List jobs with optional filtering by status and tag.

    ## Examples

        Arbor.Actions.Jobs.ListJobs.run(%{status: "active"}, %{})
        Arbor.Actions.Jobs.ListJobs.run(%{tag: "refactor", limit: 10}, %{})
    """

    use Jido.Action,
      name: "jobs_list",
      description: "List jobs with optional status and tag filtering",
      category: "jobs",
      tags: ["jobs", "tasks", "list"],
      schema: [
        status: [type: :string, default: "all", doc: "Filter: all, created, active, completed, failed, cancelled"],
        tag: [type: :string, doc: "Filter by tag"],
        limit: [type: :integer, default: 20, doc: "Maximum results"]
      ]

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)
      jobs = Arbor.Actions.Jobs

      filter =
        Filter.new()
        |> maybe_filter_status(params[:status])
        |> maybe_filter_tag(params[:tag])
        |> Filter.order_by(:updated_at, :desc)
        |> Filter.limit(params[:limit] || 20)

      case jobs.queryable_backend().query(filter, jobs.persistence_opts()) do
        {:ok, records} ->
          job_list = Enum.map(records, &record_to_job/1)
          result = %{jobs: job_list, total: length(job_list)}
          Actions.emit_completed(__MODULE__, %{total: result.total})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to list jobs: #{inspect(reason)}"}
      end
    end

    defp maybe_filter_status(filter, "all"), do: filter
    defp maybe_filter_status(filter, nil), do: filter
    defp maybe_filter_status(filter, status), do: Filter.where(filter, :status, :eq, status)

    defp maybe_filter_tag(filter, nil), do: filter
    defp maybe_filter_tag(filter, tag), do: Filter.where(filter, :tags, :contains, tag)

    defp record_to_job(%Record{} = record) do
      Map.merge(record.data, %{
        "job_id" => record.key,
        "created_at" => record.inserted_at && DateTime.to_iso8601(record.inserted_at),
        "updated_at" => record.updated_at && DateTime.to_iso8601(record.updated_at)
      })
    end
  end

  # ============================================================================
  # GetJob
  # ============================================================================

  defmodule GetJob do
    @moduledoc """
    Get a single job by ID, optionally with its event history.

    ## Examples

        Arbor.Actions.Jobs.GetJob.run(%{job_id: "job_abc123"}, %{})
        Arbor.Actions.Jobs.GetJob.run(%{job_id: "job_abc123", include_history: true}, %{})
    """

    use Jido.Action,
      name: "jobs_get",
      description: "Get a job by ID with optional event history",
      category: "jobs",
      tags: ["jobs", "tasks", "get"],
      schema: [
        job_id: [type: :string, required: true, doc: "Job ID"],
        include_history: [type: :boolean, default: false, doc: "Include event history"]
      ]

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)
      jobs = Arbor.Actions.Jobs

      job_id = params.job_id

      case jobs.queryable_backend().get(job_id, jobs.persistence_opts()) do
        {:ok, record} ->
          job = Map.merge(record.data, %{
            "job_id" => record.key,
            "created_at" => record.inserted_at && DateTime.to_iso8601(record.inserted_at),
            "updated_at" => record.updated_at && DateTime.to_iso8601(record.updated_at)
          })

          history = fetch_history(params[:include_history], job_id, jobs)

          result = %{job: job, history: history}
          Actions.emit_completed(__MODULE__, %{job_id: job_id})
          {:ok, result}

        {:error, :not_found} ->
          Actions.emit_failed(__MODULE__, :not_found)
          {:error, "Job not found: #{job_id}"}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to get job: #{inspect(reason)}"}
      end
    end

    defp fetch_history(true, job_id, jobs) do
      case jobs.event_log_backend().read_stream(
             jobs.job_stream(job_id),
             jobs.event_log_opts()
           ) do
        {:ok, events} -> Enum.map(events, &event_to_map/1)
        _ -> []
      end
    end

    defp fetch_history(_, _job_id, _jobs), do: nil

    defp event_to_map(%Arbor.Persistence.Event{} = event) do
      %{
        "type" => event.type,
        "data" => event.data,
        "timestamp" => event.timestamp && DateTime.to_iso8601(event.timestamp)
      }
    end
  end

  # ============================================================================
  # UpdateJob
  # ============================================================================

  defmodule UpdateJob do
    @moduledoc """
    Update a job's status or add progress notes.

    ## Examples

        Arbor.Actions.Jobs.UpdateJob.run(
          %{job_id: "job_abc123", status: "active"},
          %{}
        )

        Arbor.Actions.Jobs.UpdateJob.run(
          %{job_id: "job_abc123", notes: "Completed the refactoring of module X"},
          %{}
        )
    """

    use Jido.Action,
      name: "jobs_update",
      description: "Update a job's status or add progress notes",
      category: "jobs",
      tags: ["jobs", "tasks", "update"],
      schema: [
        job_id: [type: :string, required: true, doc: "Job ID"],
        status: [type: :string, doc: "New status: active, completed, failed, cancelled"],
        notes: [type: :string, doc: "Progress note to append"]
      ]

    @valid_statuses ~w(active completed failed cancelled)

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)
      jobs = Arbor.Actions.Jobs

      job_id = params.job_id

      with {:ok, record} <- jobs.queryable_backend().get(job_id, jobs.persistence_opts()),
           :ok <- validate_status_transition(record.data["status"], params[:status]) do
        # Build updated data
        updated_data =
          record.data
          |> maybe_update_status(params[:status])
          |> maybe_add_note(params[:notes])

        updated_record = Record.update(record, updated_data)

        case jobs.queryable_backend().put(job_id, updated_record, jobs.persistence_opts()) do
          :ok ->
            # Determine event type
            event_type = determine_event_type(params)

            event = Event.new(jobs.job_stream(job_id), event_type, %{
              job_id: job_id,
              status: updated_data["status"],
              notes: params[:notes]
            })

            jobs.event_log_backend().append(
              jobs.job_stream(job_id),
              event,
              jobs.event_log_opts()
            )

            result = %{
              job_id: job_id,
              status: updated_data["status"],
              updated: true
            }

            Actions.emit_completed(__MODULE__, result)
            {:ok, result}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, "Failed to update job: #{inspect(reason)}"}
        end
      else
        {:error, :not_found} ->
          Actions.emit_failed(__MODULE__, :not_found)
          {:error, "Job not found: #{job_id}"}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "#{inspect(reason)}"}
      end
    end

    defp validate_status_transition(_current, nil), do: :ok

    defp validate_status_transition(current, new) when new in @valid_statuses do
      valid_transitions = %{
        "created" => ~w(active cancelled),
        "active" => ~w(completed failed cancelled),
        "completed" => [],
        "failed" => ~w(active),
        "cancelled" => ~w(active)
      }

      allowed = Map.get(valid_transitions, current, [])

      if new in allowed do
        :ok
      else
        {:error, "Invalid transition from '#{current}' to '#{new}'. Allowed: #{Enum.join(allowed, ", ")}"}
      end
    end

    defp validate_status_transition(_current, invalid) do
      {:error, "Invalid status '#{invalid}'. Must be one of: #{Enum.join(@valid_statuses, ", ")}"}
    end

    defp maybe_update_status(data, nil), do: data
    defp maybe_update_status(data, status), do: Map.put(data, "status", status)

    defp maybe_add_note(data, nil), do: data

    defp maybe_add_note(data, note) do
      notes = data["notes"] || []
      entry = %{"text" => note, "at" => DateTime.to_iso8601(DateTime.utc_now())}
      Map.put(data, "notes", notes ++ [entry])
    end

    defp determine_event_type(params) do
      cond do
        params[:status] -> "job.#{params[:status]}"
        params[:notes] -> "job.progressed"
        true -> "job.updated"
      end
    end
  end
end
