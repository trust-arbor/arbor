defmodule Arbor.Common.Commands.Trust do
  @moduledoc "Show trust profile for the current agent."
  @behaviour Arbor.Common.Command

  @impl true
  def name, do: "trust"

  @impl true
  def description, do: "Show trust profile"

  @impl true
  def usage, do: "/trust"

  @impl true
  def available?(_context), do: true

  @impl true
  def execute(_args, context) do
    lines = []

    lines =
      if tier = context[:trust_tier],
        do: lines ++ ["Trust tier: #{tier}"],
        else: lines

    lines =
      if profile = context[:trust_profile] do
        rules =
          Map.get(profile, :rules, [])
          |> Enum.map(fn rule ->
            "  #{rule.uri_prefix} → #{rule.mode}"
          end)

        if rules != [] do
          lines ++ ["Profile rules:"] ++ rules
        else
          lines ++ ["Profile: default (no custom rules)"]
        end
      else
        lines ++ ["Trust profile: not loaded"]
      end

    {:ok, Enum.join(lines, "\n")}
  end
end
