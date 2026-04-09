defmodule Arbor.Common.Commands.Status do
  @moduledoc "Shows agent status information."
  @behaviour Arbor.Common.Command

  alias Arbor.Contracts.Commands.{Context, Result}

  @impl true
  def name, do: "status"

  @impl true
  def description, do: "Show agent status (model, session, trust)"

  @impl true
  def usage, do: "/status"

  @impl true
  def available?(%Context{} = ctx), do: Context.has_agent?(ctx)

  @impl true
  def execute(_args, %Context{} = ctx) do
    lines =
      [
        "Agent: #{ctx.display_name || ctx.agent_id}",
        if(ctx.model, do: "Model: #{ctx.model}"),
        if(ctx.provider, do: "Provider: #{ctx.provider}"),
        if(ctx.session_id, do: "Session: #{ctx.session_id}"),
        if(ctx.trust_tier, do: "Trust: #{ctx.trust_tier}"),
        if(length(ctx.tools) > 0, do: "Tools: #{length(ctx.tools)} available")
      ]
      |> Enum.reject(&is_nil/1)

    {:ok, Result.ok(Enum.join(lines, "\n"))}
  end
end
