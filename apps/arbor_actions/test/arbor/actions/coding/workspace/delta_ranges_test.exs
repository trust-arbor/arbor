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
end
