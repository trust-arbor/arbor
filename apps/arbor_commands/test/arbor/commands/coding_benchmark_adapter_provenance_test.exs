defmodule Arbor.Commands.CodingBenchmarkAdapterProvenanceTest do
  use Arbor.Commands.CodingBenchmarkAdapterCase, async: false

  test "provenance symlinks, malformed manifests, and changed DOT bytes fail verification" do
    scenario = production_scenario!()
    install_leased_executors()

    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :symlink_artifact)
    assert {:ok, symlink_report} = run_production_scenario(scenario)

    symlink_pipeline = row(symlink_report, "pipeline")
    assert symlink_pipeline["terminal_status"] == "change_committed"
    assert symlink_pipeline["objective_verifier"]["status"] == "passed"
    assert symlink_pipeline["artifact_hash_verification"]["graph_hash_verified"] == false
    assert symlink_pipeline["artifact_hash_verification"]["status"] == "failed"

    invalid_scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :invalid_manifest)
    assert {:ok, invalid_report} = run_production_scenario(invalid_scenario)
    assert row(invalid_report, "pipeline")["artifact_hash_verification"]["status"] == "failed"

    tampered_scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :tampered_dot)
    assert {:ok, tampered_report} = run_production_scenario(tampered_scenario)

    tampered = row(tampered_report, "pipeline")["artifact_hash_verification"]
    assert tampered["graph_hash_verified"] == false
    assert tampered["status"] == "failed"
  end

  # Descriptor-schema mutations hit the public production gate without cloning
  # fixtures. One accepted and one rejected full production scenario below
  # prove the same gate is wired into end-to-end provenance verification.

  test "known optional artifact evidence: workspace_release is admitted by descriptor gate" do
    assert_pipeline_artifact_descriptors_accepted(fn artifacts, _root ->
      Map.put(artifacts, "workspace_release", %{
        "workspace_release_status" => "retained",
        "workspace_expires_at" => "2026-07-17T12:00:00Z"
      })
    end)
  end

  test "known optional artifact evidence: workspace_release and acp_transcript are admitted by descriptor gate" do
    assert_pipeline_artifact_descriptors_accepted(fn artifacts, root ->
      artifacts
      |> Map.put("workspace_release", %{"workspace_release_status" => "removed"})
      |> Map.put("acp_transcript", synthetic_transcript_descriptor(root))
    end)
  end

  test "security regression: optional artifact evidence rejects unknown top-level artifact" do
    assert_pipeline_artifact_descriptors_rejected(fn artifacts, _root ->
      Map.put(artifacts, "unexpected_evidence", %{})
    end)
  end

  test "security regression: optional artifact evidence rejects workspace_release unknown field" do
    assert_pipeline_artifact_descriptors_rejected(fn artifacts, _root ->
      Map.put(artifacts, "workspace_release", %{
        "workspace_release_status" => "retained",
        "workspace_id" => "inline-authority"
      })
    end)
  end

  test "security regression: optional artifact evidence rejects workspace_release oversized scalar" do
    assert_pipeline_artifact_descriptors_rejected(fn artifacts, _root ->
      Map.put(artifacts, "workspace_release", %{
        "workspace_release_status" => String.duplicate("x", 257)
      })
    end)
  end

  test "security regression: optional artifact evidence rejects workspace_release unknown status" do
    assert_pipeline_artifact_descriptors_rejected(fn artifacts, _root ->
      Map.put(artifacts, "workspace_release", %{
        "workspace_release_status" => "pending"
      })
    end)
  end

  test "security regression: optional artifact evidence rejects workspace_release non-ISO workspace_expires_at" do
    assert_pipeline_artifact_descriptors_rejected(fn artifacts, _root ->
      Map.put(artifacts, "workspace_release", %{
        "workspace_release_status" => "retained",
        "workspace_expires_at" => "not-a-timestamp"
      })
    end)
  end

  test "security regression: optional artifact evidence rejects inline transcript turns" do
    assert_pipeline_artifact_descriptors_rejected(
      transcript_mutation(fn descriptor -> Map.put(descriptor, "turns", []) end)
    )
  end

  test "security regression: optional artifact evidence rejects inline transcript stream" do
    assert_pipeline_artifact_descriptors_rejected(
      transcript_mutation(fn descriptor -> Map.put(descriptor, "stream", %{}) end)
    )
  end

  test "security regression: optional artifact evidence rejects non-canonical transcript path" do
    assert_pipeline_artifact_descriptors_rejected(
      transcript_mutation(fn descriptor ->
        Map.put(descriptor, "path", Path.join(descriptor["path"], "../transcript.json"))
      end)
    )
  end

  test "security regression: optional artifact evidence rejects uppercase transcript digest" do
    assert_pipeline_artifact_descriptors_rejected(
      transcript_mutation(fn descriptor ->
        Map.update!(descriptor, "sha256", &String.upcase/1)
      end)
    )
  end

  test "security regression: optional artifact evidence rejects oversized transcript" do
    assert_pipeline_artifact_descriptors_rejected(
      transcript_mutation(fn descriptor -> Map.put(descriptor, "byte_size", 512_001) end)
    )
  end

  test "security regression: optional artifact evidence rejects inconsistent transcript counts" do
    assert_pipeline_artifact_descriptors_rejected(
      transcript_mutation(fn descriptor -> Map.put(descriptor, "turns_seen", 4) end)
    )
  end

  test "security regression: optional artifact evidence rejects inconsistent transcript truncation" do
    assert_pipeline_artifact_descriptors_rejected(
      transcript_mutation(fn descriptor -> Map.put(descriptor, "turns_truncated", false) end)
    )
  end

  test "security regression: optional artifact evidence rejects invalid transcript aggregate flag" do
    assert_pipeline_artifact_descriptors_rejected(
      transcript_mutation(fn descriptor ->
        Map.put(descriptor, "aggregate_truncated", "false")
      end)
    )
  end

  test "security regression: optional artifact evidence rejects invalid transcript schema" do
    assert_pipeline_artifact_descriptors_rejected(
      transcript_mutation(fn descriptor -> Map.put(descriptor, "schema_version", 2) end)
    )
  end

  test "security regression: optional artifact evidence rejects blank transcript task id" do
    assert_pipeline_artifact_descriptors_rejected(
      transcript_mutation(fn descriptor -> Map.put(descriptor, "task_id", " ") end)
    )
  end

  test "security regression: required provenance rejects missing graph hash" do
    assert_pipeline_artifact_descriptors_rejected(fn artifacts, _root ->
      Map.delete(artifacts, "graph_hash")
    end)
  end

  test "security regression: required provenance rejects duplicate graph hash" do
    assert_pipeline_artifact_descriptors_rejected(fn artifacts, _root ->
      Map.put(artifacts, :graph_hash, String.duplicate("0", 64))
    end)
  end

  test "known optional artifact evidence through production preserves authority and parity" do
    assert_optional_artifact_accepted(fn artifacts, root ->
      artifacts
      |> Map.put("workspace_release", %{
        "workspace_release_status" => "retained",
        "workspace_expires_at" => "2026-07-17T12:00:00Z"
      })
      |> Map.put("acp_transcript", valid_transcript_descriptor(root))
    end)
  end

  test "security regression: invalid optional artifact evidence fails production provenance" do
    assert_optional_artifact_rejected(fn artifacts, _root ->
      Map.put(artifacts, "unexpected_evidence", %{})
    end)
  end

  test "security regression: mismatched graph hash fails production provenance" do
    assert_optional_artifact_rejected(fn artifacts, _root ->
      Map.put(artifacts, "graph_hash", String.duplicate("0", 64))
    end)
  end

  test "provenance artifact swaps are rejected immediately before reads" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, report} =
             run_production_scenario(scenario,
               verifiers: %{"scripted_objective" => ArtifactSwapVerifier}
             )

    pipeline = row(report, "pipeline")
    assert pipeline["terminal_status"] == "change_committed"
    assert pipeline["artifact_hash_verification"]["graph_hash_verified"] == false
    assert pipeline["artifact_hash_verification"]["status"] == "failed"
  end

  test "same-size regular artifact swaps fail descriptor identity verification" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)
    handler_id = "coding-benchmark-inode-swap-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:arbor, :commands, :coding_benchmark, :artifact_opened],
        fn _event, _measurements, %{path: path}, _config ->
          if Path.basename(path) == "coding-pipeline.dot" do
            backup = path <> ".inode-swap"
            :ok = File.rename(path, backup)
            :ok = File.cp(backup, path)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, report} = run_production_scenario(scenario)

    pipeline = row(report, "pipeline")
    assert pipeline["terminal_status"] == "change_committed"
    assert pipeline["artifact_hash_verification"]["graph_hash_verified"] == false
    assert pipeline["artifact_hash_verification"]["status"] == "failed"
  end

  test "security regression: same-inode same-size in-place mutation during read is rejected" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)
    handler_id = "coding-benchmark-in-place-mutation-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arbor, :commands, :coding_benchmark, :artifact_chunk_read],
      fn _event, _measurements, metadata, _config ->
        if metadata.pass == 1 and metadata.offset == 0 and
             Path.basename(metadata.path) == "coding-pipeline.dot" do
          path = metadata.path
          original = File.read!(path)
          replacement = :binary.copy("x", byte_size(original))
          File.write!(path, replacement)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    assert {:ok, report} = run_production_scenario(scenario)
    pipeline = row(report, "pipeline")
    assert pipeline["artifact_hash_verification"]["graph_hash_verified"] == false
    assert pipeline["artifact_hash_verification"]["status"] == "failed"
  end

  test "objective verifier timeout is bounded by the benchmark timeout" do
    # Scenario adapters do not use production plan-budget derivation; a short
    # harness timeout still bounds verifier Task.yield independently.
    scenario = production_scenario!(1_000)

    assert {:ok, report} =
             run_production_scenario(scenario,
               adapters: Scenario.adapters(),
               verifiers: %{"scripted_objective" => HangingVerifier}
             )

    assert_receive {:hanging_verifier_started, verifier_pid}
    refute Process.alive?(verifier_pid)

    for result <- report["rows"] do
      assert result["objective_verifier"] == %{
               "reason" => "verifier_timeout:1000",
               "status" => "failed"
             }
    end
  end

  defp transcript_mutation(mutation) when is_function(mutation, 1) do
    fn artifacts, root ->
      descriptor = root |> synthetic_transcript_descriptor() |> mutation.()
      Map.put(artifacts, "acp_transcript", descriptor)
    end
  end
end
