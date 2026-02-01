defmodule Arbor.Actions.JobsTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Jobs.{CreateJob, GetJob, ListJobs, UpdateJob}
  alias Arbor.Persistence.EventLog.ETS, as: ELog
  alias Arbor.Persistence.QueryableStore.ETS, as: QStore

  setup do
    # Restart the application-managed ETS stores for a clean state.
    # These are started by Arbor.Persistence.Application under its supervisor.
    for id <- [QStore, ELog] do
      Supervisor.terminate_child(Arbor.Persistence.Supervisor, id)
      Supervisor.restart_child(Arbor.Persistence.Supervisor, id)
    end

    # Configure actions to use ETS backends
    original = Application.get_env(:arbor_actions, :persistence)

    Application.put_env(:arbor_actions, :persistence,
      queryable_store_backend: QStore,
      event_log_backend: ELog
    )

    on_exit(fn ->
      if original do
        Application.put_env(:arbor_actions, :persistence, original)
      else
        Application.delete_env(:arbor_actions, :persistence)
      end
    end)

    :ok
  end

  # ============================================================================
  # CreateJob
  # ============================================================================

  describe "CreateJob metadata" do
    test "has correct action metadata" do
      assert CreateJob.name() == "jobs_create"
      assert CreateJob.category() == "jobs"
    end

    test "generates tool schema" do
      tool = CreateJob.to_tool()
      assert is_map(tool)
      assert tool[:name] == "jobs_create"
    end
  end

  describe "CreateJob.run/2" do
    test "creates a job with required fields" do
      params = %{title: "Test Job"}
      assert {:ok, result} = CreateJob.run(params, %{})

      assert result.status == "created"
      assert result.title == "Test Job"
      assert String.starts_with?(result.job_id, "job_")
    end

    test "creates a job with all fields" do
      params = %{
        title: "Full Job",
        description: "A detailed description",
        priority: "high",
        tags: ["refactor", "comms"]
      }

      assert {:ok, result} = CreateJob.run(params, %{})
      assert result.status == "created"

      # Verify stored data
      {:ok, record} = QStore.get(result.job_id, name: :jobs)
      assert record.data["title"] == "Full Job"
      assert record.data["description"] == "A detailed description"
      assert record.data["priority"] == "high"
      assert record.data["tags"] == ["refactor", "comms"]
      assert record.data["status"] == "created"
    end

    test "appends creation event to EventLog" do
      params = %{title: "Evented Job", priority: "critical"}
      {:ok, result} = CreateJob.run(params, %{})

      stream = "jobs-#{result.job_id}"
      {:ok, events} = ELog.read_stream(stream, name: :event_log)

      assert length(events) == 1
      event = hd(events)
      assert event.type == "job.created"
      assert event.data.title == "Evented Job"
      assert event.data.priority == "critical"
    end

    test "uses default values for optional fields" do
      params = %{title: "Minimal Job"}
      {:ok, result} = CreateJob.run(params, %{})

      {:ok, record} = QStore.get(result.job_id, name: :jobs)
      assert record.data["priority"] == "normal"
      assert record.data["tags"] == []
      assert record.data["description"] == ""
      assert record.data["notes"] == []
    end
  end

  # ============================================================================
  # ListJobs
  # ============================================================================

  describe "ListJobs.run/2" do
    setup do
      # Create a few test jobs
      {:ok, j1} = CreateJob.run(%{title: "Job 1", priority: "high", tags: ["alpha"]}, %{})
      {:ok, j2} = CreateJob.run(%{title: "Job 2", priority: "normal", tags: ["beta"]}, %{})
      {:ok, j3} = CreateJob.run(%{title: "Job 3", priority: "low", tags: ["alpha"]}, %{})

      # Activate one
      UpdateJob.run(%{job_id: j2.job_id, status: "active"}, %{})

      {:ok, jobs: [j1, j2, j3]}
    end

    test "lists all jobs", %{jobs: _jobs} do
      {:ok, result} = ListJobs.run(%{}, %{})
      assert result.total == 3
    end

    test "filters by status" do
      {:ok, result} = ListJobs.run(%{status: "created"}, %{})
      assert result.total == 2

      {:ok, result} = ListJobs.run(%{status: "active"}, %{})
      assert result.total == 1
    end

    test "returns all when status is 'all'" do
      {:ok, result} = ListJobs.run(%{status: "all"}, %{})
      assert result.total == 3
    end

    test "applies limit" do
      {:ok, result} = ListJobs.run(%{limit: 2}, %{})
      assert result.total == 2
    end

    test "returns job data in results" do
      {:ok, result} = ListJobs.run(%{status: "active"}, %{})
      job = hd(result.jobs)
      assert job["title"] == "Job 2"
      assert job["status"] == "active"
      assert is_binary(job["job_id"])
    end
  end

  # ============================================================================
  # GetJob
  # ============================================================================

  describe "GetJob.run/2" do
    test "retrieves a job by ID" do
      {:ok, created} = CreateJob.run(%{title: "Fetch Me"}, %{})

      {:ok, result} = GetJob.run(%{job_id: created.job_id}, %{})
      assert result.job["title"] == "Fetch Me"
      assert result.job["status"] == "created"
      assert result.job["job_id"] == created.job_id
      assert result.history == nil
    end

    test "includes history when requested" do
      {:ok, created} = CreateJob.run(%{title: "History Job"}, %{})
      UpdateJob.run(%{job_id: created.job_id, status: "active"}, %{})

      {:ok, result} = GetJob.run(%{job_id: created.job_id, include_history: true}, %{})
      assert is_list(result.history)
      assert length(result.history) == 2

      types = Enum.map(result.history, & &1["type"])
      assert "job.created" in types
      assert "job.active" in types
    end

    test "returns error for missing job" do
      {:error, msg} = GetJob.run(%{job_id: "job_nonexistent"}, %{})
      assert msg =~ "Job not found"
    end
  end

  # ============================================================================
  # UpdateJob
  # ============================================================================

  describe "UpdateJob.run/2" do
    test "updates status from created to active" do
      {:ok, created} = CreateJob.run(%{title: "Activate Me"}, %{})

      {:ok, result} = UpdateJob.run(%{job_id: created.job_id, status: "active"}, %{})
      assert result.status == "active"
      assert result.updated == true
    end

    test "updates status from active to completed" do
      {:ok, created} = CreateJob.run(%{title: "Complete Me"}, %{})
      UpdateJob.run(%{job_id: created.job_id, status: "active"}, %{})

      {:ok, result} = UpdateJob.run(%{job_id: created.job_id, status: "completed"}, %{})
      assert result.status == "completed"
    end

    test "adds progress notes" do
      {:ok, created} = CreateJob.run(%{title: "Note Job"}, %{})

      {:ok, _} = UpdateJob.run(%{job_id: created.job_id, notes: "First note"}, %{})
      {:ok, _} = UpdateJob.run(%{job_id: created.job_id, notes: "Second note"}, %{})

      {:ok, result} = GetJob.run(%{job_id: created.job_id}, %{})
      notes = result.job["notes"]
      assert length(notes) == 2
      assert Enum.at(notes, 0)["text"] == "First note"
      assert Enum.at(notes, 1)["text"] == "Second note"
    end

    test "rejects invalid status transitions" do
      {:ok, created} = CreateJob.run(%{title: "Locked Job"}, %{})

      # Can't go directly from created to completed
      {:error, msg} = UpdateJob.run(%{job_id: created.job_id, status: "completed"}, %{})
      assert msg =~ "Invalid transition"
    end

    test "allows re-activating failed jobs" do
      {:ok, created} = CreateJob.run(%{title: "Retry Job"}, %{})
      UpdateJob.run(%{job_id: created.job_id, status: "active"}, %{})
      UpdateJob.run(%{job_id: created.job_id, status: "failed"}, %{})

      {:ok, result} = UpdateJob.run(%{job_id: created.job_id, status: "active"}, %{})
      assert result.status == "active"
    end

    test "returns error for missing job" do
      {:error, msg} = UpdateJob.run(%{job_id: "job_nonexistent", status: "active"}, %{})
      assert msg =~ "Job not found"
    end

    test "appends events for status changes" do
      {:ok, created} = CreateJob.run(%{title: "Event Job"}, %{})
      UpdateJob.run(%{job_id: created.job_id, status: "active"}, %{})

      stream = "jobs-#{created.job_id}"
      {:ok, events} = ELog.read_stream(stream, name: :event_log)

      assert length(events) == 2
      types = Enum.map(events, & &1.type)
      assert types == ["job.created", "job.active"]
    end

    test "appends progress events for notes" do
      {:ok, created} = CreateJob.run(%{title: "Progress Job"}, %{})
      UpdateJob.run(%{job_id: created.job_id, notes: "Working on it"}, %{})

      stream = "jobs-#{created.job_id}"
      {:ok, events} = ELog.read_stream(stream, name: :event_log)

      types = Enum.map(events, & &1.type)
      assert "job.progressed" in types
    end
  end
end
