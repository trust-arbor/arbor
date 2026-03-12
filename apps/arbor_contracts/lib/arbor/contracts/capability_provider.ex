defmodule Arbor.Contracts.CapabilityProvider do
  @moduledoc """
  Behaviour for capability providers that contribute to the unified index.

  Each registry (SkillLibrary, ActionRegistry, GraphRegistry, etc.) can
  implement this behaviour to make its contents discoverable through the
  `CapabilityResolver`. Providers push descriptors into the `CapabilityIndex`
  at registration time and notify on changes.

  ## Implementing a Provider

      defmodule MyActionProvider do
        @behaviour Arbor.Contracts.CapabilityProvider

        @impl true
        def list_capabilities(_opts) do
          # Return all capabilities this provider offers
          [%CapabilityDescriptor{id: "action:my.action", ...}]
        end

        @impl true
        def describe("action:my.action") do
          {:ok, %CapabilityDescriptor{id: "action:my.action", ...}}
        end
        def describe(_), do: {:error, :not_found}

        @impl true
        def execute("action:my.action", input, _opts) do
          # Execute the capability
          {:ok, result}
        end
      end
  """

  alias Arbor.Contracts.CapabilityDescriptor

  @type opts :: keyword()

  @doc """
  List all capabilities this provider offers.

  Called during boot sync and periodic re-indexing. Should return
  descriptors for all capabilities the provider currently has.

  ## Options

  - `:trust_tier` — only return capabilities at or below this tier
  """
  @callback list_capabilities(opts()) :: [CapabilityDescriptor.t()]

  @doc """
  Describe a specific capability by its namespaced ID.

  Returns the full descriptor if found.
  """
  @callback describe(id :: String.t()) :: {:ok, CapabilityDescriptor.t()} | {:error, :not_found}

  @doc """
  Execute a capability by its namespaced ID.

  The provider is responsible for interpreting the input and returning
  a result. The resolver will have already verified trust/authorization
  before calling this.
  """
  @callback execute(id :: String.t(), input :: map(), opts()) ::
              {:ok, term()} | {:error, term()}
end
