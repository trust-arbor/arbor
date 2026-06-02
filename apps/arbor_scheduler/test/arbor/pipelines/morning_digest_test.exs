defmodule Arbor.Pipelines.MorningDigestTest do
  @moduledoc """
  Smoke checks for the morning-digest reference pipeline + script.

  Note: these tests run the real script against the user's actual
  `~/.arbor/reports/` directory and will overwrite today's digest.
  That's acceptable because the digest is regenerated daily anyway,
  and the test exercises the same code path the cron job would.

  Full end-to-end (orchestrator runs the pipeline → script writes
  digest) is verified manually during development.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  @pipeline_path "priv/pipelines/morning_digest.dot"
  @script_path "priv/scripts/morning_digest.sh"

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
             "Expected the morning-digest pipeline at #{pipeline_abs}"
    end

    test "DOT file references the bundled script", %{pipeline_abs: pipeline_abs} do
      source = File.read!(pipeline_abs)

      assert source =~ "apps/arbor_scheduler/priv/scripts/morning_digest.sh",
             "Pipeline should invoke the bundled script (relative-to-repo path)"
    end

    test "DOT file has the expected top-level graph structure", %{pipeline_abs: pipeline_abs} do
      source = File.read!(pipeline_abs)

      assert source =~ "digraph MorningDigest"
      assert source =~ ~r/start\s*\[shape=Mdiamond\]/
      assert source =~ ~r/done\s*\[shape=Msquare\]/
      assert source =~ ~r/build_digest\s*\[/
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

    test "script produces a digest at the expected path and prints it to stdout",
         %{script_abs: script_abs} do
      digest_path = Path.expand("~/.arbor/reports/morning-digest/#{Date.utc_today()}.md")

      before_mtime =
        case File.stat(digest_path) do
          {:ok, stat} -> stat.mtime
          _ -> nil
        end

      {output, exit_code} = System.cmd("bash", [script_abs], stderr_to_stdout: true)

      assert exit_code == 0, "Script should exit 0; got #{exit_code}, output:\n#{output}"

      assert String.trim(output) == digest_path,
             "Script should print the digest path to stdout; got: #{inspect(output)}"

      assert File.exists?(digest_path)

      new_mtime = File.stat!(digest_path).mtime
      assert before_mtime == nil or new_mtime >= before_mtime
    end

    test "digest content has the expected structure" do
      digest_path = Path.expand("~/.arbor/reports/morning-digest/#{Date.utc_today()}.md")

      # Re-run the script to guarantee fresh content for this assertion.
      app_dir = Path.expand("../../..", __DIR__)
      script = Path.join(app_dir, @script_path)
      {_output, 0} = System.cmd("bash", [script], stderr_to_stdout: true)

      contents = File.read!(digest_path)

      assert contents =~ "# Morning digest"

      # The script footer is unconditional regardless of whether reports
      # were found, so we can assert on it without depending on the
      # operator's actual ~/.arbor/reports/ contents.
      assert contents =~ ~r/Digest generated at \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/
    end

    test "digest skips itself when collecting reports (no self-reference)" do
      digest_path = Path.expand("~/.arbor/reports/morning-digest/#{Date.utc_today()}.md")

      # Run once so today's digest exists.
      app_dir = Path.expand("../../..", __DIR__)
      script = Path.join(app_dir, @script_path)
      {_, 0} = System.cmd("bash", [script], stderr_to_stdout: true)

      # Now run again — if the script were globbing its own output dir, the
      # second run's digest would contain the first run's digest as a section.
      {_, 0} = System.cmd("bash", [script], stderr_to_stdout: true)

      contents = File.read!(digest_path)

      # If the digest self-referenced, we'd see "## morning-digest" as a
      # section heading (the topic name = parent dir name).
      refute contents =~ ~r/^## morning-digest$/m,
             "Digest must not include itself; otherwise nested runs balloon."
    end
  end
end
