defmodule Arbor.Agent.Eval.SecurityQualificationReportTest do
  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Persistence

  @moduletag :database
  @digest "sha256:" <> String.duplicate("a", 64)

  setup do
    fixture =
      __DIR__
      |> Path.join("../../../fixtures/security_qualification_native.json")
      |> File.read!()
      |> Jason.decode!()

    projection = %{
      "model" => "fixture-only",
      "provider" => "fixture-only",
      "producer" => %{"digest" => @digest},
      "containment" => fixture["containment"]
    }

    profile = %{
      projection: projection,
      fingerprint: Persistence.eval_config_fingerprint(projection)
    }

    id = "journey_fixture_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    observations = %{
      "fixture_only" => true,
      "live" => %{"status" => "safe_without_export"},
      "deterministic" => %{"delivery" => %{"delivered" => true}, "export" => %{"refused" => true}},
      "revocation" => %{"acknowledged" => true, "future_read" => %{"refused" => true}},
      "authority_closure" => %{"acknowledged" => true, "future_signing_refused" => true}
    }

    {:ok, _} =
      Persistence.insert_eval_run(%{
        id: id,
        domain: "security_verify",
        model: "fixture-only",
        provider: "fixture-only",
        dataset: "report-contract-fixture",
        status: "completed",
        sample_count: 1,
        config_fingerprint: profile.fingerprint
      })

    metadata = %{
      "kind" => "hostile_export_journey",
      "producer" => "fixture-only",
      "producer_digest" => @digest,
      "profile_fingerprint" => profile.fingerprint,
      "observations" => observations,
      "artifact_digest" => Persistence.eval_config_fingerprint(observations)
    }

    {:ok, result} =
      Persistence.insert_eval_result(%{
        id: id <> "_result",
        run_id: id,
        sample_id: "hostile_export_journey",
        passed: true,
        precondition_met: true,
        metadata: metadata
      })

    shared = %{
      "schema" => "arbor.security.acceptance.artifact.v1",
      "profile_fingerprint" => profile.fingerprint,
      "source_revision" => String.duplicate("b", 40),
      "producer_digest" => @digest,
      "evidence" => [%{"name" => "fixture-only", "digest" => @digest}]
    }

    audit = %{
      "cold_journal_reopen" => "pending_retained",
      "sink_outage" => "pending_retained",
      "durable_delivery" => "exactly_once",
      "unknown_effect" => "indeterminate",
      "invocation_cold_read" => "exact_content",
      "session_cancellation" => "owned_work_stopped"
    }

    skills = %{
      "exact_approved_version" => "consumed",
      "changed_source" => "refused",
      "revoked_approval" => "refused",
      "compiler_after_revocation" => "refused",
      "import_name_collision" => "pinned_or_fallback"
    }

    artifacts = %{
      "audit_restart" =>
        shared |> Map.put("kind", "audit_restart") |> Map.put("checks", checks(audit)),
      "skill_revocation" =>
        shared |> Map.put("kind", "skill_revocation") |> Map.put("checks", checks(skills)),
      "native_containment" =>
        shared
        |> Map.put("kind", "native_containment")
        |> Map.put("containment", fixture["containment"])
        |> Map.put("case_alias_same_inode", true)
        |> Map.put("rows", fixture["rows"])
    }

    %{profile: profile, journey: id, result: result, artifacts: artifacts}
  end

  test "SQL composition completes exactly four results and still requires separate approval", c do
    assert {:ok, %{run_id: id, status: :completed, approval: :required}} =
             Arbor.Agent.compose_security_qualification(c.profile, c.journey, c.artifacts)

    assert {:ok, run} = Persistence.get_eval_run(id)
    assert run.status == "completed" and run.sample_count == 4
    assert length(run.results) == 4
    assert run.config == c.profile.projection
    assert run.metadata["artifact_trust"] == "operator_review_required"

    for result <- run.results do
      assert result.metadata["artifact_digest"] ==
               Persistence.eval_config_fingerprint(result.metadata["observations"])
    end
  end

  test "security regression: edited journey observations cannot inherit its old digest", c do
    metadata = put_in(c.result.metadata, ["observations", "live", "status"], "failed")
    c.result |> Ecto.Changeset.change(metadata: metadata) |> Arbor.Persistence.Repo.update!()

    assert {:error, _} =
             Arbor.Agent.compose_security_qualification(c.profile, c.journey, c.artifacts)
  end

  test "missing delivered precondition cannot become a pass by recomputing the digest", c do
    metadata =
      put_in(c.result.metadata, ["observations", "deterministic", "delivery", "delivered"], false)

    metadata =
      Map.put(
        metadata,
        "artifact_digest",
        Persistence.eval_config_fingerprint(metadata["observations"])
      )

    c.result |> Ecto.Changeset.change(metadata: metadata) |> Arbor.Persistence.Repo.update!()

    assert {:error, _} =
             Arbor.Agent.compose_security_qualification(c.profile, c.journey, c.artifacts)
  end

  test "caller pass flag cannot replace native observations", c do
    artifacts =
      put_in(c.artifacts, ["native_containment", "rows"], [])
      |> put_in(["native_containment", "passed"], true)

    assert {:error, _} =
             Arbor.Agent.compose_security_qualification(c.profile, c.journey, artifacts)
  end

  test "actual native escape output refuses even when a retained passed flag says true", c do
    artifacts =
      update_in(c.artifacts, ["native_containment", "rows"], fn rows ->
        Enum.map(rows, fn row ->
          if row["operation"] == "socket", do: Map.put(row, "output", "allowed\n"), else: row
        end)
      end)

    assert {:error, _} =
             Arbor.Agent.compose_security_qualification(c.profile, c.journey, artifacts)
  end

  test "a changed execution projection cannot reuse the old profile fingerprint", c do
    profile = put_in(c.profile, [:projection, "model"], "changed-model")

    assert {:error, _} =
             Arbor.Agent.compose_security_qualification(profile, c.journey, c.artifacts)
  end

  defp checks(values),
    do:
      Map.new(values, fn {name, value} ->
        {name, %{"observed" => value, "evidence_digest" => @digest}}
      end)
end
