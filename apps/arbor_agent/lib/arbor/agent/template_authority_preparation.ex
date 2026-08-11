defmodule Arbor.Agent.TemplateAuthorityPreparation do
  @moduledoc false

  # Internal C3B2/C3B3 handoff envelope for frozen template-authority preparation.
  # Holds the authoritative profile Record (transient private evidence), closed
  # freeze facts, the canonical governed profile mutation, and the privately
  # recomputed replay commitment. Never public facade material; never enter
  # Engine context, status/report, log, signal, or telemetry. Inspect is
  # permanently redacted.
  #
  # Construction is closed: exact atom attrs only, CAS aligned to the Record,
  # Policy-validated canonical desired_authority with non-nil provenance layer,
  # exact shared-admitted root, already-canonical effective capabilities
  # (raw === re-derived), and independently recomputed commitment via
  # ProfileAuthorityMutationCore.commit_prepared_mutation/2.

  alias Arbor.Agent.ProfileAuthorityMutationCore
  alias Arbor.Agent.TemplateAuthorityCapabilityProjection
  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Contracts.Persistence.Record

  @enforce_keys [
    :record,
    :profile_cas,
    :desired_authority,
    :repo_root,
    :effective_capabilities,
    :governed,
    :replay_commitment
  ]
  defstruct @enforce_keys

  @attr_keys MapSet.new([
               :record,
               :profile_cas,
               :desired_authority,
               :repo_root,
               :effective_capabilities
             ])
  @profile_cas_keys MapSet.new(["record_id", "generation", "revision"])
  @desired_keys MapSet.new(["envelope", "declaration_digest", "provenance"])
  @provenance_keys MapSet.new(["name", "layer"])
  @provenance_layers MapSet.new(["user", "shipped", "legacy_json"])
  @max_caps 256

  @type profile_cas :: %{required(String.t()) => String.t() | pos_integer()}
  @type desired_authority :: %{required(String.t()) => map() | String.t()}
  @type governed :: %{required(String.t()) => term()}
  @type commitment :: %{required(String.t()) => term()}

  @type t :: %__MODULE__{
          record: Record.t(),
          profile_cas: profile_cas(),
          desired_authority: desired_authority(),
          repo_root: String.t(),
          effective_capabilities: [map()],
          governed: governed(),
          replay_commitment: commitment()
        }

  @doc false
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_list(attrs) do
    if keyword_attrs?(attrs) do
      new(Map.new(attrs))
    else
      {:error, :invalid_preparation}
    end
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- require_exact_attr_keys(attrs),
         {:ok, record} <- require_record(Map.fetch!(attrs, :record)),
         {:ok, profile_cas} <-
           require_profile_cas_matching(Map.fetch!(attrs, :profile_cas), record),
         {:ok, desired} <- require_canonical_desired(Map.fetch!(attrs, :desired_authority)),
         {:ok, repo_root} <- require_exact_canonical_root(Map.fetch!(attrs, :repo_root)),
         {:ok, caps} <-
           require_exact_canonical_caps(
             Map.fetch!(attrs, :effective_capabilities),
             desired,
             record,
             repo_root
           ),
         {:ok, governed} <- derive_governed(desired),
         {:ok, %{commitment: commitment}} <-
           ProfileAuthorityMutationCore.commit_prepared_mutation(record, governed) do
      {:ok,
       %__MODULE__{
         record: record,
         profile_cas: profile_cas,
         desired_authority: desired,
         repo_root: repo_root,
         effective_capabilities: caps,
         governed: governed,
         replay_commitment: commitment
       }}
    else
      {:error, :invalid_preparation} = err ->
        err

      {:error, _} ->
        {:error, :invalid_preparation}

      _ ->
        {:error, :invalid_preparation}
    end
  end

  def new(_), do: {:error, :invalid_preparation}

  @doc false
  @spec record(t()) :: Record.t()
  def record(%__MODULE__{record: record}), do: record

  @doc false
  @spec profile_cas(t()) :: profile_cas()
  def profile_cas(%__MODULE__{profile_cas: cas}), do: cas

  @doc false
  @spec desired_authority(t()) :: desired_authority()
  def desired_authority(%__MODULE__{desired_authority: desired}), do: desired

  @doc false
  @spec repo_root(t()) :: String.t()
  def repo_root(%__MODULE__{repo_root: root}), do: root

  @doc false
  @spec effective_capabilities(t()) :: [map()]
  def effective_capabilities(%__MODULE__{effective_capabilities: caps}), do: caps

  @doc false
  @spec replay_commitment(t()) :: commitment()
  def replay_commitment(%__MODULE__{replay_commitment: cmt}), do: cmt

  @doc false
  @spec governed(t()) :: governed()
  def governed(%__MODULE__{governed: governed}), do: governed

  defp keyword_attrs?(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      keys = Keyword.keys(attrs)

      length(keys) == MapSet.size(@attr_keys) and
        MapSet.equal?(MapSet.new(keys), @attr_keys)
    else
      false
    end
  end

  defp require_exact_attr_keys(attrs) do
    keys = Map.keys(attrs) |> MapSet.new()

    if MapSet.equal?(keys, @attr_keys) and Enum.all?(Map.keys(attrs), &is_atom/1) do
      :ok
    else
      {:error, :invalid_preparation}
    end
  end

  defp require_record(%Record{} = record) do
    with true <- is_binary(record.id) and record.id != "",
         true <- is_binary(record.key) and record.key != "",
         true <- is_map(record.data) and not is_struct(record.data),
         true <- is_integer(record.generation) and record.generation >= 1,
         true <- is_integer(record.revision) and record.revision >= 1,
         true <- not Map.has_key?(record.data, :agent_id),
         agent_id when is_binary(agent_id) and agent_id != "" and agent_id === record.key <-
           record.data["agent_id"] do
      {:ok, record}
    else
      _ -> {:error, :invalid_preparation}
    end
  end

  defp require_record(_), do: {:error, :invalid_preparation}

  defp require_profile_cas_matching(cas, %Record{} = record) when is_map(cas) do
    with :ok <- closed_string_keyset(cas, @profile_cas_keys),
         id when is_binary(id) and id == record.id <- cas["record_id"],
         gen when is_integer(gen) and gen == record.generation and gen >= 1 <- cas["generation"],
         rev when is_integer(rev) and rev == record.revision and rev >= 1 <- cas["revision"] do
      {:ok, %{"record_id" => id, "generation" => gen, "revision" => rev}}
    else
      _ -> {:error, :invalid_preparation}
    end
  end

  defp require_profile_cas_matching(_, _), do: {:error, :invalid_preparation}

  defp require_canonical_desired(desired) when is_map(desired) and not is_struct(desired) do
    with :ok <- closed_string_keyset(desired, @desired_keys),
         {:ok, validated} <- TemplateAuthorityPolicy.validate_envelope(desired["envelope"]),
         true <- desired["envelope"] === validated,
         true <- desired["declaration_digest"] === validated["digest"],
         {:ok, derived_prov} <- derived_provenance(validated),
         true <- desired["provenance"] === derived_prov do
      {:ok,
       %{
         "envelope" => validated,
         "declaration_digest" => validated["digest"],
         "provenance" => derived_prov
       }}
    else
      _ -> {:error, :invalid_preparation}
    end
  end

  defp require_canonical_desired(_), do: {:error, :invalid_preparation}

  # Phase 4B rejects nil persisted layers; a nil-layer successor can never be
  # "current". Fail closed here so Preparation never freezes that state.
  defp derived_provenance(validated) do
    snap = TemplateAuthorityPolicy.snapshot(validated)
    prov = TemplateAuthorityPolicy.provenance(snap)
    name = Map.get(prov, "name") || Map.get(snap, "template")
    layer = Map.get(prov, "layer")

    derived = %{"name" => name, "layer" => layer}

    with :ok <- closed_string_keyset(derived, @provenance_keys),
         true <- is_binary(name) and name != "",
         true <- is_binary(layer) and MapSet.member?(@provenance_layers, layer) do
      {:ok, derived}
    else
      _ -> :error
    end
  end

  defp derive_governed(desired) when is_map(desired) do
    envelope = desired["envelope"]
    source = desired["provenance"]
    meta_key = TemplateAuthorityPolicy.metadata_key()

    with true <- is_map(envelope),
         snap when is_map(snap) <- TemplateAuthorityPolicy.snapshot(envelope),
         template when is_binary(template) and template != "" <-
           desired["provenance"]["name"],
         true <- snap["template"] === template,
         declared when is_list(declared) <- TemplateAuthorityPolicy.capabilities(snap),
         snap_prov when is_map(snap_prov) <- TemplateAuthorityPolicy.provenance(snap),
         true <- snap_prov === source do
      {:ok,
       %{
         "template" => template,
         "initial_capabilities" => declared,
         "metadata" => %{
           meta_key => envelope,
           "template_source" => source
         }
       }}
    else
      _ -> {:error, :invalid_preparation}
    end
  end

  defp derive_governed(_), do: {:error, :invalid_preparation}

  defp require_exact_canonical_root(root) when is_binary(root) do
    case TemplateAuthorityCapabilityProjection.admit_canonical_repo_root(root) do
      {:ok, admitted} when admitted === root ->
        {:ok, admitted}

      _ ->
        {:error, :invalid_preparation}
    end
  end

  defp require_exact_canonical_root(_), do: {:error, :invalid_preparation}

  defp require_exact_canonical_caps(caps, desired, %Record{} = record, repo_root)
       when is_list(caps) do
    with :ok <- require_raw_cap_list(caps),
         {:ok, derived} <- derive_caps(desired, record.key, repo_root),
         true <- derived === caps do
      {:ok, derived}
    else
      _ -> {:error, :invalid_preparation}
    end
  end

  defp require_exact_canonical_caps(_, _, _, _), do: {:error, :invalid_preparation}

  defp require_raw_cap_list(caps) when is_list(caps) do
    case walk_list(caps, 0, @max_caps) do
      :ok -> require_binary_keyed_maps(caps)
      _ -> {:error, :invalid_preparation}
    end
  end

  defp walk_list([], _n, _max), do: :ok
  defp walk_list([_ | t], n, max) when is_list(t) and n < max, do: walk_list(t, n + 1, max)
  defp walk_list(_, _, _), do: :error

  defp require_binary_keyed_maps([]), do: :ok

  defp require_binary_keyed_maps([cap | rest]) when is_list(rest) do
    if is_map(cap) and not is_struct(cap) and Enum.all?(Map.keys(cap), &is_binary/1) do
      require_binary_keyed_maps(rest)
    else
      {:error, :invalid_preparation}
    end
  end

  defp require_binary_keyed_maps(_), do: {:error, :invalid_preparation}

  defp derive_caps(desired, target_agent_id, repo_root)
       when is_map(desired) and is_binary(target_agent_id) do
    envelope = desired["envelope"]

    with true <- is_map(envelope),
         snap when is_map(snap) <- TemplateAuthorityPolicy.snapshot(envelope),
         declared when is_list(declared) <- TemplateAuthorityPolicy.capabilities(snap),
         {:ok, derived} <-
           TemplateAuthorityCapabilityProjection.project_normalized(declared, target_agent_id,
             repo_root: repo_root
           ) do
      {:ok, derived}
    else
      _ -> :error
    end
  end

  defp derive_caps(_, _, _), do: :error

  defp closed_string_keyset(map, expected) when is_map(map) do
    keys = Map.keys(map) |> MapSet.new()

    if MapSet.equal?(keys, expected) and Enum.all?(Map.keys(map), &is_binary/1) do
      :ok
    else
      {:error, :invalid_preparation}
    end
  end

  defp closed_string_keyset(_, _), do: {:error, :invalid_preparation}
end

defimpl Inspect, for: Arbor.Agent.TemplateAuthorityPreparation do
  def inspect(%Arbor.Agent.TemplateAuthorityPreparation{}, _opts) do
    "#Arbor.Agent.TemplateAuthorityPreparation<redacted>"
  end
end
