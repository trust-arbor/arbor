defmodule Arbor.Orchestrator.CodingPlan.Compilation do
  @moduledoc false

  use TypedStruct

  @type json_scalar :: nil | boolean() | number() | String.t()
  @type json_value :: json_scalar() | [json_value()] | %{String.t() => json_value()}
  @type json_object :: %{String.t() => json_value()}

  typedstruct enforce: true do
    field(:plan_map, json_object())
    field(:dot_source, String.t())
    field(:graph_hash, String.t())
    field(:compiler_version, String.t())
    field(:template_version, String.t())
    field(:plan_fingerprint, String.t())
    field(:action_catalog_digest, String.t())
    field(:initial_values, json_object())
    field(:manifest, json_object())
  end

  @doc "Return the compilation result as a string-keyed, JSON-clean map."
  @spec to_map(t()) :: json_object()
  def to_map(%__MODULE__{} = compilation) do
    %{
      "plan_map" => compilation.plan_map,
      "dot_source" => compilation.dot_source,
      "graph_hash" => compilation.graph_hash,
      "compiler_version" => compilation.compiler_version,
      "template_version" => compilation.template_version,
      "plan_fingerprint" => compilation.plan_fingerprint,
      "action_catalog_digest" => compilation.action_catalog_digest,
      "initial_values" => compilation.initial_values,
      "manifest" => compilation.manifest
    }
  end
end
