defmodule Arbor.Commands.SafeRecoveryArtifactFixture do
  @moduledoc false

  import Bitwise

  @profile %{
    "schema" => "arbor.packaging.safe_recovery_profile.intent.v1",
    "name" => "safe_recovery",
    "digest" => "4a377b057ac0ea05c5d97f19b07c6e4b421adbba66797efdc381066ec479dd94",
    "evidence_status" => "conformant",
    "architecture_status" => "blocked"
  }

  @platform_inventory %{
    "platform_inventory_schema" => "arbor.packaging.platform_inventory.v1",
    "selected_file_count" => 318,
    "selected_index_digest" => "1c55e299738edbbea68359f91332ad2420df679a0b7e8040b6ef53cbf8ed21a2",
    "entries_digest" => "75cd2f9aa708c68aa3c5981ce00c82a339ca40d3a351caf5a05a18f081943cb0",
    "review_digest" => "dd307c2ab8365077471a9c2e4a62b79bb5869b0ff5b732ba30390b89e0394172"
  }

  @tool_versions_sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @mix_lock_sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  def profile, do: @profile
  def platform_inventory, do: @platform_inventory

  def hydrate_fixture(document) do
    files =
      Enum.map(document["files"], fn file ->
        bytes = file_bytes(file)
        {file["path"], bytes, Map.get(file, "mode", 0o644)}
      end)

    dirs = Enum.map(document["directories"], &%{"path" => &1, "mode" => 0o755})
    regular = Enum.map(files, fn {path, bytes, mode} -> regular_file(path, bytes, mode) end)

    snapshot = %{
      "inventory" => inventory(dirs, regular),
      "term_contents" => term_contents(files)
    }

    %{
      "profile" => document["profile"],
      "source" => document["source"],
      "toolchain" => document["toolchain"],
      "release" => document["release"],
      "builds" => [snapshot, snapshot]
    }
  end

  def load_checked_in_fixture do
    __DIR__
    |> Path.join("../arbor/commands/safe_recovery_artifact/fixtures/two_build_candidate.json")
    |> Path.expand()
    |> File.read!()
    |> Jason.decode!()
    |> hydrate_fixture()
  end

  defp file_bytes(%{"bytes" => bytes}), do: bytes

  defp file_bytes(%{"bytes_hex" => hex}) do
    {:ok, bytes} = Base.decode16(hex, case: :lower)
    bytes
  end

  def candidate(opts \\ []) do
    snapshot = Keyword.get(opts, :snapshot, golden_snapshot())
    second = Keyword.get(opts, :second, snapshot)

    %{
      "profile" => Keyword.get(opts, :profile, @profile),
      "source" => Keyword.get(opts, :source, source()),
      "toolchain" => Keyword.get(opts, :toolchain, toolchain()),
      "release" => Keyword.get(opts, :release, release_id()),
      "builds" => [snapshot, second]
    }
  end

  def source do
    %{
      "commit" => "0123456789abcdef0123456789abcdef01234567",
      "tree" => "89abcdef0123456789abcdef0123456789abcdef",
      "object_format" => "sha1",
      "platform_inventory" => @platform_inventory,
      "build_inputs" => [
        %{"path" => ".tool-versions", "sha256" => @tool_versions_sha256},
        %{"path" => "mix.lock", "sha256" => @mix_lock_sha256}
      ]
    }
  end

  def toolchain do
    %{
      "target" => "aarch64-apple-darwin",
      "erlang" => "28.4.1",
      "erts" => "16.3",
      "elixir" => "1.19.5",
      "mix" => "1.19.5",
      "environment" => "prod",
      "tool_versions_sha256" => @tool_versions_sha256,
      "mix_lock_sha256" => @mix_lock_sha256
    }
  end

  def release_id do
    %{"name" => "arbor_trust", "version" => "0.1.0", "logical_root" => "rel/arbor_trust"}
  end

  def golden_snapshot do
    bodies = golden_bodies()
    files = Enum.map(bodies, fn {path, bytes, mode} -> regular_file(path, bytes, mode) end)
    dirs = golden_directories()

    %{
      "inventory" => inventory(dirs, files),
      "term_contents" => term_contents(bodies)
    }
  end

  def golden_bodies do
    beam = beam_bytes()
    exec = "ERLEXEC-NOT-NATIVE"

    [
      {"bin/erlexec", exec, 0o755},
      {"lib/arbor_kernel-0.1.0/ebin/arbor_kernel.app", app_body("arbor_kernel"), 0o644},
      {"lib/arbor_kernel_runtime-0.1.0/ebin/arbor_kernel_runtime.app",
       app_body("arbor_kernel_runtime"), 0o644},
      {"lib/arbor_security-0.1.0/ebin/arbor_security.app", app_body("arbor_security"), 0o644},
      {"lib/arbor_trust-0.1.0/ebin/Elixir.Arbor.Trust.beam", beam, 0o644},
      {"lib/arbor_trust-0.1.0/ebin/arbor_trust.app", app_body("arbor_trust"), 0o644},
      {"lib/jason-1.0.0/ebin/jason.app", app_body("jason", "1.0.0"), 0o644},
      {"lib/kernel-1.0.0/ebin/kernel.app", kernel_app_body(), 0o644},
      {"releases/0.1.0/arbor_trust.rel", rel_body(), 0o644}
    ]
  end

  def app_body(name, version \\ "0.1.0") do
    "{application,#{name},[{description,\"#{name}\"},{vsn,\"#{version}\"}," <>
      "{modules,[]},{registered,[]},{applications,[kernel]},{mod,{'Elixir.App',[]}},{env,[]}]}."
  end

  def kernel_app_body do
    "{application,kernel,[{description,\"kernel\"},{vsn,\"1.0.0\"}," <>
      "{modules,[]},{registered,[]},{applications,[]},{env,[]}]}."
  end

  def rel_body do
    "{release,<<\"arbor_trust\">>,<<\"0.1.0\">>,<<\"16.3\">>," <>
      "[{arbor_kernel,<<\"0.1.0\">>},{arbor_kernel_runtime,<<\"0.1.0\">>}," <>
      "{arbor_security,<<\"0.1.0\">>},{arbor_trust,<<\"0.1.0\">>}," <>
      "{jason,<<\"1.0.0\">>},{kernel,<<\"1.0.0\">>}]}."
  end

  def beam_bytes do
    <<"FOR1", 4::unsigned-big-32, "BEAM">>
  end

  def regular_file(path, bytes, mode) do
    executable = (mode &&& 0o111) != 0

    %{
      "path" => path,
      "mode" => mode,
      "executable" => executable,
      "size" => byte_size(bytes),
      "sha256" => sha256_hex(bytes),
      "prefix_hex" => prefix_hex(bytes)
    }
  end

  def inventory(dirs, files) do
    %{
      "schema" => "arbor.shell.regular_tree_inventory.v1",
      "directories" => Enum.sort_by(dirs, & &1["path"]),
      "regular_files" => Enum.sort_by(files, & &1["path"]),
      "counts" => %{
        "directories" => length(dirs),
        "regular_files" => length(files),
        "entries" => length(dirs) + length(files),
        "total_regular_bytes" => Enum.reduce(files, 0, fn file, acc -> acc + file["size"] end)
      }
    }
  end

  def golden_directories do
    [
      "bin",
      "lib",
      "lib/arbor_kernel-0.1.0",
      "lib/arbor_kernel-0.1.0/ebin",
      "lib/arbor_kernel_runtime-0.1.0",
      "lib/arbor_kernel_runtime-0.1.0/ebin",
      "lib/arbor_security-0.1.0",
      "lib/arbor_security-0.1.0/ebin",
      "lib/arbor_trust-0.1.0",
      "lib/arbor_trust-0.1.0/ebin",
      "lib/jason-1.0.0",
      "lib/jason-1.0.0/ebin",
      "lib/kernel-1.0.0",
      "lib/kernel-1.0.0/ebin",
      "releases",
      "releases/0.1.0"
    ]
    |> Enum.map(&%{"path" => &1, "mode" => 0o755})
  end

  def term_contents(bodies) do
    bodies
    |> Enum.filter(fn {path, _bytes, _mode} ->
      String.ends_with?(path, ".app") or String.ends_with?(path, ".rel")
    end)
    |> Enum.map(fn {path, bytes, _mode} -> %{"path" => path, "bytes" => bytes} end)
    |> Enum.sort_by(& &1["path"])
  end

  def sha256_hex(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  def prefix_hex(bytes) do
    take = min(byte_size(bytes), 256)
    bytes |> binary_part(0, take) |> Base.encode16(case: :lower)
  end

  def thin_arm64 do
    # MH_MAGIC_64 LE + ARM64 cputype LE + remaining header zeros.
    <<0xFEEDFACF::unsigned-little-32, 0x0100000C::unsigned-little-32,
      0::unsigned-little-32, 0::unsigned-little-32, 0::unsigned-little-32,
      0::unsigned-little-32, 0::unsigned-little-32, 0::unsigned-little-32>>
  end

  def thin_x86_64 do
    <<0xFEEDFACF::unsigned-little-32, 0x01000007::unsigned-little-32,
      0::unsigned-little-32, 0::unsigned-little-32, 0::unsigned-little-32,
      0::unsigned-little-32, 0::unsigned-little-32, 0::unsigned-little-32>>
  end

  def fat32_arm64 do
    header = <<0xCAFEBABE::unsigned-big-32, 1::unsigned-big-32>>
    offset = 28
    size = 32
    align = 2

    arch =
      <<0x0100000C::unsigned-big-32, 0::unsigned-big-32, offset::unsigned-big-32,
        size::unsigned-big-32, align::unsigned-big-32>>

    pad = :binary.copy(<<0>>, offset - byte_size(header) - byte_size(arch))
    slice = :binary.copy(<<0>>, size)
    header <> arch <> pad <> slice
  end

  def replace_file(snapshot, path, bytes, mode) do
    inventory = snapshot["inventory"]
    files = Enum.reject(inventory["regular_files"], &(&1["path"] == path))
    files = [regular_file(path, bytes, mode) | files]
    contents = Enum.reject(snapshot["term_contents"], &(&1["path"] == path))

    contents =
      if String.ends_with?(path, ".app") or String.ends_with?(path, ".rel") do
        [%{"path" => path, "bytes" => bytes} | contents]
      else
        contents
      end

    %{
      "inventory" => inventory(inventory["directories"], files),
      "term_contents" => Enum.sort_by(contents, & &1["path"])
    }
  end

  def add_file(snapshot, path, bytes, mode) do
    inventory = snapshot["inventory"]
    files = [regular_file(path, bytes, mode) | inventory["regular_files"]]

    %{
      snapshot
      | "inventory" => inventory(inventory["directories"], files)
    }
  end
end
