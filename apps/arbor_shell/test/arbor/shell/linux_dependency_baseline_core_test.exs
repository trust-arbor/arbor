defmodule Arbor.Shell.LinuxDependencyBaselineCoreTest do
  @moduledoc """
  Focused pure unit tests for Linux dependency-baseline manifest/tree core.

  Slice 2B2A only: validates closed manifest + inventory as data. Does not wire
  facade, materializer, or production spawn backend.
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell.LinuxDependencyBaselineCore

  @moduletag :fast

  @domain "arbor-linux-dependency-baseline-v1\0"
  @index_hex String.duplicate("a", 64)
  @manifest_hex String.duplicate("b", 64)
  @mix_lock_hex String.duplicate("c", 64)
  @content_hex String.duplicate("1", 64)
  @other_content_hex String.duplicate("2", 64)
  @other_hex String.duplicate("e", 64)

  @index_digest "sha256:#{@index_hex}"
  @manifest_digest "sha256:#{@manifest_hex}"

  @erlang_version "28.4.1"
  @elixir_version "1.19.5-otp-28"

  @invalid_utf8 <<0xC3, 0x28>>

  # --- Helpers ---

  defp dir(path), do: %{path: path, type: "directory"}

  defp file(path, opts \\ []) do
    %{
      path: path,
      type: "regular",
      size: Keyword.get(opts, :size, 10),
      sha256: Keyword.get(opts, :sha256, @content_hex),
      executable: Keyword.get(opts, :executable, false)
    }
  end

  defp frame_entry(%{type: "directory", path: path}) do
    <<0, byte_size(path)::unsigned-32, path::binary>>
  end

  defp frame_entry(%{
         type: "regular",
         path: path,
         size: size,
         sha256: sha256_hex,
         executable: executable
       }) do
    flag = if executable, do: 1, else: 0
    raw = Base.decode16!(sha256_hex, case: :lower)

    <<1, byte_size(path)::unsigned-32, path::binary, flag::unsigned-8, size::unsigned-64,
      raw::binary-size(32)>>
  end

  defp tree_digest(entries) do
    sorted = Enum.sort_by(entries, & &1.path)

    binary =
      Enum.reduce(sorted, @domain, fn entry, acc ->
        acc <> frame_entry(entry)
      end)

    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end

  defp total_bytes(entries) do
    entries
    |> Enum.filter(&(&1.type == "regular"))
    |> Enum.reduce(0, fn e, acc -> acc + e.size end)
  end

  # Nested parents required for hex_core/priv/native.so
  defp fixture_entries do
    [
      dir("hex"),
      dir("hex_core"),
      dir("hex_core/priv"),
      file("hex/mix.exs", size: 42, sha256: @content_hex, executable: false),
      file("hex_core/priv/native.so", size: 100, sha256: @other_content_hex, executable: true)
    ]
  end

  defp build_input(entries, overrides \\ %{}) do
    digest = tree_digest(entries)

    manifest =
      Map.merge(
        %{
          schema: "1",
          platform: "linux/arm64",
          image_index_digest: @index_digest,
          image_manifest_digest: @manifest_digest,
          mix_lock_digest: @mix_lock_hex,
          baseline_tree_digest: digest,
          toolchain: %{
            erlang: @erlang_version,
            elixir: @elixir_version
          },
          entry_count: length(entries),
          total_bytes: total_bytes(entries)
        },
        overrides
      )

    %{manifest: manifest, entries: entries}
  end

  defp put_manifest(input, key, value) do
    put_in(input, [:manifest, key], value)
  end

  # --- Limits projection for imperative shells ---

  describe "limits/0" do
    test "exposes the fixed v1 inventory bounds without changing semantics" do
      assert LinuxDependencyBaselineCore.limits() == %{
               max_entries: 50_000,
               max_total_bytes: 512 * 1024 * 1024,
               max_path_bytes: 4_096,
               max_component_bytes: 255,
               max_path_depth: 48
             }
    end

    test "limits match the existing too_many_entries and total_bytes_exceeded bounds" do
      limits = LinuxDependencyBaselineCore.limits()

      entries =
        for i <- 1..(limits.max_entries + 1) do
          dir("e#{i}")
        end

      assert {:error, :too_many_entries} =
               LinuxDependencyBaselineCore.new(%{
                 manifest:
                   Map.merge(build_input([dir("x")]).manifest, %{
                     entry_count: limits.max_entries + 1,
                     total_bytes: 0,
                     baseline_tree_digest: @other_hex
                   }),
                 entries: entries
               })

      entries = [
        dir("pkg"),
        file("pkg/big", size: limits.max_total_bytes, sha256: @content_hex),
        file("pkg/extra", size: 1, sha256: @other_content_hex)
      ]

      assert {:error, :total_bytes_exceeded} =
               LinuxDependencyBaselineCore.new(%{
                 manifest:
                   Map.merge(build_input([dir("x")]).manifest, %{
                     entry_count: 3,
                     total_bytes: limits.max_total_bytes + 1,
                     baseline_tree_digest: @other_hex
                   }),
                 entries: entries
               })
    end
  end

  # --- Positive path ---

  describe "positive validation" do
    test "accepts a complete v1 manifest and inventory" do
      input = build_input(fixture_entries())
      assert {:ok, state} = LinuxDependencyBaselineCore.new(input)

      assert state.schema == "1"
      assert state.platform == "linux/arm64"
      assert state.image_index_digest == @index_digest
      assert state.image_manifest_digest == @manifest_digest
      assert state.mix_lock_digest == @mix_lock_hex
      assert state.baseline_tree_digest == tree_digest(fixture_entries())
      assert state.toolchain == %{erlang: @erlang_version, elixir: @elixir_version}
      assert state.entry_count == 5
      assert state.total_bytes == 142

      sorted = LinuxDependencyBaselineCore.materialization_entries(state)

      assert Enum.map(sorted, & &1.path) == [
               "hex",
               "hex/mix.exs",
               "hex_core",
               "hex_core/priv",
               "hex_core/priv/native.so"
             ]
    end

    test "known-answer v1 tree digest for pkg + pkg/a" do
      # Fixed KA independent of the local tree_digest/1 helper.
      # directory "pkg"; regular "pkg/a" size 3; sha256 = 64×'1'; executable false
      known_digest = "1d76d74bf0c8da43719360aed0b9de933169a3b5f0a2b0436a6e9d057bc22afc"
      ones = String.duplicate("1", 64)

      entries = [
        %{path: "pkg", type: "directory"},
        %{
          path: "pkg/a",
          type: "regular",
          size: 3,
          sha256: ones,
          executable: false
        }
      ]

      input = %{
        manifest: %{
          schema: "1",
          platform: "linux/arm64",
          image_index_digest: @index_digest,
          image_manifest_digest: @manifest_digest,
          mix_lock_digest: @mix_lock_hex,
          baseline_tree_digest: known_digest,
          toolchain: %{
            erlang: @erlang_version,
            elixir: @elixir_version
          },
          entry_count: 2,
          total_bytes: 3
        },
        entries: entries
      }

      assert {:ok, state} = LinuxDependencyBaselineCore.new(input)
      assert state.baseline_tree_digest == known_digest

      refute match?(
               {:ok, _},
               LinuxDependencyBaselineCore.new(
                 put_in(input, [:manifest, :baseline_tree_digest], String.duplicate("0", 64))
               )
             )
    end

    test "tree digest is deterministic and independent of input entry order" do
      entries = fixture_entries()
      forward = build_input(entries)
      reverse = build_input(Enum.reverse(entries))
      shuffled = build_input(Enum.shuffle(entries))

      assert {:ok, a} = LinuxDependencyBaselineCore.new(forward)
      assert {:ok, b} = LinuxDependencyBaselineCore.new(reverse)
      assert {:ok, c} = LinuxDependencyBaselineCore.new(shuffled)

      assert a.baseline_tree_digest == b.baseline_tree_digest
      assert b.baseline_tree_digest == c.baseline_tree_digest
      assert a.entries == b.entries
      assert b.entries == c.entries
    end

    test "show/1 emits compact JSON-clean attestation without inventory" do
      assert {:ok, state} = LinuxDependencyBaselineCore.new(build_input(fixture_entries()))
      shown = LinuxDependencyBaselineCore.show(state)

      assert shown == %{
               "schema" => "1",
               "platform" => "linux/arm64",
               "image_index_digest" => @index_digest,
               "image_manifest_digest" => @manifest_digest,
               "mix_lock_digest" => @mix_lock_hex,
               "baseline_tree_digest" => state.baseline_tree_digest,
               "toolchain" => %{
                 "erlang" => @erlang_version,
                 "elixir" => @elixir_version
               },
               "entry_count" => 5,
               "total_bytes" => 142
             }

      refute Map.has_key?(shown, "entries")
      refute Map.has_key?(shown, :entries)
      assert Jason.encode!(shown)
    end

    test "accepts string-keyed request, manifest, toolchain, and entries" do
      entries = [
        %{"path" => "pkg", "type" => "directory"},
        %{
          "path" => "pkg/file.ex",
          "type" => "regular",
          "size" => 3,
          "sha256" => @content_hex,
          "executable" => false
        }
      ]

      digest = tree_digest([dir("pkg"), file("pkg/file.ex", size: 3)])

      input = %{
        "manifest" => %{
          "schema" => "1",
          "platform" => "linux/arm64",
          "image_index_digest" => @index_digest,
          "image_manifest_digest" => @manifest_digest,
          "mix_lock_digest" => @mix_lock_hex,
          "baseline_tree_digest" => digest,
          "toolchain" => %{
            "erlang" => @erlang_version,
            "elixir" => @elixir_version
          },
          "entry_count" => 2,
          "total_bytes" => 3
        },
        "entries" => entries
      }

      assert {:ok, state} = LinuxDependencyBaselineCore.new(input)
      assert state.entry_count == 2
      assert state.total_bytes == 3
    end

    test "directory-only inventory is valid with total_bytes 0" do
      entries = [dir("only_dir")]
      assert {:ok, state} = LinuxDependencyBaselineCore.new(build_input(entries))
      assert state.total_bytes == 0
      assert state.entry_count == 1
    end
  end

  # --- Closed maps / aliases ---

  describe "closed maps and duplicate aliases" do
    test "rejects non-map request" do
      assert {:error, :invalid_request} = LinuxDependencyBaselineCore.new("nope")
      assert {:error, :invalid_request} = LinuxDependencyBaselineCore.new([])
    end

    test "rejects unknown request keys" do
      input = Map.put(build_input(fixture_entries()), :extra, true)
      assert {:error, {:unsupported_keys, :request}} = LinuxDependencyBaselineCore.new(input)
    end

    test "rejects duplicate request key aliases" do
      base = build_input(fixture_entries())
      input = Map.put(base, "manifest", base.manifest)

      assert {:error, {:duplicate_key_alias, :request, :manifest}} =
               LinuxDependencyBaselineCore.new(input)
    end

    test "rejects missing manifest and entries" do
      assert {:error, :missing_manifest} =
               LinuxDependencyBaselineCore.new(%{entries: fixture_entries()})

      assert {:error, :missing_entries} =
               LinuxDependencyBaselineCore.new(%{
                 manifest: build_input(fixture_entries()).manifest
               })
    end

    test "rejects invalid manifest and entries types" do
      assert {:error, :invalid_manifest} =
               LinuxDependencyBaselineCore.new(%{manifest: "x", entries: []})

      assert {:error, :invalid_entries} =
               LinuxDependencyBaselineCore.new(%{
                 manifest: build_input(fixture_entries()).manifest,
                 entries: %{}
               })
    end

    test "rejects unknown and duplicate manifest keys" do
      input = build_input(fixture_entries())
      bad = put_in(input, [:manifest, :extra], 1)
      assert {:error, {:unsupported_keys, :manifest}} = LinuxDependencyBaselineCore.new(bad)

      with_dup =
        put_in(input, [:manifest], Map.put(input.manifest, "schema", "1"))

      assert {:error, {:duplicate_key_alias, :manifest, :schema}} =
               LinuxDependencyBaselineCore.new(with_dup)
    end

    test "rejects unknown and duplicate toolchain keys" do
      input = build_input(fixture_entries())

      bad =
        put_in(input, [:manifest, :toolchain], Map.put(input.manifest.toolchain, :extra, "x"))

      assert {:error, {:unsupported_keys, :toolchain}} = LinuxDependencyBaselineCore.new(bad)

      dup =
        put_in(
          input,
          [:manifest, :toolchain],
          Map.put(input.manifest.toolchain, "erlang", @erlang_version)
        )

      assert {:error, {:duplicate_key_alias, :toolchain, :erlang}} =
               LinuxDependencyBaselineCore.new(dup)
    end

    test "rejects unknown and duplicate directory entry keys" do
      entries = [Map.put(dir("pkg"), :extra, 1)]
      # Digest would not matter; closed-map fails first.
      input = build_input([dir("pkg")])
      input = %{input | entries: entries}

      assert {:error, {:unsupported_keys, :directory_entry}} =
               LinuxDependencyBaselineCore.new(input)

      entries = [Map.merge(dir("pkg"), %{"path" => "pkg"})]
      input = %{build_input([dir("pkg")]) | entries: entries}

      assert {:error, {:duplicate_key_alias, :directory_entry, :path}} =
               LinuxDependencyBaselineCore.new(input)
    end

    test "rejects unknown and duplicate regular entry keys" do
      entries = [
        dir("pkg"),
        Map.put(file("pkg/a"), :extra, true)
      ]

      input = %{build_input([dir("pkg"), file("pkg/a")]) | entries: entries}

      assert {:error, {:unsupported_keys, :regular_entry}} =
               LinuxDependencyBaselineCore.new(input)

      entries = [
        dir("pkg"),
        Map.merge(file("pkg/a"), %{"executable" => false})
      ]

      input = %{build_input([dir("pkg"), file("pkg/a")]) | entries: entries}

      assert {:error, {:duplicate_key_alias, :regular_entry, :executable}} =
               LinuxDependencyBaselineCore.new(input)
    end
  end

  # --- Manifest field validation ---

  describe "manifest field validation" do
    test "rejects unsupported schema and platform" do
      assert {:error, :unsupported_schema} =
               LinuxDependencyBaselineCore.new(
                 put_manifest(build_input(fixture_entries()), :schema, "2")
               )

      assert {:error, :unsupported_platform} =
               LinuxDependencyBaselineCore.new(
                 put_manifest(build_input(fixture_entries()), :platform, "linux/amd64")
               )
    end

    test "rejects missing and malformed digests" do
      base = build_input(fixture_entries())

      assert {:error, :missing_image_index_digest} =
               LinuxDependencyBaselineCore.new(
                 put_in(base, [:manifest], Map.delete(base.manifest, :image_index_digest))
               )

      assert {:error, :invalid_image_index_digest} =
               LinuxDependencyBaselineCore.new(
                 put_manifest(base, :image_index_digest, "SHA256:" <> @index_hex)
               )

      assert {:error, :invalid_image_manifest_digest} =
               LinuxDependencyBaselineCore.new(
                 put_manifest(
                   base,
                   :image_manifest_digest,
                   "sha256:" <> String.duplicate("G", 64)
                 )
               )

      assert {:error, {:invalid, :mix_lock_digest}} =
               LinuxDependencyBaselineCore.new(
                 put_manifest(base, :mix_lock_digest, "sha256:" <> @mix_lock_hex)
               )

      assert {:error, {:invalid, :baseline_tree_digest}} =
               LinuxDependencyBaselineCore.new(
                 put_manifest(base, :baseline_tree_digest, String.upcase(@other_hex))
               )
    end

    test "rejects malformed toolchain versions" do
      base = build_input(fixture_entries())

      assert {:error, :invalid_toolchain_erlang} =
               LinuxDependencyBaselineCore.new(
                 put_manifest(base, :toolchain, %{
                   erlang: "bad@version",
                   elixir: @elixir_version
                 })
               )

      assert {:error, :invalid_toolchain_elixir} =
               LinuxDependencyBaselineCore.new(
                 put_manifest(base, :toolchain, %{
                   erlang: @erlang_version,
                   elixir: ""
                 })
               )

      assert {:error, :unsafe_toolchain_erlang} =
               LinuxDependencyBaselineCore.new(
                 put_manifest(base, :toolchain, %{
                   erlang: "28\n4",
                   elixir: @elixir_version
                 })
               )
    end

    test "rejects entry_count and total_bytes mismatches and bad types" do
      base = build_input(fixture_entries())

      assert {:error, :entry_count_mismatch} =
               LinuxDependencyBaselineCore.new(put_manifest(base, :entry_count, 1))

      assert {:error, :total_bytes_mismatch} =
               LinuxDependencyBaselineCore.new(put_manifest(base, :total_bytes, 0))

      assert {:error, {:invalid, :entry_count}} =
               LinuxDependencyBaselineCore.new(put_manifest(base, :entry_count, "5"))

      assert {:error, {:negative, :total_bytes}} =
               LinuxDependencyBaselineCore.new(put_manifest(base, :total_bytes, -1))
    end

    test "rejects baseline_tree_digest mismatch against inventory" do
      assert {:error, :baseline_tree_digest_mismatch} =
               LinuxDependencyBaselineCore.new(
                 put_manifest(build_input(fixture_entries()), :baseline_tree_digest, @other_hex)
               )
    end
  end

  # --- Path validation ---

  describe "path validation" do
    test "rejects absolute paths" do
      entries = [dir("/abs")]
      input = build_input([dir("x")])

      input = %{
        input
        | entries: entries,
          manifest: %{
            input.manifest
            | entry_count: 1,
              total_bytes: 0,
              baseline_tree_digest: tree_digest(entries)
          }
      }

      # validate_path fails before digest; still build valid counts
      assert {:error, :absolute_path} = LinuxDependencyBaselineCore.new(input)
    end

    test "rejects empty path, empty segments, trailing slash" do
      assert {:error, :empty_path} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("x")])
                 | entries: [dir("")]
               })

      assert {:error, :empty_path_segment} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("x")])
                 | entries: [dir("a//b")]
               })

      assert {:error, :trailing_slash} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("x")])
                 | entries: [dir("pkg/")]
               })
    end

    test "rejects dot and dotdot segments" do
      assert {:error, :dot_path_segment} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("x")])
                 | entries: [dir(".")]
               })

      assert {:error, :dotdot_path_segment} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("x")])
                 | entries: [dir("a/../b")]
               })

      assert {:error, :dot_path_segment} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("x")])
                 | entries: [dir("a/./b")]
               })
    end

    test "rejects NUL and control characters in paths" do
      assert {:error, :unsafe_path} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("x")])
                 | entries: [dir("a\0b")]
               })

      assert {:error, :unsafe_path} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("x")])
                 | entries: [dir("a\nb")]
               })
    end

    test "rejects overlong component, path, and depth" do
      long_component = String.duplicate("c", 256)

      assert {:error, :path_component_too_long} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("x")])
                 | entries: [dir(long_component)]
               })

      long_path =
        1..21
        |> Enum.map(fn i -> String.duplicate("p", 200) <> Integer.to_string(i) end)
        |> Enum.join("/")

      assert byte_size(long_path) > 4096

      assert {:error, :path_too_long} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("x")])
                 | entries: [dir(long_path)]
               })

      deep =
        1..49
        |> Enum.map(&Integer.to_string/1)
        |> Enum.join("/")

      # Need all parents — but depth check should fire during path validation.
      assert {:error, :path_depth_exceeded} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("x")])
                 | entries: [dir(deep)]
               })
    end

    test "rejects invalid UTF-8 paths" do
      assert {:error, :invalid_utf8} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("x")])
                 | entries: [%{path: @invalid_utf8, type: "directory"}]
               })
    end
  end

  # --- Entry types and tree structure ---

  describe "entry types and tree structure" do
    test "rejects symlink and other special entry types" do
      for type <- ["symlink", "fifo", "socket", "block", "character", "hardlink"] do
        entries = [%{path: "x", type: type}]

        assert {:error, {:unsupported_entry_type, ^type}} =
                 LinuxDependencyBaselineCore.new(%{
                   build_input([dir("x")])
                   | entries: entries
                 })
      end
    end

    test "rejects missing parent directories" do
      entries = [file("pkg/file.ex", size: 1)]

      assert {:error, :missing_parent_directory} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("pkg"), file("pkg/file.ex", size: 1)])
                 | entries: entries,
                   manifest:
                     Map.merge(
                       build_input([dir("pkg"), file("pkg/file.ex", size: 1)]).manifest,
                       %{
                         entry_count: 1,
                         total_bytes: 1,
                         baseline_tree_digest: tree_digest(entries)
                       }
                     )
               })
    end

    test "rejects parent that is a regular file (file/descendant conflict)" do
      # Linear sorted pass fails closed when the child reveals a non-directory parent.
      entries = [
        file("pkg", size: 1),
        file("pkg/nested", size: 1)
      ]

      assert {:error, :parent_not_directory} =
               LinuxDependencyBaselineCore.new(%{
                 build_input(entries)
                 | entries: entries,
                   manifest:
                     Map.merge(build_input([dir("x")]).manifest, %{
                       entry_count: 2,
                       total_bytes: 2,
                       baseline_tree_digest: tree_digest(entries)
                     })
               })
    end

    test "rejects duplicate paths" do
      entries = [dir("pkg"), dir("pkg")]

      assert {:error, :duplicate_path} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("pkg")])
                 | entries: entries,
                   manifest:
                     Map.merge(build_input([dir("pkg")]).manifest, %{
                       entry_count: 2,
                       total_bytes: 0,
                       baseline_tree_digest: tree_digest(entries)
                     })
               })
    end

    test "rejects file/descendant conflicts via non-directory parent" do
      entries = [
        dir("root"),
        file("root/leaf", size: 1),
        dir("root/leaf/child")
      ]

      assert {:error, :parent_not_directory} =
               LinuxDependencyBaselineCore.new(%{
                 build_input([dir("root")])
                 | entries: entries,
                   manifest:
                     Map.merge(build_input([dir("root")]).manifest, %{
                       entry_count: 3,
                       total_bytes: 1,
                       baseline_tree_digest: tree_digest(entries)
                     })
               })
    end

    test "rejects malformed regular entry fields" do
      base_entries = [dir("pkg"), file("pkg/a", size: 1)]

      assert {:error, :negative_entry_size} =
               LinuxDependencyBaselineCore.new(%{
                 build_input(base_entries)
                 | entries: [dir("pkg"), Map.put(file("pkg/a"), :size, -1)]
               })

      assert {:error, :invalid_entry_executable} =
               LinuxDependencyBaselineCore.new(%{
                 build_input(base_entries)
                 | entries: [dir("pkg"), Map.put(file("pkg/a"), :executable, "false")]
               })

      assert {:error, {:invalid, :sha256}} =
               LinuxDependencyBaselineCore.new(%{
                 build_input(base_entries)
                 | entries: [dir("pkg"), Map.put(file("pkg/a"), :sha256, "not-hex")]
               })

      assert {:error, :missing_entry_type} =
               LinuxDependencyBaselineCore.new(%{
                 build_input(base_entries)
                 | entries: [%{path: "pkg"}]
               })
    end
  end

  # --- Bounds ---

  describe "inventory bounds" do
    test "rejects empty inventory" do
      assert {:error, :empty_inventory} =
               LinuxDependencyBaselineCore.new(%{
                 manifest:
                   Map.merge(build_input([dir("x")]).manifest, %{
                     entry_count: 0,
                     total_bytes: 0,
                     baseline_tree_digest: tree_digest([])
                   }),
                 entries: []
               })
    end

    test "rejects more than 50_000 entries before full acceptance" do
      # Fail-closed without materializing an enormous validated inventory:
      # exceed the bound with a stream of closed directory entries.
      entries =
        for i <- 1..50_001 do
          dir("e#{i}")
        end

      assert {:error, :too_many_entries} =
               LinuxDependencyBaselineCore.new(%{
                 manifest:
                   Map.merge(build_input([dir("x")]).manifest, %{
                     entry_count: 50_001,
                     total_bytes: 0,
                     baseline_tree_digest: @other_hex
                   }),
                 entries: entries
               })
    end

    test "rejects aggregate regular-file bytes over 512 MiB" do
      max = 512 * 1024 * 1024

      entries = [
        dir("pkg"),
        file("pkg/big", size: max, sha256: @content_hex),
        file("pkg/extra", size: 1, sha256: @other_content_hex)
      ]

      assert {:error, :total_bytes_exceeded} =
               LinuxDependencyBaselineCore.new(%{
                 manifest:
                   Map.merge(build_input([dir("x")]).manifest, %{
                     entry_count: 3,
                     total_bytes: max + 1,
                     baseline_tree_digest: @other_hex
                   }),
                 entries: entries
               })
    end
  end

  # --- Digest sensitivity ---

  describe "digest sensitivity" do
    test "executable bit changes the tree digest" do
      a = [dir("pkg"), file("pkg/bin", size: 1, executable: false)]
      b = [dir("pkg"), file("pkg/bin", size: 1, executable: true)]

      da = tree_digest(a)
      db = tree_digest(b)
      assert da != db

      assert {:ok, state_a} = LinuxDependencyBaselineCore.new(build_input(a))
      assert {:ok, state_b} = LinuxDependencyBaselineCore.new(build_input(b))
      assert state_a.baseline_tree_digest == da
      assert state_b.baseline_tree_digest == db
      assert state_a.baseline_tree_digest != state_b.baseline_tree_digest
    end

    test "content hash changes the tree digest" do
      a = [dir("pkg"), file("pkg/f", size: 1, sha256: @content_hex)]
      b = [dir("pkg"), file("pkg/f", size: 1, sha256: @other_content_hex)]

      assert tree_digest(a) != tree_digest(b)

      assert {:ok, sa} = LinuxDependencyBaselineCore.new(build_input(a))
      assert {:ok, sb} = LinuxDependencyBaselineCore.new(build_input(b))
      assert sa.baseline_tree_digest != sb.baseline_tree_digest
    end

    test "path set changes the tree digest" do
      a = [dir("pkg"), file("pkg/a", size: 1)]
      b = [dir("pkg"), file("pkg/b", size: 1)]
      assert tree_digest(a) != tree_digest(b)
    end
  end
end
