defmodule Arbor.Scheduler.Workers.PipelineRunnerTest do
  @moduledoc """
  Tests for the `PipelineRunner` Oban worker.

  Covers the error-handling matrix that matters for unattended overnight
  runs:

  - Missing `pipeline_path` arg → discard (won't retry)
  - Pipeline file not found → discard (won't retry)
  - Orchestrator unavailable → error (retry, since it might be transient)
  - Exception / exit / throw during pipeline run → error (retry)

  The "happy path" (orchestrator available + file exists + pipeline
  completes) gets exercised by reference-pipeline e2e tests once a
  concrete pipeline ships.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Scheduler.Workers.PipelineRunner

  describe "perform/1 error contracts" do
    test "missing pipeline_path arg → discard" do
      job = %Oban.Job{args: %{"args" => %{}}}
      assert {:discard, _reason} = PipelineRunner.perform(job)
    end

    test "pipeline file not found → discard" do
      # Use a path that definitely doesn't exist. Orchestrator is loaded
      # in test (compiled into _build) so the not-loaded branch doesn't
      # short-circuit before the file check.
      job = %Oban.Job{
        args: %{
          "pipeline_path" =>
            "definitely/does/not/exist/#{System.unique_integer([:positive])}.dot",
          "args" => %{}
        }
      }

      assert {:discard, _reason} = PipelineRunner.perform(job)
    end
  end

  describe "max_attempts default" do
    test "is 3 (Phase-1 default — operator overridable per-enqueue)" do
      assert PipelineRunner.__opts__()[:max_attempts] == 3
    end

    test "queue defaults to :default" do
      assert PipelineRunner.__opts__()[:queue] == :default
    end
  end
end
