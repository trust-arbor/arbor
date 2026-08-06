defmodule Arbor.Memory.StrictEmbeddingInput do
  @moduledoc false

  # Builds closed strict embedding inputs for Index / IndexOps / MemoryStore owners.

  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Memory.MemoryStoreIdentity

  @index_namespace "memory_index"
  @default_category "untyped"

  @doc "Index source namespace constant."
  @spec index_namespace() :: String.t()
  def index_namespace, do: @index_namespace

  @doc "Default category when no type is supplied."
  @spec default_category() :: String.t()
  def default_category, do: @default_category

  @doc "Category string for an Index entry type."
  @spec category_for_type(term()) :: String.t()
  def category_for_type(nil), do: @default_category
  def category_for_type(type) when is_atom(type), do: Atom.to_string(type)
  def category_for_type(type) when is_binary(type) and type != "", do: type
  def category_for_type(_), do: @default_category

  @doc "Build a closed Index insert input."
  @spec index_insert(map()) :: map()
  def index_insert(attrs) do
    entry_id = Map.fetch!(attrs, :entry_id)
    metadata = payload_metadata(Map.get(attrs, :metadata, %{}))
    type = Map.get(metadata, :type) || Map.get(metadata, "type")

    %{
      kind: :insert,
      id: entry_id,
      agent_id: Map.fetch!(attrs, :agent_id),
      source_namespace: @index_namespace,
      source_key: entry_id,
      payload: %{
        "content" => Map.fetch!(attrs, :content),
        "metadata" => stringify_keys(metadata)
      },
      vector: Map.fetch!(attrs, :vector),
      category: category_for_type(type),
      generation: 0,
      revision: 0,
      tombstone: false,
      expected_generation: nil,
      expected_revision: nil,
      model_evidence: Map.fetch!(attrs, :model_evidence),
      taint: Map.get(attrs, :taint, TaintEnvelope.missing_fallback())
    }
  end

  @doc "Build a closed Index delete input from a fetched decoded view."
  @spec index_delete(map()) :: map()
  def index_delete(view) when is_map(view) do
    %{
      kind: :delete,
      id: view_field(view, :id),
      agent_id: view_field(view, :agent_id),
      source_namespace: view_field(view, :source_namespace),
      source_key: view_field(view, :source_key),
      payload: view_field(view, :body),
      vector: view_field(view, :vector),
      category: view_field(view, :category),
      generation: view_field(view, :generation),
      revision: view_field(view, :revision),
      tombstone: false,
      expected_generation: view_field(view, :generation),
      expected_revision: view_field(view, :revision),
      model_evidence: model_evidence_from_view(view),
      taint: view_field(view, :taint)
    }
  end

  @doc "Build a closed MemoryStore insert input. source_key remains the original key."
  @spec memory_store_insert(map()) :: map()
  def memory_store_insert(attrs) do
    agent_id = Map.fetch!(attrs, :agent_id)
    namespace = Map.fetch!(attrs, :namespace)
    key = Map.fetch!(attrs, :key)
    type = Map.get(attrs, :type)

    %{
      kind: :insert,
      id: MemoryStoreIdentity.row_id(agent_id, namespace, key),
      agent_id: agent_id,
      source_namespace: namespace,
      source_key: key,
      payload: %{
        "content" => Map.fetch!(attrs, :content),
        "metadata" => stringify_keys(Map.get(attrs, :metadata, %{}))
      },
      vector: Map.fetch!(attrs, :vector),
      category: category_for_type(type),
      generation: 0,
      revision: 0,
      tombstone: false,
      expected_generation: nil,
      expected_revision: nil,
      model_evidence: Map.fetch!(attrs, :model_evidence),
      taint: Map.get(attrs, :taint, TaintEnvelope.missing_fallback())
    }
  end

  @doc "Build a fenced MemoryStore update or reinsert from an exact fetched view."
  @spec memory_store_replace(map(), map()) :: map()
  def memory_store_replace(attrs, view) when is_map(attrs) and is_map(view) do
    agent_id = Map.fetch!(attrs, :agent_id)
    namespace = Map.fetch!(attrs, :namespace)
    key = Map.fetch!(attrs, :key)
    type = Map.get(attrs, :type)

    %{
      kind: if(view_field(view, :tombstone), do: :reinsert, else: :update),
      id: MemoryStoreIdentity.row_id(agent_id, namespace, key),
      agent_id: agent_id,
      source_namespace: namespace,
      source_key: key,
      payload: %{
        "content" => Map.fetch!(attrs, :content),
        "metadata" => stringify_keys(Map.get(attrs, :metadata, %{}))
      },
      vector: Map.fetch!(attrs, :vector),
      category: category_for_type(type),
      generation: view_field(view, :generation),
      revision: view_field(view, :revision),
      tombstone: false,
      expected_generation: view_field(view, :generation),
      expected_revision: view_field(view, :revision),
      model_evidence: Map.fetch!(attrs, :model_evidence),
      taint: Map.get(attrs, :taint, TaintEnvelope.missing_fallback())
    }
  end

  defp model_evidence_from_view(view) when is_map(view) do
    {:model_id, view_field(view, :model_id)}
  end

  defp view_field(view, key) do
    case Map.fetch(view, key) do
      {:ok, value} -> value
      :error -> Map.get(view, Atom.to_string(key))
    end
  end

  # Caller metadata is payload only. Even authority-named keys such as `id`,
  # `model`, or `taint` remain ordinary body data because the owner constructs
  # every authoritative top-level field independently.
  defp payload_metadata(metadata) when is_map(metadata), do: metadata
  defp payload_metadata(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, Atom.to_string(k), stringify_value(v))
      {k, v}, acc when is_binary(k) -> Map.put(acc, k, stringify_value(v))
      _, acc -> acc
    end)
  end

  defp stringify_value(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)
  defp stringify_value(v) when is_map(v), do: stringify_keys(v)
  defp stringify_value(_), do: nil
end
