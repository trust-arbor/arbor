defmodule Arbor.Agent.Orchestration.TaskRunner do
  @moduledoc """
  Default async orchestration task runner.

  The runner adapts the existing synchronous `Arbor.Agent.Manager.chat/3`
  surface into the structured result shape returned by Slice 2 task APIs.
  """

  @default_sender "Orchestration"

  @type task :: String.t() | map()

  alias Arbor.Agent.Orchestration.TaskArtifacts

  @doc "Run a task against an agent and return a structured result."
  @spec run(String.t(), task(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(agent_id, task, opts \\ []) when is_binary(agent_id) do
    with {:ok, input} <- task_input(task) do
      manager = Keyword.get(opts, :manager_module, Arbor.Agent.Manager)
      sender = Keyword.get(opts, :sender, @default_sender)

      chat_opts =
        [agent_id: agent_id]
        |> maybe_put(:timeout, Keyword.get(opts, :timeout))

      case call_manager(manager, input, sender, chat_opts) do
        {:ok, result} -> {:ok, TaskArtifacts.normalize(result)}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_runner_result, other}}
      end
    end
  end

  defp task_input(task) when is_binary(task) do
    task
    |> String.trim()
    |> case do
      "" -> {:error, :empty_task}
      input -> {:ok, input}
    end
  end

  defp task_input(task) when is_map(task) do
    [:input, "input", :prompt, "prompt", :message, "message", :task, "task"]
    |> Enum.find_value(fn key ->
      case Map.get(task, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, :missing_task_input}
      input -> task_input(input)
    end
  end

  defp task_input(_task), do: {:error, :invalid_task}

  defp call_manager(manager, input, sender, chat_opts) do
    if function_exported?(manager, :chat_response, 3) do
      manager.chat_response(input, sender, chat_opts)
    else
      manager.chat(input, sender, chat_opts)
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
