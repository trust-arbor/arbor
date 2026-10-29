defmodule Arbor.Contracts.CapabilityDescriptor do
  @moduledoc """
  Normalized metadata for a discoverable capability, regardless of source.

  A capability descriptor represents anything an agent can do — a skill,
  an action module, a DOT pipeline, a handler, a prompt, or a plugin.
  The descriptor provides enough metadata for discovery and ranking
  without exposing internal implementation details.

  ## Fields

  - `id` — unique namespaced identifier (e.g., `"action:file.read"`, `"skill:email-triage"`)
  - `name` — human-readable display name
  - `kind` — source type: `:skill`, `:action`, `:pipeline`, `:handler`, `:prompt`, `:plugin`
  - `description` — what it does, used for keyword search
  - `tags` — searchable tags for discovery
  - `trust_required` — minimum trust tier to see/use this capability
  - `provider` — module implementing `CapabilityProvider` that owns this capability
  - `source_ref` — opaque reference back to the original (path, module name, etc.)
  - `metadata` — provider-specific extras
  """

  use TypedStruct

  @type kind :: :skill | :action | :pipeline | :handler | :prompt | :plugin | :derived

  typedstruct do
    @typedoc "A normalized capability descriptor for unified discovery"

    field(:id, String.t(), enforce: true)
    field(:name, String.t(), enforce: true)
    field(:kind, kind(), enforce: true)
    field(:description, String.t(), default: "")
    field(:tags, [String.t()], default: [])
    field(:trust_required, atom(), default: :new)
    field(:provider, module(), enforce: true)
    field(:source_ref, String.t() | nil)
    field(:metadata, map(), default: %{})
  end

  @doc """
  Creates a new descriptor, validating required fields.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required(attrs, :id),
         :ok <- validate_required(attrs, :name),
         :ok <- validate_required(attrs, :kind),
         :ok <- validate_required(attrs, :provider) do
      {:ok,
       %__MODULE__{
         id: attrs.id,
         name: attrs.name,
         kind: attrs.kind,
         description: Map.get(attrs, :description, ""),
         tags: Map.get(attrs, :tags, []),
         trust_required: Map.get(attrs, :trust_required, :new),
         provider: attrs.provider,
         source_ref: Map.get(attrs, :source_ref),
         metadata: Map.get(attrs, :metadata, %{})
       }}
    end
  end

  defp validate_required(attrs, field) do
    case Map.get(attrs, field) do
      nil -> {:error, {:missing_required_field, field}}
      _ -> :ok
    end
  end
end
