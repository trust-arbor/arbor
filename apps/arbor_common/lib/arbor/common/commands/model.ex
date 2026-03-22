defmodule Arbor.Common.Commands.Model do
  @moduledoc "Show or switch the current LLM model."
  @behaviour Arbor.Common.Command

  @impl true
  def name, do: "model"

  @impl true
  def description, do: "Show or switch LLM model"

  @impl true
  def usage, do: "/model [provider/model-name]"

  @impl true
  def available?(_context), do: true

  @impl true
  def execute("", context) do
    model = context[:model] || "not set"
    provider = context[:provider] || "unknown"
    {:ok, "Current model: #{model} (#{provider})"}
  end

  def execute("list", context) do
    # Delegate to callback if provided, otherwise show hint
    case context[:list_models_fn] do
      fun when is_function(fun, 0) ->
        models = fun.()
        lines = Enum.map(models, fn m -> "  #{m}" end)
        {:ok, "Available models:\n" <> Enum.join(lines, "\n")}

      _ ->
        {:ok, "Model listing not available in this context. Use the provider's API to list models."}
    end
  end

  def execute(model_spec, context) do
    model_spec = String.trim(model_spec)

    case context[:switch_model_fn] do
      fun when is_function(fun, 1) ->
        case fun.(model_spec) do
          :ok -> {:ok, "Switched to model: #{model_spec}"}
          {:ok, msg} -> {:ok, msg}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:ok, "Model switching not available in this context. Restart the agent with --model #{model_spec}"}
    end
  end
end
