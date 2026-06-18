defmodule Arbor.Agent.Eval.SecurityReview.Reviewers do
  @moduledoc """
  The reviewer roster for the Security Sentinel L2-review eval — config-driven so
  the model set isn't hardcoded into the runner.

  Each reviewer is an API-class reviewer (a model reached via `Arbor.LLM.generate`):

      %{id: "kebab id", provider: atom, model: "model-id", tier: :local | :cloud}

  `tier` gates cost: the runner defaults to `[:local]`, so cloud models are inert
  until explicitly enabled. The agentic (ACP coding-agent) reviewers are a separate
  class handled in a later increment — not represented here.

  This is a *seed* roster. The local default mirrors L1's known-working config
  (`gemma-4-31b-it` via LM Studio). Hysun supplies the real local/cloud model IDs;
  extend `default/0` (or pass `:reviewers` to the runner) as they land.
  """

  @type reviewer :: %{
          id: String.t(),
          provider: atom(),
          model: String.t(),
          tier: :local | :cloud
        }

  @seed [
    # --- local (the first-run default; free + private) ---
    %{id: "gemma-local", provider: :lm_studio, model: "gemma-4-31b-it", tier: :local},

    # --- cloud (inert unless tier :cloud is enabled; placeholders to confirm) ---
    %{id: "claude-sonnet", provider: :anthropic, model: "claude-sonnet-4-6", tier: :cloud}
  ]

  @doc "The full seed roster (all tiers)."
  @spec default() :: [reviewer()]
  def default, do: @seed

  @doc "Reviewers whose tier is in `tiers` (default `[:local]`)."
  @spec by_tiers([atom()], [reviewer()]) :: [reviewer()]
  def by_tiers(tiers \\ [:local], roster \\ @seed) do
    Enum.filter(roster, &(&1.tier in tiers))
  end
end
