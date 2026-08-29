defmodule Arbor.Orchestrator.LlmRouting.ProviderFallbackCore do
  @moduledoc """
  Kept as the orchestrator-facing name; the pure core moved to
  `Arbor.Common.ProviderFallbackCore` (arbor_kernel_runtime) so the advisory
  council evaluator can share it without a dependency on this library.
  """

  alias Arbor.Common.ProviderFallbackCore, as: Core

  defdelegate resolve(provider, model, available?, specific, generic), to: Core
  defdelegate normalize_config(specific, generic), to: Core
  defdelegate normalize_candidates(list), to: Core
end
