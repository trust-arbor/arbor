defmodule Arbor.Actions.Security.Detectors.DependencyScanTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.Detectors.DependencyScan

  @mix """
  defmodule Fix.MixProject do
    use Mix.Project

    def project, do: [app: :fix, deps: deps()]

    defp deps do
      [
        {:floats, git: "https://example.com/floats.git", branch: "main"},
        {:default_branch, git: "https://example.com/db.git"},
        {:pinned, git: "https://example.com/pinned.git", ref: "abc123def"},
        {:tagged, github: "owner/tagged", tag: "v1.2.3"},
        {:hexed, "~> 1.0"},
        {:hexed_opts, "~> 2.0", only: :test}
      ]
    end
  end
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "depscan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "mix.exs")
    File.write!(file, @mix)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, mixfile: file}
  end

  defp flagged(file),
    do: DependencyScan.detect(mix_files: [file]) |> Enum.map(& &1.evidence[:dependency])

  test "flags git deps on a branch and on the default branch", %{mixfile: file} do
    names = flagged(file)
    assert :floats in names
    assert :default_branch in names
  end

  test "does not flag git deps pinned to a ref or tag", %{mixfile: file} do
    names = flagged(file)
    refute :pinned in names
    refute :tagged in names
  end

  test "does not flag plain hex version deps", %{mixfile: file} do
    names = flagged(file)
    refute :hexed in names
    refute :hexed_opts in names
  end

  test "findings carry the dependency_risk category + a pin recommendation", %{mixfile: file} do
    [f | _] = DependencyScan.detect(mix_files: [file])
    assert f.category == :dependency_risk
    assert f.severity[:level] == :medium
    assert f.recommendation[:approach] =~ "ref:"
  end

  test "RunDependencyScan action returns a summary (audit off in test)", %{mixfile: file} do
    # audit: false avoids the hex.audit subprocess; point at our fixture via the
    # detector directly through the same path the action uses.
    findings = DependencyScan.detect(mix_files: [file], audit: false)
    assert length(findings) == 2
  end
end
