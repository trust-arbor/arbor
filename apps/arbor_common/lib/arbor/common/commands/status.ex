defmodule Arbor.Common.Commands.Status do
  @moduledoc "Shows agent status information."
  @behaviour Arbor.Common.Command

  @impl true
  def name, do: "status"

  @impl true
  def description, do: "Show agent status (model, session, trust)"

  @impl true
  def usage, do: "/status"

  @impl true
  def available?(_context), do: true

  @impl true
  def execute(_args, context) do
    lines = []

    lines =
      if agent_id = context[:agent_id] do
        lines ++ ["Agent: #{context[:display_name] || agent_id}"]
      else
        lines ++ ["Agent: (none)"]
      end

    lines =
      if model = context[:model] do
        lines ++ ["Model: #{model}"]
      else
        lines
      end

    lines =
      if provider = context[:provider] do
        lines ++ ["Provider: #{provider}"]
      else
        lines
      end

    lines =
      if session_id = context[:session_id] do
        lines ++ ["Session: #{session_id}"]
      else
        lines
      end

    lines =
      if trust_tier = context[:trust_tier] do
        lines ++ ["Trust: #{trust_tier}"]
      else
        lines
      end

    lines =
      if tools_count = context[:tools_count] do
        lines ++ ["Tools: #{tools_count} available"]
      else
        lines
      end

    {:ok, Enum.join(lines, "\n")}
  end
end
