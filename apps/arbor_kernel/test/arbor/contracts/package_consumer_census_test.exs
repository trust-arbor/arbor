defmodule Arbor.Contracts.PackageConsumerCensusTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Census
  alias Arbor.Contracts.Coding.SourceInventory

  @moduletag :fast
  @contract_path "lib/arbor/contracts/example.ex"
  @contract_source "defmodule Arbor.Contracts.Example do\n  defstruct [:id]\nend\n"
  @consumer_paths [
    "packages/arbor_persistence/lib/consumer.ex",
    "packages/arbor_persistence_sql/test/consumer_test.exs",
    "apps/arbor_persistence_host/lib/consumer.ex"
  ]
  @owners ~w(arbor_persistence arbor_persistence_host arbor_persistence_sql)

  test "tracked package consumers keep distinct real owner identities in contract admission" do
    root = fixture!()

    assert {:ok, report} = Census.run(options(root, %{}))
    assert [%{external_consumers: @owners, tier: :shared}] = report.entries
    assert report.violations == []
  end

  test "contained source inventories retain the same package consumers without Git fallback" do
    root = fixture!()
    inventory_path = Path.join(root, "inventory.json")
    assert {:ok, inventory} = SourceInventory.build(String.duplicate("a", 40), @consumer_paths)
    assert {:ok, bytes} = SourceInventory.encode(inventory)
    File.write!(inventory_path, bytes)
    File.rename!(Path.join(root, ".git"), Path.join(root, "hidden-git"))

    env = %{
      "ARBOR_MIX_CONTAINED" => "1",
      "ARBOR_SOURCE_INVENTORY_PATH" => inventory_path
    }

    assert {:ok, report} = Census.run(options(root, env))
    assert [%{external_consumers: @owners, tier: :shared}] = report.entries
    assert report.violations == []
  end

  defp options(root, env) do
    [
      root: root,
      env: env,
      contract_sources: [{@contract_path, @contract_source}],
      registry_source: "",
      grandfathered: %{},
      mode: :enforce
    ]
  end

  defp fixture! do
    suffix = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    root = Path.join(System.tmp_dir!(), "arbor-package-consumer-census-#{suffix}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for path <- @consumer_paths do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "defmodule Fixture.Consumer do\n  alias Arbor.Contracts.Example\nend\n")
    end

    # An untracked caller must not manufacture an additional consumer.
    untracked = Path.join(root, "apps/untracked/lib/consumer.ex")
    File.mkdir_p!(Path.dirname(untracked))
    File.write!(untracked, "alias Arbor.Contracts.Example\n")

    git!(root, ["init", "--quiet"])
    git!(root, ["add", "--" | @consumer_paths])
    root
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
