defmodule Arbor.Commands.TwoBuildFactFixture do
  @moduledoc false

  # Test-only fixture builder for exercising
  # Arbor.Commands.SafeRecoveryArtifact.compose_from_facts_for_test/1 without
  # ever touching Arbor.Shell/SourceStaging.

  alias Arbor.Commands.SafeRecoveryArtifactFixture, as: Fixture

  @identity %{
    "path" => "/tmp/arbor-two-build-fixture-source",
    "type" => "directory",
    "device" => 1,
    "minor_device" => 0,
    "inode" => 1
  }

  @phase_ok %{exit_code: 0, timed_out: false, killed: false}

  @spec phase_ok() :: map()
  def phase_ok, do: @phase_ok

  @spec source_lease() :: map()
  def source_lease do
    Fixture.source()
    |> Map.put("identity", @identity)
  end

  @spec deps_inventory() :: map()
  def deps_inventory do
    files = [Fixture.regular_file("some_dep-1.0.0/ebin/some_dep.app", "app-body", 0o644)]

    dirs = [
      %{"path" => "some_dep-1.0.0", "mode" => 0o755},
      %{"path" => "some_dep-1.0.0/ebin", "mode" => 0o755}
    ]

    trusted_build_document(dirs, files, "deps")
  end

  @doc """
  Returns `{release_document, bytes_by_rebased_path}` -- a closed
  "arbor.shell.trusted_build.inventory.v1"/"release" document rooted at
  "arbor_trust/..." (built from the golden E0B2B fixture bodies) plus the raw
  bytes for every regular file, keyed by its *rebased* (post-strip) path.
  """
  @spec release_inventory() :: {map(), %{optional(String.t()) => binary()}}
  def release_inventory do
    bodies = Fixture.golden_bodies()

    bytes_by_rebased_path = Map.new(bodies, fn {path, bytes, _mode} -> {path, bytes} end)

    files =
      Enum.map(bodies, fn {path, bytes, mode} ->
        Fixture.regular_file(prefixed(path), bytes, mode)
      end)

    dirs =
      [%{"path" => "arbor_trust", "mode" => 0o755} | Fixture.golden_directories()]
      |> Enum.map(fn
        %{"path" => "arbor_trust"} = row -> row
        %{"path" => path} = row -> %{row | "path" => prefixed(path)}
      end)

    document = trusted_build_document(dirs, files, "release")

    {document, bytes_by_rebased_path}
  end

  @doc "Selector-keyed `%{\"path\"=>selector,\"bytes\"=>bytes}` replies for every attested .app/.rel row."
  @spec descriptor_replies(map(), %{optional(String.t()) => binary()}) :: [map()]
  def descriptor_replies(release_document, bytes_by_rebased_path) do
    release_document["regular_files"]
    |> Enum.filter(
      &(String.ends_with?(&1["path"], ".app") or String.ends_with?(&1["path"], ".rel"))
    )
    |> Enum.map(fn %{"path" => selector} ->
      rebased = selector |> Path.split() |> tl() |> Path.join()
      %{"path" => selector, "bytes" => Map.fetch!(bytes_by_rebased_path, rebased)}
    end)
  end

  @doc "A complete happy-path `facts` map for both slots -- suitable for `%{mode: :compose, facts: facts()}`."
  @spec facts() :: map()
  def facts do
    source = source_lease()
    deps = deps_inventory()
    {release_a, bytes_a} = release_inventory()
    {release_b, bytes_b} = release_inventory()

    replies =
      %{}
      |> Map.merge(%{
        {:stage_source, :a} => {:ok, source},
        {:stage_source, :b} => {:ok, source},
        {:acquire_build, :a} => {:ok, :fixture_build_a},
        {:acquire_build, :b} => {:ok, :fixture_build_b},
        {:remove_cookie, :a} => {:ok, %{}},
        {:remove_cookie, :b} => {:ok, %{}}
      })
      |> Map.merge(phase_replies(:a))
      |> Map.merge(phase_replies(:b))
      |> Map.put({:inventory_deps, :a}, {:ok, deps})
      |> Map.put({:inventory_deps, :b}, {:ok, deps})
      |> Map.put({:inventory_release, :a}, {:ok, release_a})
      |> Map.put({:inventory_release, :b}, {:ok, release_b})
      |> Map.put({:read_descriptors, :a}, {:ok, descriptor_replies(release_a, bytes_a)})
      |> Map.put({:read_descriptors, :b}, {:ok, descriptor_replies(release_b, bytes_b)})

    %{replies: replies, cleanup_replies: %{}}
  end

  defp phase_replies(slot) do
    %{
      {:run_phase, slot, "deps_get"} => {:ok, @phase_ok},
      {:stage_native, slot} => {:ok, %{}},
      {:run_phase, slot, "compile"} => {:ok, @phase_ok},
      {:run_phase, slot, "release"} => {:ok, @phase_ok}
    }
  end

  defp trusted_build_document(dirs, files, kind) do
    sorted_dirs = Enum.sort_by(dirs, & &1["path"])
    sorted_files = Enum.sort_by(files, & &1["path"])

    %{
      "schema" => "arbor.shell.trusted_build.inventory.v1",
      "kind" => kind,
      "directories" => sorted_dirs,
      "regular_files" => sorted_files,
      "counts" => %{
        "directories" => length(sorted_dirs),
        "regular_files" => length(sorted_files),
        "entries" => length(sorted_dirs) + length(sorted_files),
        "total_regular_bytes" => Enum.reduce(sorted_files, 0, &(&1["size"] + &2))
      }
    }
  end

  defp prefixed(path), do: "arbor_trust/" <> path
end
