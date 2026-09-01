defmodule Arbor.Contracts.Coding.CandidateMaterializationTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.CandidateMaterialization

  @moduletag :fast

  @oid40_a String.duplicate("a", 40)
  @oid40_b String.duplicate("b", 40)
  @oid40_c String.duplicate("c", 40)
  @oid64_a String.duplicate("a", 64)
  @oid64_b String.duplicate("b", 64)
  @oid64_c String.duplicate("c", 64)

  @canonical_bytes ~s({"source_commit_oid":"#{@oid40_a}","expected_tree_oid":"#{@oid40_b}","entries":[{"path":"mix.exs","blob_oid":"#{@oid40_c}","mode":100644}]})
  @canonical_digest "sha256:" <>
                      Base.encode16(:crypto.hash(:sha256, @canonical_bytes), case: :lower)

  defp valid_attrs(overrides \\ %{}) do
    %{
      "source_commit_oid" => @oid40_a,
      "expected_tree_oid" => @oid40_b,
      "entries" => [
        %{"path" => "mix.exs", "blob_oid" => @oid40_c, "mode" => 100_644}
      ]
    }
    |> Map.merge(overrides)
  end

  defp valid_entry(path, overrides \\ %{}) do
    %{
      "path" => path,
      "blob_oid" => @oid40_c,
      "mode" => 100_644
    }
    |> Map.merge(overrides)
  end

  defp nest_maps(1), do: %{}
  defp nest_maps(n) when n > 1, do: %{"k" => nest_maps(n - 1)}

  defp segment_path(count), do: Enum.join(List.duplicate("s", count), "/")

  test "exposes frozen bounds and admitted modes" do
    assert CandidateMaterialization.max_entries() == 2048
    assert CandidateMaterialization.max_path_bytes() == 1024
    assert CandidateMaterialization.max_path_depth() == 48
    assert CandidateMaterialization.max_component_bytes() == 255
    assert CandidateMaterialization.max_encoded_bytes() == 1_048_576
    assert CandidateMaterialization.max_recovery_nodes() == 65_536
    assert CandidateMaterialization.max_record_bytes() == 4_194_304
    assert CandidateMaterialization.max_inventory_bytes() == 8_388_608
    assert CandidateMaterialization.max_structural_depth() == 8
    assert CandidateMaterialization.allowed_modes() == [100_644, 100_755]
  end

  test "constructs a canonical descriptor and round-trips encode, digest, and JSON" do
    atom_attrs = [
      source_commit_oid: @oid40_a,
      expected_tree_oid: @oid40_b,
      entries: [
        [path: "mix.exs", blob_oid: @oid40_c, mode: 100_644]
      ]
    ]

    assert {:ok, atom_descriptor} = CandidateMaterialization.new(atom_attrs)
    assert {:ok, string_descriptor} = CandidateMaterialization.new(valid_attrs())
    assert atom_descriptor == string_descriptor

    canonical = %{
      "source_commit_oid" => @oid40_a,
      "expected_tree_oid" => @oid40_b,
      "entries" => [
        %{"path" => "mix.exs", "blob_oid" => @oid40_c, "mode" => 100_644}
      ]
    }

    assert CandidateMaterialization.to_map(atom_descriptor) == canonical
    assert {:ok, ^canonical} = CandidateMaterialization.normalize(atom_attrs)
    assert CandidateMaterialization.valid?(atom_descriptor)
    assert CandidateMaterialization.valid?(valid_attrs())
    refute CandidateMaterialization.valid?(%{})
    refute CandidateMaterialization.valid?(:nope)

    assert {:ok, bytes} = CandidateMaterialization.canonical_bytes(atom_descriptor)
    assert bytes == @canonical_bytes
    assert {:ok, ^bytes} = CandidateMaterialization.canonical_bytes(valid_attrs())
    assert {:ok, decoded} = Jason.decode(bytes)
    assert {:ok, ^atom_descriptor} = CandidateMaterialization.new(decoded)
    assert {:ok, ^bytes} = CandidateMaterialization.canonical_bytes(decoded)

    assert {:ok, digest} = CandidateMaterialization.digest(atom_descriptor)
    assert digest == @canonical_digest
    assert digest =~ ~r/\Asha256:[0-9a-f]{64}\z/

    assert {:ok, ^atom_descriptor} =
             CandidateMaterialization.new(CandidateMaterialization.to_map(atom_descriptor))
  end

  test "canonical bytes do not depend on input object key order" do
    reversed = %{
      "entries" => [
        %{"mode" => 100_644, "blob_oid" => @oid40_c, "path" => "mix.exs"}
      ],
      "expected_tree_oid" => @oid40_b,
      "source_commit_oid" => @oid40_a
    }

    assert {:ok, bytes} = CandidateMaterialization.canonical_bytes(reversed)
    assert bytes == @canonical_bytes
  end

  test "accepts 64-hex OIDs of one consistent width and executable mode" do
    attrs = %{
      "source_commit_oid" => @oid64_a,
      "expected_tree_oid" => @oid64_b,
      "entries" => [
        %{"path" => "bin/run", "blob_oid" => @oid64_c, "mode" => 100_755}
      ]
    }

    assert {:ok, descriptor} = CandidateMaterialization.new(attrs)
    assert descriptor.source_commit_oid == @oid64_a
    assert hd(descriptor.entries)["mode"] == 100_755
  end

  test "derives a shallow recovery shape from unique strict ancestors and frozen facts" do
    attrs =
      valid_attrs(%{
        "entries" => [
          valid_entry("apps/foo/bar.ex"),
          valid_entry("apps/foo/baz.ex", %{"mode" => 100_755}),
          valid_entry("mix.exs")
        ]
      })

    assert {:ok, descriptor} = CandidateMaterialization.new(attrs)
    assert {:ok, shape} = CandidateMaterialization.recovery_shape(descriptor)

    assert shape == %{
             "ancestors" => ["apps", "apps/foo"],
             "records" => [
               %{
                 "path" => "apps/foo/bar.ex",
                 "blob_oid" => @oid40_c,
                 "mode" => 100_644,
                 "stage" => 0,
                 "quarantine" => false,
                 "index" => 0,
                 "phase" => "pending"
               },
               %{
                 "path" => "apps/foo/baz.ex",
                 "blob_oid" => @oid40_c,
                 "mode" => 100_755,
                 "stage" => 0,
                 "quarantine" => false,
                 "index" => 1,
                 "phase" => "pending"
               },
               %{
                 "path" => "mix.exs",
                 "blob_oid" => @oid40_c,
                 "mode" => 100_644,
                 "stage" => 0,
                 "quarantine" => false,
                 "index" => 2,
                 "phase" => "pending"
               }
             ]
           }

    assert {:ok, ^shape} = CandidateMaterialization.admit_recovery_value(shape)
  end

  test "rejects missing, unknown, duplicate-alias, and non-object input" do
    assert {:error, {:missing_field, "source_commit_oid"}} =
             CandidateMaterialization.new(%{})

    assert {:error, {:unknown_fields, ["unexpected"]}} =
             CandidateMaterialization.new(Map.put(valid_attrs(), "unexpected", 1))

    assert {:error, {:unknown_fields, ["recovery_shape"]}} =
             CandidateMaterialization.new(Map.put(valid_attrs(), "recovery_shape", %{}))

    duplicate = Map.put(valid_attrs(), :source_commit_oid, @oid40_a)

    assert {:error, {:duplicate_fields, ["source_commit_oid"]}} =
             CandidateMaterialization.new(duplicate)

    assert {:error, {:invalid_object, :object_required}} =
             CandidateMaterialization.new("not an object")

    assert {:error, {:invalid_object, :struct_not_allowed}} =
             CandidateMaterialization.new(DateTime.utc_now())

    assert {:error, {:invalid_object, :improper_list}} =
             CandidateMaterialization.new([{:source_commit_oid, @oid40_a} | :tail])
  end

  test "rejects malformed, empty, unsorted, duplicate, and oversized entries" do
    assert {:error, {:invalid_field, "entries", :expected_list}} =
             CandidateMaterialization.new(valid_attrs(%{"entries" => %{}}))

    assert {:error, {:invalid_field, "entries", :must_be_non_empty}} =
             CandidateMaterialization.new(valid_attrs(%{"entries" => []}))

    assert {:error, {:invalid_field, "entries", :improper_list}} =
             CandidateMaterialization.new(
               valid_attrs(%{"entries" => [valid_entry("a.ex") | :tail]})
             )

    unsorted = [valid_entry("z.ex"), valid_entry("a.ex")]

    assert {:error, {:invalid_field, "entries[1].path", :unsorted}} =
             CandidateMaterialization.new(valid_attrs(%{"entries" => unsorted}))

    duplicates = [valid_entry("a.ex"), valid_entry("a.ex")]

    assert {:error, {:invalid_field, "entries[1].path", :duplicate_path}} =
             CandidateMaterialization.new(valid_attrs(%{"entries" => duplicates}))

    extra_entry = Map.put(valid_entry("a.ex"), "extra", 1)

    assert {:error, {:unknown_fields, ["entries[0].extra"]}} =
             CandidateMaterialization.new(valid_attrs(%{"entries" => [extra_entry]}))

    aliased = %{:path => "a.ex", "path" => "b.ex", :blob_oid => @oid40_c, :mode => 100_644}

    assert {:error, {:duplicate_fields, ["entries[0].path"]}} =
             CandidateMaterialization.new(valid_attrs(%{"entries" => [aliased]}))

    too_many =
      Enum.map(1..(CandidateMaterialization.max_entries() + 1), fn index ->
        valid_entry(String.pad_leading(Integer.to_string(index), 4, "0") <> ".ex")
      end)

    assert {:error, {:invalid_field, "entries", :list_too_large}} =
             CandidateMaterialization.new(valid_attrs(%{"entries" => too_many}))
  end

  test "rejects every path class" do
    cases = [
      {123, :expected_string},
      {<<0xFF>>, :invalid_utf8},
      {"", :empty_path},
      {String.duplicate("a", 1025), :path_too_long},
      {"foo" <> <<0>> <> "bar.ex", :nul_byte},
      {"foo\nbar.ex", :crlf},
      {"foo\rbar.ex", :crlf},
      {"foo\\bar.ex", :backslash},
      {"/abs.ex", :absolute_path},
      {"C:/abs.ex", :absolute_path},
      {"./foo.ex", :leading_dot_slash},
      {"foo//bar.ex", :repeated_slash},
      {"foo/", :trailing_slash},
      {segment_path(49), :path_depth},
      {String.duplicate("a", 256), :component_too_long},
      {".", :dot_segment},
      {"foo/./bar.ex", :dot_segment},
      {"..", :dotdot_segment},
      {"foo/../bar.ex", :dotdot_segment},
      {".git", :git_segment},
      {"foo/.git/bar.ex", :git_segment}
    ]

    for {path, reason} <- cases do
      assert {:error, {:invalid_field, "entries[0].path", ^reason}} =
               CandidateMaterialization.new(valid_attrs(%{"entries" => [valid_entry(path)]}))
    end
  end

  test "admits .github and foo.git filenames that are not .git segments" do
    attrs =
      valid_attrs(%{
        "entries" => [
          valid_entry(".github/workflows.yml"),
          valid_entry("foo.git")
        ]
      })

    assert {:ok, descriptor} = CandidateMaterialization.new(attrs)
    assert Enum.map(descriptor.entries, & &1["path"]) == [".github/workflows.yml", "foo.git"]
  end

  test "rejects uppercase, short, long, non-hex, and mixed-width OIDs" do
    assert {:error, {:invalid_field, "source_commit_oid", :invalid_oid}} =
             CandidateMaterialization.new(
               valid_attrs(%{"source_commit_oid" => String.duplicate("A", 40)})
             )

    assert {:error, {:invalid_field, "source_commit_oid", :invalid_oid}} =
             CandidateMaterialization.new(
               valid_attrs(%{"source_commit_oid" => String.duplicate("a", 39)})
             )

    assert {:error, {:invalid_field, "expected_tree_oid", :invalid_oid}} =
             CandidateMaterialization.new(
               valid_attrs(%{"expected_tree_oid" => String.duplicate("a", 41)})
             )

    assert {:error, {:invalid_field, "expected_tree_oid", :invalid_oid}} =
             CandidateMaterialization.new(valid_attrs(%{"expected_tree_oid" => "not-hex"}))

    assert {:error, {:invalid_field, "expected_tree_oid", :inconsistent_oid_width}} =
             CandidateMaterialization.new(valid_attrs(%{"expected_tree_oid" => @oid64_b}))

    mixed_blob = [valid_entry("mix.exs", %{"blob_oid" => @oid64_c})]

    assert {:error, {:invalid_field, "entries[0].blob_oid", :inconsistent_oid_width}} =
             CandidateMaterialization.new(valid_attrs(%{"entries" => mixed_blob}))
  end

  test "rejects unsupported modes including symlink, submodule, and string modes" do
    for mode <- ["100644", 100_644.0, 644, 100_666, 120_000, 160_000, 40000] do
      assert {:error, {:invalid_field, "entries[0].mode", :unsupported}} =
               CandidateMaterialization.new(
                 valid_attrs(%{"entries" => [valid_entry("mix.exs", %{"mode" => mode})]})
               )
    end
  end

  test "rejects canonical descriptor bytes above 1 MiB" do
    entries =
      Enum.map(1..1200, fn index ->
        suffix = String.pad_leading(Integer.to_string(index), 4, "0")
        valid_entry(suffix <> "/" <> String.duplicate("a", 900))
      end)

    assert {:error, {:invalid_candidate_materialization, :too_large}} =
             CandidateMaterialization.new(valid_attrs(%{"entries" => entries}))
  end

  test "admits a 48-segment path and rejects a 49-segment path as the path rule" do
    admitted = valid_attrs(%{"entries" => [valid_entry(segment_path(48))]})
    rejected = valid_attrs(%{"entries" => [valid_entry(segment_path(49))]})

    assert {:ok, descriptor} = CandidateMaterialization.new(admitted)
    assert hd(descriptor.entries)["path"] == segment_path(48)

    assert {:error, {:invalid_field, "entries[0].path", :path_depth}} =
             CandidateMaterialization.new(rejected)
  end

  test "does not treat a 9-segment path as recovery structural depth" do
    attrs = valid_attrs(%{"entries" => [valid_entry(segment_path(9))]})
    assert {:ok, descriptor} = CandidateMaterialization.new(attrs)
    assert {:ok, shape} = CandidateMaterialization.recovery_shape(descriptor)
    assert {:ok, ^shape} = CandidateMaterialization.admit_recovery_value(shape)
    assert hd(shape["ancestors"]) == "s"
    assert length(shape["ancestors"]) == 8
  end

  test "admits eight nested recovery containers and rejects a ninth as structural depth" do
    assert {:ok, nested} = CandidateMaterialization.admit_recovery_value(nest_maps(8))

    assert {:error, {:invalid_candidate_materialization, :structural_depth_exceeded}} =
             CandidateMaterialization.admit_recovery_value(nest_maps(9))

    assert nested == nest_maps(8)
  end

  test "rejects synthetic recovery values over each aggregate structural limit" do
    over_nodes = Enum.to_list(1..65_536)

    assert {:error, {:invalid_candidate_materialization, :recovery_nodes_exceeded}} =
             CandidateMaterialization.admit_recovery_value(over_nodes)

    over_record = %{"records" => [String.duplicate("x", 4_194_304)]}

    assert {:error, {:invalid_candidate_materialization, :record_too_large}} =
             CandidateMaterialization.admit_recovery_value(over_record)

    over_inventory = %{
      "records" => [
        String.duplicate("a", 3_000_000),
        String.duplicate("b", 3_000_000),
        String.duplicate("c", 3_000_000)
      ]
    }

    assert {:error, {:invalid_candidate_materialization, :inventory_too_large}} =
             CandidateMaterialization.admit_recovery_value(over_inventory)
  end
end
