defmodule Arbor.Contracts do
  @moduledoc """
  Boundary root for the shared primitives that stay in `arbor_kernel`.

  Domain contracts no longer live here. Each package or app owns the
  behaviours and structs for its own domain, under the same
  `Arbor.Contracts.*` module names they had before the split. What remains is
  the small set every layer shares:

  - `Arbor.Types` and `Arbor.Identifiers`
  - `Arbor.Contracts.Security.Taint`, `TaintEnvelope`, `TaintedValue` and
    `Classification`
  - `Arbor.Contracts.Coding.CanonicalJson` and `SourceInventory`
  - `Arbor.Contracts.Persistence.*`, the store port implemented by
    Capabilities, Trust, Memory and the Persistence host
  - `Arbor.Contracts.Extension.Envelope`, verified at boot by Kernel Runtime
    and at activation by Capabilities
  """

  use Boundary,
    top_level?: true,
    deps: [Arbor.Types, Arbor.Identifiers, Jason, TypedStruct],
    exports: :all

  @doc """
  Lists the contract modules that remain in `arbor_kernel`.

  `Arbor.Contracts.Census` reads this list from source to mark registry
  membership, so keep it a literal list.
  """
  @spec list_contracts() :: [module()]
  def list_contracts do
    [
      Arbor.Contracts.Coding.CanonicalJson,
      Arbor.Contracts.Coding.SourceInventory,
      Arbor.Contracts.Extension.Envelope,
      Arbor.Contracts.Feature,
      Arbor.Contracts.Persistence.AppendOperation,
      Arbor.Contracts.Persistence.Filter,
      Arbor.Contracts.Persistence.Record,
      Arbor.Contracts.Persistence.Revision,
      Arbor.Contracts.Persistence.Store,
      Arbor.Contracts.Persistence.VectorMatch,
      Arbor.Contracts.Persistence.VectorOperation,
      Arbor.Contracts.Persistence.VectorReceipt,
      Arbor.Contracts.Persistence.VectorRecord,
      Arbor.Contracts.Persistence.VectorValidation,
      Arbor.Contracts.Security.Classification,
      Arbor.Contracts.Security.Sanitizer,
      Arbor.Contracts.Security.Taint,
      Arbor.Contracts.Security.TaintEnvelope,
      Arbor.Contracts.Security.TaintedValue
    ]
  end
end
