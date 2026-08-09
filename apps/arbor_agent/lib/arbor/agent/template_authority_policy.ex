defmodule Arbor.Agent.TemplateAuthorityPolicy do
  @moduledoc """
  Generic **authority-only** template policy envelope and shared normalization.

  Snapshots a template's declared capabilities and trust preset into a bounded,
  JSON-clean envelope with a deterministic semantic digest. Unlike
  `Arbor.Agent.ExactTemplatePolicy`, this module:

  - does **not** require exact runtime / tool / sandbox / capability / trust
    policy markers
  - does **not** expand repo-scoped or session-turn resources
  - does **not** bind a repo root or sandbox level
  - never exposes capability IDs, secrets, or absolute source paths in the
    semantic snapshot / digest

  Public normalization (`normalize_authority_view/1`, `normalize_capabilities/1`,
  `normalize_trust_preset/1`) is the **single** bounded path for both declared
  template data and live capability views (including Capability structs).

  This is a pure, read-only foundation. It does not grant, revoke, write trust,
  persist profiles, or open Gateway/MCP paths.
  """

  alias Arbor.Contracts.Security.{CapabilityUri, TrustRule}

  @metadata_key "template_authority_policy"
  @snapshot_version 1
  @known_constraint_keys ["rate_limit", "requires_approval"]
  @trust_modes ~w(block ask allow auto)
  @provenance_layers ~w(user shipped legacy_json)
  @max_capabilities 256
  @max_trust_rules 256
  @max_resource_bytes 1_024
  @max_uri_bytes 1_024
  @max_name_bytes 256
  @max_constraint_key_bytes 256

  @type envelope :: map()
  @type snapshot :: map()
  @type authority_view :: %{
          required(String.t()) => term()
        }

  @doc """
  Build an authority-only envelope from template name + template data.

  Accepts mixed atom/string keys. Does not require ExactTemplatePolicy markers.
  Optional opts:

    * `:provenance` — override provenance map (`name` / `layer` only; paths stripped)
  """
  @spec build(String.t(), map(), keyword()) :: {:ok, envelope()} | {:error, term()}
  def build(template_name, data, opts \\ [])

  def build(template_name, data, opts)
      when is_binary(template_name) and is_map(data) and is_list(opts) do
    with :ok <- validate_build_options(opts),
         {:ok, template_name} <- normalize_name(template_name, :template_name_invalid),
         :ok <- validate_template_name(template_name, data),
         {:ok, capabilities} <- normalize_capabilities(value(data, "required_capabilities")),
         {:ok, trust_preset} <- normalize_trust_preset(value(data, "trust_preset")),
         {:ok, provenance} <- normalize_provenance(template_name, data, opts) do
      snapshot = %{
        "version" => @snapshot_version,
        "template" => template_name,
        "capabilities" => capabilities,
        "trust_preset" => trust_preset,
        "provenance" => provenance
      }

      {:ok,
       %{
         "version" => @snapshot_version,
         "kind" => "template_authority_policy",
         "snapshot" => snapshot,
         "digest" => snapshot_digest(snapshot)
       }}
    end
  end

  def build(_template_name, _data, _opts), do: error(:invalid_build_input)

  @doc """
  Normalize a declared or live authority view to a closed
  `%{"capabilities" => ..., "trust_preset" => ...}` map.

  Full envelopes (`snapshot` + `digest`) are validated via `validate_envelope/1`
  — the supplied digest is verified, never discarded or replaced. Raw views
  (and Capability-struct live rows) share the same bounded capability/trust
  normalization as template builds.
  """
  @spec normalize_authority_view(map()) :: {:ok, authority_view()} | {:error, term()}
  def normalize_authority_view(input) when is_map(input) do
    cond do
      envelope_candidate?(input) ->
        # Any envelope marker is an envelope claim: verify the complete shape
        # and supplied digest rather than falling through to raw normalization.
        with {:ok, envelope} <- validate_envelope(input) do
          snap = snapshot(envelope)

          {:ok,
           %{
             "capabilities" => capabilities(snap),
             "trust_preset" => trust_preset(snap)
           }}
        end

      true ->
        normalize_raw_authority(input)
    end
  end

  def normalize_authority_view(_input), do: error(:invalid_authority_view)

  @doc """
  Normalize a capability list from declared template data or live grants.

  Accepts maps and Capability-like structs (`resource` / `resource_uri`).
  Identical same-resource duplicates are deduped; conflicting constraints for
  the same resource are rejected. Order never chooses authority.
  """
  @spec normalize_capabilities(term()) :: {:ok, [map()]} | {:error, term()}
  def normalize_capabilities(nil), do: {:ok, []}

  def normalize_capabilities(capabilities) when is_list(capabilities) do
    if length(capabilities) > @max_capabilities do
      error(:capabilities_too_many)
    else
      capabilities
      |> Enum.reduce_while({:ok, %{}}, fn capability, {:ok, by_resource} ->
        case normalize_capability(capability) do
          {:ok, normalized} ->
            resource = normalized["resource"]

            case Map.fetch(by_resource, resource) do
              :error ->
                {:cont, {:ok, Map.put(by_resource, resource, normalized)}}

              {:ok, ^normalized} ->
                {:cont, {:ok, by_resource}}

              {:ok, existing} ->
                if existing["constraints"] == normalized["constraints"] do
                  {:cont, {:ok, by_resource}}
                else
                  {:halt, error({:capability_resource_conflict, resource})}
                end
            end

          {:error, _} = failure ->
            {:halt, failure}
        end
      end)
      |> case do
        {:ok, by_resource} ->
          sorted =
            by_resource
            |> Enum.sort_by(fn {resource, _} -> resource end)
            |> Enum.map(fn {_resource, cap} -> cap end)

          {:ok, sorted}

        {:error, _} = failure ->
          failure
      end
    end
  end

  def normalize_capabilities(_capabilities), do: error(:capabilities_missing_or_invalid)

  @doc """
  Normalize a trust preset (`baseline` + `rules`).

  Trust URIs are canonicalized; URIs that collapse to one key with conflicting
  modes are rejected. Identical duplicates are accepted. Order never chooses
  authority.
  """
  @spec normalize_trust_preset(term()) :: {:ok, map()} | {:error, term()}
  def normalize_trust_preset(nil), do: error(:trust_preset_missing_or_invalid)

  def normalize_trust_preset(preset) when is_map(preset) and not is_struct(preset) do
    with {:ok, baseline} <- normalize_trust_mode(value(preset, "baseline")),
         {:ok, rules} <- normalize_trust_rules(value(preset, "rules")) do
      {:ok, %{"baseline" => baseline, "rules" => rules}}
    end
  end

  def normalize_trust_preset(_preset), do: error(:trust_preset_missing_or_invalid)

  @doc "Read a stored authority envelope from profile metadata, if present."
  @spec from_metadata(map()) :: {:ok, envelope()} | :not_marked | {:error, term()}
  def from_metadata(metadata) when is_map(metadata) do
    case fetch_value(metadata, @metadata_key) do
      :error ->
        :not_marked

      {:ok, envelope} when is_map(envelope) ->
        validate_envelope(envelope)

      {:ok, _other} ->
        error(:invalid_profile_metadata)
    end
  end

  def from_metadata(_metadata), do: :not_marked

  @doc """
  Validate a previously built envelope (version, shape, **supplied digest**).

  Re-normalizes the snapshot for closed JSON-clean form, then verifies the
  caller's digest against that form. The supplied digest is never discarded or
  rewritten. It is a recomputable semantic-integrity and compare-and-swap value,
  not authentication against a caller that can replace both content and digest.
  """
  @spec validate_envelope(map()) :: {:ok, envelope()} | {:error, term()}
  def validate_envelope(envelope) when is_map(envelope) do
    version = value(envelope, "version")
    kind = normalize_kind(value(envelope, "kind"))
    snapshot = value(envelope, "snapshot")
    digest = value(envelope, "digest")

    cond do
      not is_map(snapshot) ->
        error(:snapshot_missing_or_invalid)

      not valid_digest?(digest) ->
        error(:digest_missing_or_invalid)

      version != @snapshot_version ->
        error({:unsupported_snapshot_version, version})

      kind != "template_authority_policy" ->
        error({:unsupported_envelope_kind, kind})

      true ->
        with {:ok, normalized_snapshot} <- normalize_snapshot(snapshot) do
          expected = snapshot_digest(normalized_snapshot)

          # Keep the caller's digest bytes only when they match the semantic form.
          if expected == digest do
            {:ok,
             %{
               "version" => @snapshot_version,
               "kind" => "template_authority_policy",
               "snapshot" => normalized_snapshot,
               "digest" => digest
             }}
          else
            error(:authority_snapshot_digest_mismatch)
          end
        end
    end
  end

  def validate_envelope(_envelope), do: error(:envelope_invalid)

  @doc "Put the envelope under the authority-policy metadata key."
  @spec put_metadata(map(), envelope()) :: map()
  def put_metadata(metadata, envelope) when is_map(metadata) and is_map(envelope) do
    Map.put(metadata, @metadata_key, envelope)
  end

  @spec marked?(map()) :: boolean()
  def marked?(metadata) when is_map(metadata) do
    Map.has_key?(metadata, @metadata_key) or Map.has_key?(metadata, :template_authority_policy)
  end

  def marked?(_metadata), do: false

  @spec snapshot(envelope()) :: snapshot() | nil
  def snapshot(envelope), do: value(envelope, "snapshot")

  @spec digest(envelope()) :: String.t() | nil
  def digest(envelope), do: value(envelope, "digest")

  @spec capabilities(snapshot()) :: [map()]
  def capabilities(snapshot) when is_map(snapshot), do: value(snapshot, "capabilities") || []
  def capabilities(_snapshot), do: []

  @spec trust_preset(snapshot()) :: map()
  def trust_preset(snapshot) when is_map(snapshot), do: value(snapshot, "trust_preset") || %{}
  def trust_preset(_snapshot), do: %{}

  @spec provenance(snapshot()) :: map()
  def provenance(snapshot) when is_map(snapshot), do: value(snapshot, "provenance") || %{}
  def provenance(_snapshot), do: %{}

  @doc "Metadata key used when embedding the envelope in profile metadata."
  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @doc "Snapshot schema version."
  @spec snapshot_version() :: pos_integer()
  def snapshot_version, do: @snapshot_version

  # ---------------------------------------------------------------------------
  # Envelope / raw authority detection
  # ---------------------------------------------------------------------------

  defp envelope_candidate?(input) when is_map(input) do
    match?({:ok, _}, fetch_value(input, "snapshot")) or
      match?({:ok, _}, fetch_value(input, "digest"))
  end

  defp valid_digest?(digest) when is_binary(digest) do
    byte_size(digest) == 64 and String.match?(digest, ~r/^[0-9a-f]{64}$/)
  end

  defp valid_digest?(_digest), do: false

  defp normalize_raw_authority(input) when is_map(input) do
    caps = value(input, "capabilities") || value(input, "required_capabilities")
    trust = value(input, "trust_preset") || value(input, "trust")

    with {:ok, capabilities} <- normalize_capabilities(caps),
         {:ok, trust_preset} <- normalize_trust_preset(trust) do
      {:ok, %{"capabilities" => capabilities, "trust_preset" => trust_preset}}
    end
  end

  # ---------------------------------------------------------------------------
  # Snapshot normalization (envelope path)
  # ---------------------------------------------------------------------------

  defp normalize_snapshot(snapshot) when is_map(snapshot) do
    with :ok <- require_snapshot_version(value(snapshot, "version")),
         {:ok, template} <- normalize_name(value(snapshot, "template"), :template_name_invalid),
         {:ok, capabilities} <- normalize_capabilities(value(snapshot, "capabilities")),
         {:ok, trust_preset} <- normalize_trust_preset(value(snapshot, "trust_preset")),
         {:ok, provenance} <-
           normalize_provenance_map(value(snapshot, "provenance"), template) do
      {:ok,
       %{
         "version" => @snapshot_version,
         "template" => template,
         "capabilities" => capabilities,
         "trust_preset" => trust_preset,
         "provenance" => provenance
       }}
    end
  end

  defp normalize_snapshot(_snapshot), do: error(:snapshot_missing_or_invalid)

  defp require_snapshot_version(@snapshot_version), do: :ok
  defp require_snapshot_version(other), do: error({:unsupported_snapshot_version, other})

  defp normalize_kind(nil), do: nil
  defp normalize_kind("template_authority_policy"), do: "template_authority_policy"
  defp normalize_kind(:template_authority_policy), do: "template_authority_policy"
  defp normalize_kind(other), do: other

  defp normalize_name(name, reason_tag) when is_atom(name),
    do: normalize_name(Atom.to_string(name), reason_tag)

  defp normalize_name(name, reason_tag) when is_binary(name) do
    if name != "" and String.valid?(name) and byte_size(name) <= @max_name_bytes and
         not String.contains?(name, <<0>>) do
      {:ok, name}
    else
      error(reason_tag)
    end
  end

  defp normalize_name(_name, reason_tag), do: error(reason_tag)

  defp validate_template_name(template_name, data) do
    case value(data, "name") do
      nil ->
        :ok

      other ->
        case normalize_name(other, :template_name_invalid) do
          {:ok, ^template_name} -> :ok
          {:ok, other_name} -> error({:template_name_mismatch, other_name, template_name})
          {:error, _} = failure -> failure
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Capability normalization
  # ---------------------------------------------------------------------------

  defp normalize_capability(capability) when is_struct(capability) do
    # Capability structs and other live grant structs expose atom fields.
    normalize_capability(Map.from_struct(capability))
  end

  defp normalize_capability(capability) when is_map(capability) do
    resource = value(capability, "resource") || value(capability, "resource_uri")

    with {:ok, resource} <- normalize_resource(resource),
         {:ok, constraints} <- normalize_constraints(value(capability, "constraints")) do
      # Authority identity is resource + constraints only — drop ids, source,
      # description, metadata, secrets.
      {:ok, %{"resource" => resource, "constraints" => constraints}}
    end
  end

  defp normalize_capability(_capability), do: error(:capability_invalid)

  defp normalize_resource(resource) when is_atom(resource),
    do: normalize_resource(Atom.to_string(resource))

  defp normalize_resource(resource) when is_binary(resource) do
    if resource != "" and String.valid?(resource) and byte_size(resource) <= @max_resource_bytes and
         not String.contains?(resource, <<0>>) and valid_capability_uri?(resource) do
      {:ok, resource}
    else
      error(:capability_resource_missing_or_invalid)
    end
  end

  defp normalize_resource(_resource), do: error(:capability_resource_missing_or_invalid)

  defp normalize_constraints(nil), do: {:ok, %{}}

  defp normalize_constraints(constraints)
       when is_map(constraints) and not is_struct(constraints) do
    constraints
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- normalize_constraint_key(key),
           {:ok, value} <- normalize_constraint_value(key, value) do
        case Map.fetch(acc, key) do
          :error ->
            {:cont, {:ok, Map.put(acc, key, value)}}

          {:ok, ^value} ->
            {:cont, {:ok, acc}}

          {:ok, _other} ->
            {:halt, error(:capability_constraints_invalid)}
        end
      else
        {:error, _} = failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, cleaned} ->
        # Deterministic key order for digests; never depend on map iteration.
        {:ok, cleaned |> Enum.sort_by(fn {k, _} -> k end) |> Map.new()}

      failure ->
        failure
    end
  end

  defp normalize_constraints(_constraints), do: error(:capability_constraints_invalid)

  defp normalize_constraint_key(key) when is_atom(key),
    do: normalize_constraint_key(Atom.to_string(key))

  defp normalize_constraint_key(key) when is_binary(key) do
    if key != "" and String.valid?(key) and byte_size(key) <= @max_constraint_key_bytes and
         not String.contains?(key, <<0>>) do
      if key in @known_constraint_keys do
        {:ok, key}
      else
        error({:unsupported_capability_constraints, [key]})
      end
    else
      error(:capability_constraints_invalid)
    end
  end

  defp normalize_constraint_key(_key), do: error(:capability_constraints_invalid)

  defp normalize_constraint_value("rate_limit", value)
       when is_integer(value) and value >= 0 and value <= 1_000_000,
       do: {:ok, value}

  defp normalize_constraint_value("requires_approval", value) when is_boolean(value),
    do: {:ok, value}

  defp normalize_constraint_value(_key, _value), do: error(:capability_constraints_invalid)

  # ---------------------------------------------------------------------------
  # Trust normalization
  # ---------------------------------------------------------------------------

  defp normalize_trust_rules(nil), do: {:ok, %{}}

  defp normalize_trust_rules(rules) when is_map(rules) and not is_struct(rules) do
    if map_size(rules) > @max_trust_rules do
      error(:trust_rules_too_many)
    else
      Enum.reduce_while(rules, {:ok, %{}}, fn {uri, mode}, {:ok, acc} ->
        case normalize_trust_rule(uri, mode) do
          {:ok, normalized_uri, normalized_mode} ->
            case Map.fetch(acc, normalized_uri) do
              :error ->
                {:cont, {:ok, Map.put(acc, normalized_uri, normalized_mode)}}

              {:ok, ^normalized_mode} ->
                {:cont, {:ok, acc}}

              {:ok, other_mode} ->
                {:halt,
                 error({:trust_rule_conflict, normalized_uri, other_mode, normalized_mode})}
            end

          {:error, _} = failure ->
            {:halt, failure}
        end
      end)
      |> case do
        {:ok, normalized} ->
          {:ok, normalized |> Enum.sort_by(fn {uri, _} -> uri end) |> Map.new()}

        {:error, _} = failure ->
          failure
      end
    end
  end

  defp normalize_trust_rules(_rules), do: error(:trust_rules_missing_or_invalid)

  defp normalize_trust_rule(uri, mode) do
    with {:ok, uri} <- normalize_trust_uri(uri),
         {:ok, mode} <- normalize_trust_mode(mode) do
      {:ok, uri, mode}
    end
  end

  defp normalize_trust_uri(uri) when is_atom(uri), do: normalize_trust_uri(Atom.to_string(uri))

  defp normalize_trust_uri(uri) when is_binary(uri) do
    if uri != "" and String.valid?(uri) and byte_size(uri) <= @max_uri_bytes and
         not String.contains?(uri, <<0>>) and String.starts_with?(uri, "arbor://") do
      canonical =
        if TrustRule.glob?(uri) do
          TrustRule.canonicalize(uri)
        else
          uri
        end

      if canonical != "" and not TrustRule.glob?(canonical) and valid_capability_uri?(canonical) do
        {:ok, canonical}
      else
        error(:trust_rule_uri_invalid)
      end
    else
      error(:trust_rule_uri_invalid)
    end
  end

  defp normalize_trust_uri(_uri), do: error(:trust_rule_uri_invalid)

  defp normalize_trust_mode(mode) when mode in @trust_modes, do: {:ok, mode}

  defp normalize_trust_mode(mode) when mode in [:block, :ask, :allow, :auto],
    do: {:ok, Atom.to_string(mode)}

  defp normalize_trust_mode(_mode), do: error(:trust_mode_invalid)

  # ---------------------------------------------------------------------------
  # Provenance — name must match template; absolute path never in digest
  # ---------------------------------------------------------------------------

  defp normalize_provenance(template_name, data, opts) do
    override = Keyword.get(opts, :provenance)

    source =
      if is_map(override) do
        override
      else
        value(data, "template_source")
      end

    normalize_provenance_map(source, template_name)
  end

  defp normalize_provenance_map(nil, template_name) do
    {:ok, %{"name" => template_name, "layer" => nil}}
  end

  defp normalize_provenance_map(source, template_name)
       when is_map(source) and not is_struct(source) do
    raw_name = value(source, "name")

    with {:ok, name} <-
           (case raw_name do
              nil -> {:ok, template_name}
              other -> normalize_name(other, :provenance_invalid)
            end),
         :ok <- match_provenance_name(name, template_name),
         {:ok, layer} <- normalize_provenance_layer(value(source, "layer")) do
      # Absolute source paths are intentionally dropped — never enter the digest.
      {:ok, %{"name" => name, "layer" => layer}}
    end
  end

  defp normalize_provenance_map(_source, _template_name), do: error(:provenance_invalid)

  defp match_provenance_name(name, template_name) when name == template_name, do: :ok

  defp match_provenance_name(name, template_name),
    do: error({:provenance_name_mismatch, name, template_name})

  defp normalize_provenance_layer(nil), do: {:ok, nil}
  defp normalize_provenance_layer(layer) when layer in @provenance_layers, do: {:ok, layer}

  defp normalize_provenance_layer(layer) when layer in [:user, :shipped, :legacy_json],
    do: {:ok, Atom.to_string(layer)}

  defp normalize_provenance_layer(_layer), do: error(:provenance_layer_invalid)

  defp validate_build_options(opts) do
    if Keyword.keyword?(opts), do: :ok, else: error(:invalid_build_options)
  end

  defp valid_capability_uri?(uri) do
    with {:ok, parsed} <- CapabilityUri.parse(uri) do
      CapabilityUri.capability_match?(uri, CapabilityUri.canonical(parsed))
    else
      {:error, _reason} -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Digest / helpers
  # ---------------------------------------------------------------------------

  defp snapshot_digest(snapshot) do
    snapshot
    |> canonical_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_term(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical_term(value)} end)
    |> Enum.sort()
  end

  defp canonical_term(list) when is_list(list), do: Enum.map(list, &canonical_term/1)
  defp canonical_term(value), do: value

  defp fetch_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, _value} = found ->
        found

      :error ->
        atom_key =
          cond do
            is_binary(key) ->
              try do
                String.to_existing_atom(key)
              rescue
                ArgumentError -> nil
              end

            true ->
              nil
          end

        if is_atom(atom_key), do: Map.fetch(map, atom_key), else: :error
    end
  end

  defp value(map, key) when is_map(map) do
    case fetch_value(map, key) do
      {:ok, found} -> found
      :error -> nil
    end
  end

  defp value(_map, _key), do: nil

  defp error(reason), do: {:error, {:template_authority_policy, reason}}
end
