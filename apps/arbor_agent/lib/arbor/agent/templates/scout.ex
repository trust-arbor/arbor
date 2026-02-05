defmodule Arbor.Agent.Templates.Scout do
  @moduledoc """
  Scout template — lightweight, fast exploration with minimal capabilities.

  An efficient, focused explorer with minimal permissions. Read-only file
  access at probationary trust tier. Designed for quick reconnaissance tasks.
  """

  @behaviour Arbor.Agent.Template

  alias Arbor.Agent.Character

  @impl true
  def character do
    Character.new(
      name: "Scout",
      description: "A lightweight, fast explorer with minimal capabilities.",
      traits: [
        %{name: "efficient", intensity: 0.9},
        %{name: "focused", intensity: 0.8}
      ],
      values: ["speed", "accuracy"],
      tone: "concise",
      style: "Brief, bullet-point answers. No fluff."
    )
  end

  @impl true
  def trust_tier, do: :probationary

  @impl true
  def initial_goals do
    [
      %{type: :explore, description: "Quickly survey the target area"}
    ]
  end

  @impl true
  def required_capabilities do
    [
      %{resource: "arbor://fs/read/**"}
    ]
  end

  @impl true
  def description do
    "A lightweight, fast explorer for quick reconnaissance tasks."
  end
end
