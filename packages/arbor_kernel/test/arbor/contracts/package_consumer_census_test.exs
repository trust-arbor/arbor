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

  test "packaged Kernel sources retain their internal ownership and registry in both inventories" do
    root = fixture!()

    kernel_sources = %{
      "packages/arbor_kernel/lib/arbor/contracts/example.ex" => @contract_source,
      "packages/arbor_kernel/lib/arbor/contracts.ex" =>
        "defmodule Arbor.Contracts do\n  def list_contracts, do: [Arbor.Contracts.Example]\nend\n",
      "packages/arbor_kernel/lib/kernel_consumer.ex" =>
        "defmodule Fixture.KernelConsumer do\n  alias Arbor.Contracts.Example\nend\n"
    }

    for {path, source} <- kernel_sources do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, source)
    end

    git!(root, ["add", "--" | Map.keys(kernel_sources)])
    options = [root: root, env: %{}, grandfathered: %{}, mode: :enforce]
    assert {:ok, git_report} = Census.run(options)

    assert [entry] = git_report.entries
    assert entry.path == @contract_path
    assert entry.external_consumers == @owners
    assert entry.internal_consumers == ["lib/arbor/contracts.ex", "lib/kernel_consumer.ex"]
    assert entry.in_registry
    assert entry.tier == :shared
    assert git_report.violations == []

    inventory_path = Path.join(root, "kernel-inventory.json")
    paths = Enum.sort(@consumer_paths ++ Map.keys(kernel_sources))
    assert {:ok, inventory} = SourceInventory.build(String.duplicate("b", 40), paths)
    assert {:ok, bytes} = SourceInventory.encode(inventory)
    File.write!(inventory_path, bytes)
    File.rename!(Path.join(root, ".git"), Path.join(root, "hidden-git"))

    env = %{
      "ARBOR_MIX_CONTAINED" => "1",
      "ARBOR_SOURCE_INVENTORY_PATH" => inventory_path
    }

    assert {:ok, contained_report} = Census.run(Keyword.put(options, :env, env))
    assert contained_report.entries == git_report.entries
    assert contained_report.violations == []
  end

  test "nested example sources cannot manufacture consumers or contract admission" do
    root = fixture!()

    sources = %{
      "apps/arbor_security/lib/solo_consumer.ex" =>
        "defmodule Fixture.SecurityConsumer do\n  alias Arbor.Contracts.Solo\nend\n",
      "packages/arbor_kernel/test/solo_consumer_test.exs" =>
        "defmodule Fixture.KernelTestConsumer do\n  alias Arbor.Contracts.Solo\nend\n",
      "packages/arbor_kernel/examples/standalone/lib/consumer.ex" =>
        "defmodule Fixture.KernelExample do\n  alias Arbor.Contracts.Solo\nend\n",
      "packages/arbor_kernel/priv/lib/consumer.ex" =>
        "defmodule Fixture.KernelPrivateFixture do\n  alias Arbor.Contracts.Solo\nend\n",
      "packages/example_only/examples/standalone/lib/consumer.ex" =>
        "defmodule Fixture.ForeignExample do\n  alias Arbor.Contracts.Solo\nend\n"
    }

    for {path, source} <- sources do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, source)
    end

    git!(root, ["add", "--" | Map.keys(sources)])

    options = [
      root: root,
      env: %{},
      contract_sources: [
        {"lib/arbor/contracts/solo.ex", "defmodule Arbor.Contracts.Solo do\nend\n"}
      ],
      registry_source: "",
      grandfathered: %{},
      mode: :enforce
    ]

    assert {:ok, git_report} = Census.run(options)
    assert [entry] = git_report.entries
    assert entry.external_consumers == ["arbor_security"]
    assert entry.internal_consumers == ["test/solo_consumer_test.exs"]
    assert entry.tier == :a2
    assert git_report.violations == [entry]
    assert Census.failed?(git_report)

    inventory_path = Path.join(root, "example-inventory.json")
    paths = Enum.sort(@consumer_paths ++ Map.keys(sources))
    assert {:ok, inventory} = SourceInventory.build(String.duplicate("c", 40), paths)
    assert {:ok, bytes} = SourceInventory.encode(inventory)
    File.write!(inventory_path, bytes)
    File.rename!(Path.join(root, ".git"), Path.join(root, "hidden-git"))

    env = %{
      "ARBOR_MIX_CONTAINED" => "1",
      "ARBOR_SOURCE_INVENTORY_PATH" => inventory_path
    }

    assert {:ok, contained_report} = Census.run(Keyword.put(options, :env, env))
    assert contained_report.entries == git_report.entries
    assert contained_report.violations == [entry]
    assert Census.failed?(contained_report)
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
