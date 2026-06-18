defmodule Arbor.Actions.Security.StaticScanTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.StaticScan
  alias Arbor.Contracts.Security.Finding

  @fail_open_source """
  defmodule ScanFixture do
    def authorize(ctx) do
      run_chain(ctx)
    rescue
      _ -> :ok
    end
  end
  """

  @clean_source """
  defmodule CleanFixture do
    def authorize(ctx) do
      run_chain(ctx)
    rescue
      _ -> {:error, :denied}
    end
  end
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "sentinel_scan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "produces a fail_open_authz finding from a fail-open function", %{dir: dir} do
    File.write!(Path.join(dir, "fixture.ex"), @fail_open_source)
    out = Path.join(dir, "findings")

    {findings, summary} = StaticScan.scan(dir, output_dir: out, record: true)

    assert summary.total == 1
    assert [%Finding{} = f] = findings
    assert f.category == :fail_open_authz
    assert f.location[:function] == "authorize"
    assert String.contains?(f.location[:file], "fixture.ex")
    assert f.severity[:level] == :medium
    assert f.detector[:name] == "authorization_smells"
    assert f.verification[:must_fail_on_revert] == true

    # The finding captures the offending function's source so the Sentinel's G4
    # stage can pin a real (not synthetic) regression test to the flagged code.
    # It must be the enclosing def and be parseable Elixir on its own.
    excerpt = f.evidence[:code_excerpt]
    assert is_binary(excerpt)
    assert excerpt =~ "def authorize"
    assert {:ok, _ast} = Code.string_to_quoted(excerpt)
  end

  test "records each finding as <id>.md and emits a markdown projection", %{dir: dir} do
    File.write!(Path.join(dir, "fixture.ex"), @fail_open_source)
    out = Path.join(dir, "findings")

    {[finding], summary} = StaticScan.scan(dir, output_dir: out, record: true)

    assert summary.recorded_to == out
    md_path = Path.join(out, finding.id <> ".md")
    assert File.exists?(md_path)
    assert File.read!(md_path) =~ "fail_open_authz"
    assert File.read!(md_path) =~ "authorize"
  end

  test "dry run returns findings but writes nothing", %{dir: dir} do
    File.write!(Path.join(dir, "fixture.ex"), @fail_open_source)
    out = Path.join(dir, "findings")

    {findings, summary} = StaticScan.scan(dir, output_dir: out, record: false)

    assert summary.total == 1
    assert summary.recorded_to == nil
    refute File.exists?(out)
    assert length(findings) == 1
  end

  test "clean (fail-closed) code produces no findings", %{dir: dir} do
    File.write!(Path.join(dir, "clean.ex"), @clean_source)
    {findings, summary} = StaticScan.scan(dir, record: false)
    assert summary.total == 0
    assert findings == []
  end

  test "re-running is idempotent (stable dedup id, same file)", %{dir: dir} do
    File.write!(Path.join(dir, "fixture.ex"), @fail_open_source)
    out = Path.join(dir, "findings")

    {[f1], _} = StaticScan.scan(dir, output_dir: out, record: true)
    {[f2], _} = StaticScan.scan(dir, output_dir: out, record: true)

    assert f1.id == f2.id
    assert File.ls!(out) == [f1.id <> ".md"]
  end

  test "can scan a single file path", %{dir: dir} do
    file = Path.join(dir, "fixture.ex")
    File.write!(file, @fail_open_source)
    {findings, summary} = StaticScan.scan(file, record: false)
    assert summary.total == 1
    assert length(findings) == 1
  end

  describe "RunStaticDetectors action" do
    test "returns a summary map with finding ids", %{dir: dir} do
      File.write!(Path.join(dir, "fixture.ex"), @fail_open_source)
      out = Path.join(dir, "findings")

      assert {:ok, result} =
               Arbor.Actions.Security.RunStaticDetectors.run(
                 %{path: dir, output_dir: out, record: true, git_sha: nil},
                 %{}
               )

      assert result.total == 1
      assert [_id] = result.finding_ids
      assert result.by_category == %{fail_open_authz: 1}
    end
  end
end
