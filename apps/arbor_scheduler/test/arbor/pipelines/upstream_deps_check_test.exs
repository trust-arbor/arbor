defmodule Arbor.Pipelines.UpstreamDepsCheckTest do
  @moduledoc """
  Smoke checks for the upstream-deps-check reference pipeline + script.

  The full end-to-end (orchestrator runs the pipeline → script writes
  report) is verified manually during development — see the script's
  module docstring for the one-liner. These tests just guard the
  artifacts ship correctly:

  - Pipeline DOT file exists and references the right script
  - Script exists, is executable, and runs cleanly when no config
    file is present (writes the "no config" placeholder report)
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  @pipeline_path "priv/pipelines/upstream_deps_check.dot"
  @script_path "priv/scripts/upstream_deps_check.sh"

  setup do
    app_dir = Path.expand("../../..", __DIR__)

    %{
      pipeline_abs: Path.join(app_dir, @pipeline_path),
      script_abs: Path.join(app_dir, @script_path)
    }
  end

  describe "pipeline artifact" do
    test "DOT file exists", %{pipeline_abs: pipeline_abs} do
      assert File.exists?(pipeline_abs),
             "Expected the upstream-deps-check pipeline at #{pipeline_abs}"
    end

    test "DOT file references the bundled script", %{pipeline_abs: pipeline_abs} do
      source = File.read!(pipeline_abs)

      assert source =~ "apps/arbor_scheduler/priv/scripts/upstream_deps_check.sh",
             "Pipeline should invoke the bundled script (relative-to-repo path)"
    end

    test "DOT file has the expected top-level graph structure", %{pipeline_abs: pipeline_abs} do
      source = File.read!(pipeline_abs)

      assert source =~ "digraph UpstreamDepsCheck"
      assert source =~ ~r/start\s*\[shape=Mdiamond\]/
      assert source =~ ~r/done\s*\[shape=Msquare\]/
      assert source =~ ~r/run_check\s*\[/
    end
  end

  describe "script artifact" do
    test "script exists", %{script_abs: script_abs} do
      assert File.exists?(script_abs), "Expected script at #{script_abs}"
    end

    test "script is executable", %{script_abs: script_abs} do
      stat = File.stat!(script_abs)
      mode = stat.mode |> Bitwise.band(0o111)
      assert mode != 0, "Script should be executable (chmod +x)"
    end

    test "script produces a 'no config' report when no config file exists",
         %{script_abs: script_abs} do
      # Move any existing config aside so the test exercises the
      # missing-file branch deterministically. Restore on exit.
      config_path = Path.expand("~/.arbor/upstream_deps.conf")
      backup_path = config_path <> ".test_backup_#{System.unique_integer([:positive])}"

      had_config = File.exists?(config_path)
      if had_config, do: File.rename!(config_path, backup_path)

      on_exit(fn ->
        if had_config and File.exists?(backup_path) do
          File.rename!(backup_path, config_path)
        end
      end)

      report_path = Path.expand("~/.arbor/reports/upstream-deps/#{Date.utc_today()}.md")
      # Don't assume we control whether the report exists — just snapshot
      # mtime if it does, so we can verify the script touched it.
      before_mtime =
        case File.stat(report_path) do
          {:ok, stat} -> stat.mtime
          _ -> nil
        end

      {output, exit_code} = System.cmd("bash", [script_abs], stderr_to_stdout: true)

      assert exit_code == 0, "Script should exit 0; got #{exit_code}, output:\n#{output}"

      assert String.trim(output) == report_path,
             "Script should print the report path to stdout; got: #{inspect(output)}"

      assert File.exists?(report_path)

      # mtime advanced (or the file is new — both prove the script wrote)
      new_mtime = File.stat!(report_path).mtime
      assert before_mtime == nil or new_mtime >= before_mtime

      contents = File.read!(report_path)
      assert contents =~ "Upstream deps check"
      assert contents =~ "No config file"
      assert contents =~ "Comments and blank lines are ignored"
    end
  end
end
