defmodule Mix.Tasks.Arbor.Packaging.KernelMaterializationTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.KernelMaterialization
  alias Arbor.Commands.KernelMaterialization.{Core, Encode, Evidence}
  alias Arbor.Commands.KernelMaterializationFixtures
  alias Mix.Tasks.Arbor.Packaging.KernelMaterialization, as: Task

  @moduletag :fast

  test "rejects check without phase and invalid phase" do
    assert {:error, {:phase, :required}} = Task.execute(["--check"])
    assert {:error, {:phase, :invalid}} = Task.execute(["--check", "--phase", "auto"])
    assert {:error, {:phase, :required}} = Task.execute(["--json"])
  end

  test "rejects conflicting check and write-plan" do
    assert {:error, {:mode, :conflicting_check_and_write}} =
             Task.execute(["--check", "--write-plan", "--phase", "planned"])
  end

  test "production execute refuses runtime hooks" do
    assert {:error, {:production_task_forbids_runtime_hooks, _}} =
             Task.execute(["--phase", "planned", "--json"], inventory: [])
  end

  test "write authorization precedes synthetic refusal; check never writes" do
    root = tmp_root()
    files = fixture_files()
    {:ok, plan} = Core.project(files)
    {:ok, plan_bytes} = Encode.encode_plan(plan)
    {:ok, evidence} = Evidence.admit(Evidence.empty(plan["entries_digest"]), plan)
    {:ok, evidence_bytes} = Encode.encode_evidence(evidence)

    plan_path = Path.join(root, "apps/arbor_commands/priv/packaging/plan.json")
    ev_path = Path.join(root, "apps/arbor_commands/priv/packaging/evidence.json")
    File.mkdir_p!(Path.dirname(plan_path))
    File.write!(plan_path, plan_bytes)
    File.write!(ev_path, evidence_bytes)
    before_plan = File.read!(plan_path)
    before_ev = File.read!(ev_path)

    assert {:error, :write_not_allowed} =
             KernelMaterialization.run_for_test(
               mode: "write_plan",
               root: root,
               plan: plan_path,
               transform_evidence: ev_path,
               allow_write: false
             )

    assert {:error, :write_plan_requires_git_inventory} =
             KernelMaterialization.run_for_test(
               mode: "write_plan",
               root: root,
               plan: plan_path,
               transform_evidence: ev_path,
               inventory: files,
               allow_write: true
             )

    assert File.read!(plan_path) == before_plan
    assert File.read!(ev_path) == before_ev

    assert {:ok, check} =
             KernelMaterialization.run_for_test(
               mode: "check",
               phase: "planned",
               root: root,
               plan_map: plan,
               evidence_map: evidence,
               inventory: files
             )

    assert check["phase"] == "planned"
    assert File.read!(plan_path) == before_plan
    assert File.read!(ev_path) == before_ev

    File.rm_rf(root)
  end

  test "write-plan binds evidence after the plan exists; malformed and non-empty fail closed" do
    root = tmp_root()
    files = fixture_files()
    {:ok, plan} = Core.project(files)
    {:ok, plan_bytes} = Encode.encode_plan(plan)
    digest = plan["entries_digest"]

    plan_path = Path.join(root, "apps/arbor_commands/priv/packaging/plan.json")
    ev_path = Path.join(root, "apps/arbor_commands/priv/packaging/evidence.json")
    File.mkdir_p!(Path.dirname(plan_path))
    File.write!(plan_path, plan_bytes)

    File.write!(ev_path, "{not-json")
    assert {:error, :evidence_malformed} = Evidence.bind_empty(File.read!(ev_path), digest)
    assert File.read!(plan_path) == plan_bytes
    assert File.read!(ev_path) == "{not-json"

    nonempty = %{
      "schema" => "arbor.packaging.kernel_materialization.transform_evidence.v1",
      "version" => 1,
      "plan_digest" => digest,
      "entries" => [
        %{
          "destination_path" => "apps/arbor_kernel/mix.exs",
          "kind" => "transform",
          "mode" => "100644",
          "oid" => Encode.git_blob_oid("x\n", "sha1")
        }
      ]
    }

    {:ok, nonempty_bytes} = Encode.encode_evidence(nonempty)
    File.write!(ev_path, nonempty_bytes)
    assert {:error, :evidence_not_empty} = Evidence.bind_empty(File.read!(ev_path), digest)
    assert File.read!(ev_path) == nonempty_bytes
    assert File.read!(plan_path) == plan_bytes

    File.rm_rf(root)
  end

  defp fixture_files, do: KernelMaterializationFixtures.fixture_files()

  defp tmp_root, do: KernelMaterializationFixtures.tmp_root()
end
