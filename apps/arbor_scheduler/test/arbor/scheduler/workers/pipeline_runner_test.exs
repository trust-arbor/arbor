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

  # ── seed_session_identity/2 — security regression for the bypass-revert ──
  #
  # The pre-fix Oban path used Orchestrator.run_file(.., authorization: false)
  # — skipped CapabilityCheck entirely. The fix routes through
  # Arbor.Scheduler.Identity's signer+agent_id. seed_session_identity/2 is
  # where the Identity's agent_id replaces any value an Oban payload might
  # have placed under "session.agent_id". These tests lock that in.
  describe "seed_session_identity/2 — security regression for the Oban bypass-revert" do
    test "Identity's agent_id overrides any Oban-supplied session.agent_id" do
      malicious_context = %{
        "session.agent_id" => "agent_attacker_controlled",
        "some_other_value" => "ok"
      }

      seeded =
        PipelineRunner.seed_session_identity(
          malicious_context,
          "agent_legit_scheduler"
        )

      assert seeded["session.agent_id"] == "agent_legit_scheduler",
             "Oban args MUST NOT be able to override the scheduler's identity"

      assert seeded["some_other_value"] == "ok",
             "non-identity keys should pass through unchanged"
    end

    test "absent Identity strips any pre-seeded session.agent_id (fail-closed)" do
      malicious_context = %{
        "session.agent_id" => "agent_attacker_controlled",
        "some_other_value" => "ok"
      }

      seeded = PipelineRunner.seed_session_identity(malicious_context, nil)

      refute Map.has_key?(seeded, "session.agent_id"),
             "with no Identity, attacker-supplied agent_id MUST be stripped, not preserved"

      assert seeded["some_other_value"] == "ok"
    end

    test "absent agent_id and absent session.agent_id leaves context untouched" do
      seeded = PipelineRunner.seed_session_identity(%{"k" => "v"}, nil)
      assert seeded == %{"k" => "v"}
    end

    test "Identity's agent_id is added when context had no session.agent_id" do
      seeded = PipelineRunner.seed_session_identity(%{"k" => "v"}, "agent_legit")
      assert seeded == %{"k" => "v", "session.agent_id" => "agent_legit"}
    end
  end
end
