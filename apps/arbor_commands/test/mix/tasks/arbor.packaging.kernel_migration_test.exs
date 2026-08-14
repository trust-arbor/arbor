defmodule Mix.Tasks.Arbor.Packaging.KernelMigrationTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.KernelMigration
  alias Arbor.Commands.KernelMigration.{Core, Encode}
  alias Mix.Tasks.Arbor.Packaging.KernelMigration, as: Task

  @moduletag :fast

  defp oid(tag) when is_binary(tag) do
    :crypto.hash(:sha256, tag)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 40)
  end

  test "rejects conflicting check and write-report" do
    assert {:error, {:mode, :conflicting_check_and_write}} =
             Task.execute(["--check", "--write-report"])
  end

  test "check is no-write; write authorization precedes synthetic refusal" do
    root = tmp_root()
    paths = write_manifests(root)

    census = %{
      "classified_edges" => [],
      "provenance" => %{
        "scan_manifest_digest" => String.duplicate("1", 64),
        "tree_oid" => String.duplicate("2", 40),
        "object_format" => "sha1",
        "provenance_source" => "test_injection"
      }
    }

    before = File.read!(paths.report)

    assert {:error, {:report_invalid, invalid_path}} =
             KernelMigration.run_for_test(
               mode: "check",
               root: root,
               report: paths.report,
               disposition: paths.disposition,
               boundary: paths.boundary,
               formatter: paths.formatter,
               census: census,
               blobs: %{},
               allow_write: false
             )

    assert {:error, {:report_invalid, ^invalid_path}} =
             KernelMigration.run_for_test(
               mode: "check",
               root: root,
               report: paths.report,
               disposition: paths.disposition,
               boundary: paths.boundary,
               formatter: paths.formatter,
               census: census,
               blobs: %{},
               allow_write: false
             )

    assert File.read!(paths.report) == before

    assert {:error, :write_not_allowed} =
             KernelMigration.run_for_test(
               mode: "write_report",
               root: root,
               report: paths.report,
               disposition: paths.disposition,
               boundary: paths.boundary,
               formatter: paths.formatter,
               census: census,
               blobs: %{},
               allow_write: false
             )

    assert File.read!(paths.report) == before

    assert {:error, :write_report_requires_git_inventory} =
             KernelMigration.run_for_test(
               mode: "write_report",
               root: root,
               report: paths.report,
               disposition: paths.disposition,
               boundary: paths.boundary,
               formatter: paths.formatter,
               census: census,
               allow_write: true
             )

    assert File.read!(paths.report) == before

    File.rm_rf(root)
  end

  test "check admits the checked report, fails closed on tamper, and never writes" do
    root = tmp_root()
    paths = write_manifests(root)

    census = %{
      "classified_edges" => [],
      "provenance" => %{
        "scan_manifest_digest" => String.duplicate("1", 64),
        "tree_oid" => String.duplicate("2", 40),
        "object_format" => "sha1",
        "provenance_source" => "test_injection"
      }
    }

    assert {:ok, generated} =
             KernelMigration.run_for_test(
               mode: "report",
               root: root,
               report: paths.report,
               disposition: paths.disposition,
               boundary: paths.boundary,
               formatter: paths.formatter,
               census: census,
               blobs: %{}
             )

    {:ok, bytes} = Encode.encode_report(generated)
    File.write!(paths.report, bytes)
    before = File.read!(paths.report)

    assert {:ok, check} =
             KernelMigration.run_for_test(
               mode: "check",
               root: root,
               report: paths.report,
               disposition: paths.disposition,
               boundary: paths.boundary,
               formatter: paths.formatter,
               census: census,
               blobs: %{}
             )

    assert check["status"] == "failed"
    assert File.read!(paths.report) == before
    {:ok, check_bytes} = Encode.encode_report(check)

    {:ok, again} =
      KernelMigration.run_for_test(
        mode: "check",
        root: root,
        report: paths.report,
        disposition: paths.disposition,
        boundary: paths.boundary,
        formatter: paths.formatter,
        census: census,
        blobs: %{}
      )

    {:ok, again_bytes} = Encode.encode_report(again)
    assert check_bytes == again_bytes

    tampered_bytes =
      String.replace(before, generated["identity"], String.duplicate("e", 64), global: false)

    File.write!(paths.report, tampered_bytes)

    assert {:ok, tampered} =
             KernelMigration.run_for_test(
               mode: "check",
               root: root,
               report: paths.report,
               disposition: paths.disposition,
               boundary: paths.boundary,
               formatter: paths.formatter,
               census: census,
               blobs: %{}
             )

    assert tampered["status"] == "failed"
    assert Enum.any?(tampered["comparison"]["failures"], &(&1["reason"] == "report_drift"))
    assert File.read!(paths.report) == tampered_bytes

    File.write!(paths.report, "{not-json")

    assert {:error, {:report_invalid, _}} =
             KernelMigration.run_for_test(
               mode: "check",
               root: root,
               report: paths.report,
               disposition: paths.disposition,
               boundary: paths.boundary,
               formatter: paths.formatter,
               census: census,
               blobs: %{}
             )

    File.rm(paths.report)

    assert {:error, {:report_missing, _}} =
             KernelMigration.run_for_test(
               mode: "check",
               root: root,
               report: paths.report,
               disposition: paths.disposition,
               boundary: paths.boundary,
               formatter: paths.formatter,
               census: census,
               blobs: %{}
             )

    File.rm_rf(root)
  end

  test "with_direct_runtime owns try/after cleanup and never starts arbor_shell" do
    policy = Arbor.Shell.ExecutablePolicy
    registry = Arbor.Shell.ExecutionRegistry

    already? =
      is_pid(Process.whereis(policy)) and is_pid(Process.whereis(registry))

    result =
      Arbor.Commands.SourceCoupling.with_direct_runtime(fn ->
        {:ok, Process.whereis(policy)}
      end)

    assert {:ok, pid} = result
    assert is_pid(pid)

    unless already? do
      refute Process.whereis(policy)
      refute Process.whereis(registry)
    end
  end

  test "bounded diagnostics cap failure lists" do
    failures =
      for i <- 1..60 do
        %{"reason" => "missing_disposition", "detail" => "x#{i}"}
      end

    report =
      Core.show(
        %{"runtime" => [], "mix_task" => [], "provenance" => %{}},
        %{
          "status" => "failed",
          "failures" => Enum.take(failures, 50),
          "failure_count" => 60,
          "truncated" => true
        },
        %{"mode" => "check"}
      )

    assert length(report["comparison"]["failures"]) == 50
    assert report["comparison"]["truncated"] == true
    assert report["comparison"]["failure_count"] == 60
  end

  test "query_indexed_blobs returns absent formatter configs without requiring them" do
    alias Arbor.Commands.SourceCoupling.GitInventory

    paths = [".formatter.exs", "apps/arbor_contracts/.formatter.exs"]

    run_git = fn _root, args, _stdin ->
      lit = Enum.find_index(args, &(&1 == "--literal-pathspecs"))
      ls = Enum.find_index(args, &(&1 == "ls-files"))
      assert is_integer(lit) and is_integer(ls) and lit < ls
      assert ["--literal-pathspecs", "ls-files", "-z", "--stage", "--" | ^paths] = args
      {:ok, ""}
    end

    assert {:ok, %{present: [], absent: absent}} =
             GitInventory.query_indexed_blobs("/tmp", paths, run_git: run_git)

    assert absent == paths

    assert {:error, {:blob_missing, ".formatter.exs"}} =
             GitInventory.read_indexed_blobs("/tmp", paths, run_git: run_git)
  end

  test "query_indexed_blobs rejects absolute, traversal, NUL, and pathspec-magic paths" do
    alias Arbor.Commands.SourceCoupling.GitInventory

    run_git = fn _root, _args, _stdin -> flunk("git must not run for rejected paths") end

    assert {:error, {:invalid_path, :absolute}} =
             GitInventory.query_indexed_blobs("/tmp", ["/etc/passwd"], run_git: run_git)

    assert {:error, {:invalid_path, :traversal}} =
             GitInventory.query_indexed_blobs(
               "/tmp",
               ["apps/../secret.ex"],
               run_git: run_git
             )

    assert {:error, {:invalid_path, :nul}} =
             GitInventory.query_indexed_blobs("/tmp", ["apps/foo\0.ex"], run_git: run_git)

    assert {:error, {:invalid_path, :pathspec_magic}} =
             GitInventory.query_indexed_blobs("/tmp", ["apps/**/*.ex"], run_git: run_git)

    assert {:error, {:invalid_path, :pathspec_magic}} =
             GitInventory.query_indexed_blobs("/tmp", [":(glob)apps/*.ex"], run_git: run_git)
  end

  defp tmp_root do
    root =
      System.tmp_dir!()
      |> Path.join("km-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "apps/arbor_contracts"))
    File.write!(Path.join(root, "apps/arbor_contracts/mix.exs"), "defmodule X, do: :ok\n")
    File.mkdir_p!(Path.join(root, "apps/arbor_commands/priv/packaging"))
    root
  end

  defp write_manifests(root) do
    pack = Path.join(root, "apps/arbor_commands/priv/packaging")

    disposition = %{
      "schema" => "arbor.packaging.kernel_migration.disposition.v1",
      "version" => 1,
      "entries" => []
    }

    boundary = %{
      "schema" => "arbor.packaging.kernel_migration.boundary.v1",
      "version" => 1,
      "entries" =>
        for i <- 1..20 do
          %{
            "current_path" => "apps/arbor_common/lib/f#{i}.ex",
            "from_module" => "Arbor.Common.F#{i}",
            "target" => "Arbor.Actions",
            "kind" => "expr",
            "site_line" => i,
            "proof_destination" => "apps/arbor_kernel/lib/f#{i}.ex",
            "source" => "census_runtime",
            "blob_oid" => oid("b#{i}")
          }
        end ++
          [
            %{
              "current_path" => "apps/arbor_common/lib/arbor/common/model_profile.ex",
              "from_module" => "Arbor.Common.ModelProfile",
              "target" => "LLMDB",
              "kind" => "attribute",
              "site_line" => 344,
              "proof_destination" => "apps/arbor_kernel/lib/arbor/common/model_profile.ex",
              "source" => "census_ignored_external",
              "blob_oid" => oid("llmdb")
            },
            %{
              "current_path" => "apps/arbor_common/lib/arbor/common/agent_telemetry/store.ex",
              "from_module" => "Arbor.Common.AgentTelemetry.Store",
              "target" => "Ecto.Adapters.Postgres",
              "kind" => "expr",
              "site_line" => 323,
              "proof_destination" =>
                "apps/arbor_kernel/lib/arbor/common/agent_telemetry/store.ex",
              "source" => "census_ignored_external",
              "blob_oid" => oid("pg")
            }
          ]
    }

    formatter = %{
      "schema" => "arbor.packaging.kernel_migration.formatter.v1",
      "version" => 1,
      "files" =>
        for i <- 1..38 do
          %{
            "current_path" => "apps/arbor_contracts/lib/c#{i}.ex",
            "proof_destination" => "apps/arbor_kernel/lib/c#{i}.ex",
            "blob_oid" => oid("c#{i}")
          }
        end,
      "configs" => [
        %{"path" => ".formatter.exs", "status" => "present", "blob_oid" => oid("rootfmt")},
        %{
          "path" => "apps/arbor_common/.formatter.exs",
          "status" => "present",
          "blob_oid" => oid("commonfmt")
        },
        %{"path" => "apps/arbor_contracts/.formatter.exs", "status" => "expected_absent"},
        %{"path" => "apps/arbor_monitor/.formatter.exs", "status" => "expected_absent"},
        %{"path" => "apps/arbor_signals/.formatter.exs", "status" => "expected_absent"}
      ]
    }

    paths = %{
      report: Path.join(pack, "kernel_migration_report.v1.json"),
      disposition: Path.join(pack, "kernel_migration_disposition.v1.json"),
      boundary: Path.join(pack, "kernel_migration_boundary.v1.json"),
      formatter: Path.join(pack, "kernel_migration_formatter.v1.json")
    }

    File.write!(paths.report, "{}")
    File.write!(paths.disposition, Jason.encode!(disposition))
    File.write!(paths.boundary, Jason.encode!(boundary))
    File.write!(paths.formatter, Jason.encode!(formatter))
    paths
  end
end
