defmodule Arbor.Orchestrator.CodingPlan.SteeringEligibilityCore do
  @moduledoc false

  @type phase :: Arbor.Orchestrator.CodingPlan.WorkerPhaseCore.phase()
  @type decision :: :eligible | :ineligible

  @doc false
  @spec decide(String.t() | nil, phase() | term()) :: decision()
  def decide(_target_stage, phase) when phase not in [:design, :implement], do: :ineligible

  def decide(target_stage, :implement)
      when is_nil(target_stage) or is_binary(target_stage),
      do: :eligible

  def decide(target_stage, :design)
      when is_nil(target_stage) or target_stage == "design",
      do: :eligible

  def decide(target_stage, :design) when is_binary(target_stage), do: :ineligible

  def decide(_target_stage, _phase), do: :ineligible
end
