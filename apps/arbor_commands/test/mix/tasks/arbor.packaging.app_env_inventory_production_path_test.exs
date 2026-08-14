defmodule Mix.Tasks.Arbor.Packaging.AppEnvInventoryProductionPathTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.AppEnvInventory

  @moduletag :slow
  @moduletag timeout: 300_000

  test "production inventory reports a clean stage-0 census with verified provenance" do
    root = umbrella_root()

    assert {:ok, report} = AppEnvInventory.run(mode: "report", root: root, json: true)

    assert report["schema"] == "arbor.packaging.app_env_inventory.v1"
    assert report["status"] == "clean"
    assert report["counts"]["production"] == 0
    assert report["counts"]["test_support"] == 0
    assert report["counts"]["config_block"] == 0
    assert report["counts"]["untrusted"] == 0
    assert report["counts"]["total"] == 0
    assert report["findings"] == []
    assert report["counts"]["by_class"]["production"] == 0
    assert report["counts"]["by_class"]["test_support"] == 0
    assert report["counts"]["by_class"]["config_block"] == 0
    assert map_size(report["counts"]["by_trust"]) == 3
    assert map_size(report["counts"]["by_owner"]) == 5
    assert report["provenance"]["provenance_source"] == "git_index_blobs"
    assert report["provenance"]["object_format"] in ["sha1", "sha256"]
    assert is_binary(report["provenance"]["tree_oid"])
    assert report["provenance"]["tree_oid"] != ""
    assert is_binary(report["provenance"]["scan_manifest_digest"])
    assert report["provenance"]["scan_manifest_digest"] != ""

    oid_size = byte_size(report["provenance"]["tree_oid"])

    case report["provenance"]["object_format"] do
      "sha1" -> assert oid_size == 40
      "sha256" -> assert oid_size == 64
    end
  end

  defp umbrella_root do
    find_root(__DIR__)
  end

  defp find_root(dir) do
    cond do
      File.regular?(Path.join([dir, "apps", "arbor_kernel", "mix.exs"])) -> dir
      Path.dirname(dir) == dir -> raise "umbrella root not found"
      true -> find_root(Path.dirname(dir))
    end
  end
end
