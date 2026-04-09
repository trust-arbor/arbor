defmodule Arbor.Common.Commands.Trust do
  @moduledoc "Show trust profile for the current agent."
  @behaviour Arbor.Common.Command

  alias Arbor.Contracts.Commands.{Context, Result}

  @impl true
  def name, do: "trust"

  @impl true
  def description, do: "Show trust profile"

  @impl true
  def usage, do: "/trust"

  @impl true
  def available?(%Context{} = ctx), do: Context.has_agent?(ctx)

  @impl true
  def execute(_args, %Context{} = ctx) do
    tier_lines =
      if ctx.trust_tier, do: ["Trust tier: #{ctx.trust_tier}"], else: []

    profile_lines =
      case ctx.trust_profile do
        nil ->
          ["Trust profile: not loaded"]

        profile ->
          rules =
            profile
            |> Map.get(:rules, [])
            |> Enum.map(fn rule -> "  #{rule.uri_prefix} → #{rule.mode}" end)

          if rules == [] do
            ["Profile: default (no custom rules)"]
          else
            ["Profile rules:" | rules]
          end
      end

    {:ok, Result.ok(Enum.join(tier_lines ++ profile_lines, "\n"))}
  end
end
