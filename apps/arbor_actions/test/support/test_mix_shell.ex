defmodule Arbor.Actions.TestMixShell do
  @moduledoc """
  Test-only action facade for trusted finite Mix fixture projects.

  This module executes the repository's pinned Mix wrapper (or the exact absolute
  path Mix resolves) so positive schema tests can exercise action result
  handling. It is not a Shell backend, does not claim descendant containment,
  and must never be configured outside the test environment.

  Optional `resolve_mix_wrapper/0` is the hermetic execution seam used by
  `Arbor.Actions.Mix` projections and `run_mix/3` when this module is installed
  as `:mix_shell_module`. Production `Arbor.Shell` does not export that
  callback and continues to use code-root wrapper authority.
  """

  @fallback_wrapper Path.expand("../../../../bin/mix", __DIR__)

  @doc """
  Absolute repository Mix wrapper accepted by this test shell.

  Authority is this source-relative path only — never cwd, Application env,
  candidate worktrees, or caller opts. Production Mix keeps a separate
  code-root resolver. Output must be an absolute regular executable so
  `Arbor.Actions.Mix` validation accepts it.
  """
  @spec resolve_mix_wrapper() :: {:ok, String.t()} | {:error, term()}
  def resolve_mix_wrapper do
    wrapper = @fallback_wrapper

    with true <- is_binary(wrapper),
         true <- Path.type(wrapper) == :absolute,
         true <- File.regular?(wrapper),
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.stat(wrapper),
         true <- Bitwise.band(mode, 0o111) != 0 do
      {:ok, wrapper}
    else
      _ -> {:error, :mix_wrapper_unavailable}
    end
  end

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

      # Optional test-only: sleep for the full allocated child timeout then
      # return success without running Mix. Proves postflight budget reserve
      # when a child consumes its entire timeout. Not production behavior.
      if Process.get({__MODULE__, :consume_full_timeout}) == true do
        timeout = Keyword.get(opts, :timeout, 0)

        if is_integer(timeout) and timeout > 0 do
          Process.sleep(timeout)
        end

        {:ok,
         %{
           exit_code: 0,
           stdout: "test-mix-shell: consumed full child timeout\n",
           stderr: "",
           duration_ms: System.monotonic_time(:millisecond) - started_at,
           timed_out: false,
           killed: false,
           output_truncated: false,
           output_limit_exceeded: false
         }}
      else
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

  @doc false
  def set_consume_full_timeout(enabled) when is_boolean(enabled) do
    Process.put({__MODULE__, :consume_full_timeout}, enabled)
    :ok
  end

  @doc false
  def clear_consume_full_timeout, do: Process.delete({__MODULE__, :consume_full_timeout})

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

  defp accepted_wrapper("mix"), do: resolve_mix_wrapper()

  defp accepted_wrapper(path) when is_binary(path) do
    with {:ok, accepted} <- resolve_mix_wrapper() do
      cond do
        path == accepted ->
          {:ok, accepted}

        Path.basename(path) == "mix" and File.regular?(path) ->
          # Allow absolute path form when it is the same reviewed wrapper after
          # realpath (symlink aliases). Other mix binaries are rejected.
          case {realpath(path), realpath(accepted)} do
            {{:ok, same}, {:ok, same}} -> {:ok, accepted}
            _ -> {:error, :unsupported_test_mix_execution}
          end

        true ->
          {:error, :unsupported_test_mix_execution}
      end
    end
  end

  defp realpath(path) do
    case Arbor.Common.SafePath.resolve_real(path) do
      {:ok, canonical} -> {:ok, canonical}
      _ -> {:error, :unresolvable}
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
