defmodule Mix.Tasks.Arbor.Packaging.SourceCouplingTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Arbor.Packaging.SourceCoupling, as: Task

  @moduletag :fast

  test "rejects conflicting check and write-baseline" do
    assert {:error, {:mode, :conflicting_check_and_write}} =
             Task.execute(["--check", "--write-baseline"])
  end

  test "check mode with injected inventory detects new finding and does not write" do
    root =
      System.tmp_dir!()
      |> Path.join("sc-check-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "apps/arbor_contracts/lib"))
    File.mkdir_p!(Path.join(root, "apps/arbor_common/lib"))
    File.mkdir_p!(Path.join(root, "apps/arbor_commands/priv/packaging"))

    # Marker for root discovery
    File.mkdir_p!(Path.join(root, "apps/arbor_contracts"))
    File.write!(Path.join(root, "apps/arbor_contracts/mix.exs"), contracts_mix())
    File.write!(Path.join(root, "apps/arbor_common/mix.exs"), common_mix([]))

    File.write!(
      Path.join(root, "apps/arbor_contracts/lib/foo.ex"),
      "defmodule Arbor.Contracts.Foo do\n  def ok, do: :ok\nend\n"
    )

    File.write!(
      Path.join(root, "apps/arbor_common/lib/bar.ex"),
      "defmodule Arbor.Common.Bar do\n  def c, do: Arbor.Contracts.Foo.ok()\nend\n"
    )

    baseline_path =
      Path.join(root, "apps/arbor_commands/priv/packaging/source_coupling_baseline.v1.json")

    empty = empty_baseline()
    File.write!(baseline_path, Jason.encode!(empty))
    before = File.read!(baseline_path)

    inventory = %{
      files: [
        inv_file("apps/arbor_contracts/mix.exs", contracts_mix()),
        inv_file("apps/arbor_common/mix.exs", common_mix([])),
        inv_file(
          "apps/arbor_contracts/lib/foo.ex",
          "defmodule Arbor.Contracts.Foo do\n  def ok, do: :ok\nend\n"
        ),
        inv_file(
          "apps/arbor_common/lib/bar.ex",
          "defmodule Arbor.Common.Bar do\n  def c, do: Arbor.Contracts.Foo.ok()\nend\n"
        )
      ],
      tree_oid: String.duplicate("e", 40),
      object_format: "sha1"
    }

    assert {:ok, report} =
             Arbor.Commands.SourceCoupling.run_for_test(
               mode: "check",
               root: root,
               baseline: baseline_path,
               inventory: inventory,
               allow_write: false
             )

    assert report["status"] == "failed"
    assert File.read!(baseline_path) == before

    # Production run refuses synthetic inventory.
    assert {:error, {:production_opts_forbid_synthetic, _}} =
             Arbor.Commands.SourceCoupling.run(
               mode: "check",
               root: root,
               baseline: baseline_path,
               inventory: inventory
             )

    # write_baseline refuses synthetic inventory even via test hooks.
    assert {:error, :write_baseline_requires_git_inventory} =
             Arbor.Commands.SourceCoupling.run_for_test(
               mode: "write_baseline",
               root: root,
               baseline: baseline_path,
               inventory: inventory
             )

    File.rm_rf(root)
  end

  test "git stage parser rejects non-zero stage" do
    alias Arbor.Commands.SourceCoupling.GitInventory

    line =
      "100644 " <> String.duplicate("a", 40) <> " 1\tapps/arbor_contracts/mix.exs"

    assert {:error, {:non_zero_stage, _, 1}} = GitInventory.parse_stage_line(line)

    ok = "100644 " <> String.duplicate("b", 40) <> " 0\tapps/arbor_contracts/mix.exs"
    assert {:ok, %{stage: 0}} = GitInventory.parse_stage_line(ok)
  end

  test "compatibility flag projects private-to-tracked without canonical merge" do
    root =
      System.tmp_dir!()
      |> Path.join("sc-compat-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "apps/arbor_contracts/lib"))
    File.write!(Path.join(root, "apps/arbor_contracts/mix.exs"), contracts_mix())

    File.write!(
      Path.join(root, "apps/arbor_contracts/lib/foo.ex"),
      "defmodule Arbor.Contracts.Foo do\n  def ok, do: :ok\nend\n"
    )

    inventory = %{
      files: [
        inv_file("apps/arbor_contracts/mix.exs", contracts_mix()),
        inv_file(
          "apps/arbor_contracts/lib/foo.ex",
          "defmodule Arbor.Contracts.Foo do\n  def ok, do: :ok\nend\n"
        )
      ],
      tree_oid: String.duplicate("a", 40),
      object_format: "sha1"
    }

    private = [
      inv_file(
        "apps/arbor_integrations/mix.exs",
        """
        defmodule Arbor.Integrations.MixProject do
          use Mix.Project
          def project, do: [app: :arbor_integrations, deps: [{:arbor_contracts, in_umbrella: true}]]
        end
        """
      ),
      inv_file(
        "apps/arbor_integrations/lib/p.ex",
        """
        defmodule Arbor.Integrations.P do
          def c, do: Arbor.Contracts.Foo.ok()
        end
        """
      )
    ]

    assert {:ok, without_compat} =
             Arbor.Commands.SourceCoupling.run_for_test(
               mode: "report",
               root: root,
               inventory: inventory
             )

    assert {:ok, report} =
             Arbor.Commands.SourceCoupling.run_for_test(
               mode: "report",
               root: root,
               inventory: inventory,
               compatibility_integrations: true,
               compatibility_files: private
             )

    assert report["compatibility"]["gating"] == false

    assert Enum.any?(
             report["compatibility"]["occurrences"],
             &(&1["target"] == "Arbor.Contracts.Foo")
           )

    refute Enum.any?(
             report["undeclared"]["findings"] || [],
             &String.contains?(&1["file"], "integrations")
           )

    # Canonical gating inputs unchanged by compatibility projection.
    assert without_compat["provenance"]["scan_manifest_digest"] ==
             report["provenance"]["scan_manifest_digest"]

    assert without_compat["undeclared"]["occurrence_count"] ==
             report["undeclared"]["occurrence_count"]

    assert without_compat["summaries"]["occurrences"] == report["summaries"]["occurrences"]
    assert without_compat["summaries"]["fate"] == report["summaries"]["fate"]

    File.rm_rf(root)
  end

  test "output mode carries --json vs human" do
    root =
      System.tmp_dir!()
      |> Path.join("sc-json-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "apps/arbor_contracts/lib"))
    File.write!(Path.join(root, "apps/arbor_contracts/mix.exs"), contracts_mix())

    File.write!(
      Path.join(root, "apps/arbor_contracts/lib/foo.ex"),
      "defmodule Arbor.Contracts.Foo do\nend\n"
    )

    inventory = %{
      files: [
        inv_file("apps/arbor_contracts/mix.exs", contracts_mix()),
        inv_file("apps/arbor_contracts/lib/foo.ex", "defmodule Arbor.Contracts.Foo do\nend\n")
      ],
      tree_oid: String.duplicate("b", 40),
      object_format: "sha1"
    }

    assert {:ok, human} =
             Arbor.Commands.SourceCoupling.run_for_test(
               mode: "report",
               root: root,
               inventory: inventory,
               json: false
             )

    assert human["output"] == "human"

    assert {:ok, json} =
             Arbor.Commands.SourceCoupling.run_for_test(
               mode: "report",
               root: root,
               inventory: inventory,
               json: true
             )

    assert json["output"] == "json"

    File.rm_rf(root)
  end

  test "git stage parser security regression: rejects symlink and non-regular modes" do
    alias Arbor.Commands.SourceCoupling.GitInventory

    oid = String.duplicate("c", 40)
    path = "apps/arbor_contracts/lib/link.ex"

    # Symlink mode must never be admitted (regression: 120000 was previously
    # listed alongside regular modes, making the reject branch unreachable).
    symlink_line = "120000 #{oid} 0\t#{path}"
    assert {:error, {:symlink_blob, ^path}} = GitInventory.parse_stage_line(symlink_line)

    # Other non-regular modes (gitlink, tree, etc.) also rejected.
    for mode <- ["160000", "040000", "100666", "000000"] do
      line = "#{mode} #{oid} 0\t#{path}"
      assert {:error, {:invalid_mode, ^mode, ^path}} = GitInventory.parse_stage_line(line)
    end

    # Accepted modes are exactly regular blobs.
    assert MapSet.equal?(GitInventory.accepted_modes(), MapSet.new(["100644", "100755"]))

    assert {:ok, %{mode: "100644", blob_oid: ^oid}} =
             GitInventory.parse_stage_line("100644 #{oid} 0\t#{path}")

    assert {:ok, %{mode: "100755", blob_oid: ^oid}} =
             GitInventory.parse_stage_line("100755 #{oid} 0\t#{path}")

    # Accepted set must not include the symlink mode (guards future drift).
    refute MapSet.member?(GitInventory.accepted_modes(), "120000")
  end

  defp inv_file(path, bytes) do
    %{
      path: path,
      blob_oid: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
      bytes: bytes
    }
  end

  defp contracts_mix do
    """
    defmodule Arbor.Contracts.MixProject do
      use Mix.Project
      def project, do: [app: :arbor_contracts, deps: []]
    end
    """
  end

  defp common_mix(deps) do
    dep_src =
      Enum.map_join(deps, ", ", fn d -> "{:#{d}, in_umbrella: true}" end)

    """
    defmodule Arbor.Common.MixProject do
      use Mix.Project
      def project, do: [app: :arbor_common, deps: [#{dep_src}]]
    end
    """
  end

  defp empty_baseline do
    digest = Arbor.Commands.SourceCoupling.Encode.entries_digest([])

    %{
      "schema" => "arbor.packaging.source_coupling.baseline.v1",
      "version" => 1,
      "provenance" => %{
        "tree_oid" => String.duplicate("f", 40),
        "scan_manifest_digest" => String.duplicate("0", 64)
      },
      "policy" => %{
        "removal" => "require_write",
        "typespec_only" => "gate",
        "unresolved" => "require_disposition",
        "metadata_match" => "required"
      },
      "counts" => %{},
      "entries" => [],
      "unresolved_entries" => [],
      "entries_digest" => digest
    }
  end
end
