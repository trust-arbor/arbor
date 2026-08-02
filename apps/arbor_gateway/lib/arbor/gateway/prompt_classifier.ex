defmodule Arbor.Gateway.PromptClassifier do
  @moduledoc """
  Compatibility wrapper around `Arbor.Common.SensitivityClassifier`.

  `Arbor.Common.SensitivityClassifier` is now the lower-level production
  owner of prompt sensitivity classification (label-to-sensitivity, routing,
  and taint mapping over `Arbor.Common.SensitiveData`), living in
  `arbor_common` so consumers below an HTTP gateway (e.g. `arbor_orchestrator`,
  `arbor_voice`) don't need to depend on this gateway module for content
  policy. This module delegates to it unchanged so existing gateway callers
  (`Arbor.Gateway.IntentExtractor`, `Arbor.Gateway.PreprocessingLog`, etc.)
  keep working without modification.

  ## Usage

      result = Arbor.Gateway.PromptClassifier.classify("deploy the app to staging")
      result.overall_sensitivity   #=> :public
      result.routing_recommendation #=> :any

  """

  alias Arbor.Common.SensitivityClassifier

  @type sensitivity :: SensitivityClassifier.sensitivity()
  @type routing :: SensitivityClassifier.routing()
  @type classification :: SensitivityClassifier.classification()

  @doc """
  Classify a prompt for sensitive data, returning findings, sanitized text,
  sensitivity level, routing recommendation, and taint tags.

  Delegates to `Arbor.Common.SensitivityClassifier.classify/2`.
  """
  @spec classify(String.t(), keyword()) :: classification()
  defdelegate classify(prompt, opts \\ []), to: SensitivityClassifier

  @doc """
  Quick check — does this prompt contain any sensitive data?

  Delegates to `Arbor.Common.SensitivityClassifier.sensitive?/1`.
  """
  @spec sensitive?(String.t()) :: boolean()
  defdelegate sensitive?(prompt), to: SensitivityClassifier

  @doc """
  Return just the routing recommendation without full classification.

  Delegates to `Arbor.Common.SensitivityClassifier.routing_for/1`.
  """
  @spec routing_for(String.t()) :: routing()
  defdelegate routing_for(prompt), to: SensitivityClassifier
end
