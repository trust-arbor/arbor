defmodule Arbor.Actions.TestSupport.GeneratedExUnitRunner do
  @moduledoc false

  import ExUnit.Assertions

  @spec run!(String.t()) :: map()
  def run!(source) when is_binary(source) do
    tmp_dir = unique_tmp_dir!()
    source_path = Path.join(tmp_dir, "generated_test.exs")
    runner_path = Path.join(tmp_dir, "runner.exs")
    outcome_path = Path.join(tmp_dir, "outcome.term")

    File.write!(source_path, source)
    File.write!(runner_path, runner_source(source_path, outcome_path))

    try do
      elixir = System.find_executable("elixir") || flunk("pinned elixir executable unavailable")

      {output, exit_code} =
        System.cmd(elixir, code_path_args() ++ [runner_path],
          cd: tmp_dir,
          stderr_to_stdout: true
        )

      assert exit_code == 0,
             "generated ExUnit suite failed in fresh VM (exit #{exit_code}): " <>
               String.slice(output, 0, 8_192)

      assert {:ok, outcome_bytes} = File.read(outcome_path)
      stats = :erlang.binary_to_term(outcome_bytes, [:safe])

      assert stats.total > 0, "generated ExUnit source registered no tests"
      assert stats.failures == 0, "generated ExUnit suite reported failures"

      stats
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp code_path_args do
    Mix.Project.build_path()
    |> Path.join("lib/*/ebin")
    |> Path.wildcard()
    |> Enum.flat_map(&["-pa", &1])
  end

  defp runner_source(source_path, outcome_path) do
    """
    ExUnit.start(autorun: false)
    Code.require_file(#{inspect(source_path)})

    stats = ExUnit.run()
    File.write!(#{inspect(outcome_path)}, :erlang.term_to_binary(stats, [:deterministic]), [:binary])

    if stats.total > 0 and stats.failures == 0 do
      System.halt(0)
    else
      System.halt(1)
    end
    """
  end

  defp unique_tmp_dir! do
    suffix = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    path = Path.join(System.tmp_dir!(), "generated-ex-unit-" <> suffix)
    File.mkdir!(path)
    path
  end
end
