defmodule Arbor.SchedulerTest do
  @moduledoc """
  Tests for the public `Arbor.Scheduler` facade.

  These tests verify the **enqueue contract** — that calling the
  scheduler facade produces correctly-shaped Oban changesets — without
  touching the database or starting Oban. The
  `Arbor.Scheduler.build_pipeline_job/3` function returns an
  `Ecto.Changeset` we can inspect directly.

  Integration tests that exercise the full enqueue → insert → execute
  path live elsewhere (tagged `:database`) and run with a real Repo +
  Oban supervisor.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Scheduler
  alias Arbor.Scheduler.Workers.PipelineRunner

  describe "build_pipeline_job/3" do
    test "produces a changeset for PipelineRunner with the pipeline path + args" do
      changeset = Scheduler.build_pipeline_job("scheduled/upstream_deps.dot", %{repos: ["a"]})

      changes = changeset.changes
      # Oban stores the worker as the bare module name (no "Elixir." prefix).
      assert changes.worker == "Arbor.Scheduler.Workers.PipelineRunner"

      assert changes.args == %{
               "pipeline_path" => "scheduled/upstream_deps.dot",
               "args" => %{repos: ["a"]}
             }

      # The reference is consistent with the worker module's own self-naming.
      assert changes.worker == inspect(PipelineRunner)
    end

    test "defaults args to %{}" do
      changeset = Scheduler.build_pipeline_job("p.dot")
      assert changeset.changes.args == %{"pipeline_path" => "p.dot", "args" => %{}}
    end

    test "passes through :queue opt" do
      changeset = Scheduler.build_pipeline_job("p.dot", %{}, queue: :pipelines)
      assert changeset.changes.queue == "pipelines"
    end

    test "passes through :max_attempts opt" do
      changeset = Scheduler.build_pipeline_job("p.dot", %{}, max_attempts: 7)
      assert changeset.changes.max_attempts == 7
    end
  end

  describe "schedule_pipeline_in/4 (changeset-only assertions)" do
    test "sets scheduled_at in the future" do
      changeset = Scheduler.build_pipeline_job("p.dot", %{}, schedule_in: 3600)
      assert %DateTime{} = changeset.changes.scheduled_at
      assert DateTime.compare(changeset.changes.scheduled_at, DateTime.utc_now()) == :gt
    end

    test "rejects non-positive delay" do
      assert_raise FunctionClauseError, fn ->
        Scheduler.schedule_pipeline_in("p.dot", 0)
      end

      assert_raise FunctionClauseError, fn ->
        Scheduler.schedule_pipeline_in("p.dot", -5)
      end
    end
  end

  describe "schedule_pipeline_at/4 (changeset-only assertions)" do
    test "sets scheduled_at to the given DateTime" do
      target = DateTime.utc_now() |> DateTime.add(7200, :second)
      changeset = Scheduler.build_pipeline_job("p.dot", %{}, scheduled_at: target)
      assert changeset.changes.scheduled_at == target
    end
  end
end
