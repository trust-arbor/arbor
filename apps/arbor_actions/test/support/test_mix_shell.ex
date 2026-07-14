defmodule Arbor.Actions.TestMixShell do
  @moduledoc """
  Test-only action facade for trusted finite Mix fixture projects.

  This module executes the repository's pinned Mix wrapper (or the exact absolute
  path Mix resolves) so positive schema tests can exercise action result
  handling. It is not a Shell backend, does not claim descendant containment,
  and must never be configured outside the test environment.
  """

  @fallback_wrapper Path.expand("../../../../bin/mix", __DIR__)

  @spec execute_spawn_capable(String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_spawn_capable(tool, args, opts)
      when is_binary(tool) and is_list(args) and is_list(opts) do
    with {:ok, wrapper} <- accepted_wrapper(tool) do
      started_at = System.monotonic_time(:millisecond)
      env = command_env(Keyword.get(opts, :env, %{}))
      env_map = Map.new(env)
      deps_path = Map.get(env_map, "MIX_DEPS_PATH")
      cwd = Keyword.fetch!(opts, :cwd)

      # Optional test-only mutation of a tracked file during "validation" to
      # exercise tree-binding detection. Not a platform containment claim.
      maybe_mutate_worktree(cwd)

      deps_snapshot =
        cond do
          is_binary(deps_path) and File.dir?(deps_path) ->
            case File.ls(deps_path) do
              {:ok, entries} -> %{path: deps_path, entries: entries, mode: file_mode(deps_path)}
              _ -> %{path: deps_path, entries: [], mode: nil}
            end

          true ->
            %{path: deps_path, entries: :missing, mode: nil}
        end

      Process.put({__MODULE__, :last_invocation}, %{
        tool: tool,
        wrapper: wrapper,
        args: args,
        opts: opts,
        env: env,
        deps_snapshot: deps_snapshot
      })

      case System.cmd(wrapper, args,
             cd: cwd,
             env: env,
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
  end

  def execute_spawn_capable(_tool, _args, _opts),
    do: {:error, :unsupported_test_mix_execution}

  @doc false
  def last_invocation, do: Process.get({__MODULE__, :last_invocation})

  @doc false
  def clear_last_invocation, do: Process.delete({__MODULE__, :last_invocation})

  @doc false
  def force_worktree_mutation(rel_path, contents)
      when is_binary(rel_path) and is_binary(contents) do
    Process.put({__MODULE__, :mutate_worktree}, {rel_path, contents})
    :ok
  end

  @doc false
  def clear_worktree_mutation, do: Process.delete({__MODULE__, :mutate_worktree})

  defp maybe_mutate_worktree(cwd) when is_binary(cwd) do
    case Process.get({__MODULE__, :mutate_worktree}) do
      {rel, contents} when is_binary(rel) and is_binary(contents) ->
        path = Path.join(cwd, rel)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, contents)
        Process.delete({__MODULE__, :mutate_worktree})
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_mutate_worktree(_), do: :ok

  defp accepted_wrapper("mix"), do: {:ok, @fallback_wrapper}

  defp accepted_wrapper(path) when is_binary(path) do
    basename = Path.basename(path)

    if basename == "mix" and File.regular?(path) do
      {:ok, path}
    else
      {:error, :unsupported_test_mix_execution}
    end
  end

  defp command_env(env) when is_map(env) do
    Enum.map(env, fn
      {key, false} -> {to_string(key), nil}
      {key, value} when is_binary(value) -> {to_string(key), value}
      {key, value} -> {to_string(key), to_string(value)}
    end)
  end

  defp command_env(_), do: []

  defp file_mode(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o777)
      _ -> nil
    end
  end
end
