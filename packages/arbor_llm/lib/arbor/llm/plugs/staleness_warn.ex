defmodule Arbor.LLM.Plugs.StalenessWarn do
  @moduledoc """
  Emit a `Logger.warning/1` when a replayed fixture is older than
  the configured maximum age. No effect on the call itself — purely
  observational.

  ## Configuration

      config :arbor_llm, :fixture_max_age_days, 90

  Default is 90 days. Reasonable balance: provider APIs change
  occasionally enough that fixtures going stale matters, but tests
  shouldn't be re-recorded every CI run.

  ## Why this plug exists

  Replay is great for deterministic, free, fast tests — but a
  fixture recorded against `gpt-4o-mini` six months ago may not
  reflect what the model returns today (response shape can shift,
  finish_reason semantics can drift, cost data evolves). Silent
  replay against ancient fixtures is the worst-of-both-worlds:
  the test passes against the old answer while the production code
  has drifted to handle a different one.

  This plug is the cheap mitigation: it warns at the test boundary
  so operators see "your fixture is N days old, you may want to
  re-record." Pair with the project's CI policy on fixture freshness
  for a more rigorous gate.
  """

  use Arbor.LLM.Plug
  require Logger
  alias Arbor.LLM.Call

  @default_max_age_days 90

  # NB: no `halted: true` short-circuit — this is an observability
  # plug. It needs to see replayed (halted) calls; that's the whole
  # point of staleness warnings.

  def call(%Call{metadata: %{replayed_from: path, recorded_at: %DateTime{} = ts}} = call) do
    age_days = DateTime.diff(DateTime.utc_now(), ts, :day)
    max_age = Application.get_env(:arbor_llm, :fixture_max_age_days, @default_max_age_days)

    if age_days > max_age do
      Logger.warning(
        "LLM fixture is #{age_days} days old (max: #{max_age}): #{path}\n" <>
          "Consider re-recording with `Arbor.LLM.Plugs.Record` in the pipeline."
      )
    end

    call
  end

  # No replay metadata — call didn't come from a fixture, nothing to warn about.
  def call(%Call{} = call), do: call
end
