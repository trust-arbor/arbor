defmodule Arbor.Orchestrator.CodingPlan.ArtifactStoreTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Arbor.Orchestrator.CodingPlan.ArtifactStore

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "coding_plan_artifact_store_#{System.unique_integer([:positive])}"
      )

    root = Path.join([base, "nested", "task-root"])
    on_exit(fn -> File.rm_rf(base) end)

    %{base: base, root: root}
  end

  test "archives exact DOT bytes and JSON-clean plan and manifest", %{root: root} do
    plan = plan_fixture()
    manifest = manifest_fixture()
    dot_source = "digraph coding {\n  start -> done;\n}\n"

    assert {:ok, descriptor} = ArtifactStore.archive(root, plan, dot_source, manifest)

    expanded_root = Path.expand(root)

    assert descriptor == %{
             "coding_plan_path" => Path.join(expanded_root, "coding-plan.json"),
             "coding_pipeline_path" => Path.join(expanded_root, "coding-pipeline.dot"),
             "compile_manifest_path" => Path.join(expanded_root, "coding-compile-manifest.json"),
             "graph_hash" => manifest["graph_hash"],
             "compiler_version" => manifest["compiler_version"]
           }

    assert File.read!(descriptor["coding_pipeline_path"]) == dot_source
    assert Jason.decode!(File.read!(descriptor["coding_plan_path"])) == plan
    assert Jason.decode!(File.read!(descriptor["compile_manifest_path"])) == manifest
    assert {:ok, _encoded_descriptor} = Jason.encode(descriptor)

    assert Enum.sort(File.ls!(expanded_root)) == [
             "coding-compile-manifest.json",
             "coding-pipeline.dot",
             "coding-plan.json"
           ]
  end

  test "creates mode-0600 files", %{root: root} do
    assert {:ok, descriptor} =
             ArtifactStore.archive(root, plan_fixture(), "digraph G {}", manifest_fixture())

    for key <- ["coding_plan_path", "coding_pipeline_path", "compile_manifest_path"] do
      assert {:ok, stat} = File.stat(descriptor[key])
      assert (stat.mode &&& 0o777) == 0o600
    end
  end

  test "security regression: nonempty temporary artifacts are already mode 0600", %{
    root: root
  } do
    parent = self()
    large_dot = :binary.copy("x", 64 * 1024 * 1024)

    archive_task =
      Task.async(fn ->
        Process.flag(:priority, :low)
        send(parent, {:archive_ready, self()})

        receive do
          :archive -> :ok
        end

        ArtifactStore.archive(root, plan_fixture(), large_dot, manifest_fixture())
      end)

    observer_task =
      Task.async(fn ->
        Process.flag(:priority, :high)
        send(parent, {:observer_ready, self()})

        receive do
          {:observe, archive_pid} ->
            send(parent, :observer_polling)
            deadline = System.monotonic_time(:millisecond) + 5_000
            await_secure_nonempty_temp(root, archive_pid, deadline)
        end
      end)

    assert_receive {:archive_ready, archive_pid}, 1_000
    assert_receive {:observer_ready, observer_pid}, 1_000
    send(observer_pid, {:observe, archive_pid})
    assert_receive :observer_polling, 1_000
    send(archive_pid, :archive)

    assert :ok = Task.await(observer_task, 5_000)
    assert {:ok, _descriptor} = Task.await(archive_task, 5_000)
  end

  test "overwrites deterministically through fixed artifact paths", %{root: root} do
    plan = plan_fixture()
    manifest = manifest_fixture()
    dot_source = "digraph G { start -> validate -> done }"

    assert {:ok, first_descriptor} =
             ArtifactStore.archive(root, plan, dot_source, manifest)

    first_bytes = read_artifacts(first_descriptor)

    for {_name, path} <- artifact_paths(first_descriptor) do
      File.chmod!(path, 0o644)
    end

    assert {:ok, second_descriptor} =
             ArtifactStore.archive(root, plan, dot_source, manifest)

    assert second_descriptor == first_descriptor
    assert read_artifacts(second_descriptor) == first_bytes

    for {_name, path} <- artifact_paths(second_descriptor) do
      assert {:ok, stat} = File.stat(path)
      assert (stat.mode &&& 0o777) == 0o600
    end

    refute Enum.any?(File.ls!(root), &String.contains?(&1, ".tmp-"))
  end

  test "rejects malformed arguments with tagged errors before creating files", %{root: root} do
    manifest = manifest_fixture()

    assert {:error, {:invalid_root, :expected_string}} =
             ArtifactStore.archive(nil, plan_fixture(), "digraph G {}", manifest)

    assert {:error, {:invalid_root, :empty}} =
             ArtifactStore.archive("  ", plan_fixture(), "digraph G {}", manifest)

    assert {:error, {:invalid_plan, :expected_string_keyed_map}} =
             ArtifactStore.archive(root, [], "digraph G {}", manifest)

    assert {:error, {:invalid_plan, {:non_string_key, []}}} =
             ArtifactStore.archive(root, %{version: 1}, "digraph G {}", manifest)

    assert {:error, {:invalid_plan, {:non_json_value, ["worker", "pid"]}}} =
             ArtifactStore.archive(
               root,
               %{"worker" => %{"pid" => self()}},
               "digraph G {}",
               manifest
             )

    assert {:error, {:invalid_dot_source, :expected_non_empty_binary}} =
             ArtifactStore.archive(root, plan_fixture(), "", manifest)

    assert {:error, {:invalid_manifest, {:non_string_key, []}}} =
             ArtifactStore.archive(
               root,
               plan_fixture(),
               "digraph G {}",
               %{graph_hash: "abc", compiler_version: "v1"}
             )

    assert {:error, {:invalid_manifest_field, "graph_hash"}} =
             ArtifactStore.archive(
               root,
               plan_fixture(),
               "digraph G {}",
               %{"compiler_version" => "v1"}
             )

    assert {:error, {:invalid_manifest_field, "compiler_version"}} =
             ArtifactStore.archive(
               root,
               plan_fixture(),
               "digraph G {}",
               %{"graph_hash" => "abc", "compiler_version" => " "}
             )

    refute File.exists?(root)
  end

  test "returns a tagged filesystem error when the root is not a directory", %{
    base: base
  } do
    root_file = Path.join(base, "not-a-directory")
    File.mkdir_p!(base)
    File.write!(root_file, "occupied")

    assert {:error, {:create_artifact_root_failed, reason}} =
             ArtifactStore.archive(
               root_file,
               plan_fixture(),
               "digraph G {}",
               manifest_fixture()
             )

    assert reason in [:eexist, :enotdir]
  end

  test "removes the temporary file when atomic rename fails", %{root: root} do
    destination = Path.join(root, "coding-plan.json")
    File.mkdir_p!(destination)

    assert {:error, {:write_artifact_failed, "coding-plan.json", reason}} =
             ArtifactStore.archive(
               root,
               plan_fixture(),
               "digraph G {}",
               manifest_fixture()
             )

    assert is_atom(reason)
    refute Enum.any?(File.ls!(root), &String.contains?(&1, ".tmp-"))
  end

  test "archives closed terminal evidence with digest, size, and restrictive mode", %{root: root} do
    File.mkdir_p!(root)
    {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
    result = terminal_result(root)
    controls = [terminal_control()]

    assert {:ok, descriptor} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", result, controls)

    {:ok, canonical_root} = Arbor.Common.SafePath.resolve_real(root)
    evidence_path = Path.join(canonical_root, "coding-terminal-evidence.json")
    bytes = File.read!(evidence_path)

    assert descriptor == %{
             "path" => evidence_path,
             "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
             "byte_size" => byte_size(bytes),
             "schema_version" => 1,
             "task_id" => "task_coding_1"
           }

    assert {:ok, stat} = File.stat(evidence_path)
    assert (stat.mode &&& 0o777) == 0o600

    assert Jason.decode!(bytes) == %{
             "schema_version" => 1,
             "task_id" => "task_coding_1",
             "terminal_status" => "change_committed",
             "canonical_status" => "change_committed",
             "compiled_workflow" => %{
               "coding_plan_path" => Path.join(canonical_root, "coding-plan.json"),
               "coding_pipeline_path" => Path.join(canonical_root, "coding-pipeline.dot"),
               "compile_manifest_path" =>
                 Path.join(canonical_root, "coding-compile-manifest.json"),
               "graph_hash" => String.duplicate("a", 64),
               "compiler_version" => "coding-plan-1"
             },
             "steering_history" => controls,
             "validation_outputs" => [%{"command" => "mix test", "passed" => true}],
             "review_verdict" => %{
               "recommendation" => "approve",
               "reviewer_outcomes" => %{
                 "security" => %{
                   "status" => "failed",
                   "reason_code" => "branch_failed",
                   "provider" => "openai_oauth",
                   "model" => "gpt-5.6-sol",
                   "effective_vote" => "abstain"
                 }
               },
               "tier_decision" => "allow",
               "human_required" => false,
               "security_veto" => false,
               "blast_radius" => "low"
             }
           }

    assert Enum.sort(File.ls!(root)) == [
             "coding-terminal-evidence.json"
           ]
  end

  test "terminal evidence is deterministic and closed", %{root: root} do
    File.mkdir_p!(root)
    {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
    result = terminal_result(root)

    assert {:ok, first} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", result, [])

    first_bytes = File.read!(first["path"])

    assert {:ok, second} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", result, [])

    assert second == first
    assert File.read!(second["path"]) == first_bytes

    top_level_keys =
      ~r/^  "([^"]+)":/m
      |> Regex.scan(first_bytes, capture: :all_but_first)
      |> List.flatten()

    assert top_level_keys == Enum.sort(top_level_keys)

    evidence = Jason.decode!(first_bytes)
    assert Map.keys(evidence) |> MapSet.new() == MapSet.new(~w(
             schema_version
             task_id
             terminal_status
             canonical_status
             compiled_workflow
             steering_history
             validation_outputs
             review_verdict
           ))
    assert evidence["validation_outputs"] == [%{"command" => "mix test", "passed" => true}]

    assert evidence["review_verdict"] == %{
             "recommendation" => "approve",
             "reviewer_outcomes" => %{
               "security" => %{
                 "status" => "failed",
                 "reason_code" => "branch_failed",
                 "provider" => "openai_oauth",
                 "model" => "gpt-5.6-sol",
                 "effective_vote" => "abstain"
               }
             },
             "tier_decision" => "allow",
             "human_required" => false,
             "security_veto" => false,
             "blast_radius" => "low"
           }
  end

  test "large unretained result fields do not prevent bounded evidence archival", %{root: root} do
    File.mkdir_p!(root)

    result =
      root
      |> terminal_result()
      |> Map.put("diff", String.duplicate("x", 1_100_000))

    assert {:ok, descriptor} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", result, [])

    evidence = File.read!(descriptor["path"])
    refute evidence =~ ~s("diff")
    assert byte_size(evidence) < 1_048_576
  end

  test "rejects symlink roots, malformed evidence, oversized data, and bad controls", %{
    base: base,
    root: root
  } do
    File.mkdir_p!(root)
    {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
    result = terminal_result(root)
    link = Path.join(base, "root-link")
    File.ln_s!(root, link)

    assert {:error, {:invalid_terminal_root, _reason}} =
             ArtifactStore.archive_terminal_evidence(link, "task_coding_1", result, [])

    assert {:error, {:invalid_terminal_result, :not_successful}} =
             ArtifactStore.archive_terminal_evidence(
               root,
               "task_coding_1",
               Map.put(result, "canonical_status", "unknown"),
               []
             )

    assert {:error, {:invalid_terminal_result, :not_successful}} =
             ArtifactStore.archive_terminal_evidence(
               root,
               "task_coding_1",
               Map.put(result, "status", "unknown"),
               []
             )

    oversized = Map.put(result, "validation", [String.duplicate("x", 1_048_576)])

    assert {:error, {:terminal_evidence_too_large, 1_048_576}} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", oversized, [])

    assert {:error, {:invalid_terminal_controls, :expected_list}} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", result, %{})

    assert {:error, {:invalid_terminal_task_id, :invalid_value}} =
             ArtifactStore.archive_terminal_evidence(root, "task\nwith-control", result, [])

    assert {:error, {:invalid_terminal_control, :identity_or_order}} =
             ArtifactStore.archive_terminal_evidence(
               root,
               "task_coding_1",
               result,
               [terminal_control(%{"task_id" => "other-task"})]
             )

    assert {:error, {:invalid_terminal_controls, :too_many}} =
             ArtifactStore.archive_terminal_evidence(
               root,
               "task_coding_1",
               result,
               Enum.map(1..101, &terminal_control(%{"sequence" => &1, "control_id" => "c-#{&1}"}))
             )
  end

  defp plan_fixture do
    %{
      "version" => 1,
      "task" => "Add a focused regression test",
      "worker" => %{"provider" => "grok", "permission_mode" => "default"},
      "requested_paths" => ["apps/arbor_orchestrator/test/example_test.exs"]
    }
  end

  defp manifest_fixture do
    %{
      "compiler_version" => "coding-plan-1",
      "graph_hash" => String.duplicate("a", 64),
      "template_version" => "coding-change-v1"
    }
  end

  defp terminal_result(root) do
    {:ok, expanded_root} = Arbor.Common.SafePath.resolve_real(root)

    %{
      "status" => "change_committed",
      "canonical_status" => "change_committed",
      "validation" => [%{"command" => "mix test", "passed" => true}],
      "review" => %{
        "recommendation" => "approve",
        "reviewer_outcomes" => %{
          "security" => %{
            "status" => "failed",
            "reason_code" => "branch_failed",
            "provider" => "openai_oauth",
            "model" => "gpt-5.6-sol",
            "effective_vote" => "abstain"
          }
        }
      },
      "tier_decision" => "allow",
      "human_required" => false,
      "security_veto" => false,
      "blast_radius" => "low",
      "artifacts" => %{
        "coding_plan_path" => Path.join(expanded_root, "coding-plan.json"),
        "coding_pipeline_path" => Path.join(expanded_root, "coding-pipeline.dot"),
        "compile_manifest_path" => Path.join(expanded_root, "coding-compile-manifest.json"),
        "graph_hash" => String.duplicate("a", 64),
        "compiler_version" => "coding-plan-1"
      }
    }
  end

  defp terminal_control(overrides \\ %{}) do
    Map.merge(
      %{
        "control_id" => "control_exact_1",
        "task_id" => "task_coding_1",
        "sequence" => 1,
        "status" => "delivered",
        "sender_id" => "agent_owner",
        "message" => "apply the correction",
        "queued_at" => "2026-07-10T12:00:00Z",
        "delivered_at" => "2026-07-10T12:01:00Z",
        "target_stage" => nil,
        "delivery_mode" => "same_session_follow_up",
        "error" => nil
      },
      overrides
    )
  end

  defp read_artifacts(descriptor) do
    Map.new(artifact_paths(descriptor), fn {name, path} -> {name, File.read!(path)} end)
  end

  defp artifact_paths(descriptor) do
    Map.take(descriptor, [
      "coding_plan_path",
      "coding_pipeline_path",
      "compile_manifest_path"
    ])
  end

  defp await_secure_nonempty_temp(root, task_pid, deadline) do
    observations = temporary_file_observations(root)
    nonempty = Enum.filter(observations, &(&1.size > 0))

    case Enum.find(nonempty, &(&1.mode != 0o600)) do
      nil when nonempty != [] ->
        :ok

      nil ->
        cond do
          not Process.alive?(task_pid) ->
            {:error, :archive_completed_before_temp_was_observed}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error, :timed_out_observing_nonempty_temp}

          true ->
            Process.sleep(0)
            await_secure_nonempty_temp(root, task_pid, deadline)
        end

      observation ->
        {:error, {:nonempty_temp_had_insecure_mode, observation}}
    end
  end

  defp temporary_file_observations(root) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, ".coding-pipeline.dot.tmp-"))
        |> Enum.flat_map(fn name ->
          path = Path.join(root, name)

          case File.stat(path) do
            {:ok, stat} -> [%{name: name, size: stat.size, mode: stat.mode &&& 0o777}]
            {:error, :enoent} -> []
          end
        end)

      {:error, :enoent} ->
        []
    end
  end
end
