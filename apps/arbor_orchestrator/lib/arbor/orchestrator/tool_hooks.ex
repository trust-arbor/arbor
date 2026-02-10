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
        env =
          payload
          |> base_env()
          |> Map.to_list()

        wrapped =
          "printf '%s' \"$TOOL_HOOK_PAYLOAD\" | (" <> command <> ")"

        {out, code} =
          System.cmd("/bin/sh", ["-lc", wrapped], env: env, stderr_to_stdout: true)

        {:command, out, code}
    end
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
