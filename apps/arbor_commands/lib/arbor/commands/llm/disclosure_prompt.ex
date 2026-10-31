defmodule Arbor.Commands.LLM.DisclosurePrompt do
  @moduledoc "Product CLI interaction for the explicit LLM disclosure prompt."

  @behaviour Arbor.LLM.Contracts.DisclosurePrompt

  @impl true
  def info(text), do: Mix.shell().info(text)

  @impl true
  def yes?(question), do: Mix.shell().yes?(question)
end
