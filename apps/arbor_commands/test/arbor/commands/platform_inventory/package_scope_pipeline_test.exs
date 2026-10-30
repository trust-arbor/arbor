defmodule Arbor.Commands.PlatformInventory.PackageScopePipelineTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.PlatformInventory.{Core, Encode}
  alias Arbor.Commands.SourceCoupling.GitInventory

  @moduletag :fast
  @family_paths [
    {"packages/arbor_persistence/lib/core.ex", "arbor_persistence"},
    {"packages/arbor_persistence_sql/lib/sql.ex", "arbor_persistence_sql"},
    {"packages/arbor_persistence_eventstore/lib/eventstore.ex", "arbor_persistence_eventstore"},
    {"apps/arbor_persistence_host/lib/host.ex", "arbor_persistence_host"}
  ]

  test "staged source selection reaches the v2 projector for every split Persistence owner" do
    root = repository!()

    for {path, _owner} <- @family_paths do
      source!(root, path)
    end

    source!(root, "packages/arbor_persistence/test/ignored.ex")
    source!(root, "packages/arbor_persistence_sql/priv/ignored.ex")
    source!(root, "packages/arbor_signals/lib/unselected.ex")
    git!(root, ["add", "."])

    assert {:ok, inventory} = GitInventory.load_selected_blobs(root, Core.platform_apps())

    assert Enum.sort(Enum.map(inventory.files, & &1.path)) ==
             Enum.sort(Enum.map(@family_paths, &elem(&1, 0)))

    assert {:ok, report} = Core.project(inventory)
    assert report["schema"] == "arbor.packaging.platform_inventory.v2"
    assert Map.new(report["entries"], &{&1["path"], &1["app"]}) == Map.new(@family_paths)
    assert report["counts"]["total_files"] == 4
    assert report["counts"]["unreviewed_files"] == 4

    assert Enum.all?(@family_paths, fn {_path, owner} ->
             report["counts"]["by_app"][owner] == 1
           end)

    assert {:ok, _json} = Encode.encode_report(report)
  end

  test "old review paths cannot silently qualify the new physical owners" do
    root = repository!()
    path = "packages/arbor_persistence/lib/core.ex"
    source!(root, path)
    git!(root, ["add", "."])

    assert {:ok, inventory} = GitInventory.load_selected_blobs(root, Core.platform_apps())
    [file] = inventory.files

    review = %{
      "path" => "apps/arbor_persistence/lib/core.ex",
      "blob_oid" => file.blob_oid,
      "class" => "system_extension",
      "rationale" => "Historical v1 review; source movement needs explicit review."
    }

    assert {:ok, report} = Core.project(Map.put(inventory, :classifications, [review]))
    assert report["status"] == "mismatch"
    assert report["counts"]["reviewed_files"] == 0
    assert report["counts"]["unreviewed_files"] == 1

    assert %{"reason" => "extra_review", "detail" => review["path"]} in report["comparison"][
             "failures"
           ]

    assert %{"reason" => "missing_review", "detail" => path} in report["comparison"]["failures"]
  end

  test "an old embedded core copy fails closed after selection rather than disappearing" do
    root = repository!()
    source!(root, "packages/arbor_persistence/lib/core.ex")
    old_path = "apps/arbor_persistence/lib/embedded.ex"
    source!(root, old_path)
    git!(root, ["add", "."])

    assert {:ok, inventory} = GitInventory.load_selected_blobs(root, Core.platform_apps())
    assert Enum.any?(inventory.files, &(&1.path == old_path))
    assert {:error, {:invalid_path, ^old_path}} = Core.project(inventory)
  end

  test "Capabilities source selection preserves Core, Signals adapter and passive Host owners" do
    root = repository!()

    family = [
      {"packages/arbor_capabilities/lib/arbor/security/crypto.ex", "arbor_capabilities"},
      {"packages/arbor_capabilities_signals/lib/arbor/security/adapters/signals_transport.ex",
       "arbor_capabilities_signals"},
      {"apps/arbor_security/lib/arbor/security/host/runtime.ex", "arbor_security"}
    ]

    for {path, _owner} <- family, do: source!(root, path)
    source!(root, "packages/arbor_capabilities/test/ignored.ex")
    source!(root, "packages/arbor_capabilities_signals/priv/ignored.ex")
    source!(root, "packages/arbor_signals/lib/unselected.ex")
    git!(root, ["add", "."])

    assert {:ok, inventory} = GitInventory.load_selected_blobs(root, Core.platform_apps())

    assert Enum.sort(Enum.map(inventory.files, & &1.path)) ==
             Enum.sort(Enum.map(family, &elem(&1, 0)))

    assert {:ok, report} = Core.project(inventory)
    assert Map.new(report["entries"], &{&1["path"], &1["app"]}) == Map.new(family)
    assert report["counts"]["total_files"] == 3
    assert report["counts"]["unreviewed_files"] == 3

    for {_path, owner} <- family, do: assert(report["counts"]["by_app"][owner] == 1)
    assert {:ok, _json} = Encode.encode_report(report)
  end

  test "a stale Security host review cannot qualify Core while current Host remains reviewed" do
    root = repository!()
    core_path = "packages/arbor_capabilities/lib/arbor/security/crypto.ex"
    host_path = "apps/arbor_security/lib/arbor/security/host/runtime.ex"
    old_path = "apps/arbor_security/lib/arbor/security/crypto.ex"
    source!(root, core_path)
    source!(root, host_path)
    git!(root, ["add", "."])

    assert {:ok, inventory} = GitInventory.load_selected_blobs(root, Core.platform_apps())
    blobs = Map.new(inventory.files, &{&1.path, &1.blob_oid})

    review = fn path, blob ->
      %{
        "path" => path,
        "blob_oid" => blob,
        "class" => "system_extension",
        "rationale" => "Explicit physical source-owner review."
      }
    end

    reviews = [review.(old_path, blobs[core_path]), review.(host_path, blobs[host_path])]
    assert {:ok, report} = Core.project(Map.put(inventory, :classifications, reviews))
    assert report["status"] == "mismatch"
    assert report["counts"]["reviewed_files"] == 1
    assert report["counts"]["unreviewed_files"] == 1
    assert %{"reason" => "extra_review", "detail" => old_path} in report["comparison"]["failures"]

    assert %{"reason" => "missing_review", "detail" => core_path} in report["comparison"][
             "failures"
           ]

    assert Enum.find(report["entries"], &(&1["path"] == host_path))["app"] == "arbor_security"
    assert Enum.find(report["entries"], &(&1["path"] == core_path))["app"] == "arbor_capabilities"
  end

  test "an embedded Capabilities copy under apps fails the explicit physical-owner guard" do
    root = repository!()
    source!(root, "packages/arbor_capabilities/lib/arbor/security/crypto.ex")
    wrong_path = "apps/arbor_capabilities/lib/arbor/security/crypto.ex"
    source!(root, wrong_path)
    git!(root, ["add", "."])

    assert {:ok, inventory} = GitInventory.load_selected_blobs(root, Core.platform_apps())
    assert Enum.any?(inventory.files, &(&1.path == wrong_path))
    assert {:error, {:invalid_path, ^wrong_path}} = Core.project(inventory)
  end

  defp repository! do
    suffix = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    root = Path.join(System.tmp_dir!(), "arbor-platform-package-scope-#{suffix}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(root, ["init", "--quiet"])

    git!(root, [
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "commit",
      "--allow-empty",
      "--quiet",
      "-m",
      "fixture"
    ])

    root
  end

  defp source!(root, path) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "defmodule Fixture.Source do\n  def value, do: :ok\nend\n")
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
