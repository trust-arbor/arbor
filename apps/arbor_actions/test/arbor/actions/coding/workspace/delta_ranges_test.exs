defmodule Arbor.Actions.Coding.Workspace.DeltaRangesTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.Workspace.DeltaRanges

  @moduletag :fast

  test "derives new-side ranges and omits deletion-only hunks" do
    diff = """
    diff --git a/lib/example.ex b/lib/example.ex
    index 1111111..2222222 100644
    --- a/lib/example.ex
    +++ b/lib/example.ex
    @@ -2,2 +2,3 @@
     unchanged
    -old
    +new
    +added
    diff --git a/removed.ex b/removed.ex
    deleted file mode 100644
    index 1111111..0000000
    --- a/removed.ex
    +++ /dev/null
    @@ -1 +0,0 @@
    -removed
    """

    assert {:ok, %{"lib/example.ex" => [[2, 4]]}} = DeltaRanges.parse(diff)
  end

  test "merges adjacent and overlapping hunks while retaining disjoint ranges" do
    diff = """
    diff --git a/lib/example.ex b/lib/example.ex
    index 1111111..2222222 100644
    --- a/lib/example.ex
    +++ b/lib/example.ex
    @@ -1 +1,2 @@
    +one
    +two
    @@ -3 +3,2 @@
    +three
    +four
    @@ -4 +4,2 @@
    +four
    +five
    @@ -9 +9 @@
    +nine
    """

    assert {:ok, %{"lib/example.ex" => [[1, 5], [9, 9]]}} = DeltaRanges.parse(diff)
  end

  test "rejects decreasing new-side hunk starts" do
    diff = """
    diff --git a/lib/example.ex b/lib/example.ex
    index 1111111..2222222 100644
    --- a/lib/example.ex
    +++ b/lib/example.ex
    @@ -10 +10,3 @@
    +ten
    +eleven
    +twelve
    @@ -1 +1,3 @@
    +one
    +two
    +three
    """

    assert {:error, :out_of_order_unified_diff_hunk} = DeltaRanges.parse(diff)
  end

  test "rejects quoted, binary, malformed, and oversized diffs" do
    assert {:error, :quoted_unified_diff_path} =
             DeltaRanges.parse("diff --git \"a/file name.ex\" \"b/file name.ex\"\n")

    assert {:error, :binary_unified_diff} =
             DeltaRanges.parse(
               "diff --git a/image.png b/image.png\nBinary files a/image.png and b/image.png differ\n"
             )

    assert {:error, :malformed_unified_diff} =
             DeltaRanges.parse("diff --git a/file.ex b/file.ex\n@@ -1 +1 @@\n")

    assert {:error, :malformed_unified_diff} =
             DeltaRanges.parse(
               "diff --git a/file.ex b/file.ex\n--- a/file.ex\n+++ b/file.ex\n" <>
                 "@@ -10000001 +1 @@\n+line\n"
             )

    assert {:error, :malformed_unified_diff} =
             DeltaRanges.parse(
               "diff --git a/file.ex b/file.ex\n--- a/file.ex\n+++ b/file.ex\n" <>
                 "@@ -0 +1 @@\n+line\n"
             )

    assert {:error, :unified_diff_too_large} =
             DeltaRanges.parse(String.duplicate("x", DeltaRanges.max_diff_bytes() + 1))
  end

  test "accepts strict full-index opaque modification and addition markers" do
    path = "generated/payload.json"
    old_oid = String.duplicate("1", 40)
    new_oid = String.duplicate("2", 40)
    zero_oid = String.duplicate("0", 40)

    modified = """
    diff --git a/#{path} b/#{path}
    index #{old_oid}..#{new_oid} 100644
    Binary files a/#{path} and b/#{path} differ
    """

    assert {:ok,
            %{
              files: [^path],
              ranges: %{^path => [[1, 10_000_000]]}
            }} = DeltaRanges.parse_material("", modified, [path])

    added_path = "generated/new-payload.json"

    added = """
    diff --git a/#{added_path} b/#{added_path}
    new file mode 100644
    index #{zero_oid}..#{new_oid}
    Binary files /dev/null and b/#{added_path} differ
    """

    assert {:ok,
            %{
              files: [^added_path],
              ranges: %{^added_path => [[1, 10_000_000]]}
            }} = DeltaRanges.parse_material("", added, [added_path])
  end

  test "opaque deletion remains visible but range-free" do
    path = "generated/payload.json"
    old_oid = String.duplicate("1", 64)
    zero_oid = String.duplicate("0", 64)

    deleted = """
    diff --git a/#{path} b/#{path}
    deleted file mode 100644
    index #{old_oid}..#{zero_oid}
    Binary files a/#{path} and /dev/null differ
    """

    assert {:ok, %{files: [^path], ranges: %{}}} =
             DeltaRanges.parse_material("", deleted, [path])
  end

  test "merges ordinary and opaque ranges under one aggregate ceiling" do
    opaque_path = "generated/payload.json"
    old_oid = String.duplicate("1", 40)
    new_oid = String.duplicate("2", 40)

    ordinary = """
    diff --git a/lib/example.ex b/lib/example.ex
    index #{old_oid}..#{new_oid} 100644
    --- a/lib/example.ex
    +++ b/lib/example.ex
    @@ -1 +1,2 @@
    -old
    +new
    +line
    """

    opaque = """
    diff --git a/#{opaque_path} b/#{opaque_path}
    index #{old_oid}..#{new_oid} 100644
    Binary files a/#{opaque_path} and b/#{opaque_path} differ
    """

    assert {:ok,
            %{
              files: ["generated/payload.json", "lib/example.ex"],
              ranges: %{
                "generated/payload.json" => [[1, 10_000_000]],
                "lib/example.ex" => [[1, 2]]
              }
            }} = DeltaRanges.parse_material(ordinary, opaque, [opaque_path])

    padding = String.duplicate("x", DeltaRanges.max_diff_bytes() - byte_size(opaque) + 1)

    assert {:error, :unified_diff_too_large} =
             DeltaRanges.parse_material(padding, opaque, [opaque_path])
  end

  test "opaque markers fail closed on path, index, mode, quoting, patch, and NUL confusion" do
    path = "generated/payload.json"
    old_oid = String.duplicate("1", 40)
    new_oid = String.duplicate("2", 40)

    valid_prefix = """
    diff --git a/#{path} b/#{path}
    index #{old_oid}..#{new_oid} 100644
    """

    for {suffix, reason} <- [
          {"Binary files a/other.json and b/#{path} differ\n", :binary_marker_path_mismatch},
          {"Binary files a/#{path} and /dev/null differ\n", :binary_marker_path_mismatch},
          {"GIT binary patch\n", :binary_unified_diff},
          {"Binary files \"a/#{path}\" and \"b/#{path}\" differ\n", :binary_marker_path_mismatch}
        ] do
      assert {:error, ^reason} =
               DeltaRanges.parse_material("", valid_prefix <> suffix, [path])
    end

    malformed_index = """
    diff --git a/#{path} b/#{path}
    index 1111111..2222222 100644
    Binary files a/#{path} and b/#{path} differ
    """

    assert {:error, :malformed_binary_index} =
             DeltaRanges.parse_material("", malformed_index, [path])

    wrong_mode = String.replace(valid_prefix, "100644", "100755")

    assert {:error, :malformed_binary_index} =
             DeltaRanges.parse_material(
               "",
               wrong_mode <> "Binary files a/#{path} and b/#{path} differ\n",
               [path]
             )

    assert {:error, :binary_unified_diff} =
             DeltaRanges.parse_material("", valid_prefix <> <<0>>, [path])

    assert {:error, :unapproved_binary_marker_path} =
             DeltaRanges.parse_material(
               "",
               valid_prefix <> "Binary files a/#{path} and b/#{path} differ\n",
               ["generated/other.json"]
             )
  end
end
