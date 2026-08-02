defmodule Mix.Tasks.Arbor.Spec.CoverageTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Mix.Tasks.Arbor.Spec.Coverage

  setup do
    root =
      Path.join(System.tmp_dir!(), "arbor-spec-coverage-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "discovers legacy top-level and canonical recursive specifications", %{root: root} do
    legacy = write(root, "docs/specs/TRUST-1.0.md", "- **TRUST-1** (MUST): Legacy.\n")

    canonical =
      write(
        root,
        "docs/arbor/specs/voice/VOICE-1.0.md",
        "- **VOICE-1** (MUST): Canonical.\n"
      )

    _local_handoff =
      write(
        root,
        "docs/specs/voice/LOCAL-1.0.md",
        "- **LOCAL-1** (MUST): Not authoritative.\n"
      )

    assert Coverage.spec_paths(root) == Enum.sort([canonical, legacy])
  end

  test "parses canonical nested statements and applies the area filter", %{root: root} do
    write(
      root,
      "docs/arbor/specs/voice/VOICE-1.0.md",
      """
      - **VOICE-1** (MUST): Current requirement.
      - **VOICE-2** (MUST, planned): Future requirement.
      """
    )

    assert %{
             "VOICE-1" => %{level: "MUST", planned: false},
             "VOICE-2" => %{level: "MUST", planned: true}
           } = Coverage.parse_specs("VOICE", root)

    assert Coverage.parse_specs("TRUST", root) == %{}
  end

  test "rejects duplicate normative IDs across conformance sources", %{root: root} do
    write(root, "docs/specs/VOICE-1.0.md", "- **VOICE-1** (MUST): Legacy.\n")

    write(
      root,
      "docs/arbor/specs/VOICE-1.0.md",
      "- **VOICE-1** (MUST, planned): Canonical.\n"
    )

    assert_raise Mix.Error, ~r/Duplicate normative spec statement IDs: VOICE-1/, fn ->
      Coverage.parse_specs("VOICE", root)
    end
  end

  test "area filtering excludes unrelated test tags from dead-reference analysis", %{root: root} do
    tag = "@" <> "tag"

    write(
      root,
      "apps/example/test/conformance_test.exs",
      "#{tag} spec: \"TRUST-1\"\n#{tag} spec: \"VOICE-1,VOICE-2\"\ntest \"proof\" do\n  assert true\nend\n"
    )

    assert %{
             "VOICE-1" => [_],
             "VOICE-2" => [_]
           } = Coverage.scan_test_tags("VOICE", root)

    refute Map.has_key?(Coverage.scan_test_tags("VOICE", root), "TRUST-1")
    assert %{"TRUST-1" => [_]} = Coverage.scan_test_tags("TRUST", root)
  end

  test "comments and strings cannot claim conformance proof", %{root: root} do
    marker = "@" <> "tag spec: \"VOICE-9\""

    write(
      root,
      "apps/example/test/non_proof_test.exs",
      "# #{marker}\nvalue = #{inspect(marker)}\nassert is_binary(value)\n"
    )

    assert Coverage.scan_test_tags("VOICE", root) == %{}
  end

  test "malformed test sources fail the proof scan closed", %{root: root} do
    path = write(root, "apps/example/test/broken_test.exs", "defmodule Broken do\n")

    assert_raise Mix.Error, ~r/Cannot parse test file.*#{Regex.escape(path)}/, fn ->
      Coverage.scan_test_tags("VOICE", root)
    end
  end

  defp write(root, relative_path, content) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end
end
