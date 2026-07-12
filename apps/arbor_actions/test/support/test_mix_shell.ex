defmodule Arbor.Actions.TestMixShell do
  @moduledoc """
  Test-only action facade for trusted finite Mix fixture projects.

  This module executes the repository's pinned Mix wrapper directly so positive
  schema tests can exercise action result handling. It is not a Shell backend,
  does not claim descendant containment, and must never be configured outside
  the test environment.
  """

  @mix_wrapper Path.expand("../../../../bin/mix", __DIR__)

  @spec execute_spawn_capable(String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_spawn_capable("mix", args, opts) when is_list(args) and is_list(opts) do
    started_at = System.monotonic_time(:millisecond)

    case System.cmd(@mix_wrapper, args,
           cd: Keyword.fetch!(opts, :cwd),
           env: command_env(Keyword.get(opts, :env, %{})),
           stderr_to_stdout: true
         ) do
      {output, exit_code} ->
        {:ok,
         %{
           exit_code: exit_code,
           stdout: output,
           stderr: "",
           duration_ms: System.monotonic_time(:millisecond) - started_at,
           timed_out: false,
           killed: false,
           output_truncated: false,
           output_limit_exceeded: false
         }}
    end
  end

  def execute_spawn_capable(_tool, _args, _opts),
    do: {:error, :unsupported_test_mix_execution}

  defp command_env(env) do
    Enum.map(env, fn
      {key, false} -> {key, nil}
      {key, value} -> {key, value}
    end)
  end
end
