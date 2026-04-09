defmodule Arbor.Common.Commands.Model do
  @moduledoc "Show or switch the current LLM model."
  @behaviour Arbor.Common.Command

  alias Arbor.Contracts.Commands.{Context, Result}

  @impl true
  def name, do: "model"

  @impl true
  def description, do: "Show or switch LLM model"

  @impl true
  def usage, do: "/model [provider/model-name]"

  @impl true
  def available?(%Context{} = ctx), do: Context.has_agent?(ctx)

  @impl true
  def execute("", %Context{} = ctx) do
    model = ctx.model || "not set"
    provider = ctx.provider || "unknown"
    {:ok, Result.ok("Current model: #{model} (#{provider})")}
  end

  def execute("list", %Context{}) do
    # Listing available models requires querying providers (network I/O),
    # which is the caller's job. The command itself stays pure — return
    # informational text. A future :list_models action could push this
    # back to the caller for richer output.
    {:ok,
     Result.ok(
       "Model listing isn't yet wired to a backend. " <>
         "Use the provider's API or check the model registry directly."
     )}
  end

  def execute(model_spec, %Context{} = ctx) do
    model_spec = String.trim(model_spec)

    if Context.has_agent?(ctx) do
      {:ok,
       Result.action(
         "Switching to model: #{model_spec}",
         {:switch_model, model_spec}
       )}
    else
      {:ok,
       Result.error(
         "Cannot switch model: no current agent in this context."
       )}
    end
  end
end
