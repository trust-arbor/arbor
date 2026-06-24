defmodule Arbor.Orchestrator.ToolHooks do
  @moduledoc false

  @type hook_result :: %{
          status: :ok | :error,
          decision: :proceed | :skip,
          reason: String.t() | nil,
          exit_code: integer(),
          output: String.t() | nil
        }

  @spec run(:pre | :post, term(), map(), keyword()) :: hook_result()
  def run(_kind, nil, _payload, _opts),
    do: %{status: :ok, decision: :proceed, reason: nil, exit_code: 0, output: nil}

  def run(kind, hook, payload, opts) do
    hook
    |> execute_hook(payload, opts)
    |> normalize_result(kind)
  rescue
    exception ->
      normalize_result({:error, Exception.message(exception)}, kind)
  end

  defp execute_hook(fun, payload, _opts) when is_function(fun, 1), do: fun.(payload)
  defp execute_hook(fun, payload, opts) when is_function(fun, 2), do: fun.(payload, opts)

  defp execute_hook(command, payload, opts) when is_binary(command) do
    run_command(command, payload, opts)
  end

  defp execute_hook(other, _payload, _opts), do: {:error, "invalid hook: #{inspect(other)}"}

  defp normalize_result(result, :pre) do
    case result do
      :ok ->
        success(:proceed)

      true ->
        success(:proceed)

      :proceed ->
        success(:proceed)

      false ->
        success(:skip)

      :skip ->
        success(:skip)

      {:skip, reason} ->
        %{success(:skip) | reason: to_string(reason)}

      {:ok, _} ->
        success(:proceed)

      {:error, reason} ->
        %{error(:skip) | reason: to_string(reason)}

      {:command, out, 0} ->
        %{success(:proceed) | output: out}

      {:command, out, code} when is_integer(code) ->
        %{error(:skip) | output: out, exit_code: code}

      code when is_integer(code) and code == 0 ->
        success(:proceed)

      code when is_integer(code) ->
        %{error(:skip) | exit_code: code}

      _ ->
        success(:proceed)
    end
  end

  defp normalize_result(result, :post) do
    case result do
      :ok ->
        success(:proceed)

      true ->
        success(:proceed)

      {:ok, _} ->
        success(:proceed)

      {:error, reason} ->
        %{error(:proceed) | reason: to_string(reason)}

      {:command, out, 0} ->
        %{success(:proceed) | output: out}

      {:command, out, code} when is_integer(code) ->
        %{error(:proceed) | output: out, exit_code: code}

      code when is_integer(code) and code == 0 ->
        success(:proceed)

      code when is_integer(code) ->
        %{error(:proceed) | exit_code: code}

      _ ->
        success(:proceed)
    end
  end

  defp run_command(command, payload, opts) do
    case Keyword.get(opts, :tool_hook_runner) do
      runner when is_function(runner, 3) ->
        runner.(command, payload, opts)

      _ ->
        run_shell_hook(command, payload, opts)
    end
  end

  # SECURITY (codex command-execution.orchestrator-tool-hooks-shell): graph tool
  # hooks (`tool_hooks.pre`/`.post`, read from node/graph attrs) are shell
  # commands. Pre-fix they ran via `/bin/sh -c` with NO sandbox authorization —
  # unlike the sibling tool *command* path, which routes through
  # Arbor.Shell.Sandbox (H3). An agent-authored graph could put `rm -rf /` in a
  # hook and bypass the very gate the command path enforces. Gate the hook
  # through the same sandbox check at the node's sandbox level (threaded in by
  # ToolHandler as :sandbox_level). On denial we return {:error, _}, which
  # normalizes to a failed hook (:skip for :pre, :proceed for :post) so the
  # dangerous command never reaches System.cmd. `sandbox="none"` on the node is
  # the explicit escape hatch (same as the command path); the function-runner
  # seam (tool_hook_runner) is trusted programmatic injection and stays ungated.
  defp run_shell_hook(command, payload, opts) do
    level = Keyword.get(opts, :sandbox_level, :basic)

    case sandbox_check(command, level) do
      {:ok, :allowed} ->
        run_shell_command(command, payload)

      {:error, reason} ->
        {:error, "tool hook rejected by sandbox (level=#{level}, reason=#{inspect(reason)})"}
    end
  end

  defp sandbox_check(command, level) do
    sandbox_mod = Arbor.Shell.Sandbox

    if Code.ensure_loaded?(sandbox_mod) and function_exported?(sandbox_mod, :check, 2) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(sandbox_mod, :check, [command, level])
    else
      # Sandbox module unreachable. Strict-deny rather than fail-open: an
      # unsandboxed hook execution must not slip through silently.
      {:error, :sandbox_unavailable}
    end
  end

  defp run_shell_command(command, payload) do
    env =
      payload
      |> base_env()
      |> Map.to_list()

    # H14: pre-fix this constructed
    #   "printf '%s' \"$TOOL_HOOK_PAYLOAD\" | (" <> command <> ")"
    # and ran it through `/bin/sh -lc`. Two issues:
    #   1. The `-l` flag makes /bin/sh a *login* shell, sourcing
    #      ~/.profile / ~/.bashrc / etc. — any malicious modification of
    #      the user's shell init runs as part of the hook.
    #   2. The `command` string was concatenated into a shell wrapper
    #      with no quoting, so any metacharacter in the hook config
    #      (`;`, `&&`, backticks, command substitution) had double
    #      interpretation: once as the wrapper command and again when
    #      the wrapper re-evaluated it.
    # The fix: drop the `-l` flag (no login shell) and stop wrapping
    # the command. The hook command is passed as the literal argument
    # to `sh -c`; the payload reaches the hook via the TOOL_HOOK_PAYLOAD
    # env variable (already set by base_env) so no shell-level
    # interpolation is needed.
    {out, code} =
      System.cmd("/bin/sh", ["-c", command], env: env, stderr_to_stdout: true)

    {:command, out, code}
  end

  defp base_env(payload) do
    %{
      "TOOL_NAME" =>
        to_string(Map.get(payload, :tool_name) || Map.get(payload, "tool_name") || ""),
      "TOOL_CALL_ID" =>
        to_string(Map.get(payload, :tool_call_id) || Map.get(payload, "tool_call_id") || ""),
      "TOOL_HOOK_PHASE" => to_string(Map.get(payload, :phase) || Map.get(payload, "phase") || ""),
      "TOOL_HOOK_PAYLOAD" => Jason.encode!(payload)
    }
  end

  defp success(decision),
    do: %{status: :ok, decision: decision, reason: nil, exit_code: 0, output: nil}

  defp error(decision),
    do: %{status: :error, decision: decision, reason: nil, exit_code: 1, output: nil}
end
