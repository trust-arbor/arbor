defmodule Arbor.Orchestrator.CodingUriCatalog do
  @moduledoc """
  Fixed capability URI projection for the coding reconciliation feature.

  The host explicitly admits this provider into Security's URI registry. The
  registry owns validation and membership; this feature owns its two prefixes.
  Registering a prefix does not grant a capability or bypass reconciliation's
  source-owned authority checks.

  The Arbor host lists this module in Security's trusted
  `:uri_registration_providers` and `:uri_bootstrap_providers`. Security owns
  full-profile startup activation and registry-restart replay. Activation-only
  startup does not load this feature provider.
  """

  @behaviour Arbor.Security.Contracts.UriPrefixProvider

  @impl true
  @spec capability_uri_prefixes() :: [String.t()]
  def capability_uri_prefixes do
    [
      "arbor://coding/reconciliation/read",
      "arbor://coding/reconciliation/apply"
    ]
  end
end
