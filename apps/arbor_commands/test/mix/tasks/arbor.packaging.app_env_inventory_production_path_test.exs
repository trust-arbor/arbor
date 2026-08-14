defmodule Mix.Tasks.Arbor.Packaging.AppEnvInventoryProductionPathTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.AppEnvInventory

  @moduletag :slow
  @moduletag timeout: 300_000

  test "production inventory reports residue across production, test/support, and config blocks" do
    root = umbrella_root()

    assert {:ok, report} = AppEnvInventory.run(mode: "report", root: root, json: true)

    assert report["schema"] == "arbor.packaging.app_env_inventory.v1"
    assert report["status"] == "residue"
    assert report["counts"]["production"] > 0
    assert report["counts"]["test_support"] > 0
    assert report["counts"]["config_block"] > 0
    assert report["counts"]["total"] > 0
    assert report["counts"]["by_class"]["production"] == report["counts"]["production"]
    assert report["counts"]["by_class"]["test_support"] == report["counts"]["test_support"]
    assert report["counts"]["by_class"]["config_block"] == report["counts"]["config_block"]
    assert map_size(report["counts"]["by_trust"]) == 3
    assert map_size(report["counts"]["by_owner"]) == 5
    assert report["provenance"]["provenance_source"] == "git_index_blobs"
    assert report["provenance"]["object_format"] in ["sha1", "sha256"]

    Enum.each(report["findings"], fn finding ->
      assert finding["trust"] in ["literal", "resolved", "untrusted"]
      assert finding["class"] in ["production", "test_support", "config_block"]

      assert finding["legacy_app"] in [
               nil,
               "arbor_contracts",
               "arbor_common",
               "arbor_signals",
               "arbor_monitor"
             ]
    end)

    refute Enum.any?(report["findings"], fn finding ->
             String.contains?(finding["path"] || "", "generic") and finding["trust"] == "resolved"
           end)
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
