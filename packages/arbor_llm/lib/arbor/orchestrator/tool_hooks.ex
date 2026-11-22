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

  # Graph string hooks have no independent command capability binding, and their
  # historical semantics require a shell interpreter plus environment expansion.
  # While CapShell is unavailable there is no way to preserve those semantics and
  # prove the child process. Fail closed. Function hooks and an explicitly
  # injected :tool_hook_runner remain trusted system-only extension seams.
  defp run_shell_hook(_command, _payload, _opts) do
    {:error,
     "string tool hooks are unavailable: agent-authored runtime command expansion is disabled"}
  end

  defp success(decision),
    do: %{status: :ok, decision: decision, reason: nil, exit_code: 0, output: nil}

  defp error(decision),
    do: %{status: :error, decision: decision, reason: nil, exit_code: 1, output: nil}
end
