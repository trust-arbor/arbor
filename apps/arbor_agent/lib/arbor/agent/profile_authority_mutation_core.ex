defmodule Arbor.Agent.ProfileAuthorityMutationCore do
  @moduledoc """
  Pure CRC core for Phase 4C C3B1/C3B3 authoritative profile authority mutation.

  Owns pure decisions with NO IO, clock, randomness, Process, Application,
  store, File, or GenServer access, and no `String.to_atom`:

    * `prepare/2` — overlay a closed governed authority update onto an observed
      raw serialized profile map, preserving every unrelated top-level and
      nested field (including `exact_template_policy`).
    * `commit_prepared_mutation/2` — after a valid prepare, build a bounded
      domain-separated SHA-256 replay commitment binding the observed Record
      envelope to its exact one-revision successor.
    * `envelope_stable?/2` — pre-CAS stability predicate.
    * `classify/3` — in-process ambiguous CAS classification with live intended
      data.
    * `classify_restart/4` — restart classification from durable commitment +
      profile CAS + target identity only.

  Governed keys overwrite only: top-level `template`, `initial_capabilities`,
  nested `metadata[TemplateAuthorityPolicy.metadata_key()]`, and nested
  `metadata["template_source"]`. The Policy envelope is validated and bound
  exactly to those three surfaces before any overlay or hash.
  """

  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Contracts.Persistence.Record

  @meta_key TemplateAuthorityPolicy.metadata_key()

  @governed_top_keys MapSet.new(["template", "initial_capabilities", "metadata"])
  @governed_meta_keys MapSet.new([@meta_key, "template_source"])
  @template_source_keys MapSet.new(["name", "layer"])

  @governed_top_atoms [:template, :initial_capabilities, :metadata]
  @governed_meta_atoms [:template_authority_policy, :template_source]
  @cap_item_atoms [:resource, :constraints]

  @provenance_layers MapSet.new(~w(user shipped legacy_json))

  @max_template_bytes 256
  @max_resource_bytes 1024
  @max_capabilities 256

  @commitment_version 1
  @commitment_kind "profile_authority_mutation_replay"
  @commitment_domain "arbor.agent.profile_authority_mutation.replay.v1"
  @commitment_algorithm "sha256"
  @commitment_encoding "hex_lower"
  @commitment_keys MapSet.new([
                     "version",
                     "kind",
                     "algorithm",
                     "encoding",
                     "domain",
                     "anchor_digest",
                     "successor_digest"
                   ])
  @profile_cas_keys MapSet.new(["record_id", "generation", "revision"])

  @max_depth 12
  @max_json_nodes 8192
  @max_map_keys 256
  @max_list_len 512
  @max_string_bytes 65_536
  @max_preimage_bytes 262_144
  @max_json_safe_integer 9_007_199_254_740_991

  @digest_re ~r/\A[0-9a-f]{64}\z/
  @agent_id_re ~r/\Aagent_[A-Za-z0-9_-]+\z/

  @type outcome :: :not_applied | :already_applied | :conflict | :outcome_unknown
  @type reobserved :: {:ok, Record.t()} | :not_found | {:error, term()}
  @type commitment :: %{required(String.t()) => term()}

  @doc "Closed commitment schema version."
  @spec commitment_version() :: pos_integer()
  def commitment_version, do: @commitment_version

  @doc "Closed commitment kind identifier."
  @spec commitment_kind() :: String.t()
  def commitment_kind, do: @commitment_kind

  @doc "Domain-separation tag bound into commitment digests."
  @spec commitment_domain() :: String.t()
  def commitment_domain, do: @commitment_domain

  @doc "Commitment hash algorithm identifier."
  @spec commitment_algorithm() :: String.t()
  def commitment_algorithm, do: @commitment_algorithm

  @doc "Commitment digest encoding identifier."
  @spec commitment_encoding() :: String.t()
  def commitment_encoding, do: @commitment_encoding

  @doc """
  Shape-only admission of a durable replay commitment.

  Rejects unknown keys, atom keys, wrong constants, and non-lowercase 64-hex
  digests. Does not re-derive digests (requires private Record evidence).
  """
  @spec admit_commitment(term()) :: {:ok, commitment()} | {:error, atom()}
  def admit_commitment(commitment) when is_map(commitment) and not is_struct(commitment) do
    with :ok <- reject_any_atom_key(commitment),
         :ok <- closed_keyset(commitment, @commitment_keys, :commitment_shape),
         true <- commitment["version"] === @commitment_version,
         true <- commitment["kind"] === @commitment_kind,
         true <- commitment["algorithm"] === @commitment_algorithm,
         true <- commitment["encoding"] === @commitment_encoding,
         true <- commitment["domain"] === @commitment_domain,
         true <- valid_digest?(commitment["anchor_digest"]),
         true <- valid_digest?(commitment["successor_digest"]),
         true <- commitment["anchor_digest"] !== commitment["successor_digest"] do
      {:ok,
       %{
         "version" => @commitment_version,
         "kind" => @commitment_kind,
         "algorithm" => @commitment_algorithm,
         "encoding" => @commitment_encoding,
         "domain" => @commitment_domain,
         "anchor_digest" => commitment["anchor_digest"],
         "successor_digest" => commitment["successor_digest"]
       }}
    else
      {:error, _} = err -> err
      _ -> {:error, :commitment_shape}
    end
  end

  def admit_commitment(_), do: {:error, :commitment_shape}

  @doc """
  Prepare the closed raw authority update.

  Overlays `governed` onto a copy of `observed_data`, writing ONLY:
  top-level `"template"`, `"initial_capabilities"`, nested
  `metadata[TemplateAuthorityPolicy.metadata_key()]`, and nested
  `metadata["template_source"]`. Every other top-level key and every other
  metadata key — including `exact_template_policy` — is preserved untouched.

  The Policy envelope is validated and must already equal its canonical form.
  Snapshot template, declared capabilities, and provenance must `===` the
  governed template, initial_capabilities, and template_source respectively.
  `template_source.layer` must be a non-nil closed provenance layer.
  """
  @spec prepare(map(), map()) :: {:ok, map()} | {:error, atom()}
  def prepare(observed_data, governed) do
    meta_key = @meta_key

    with :ok <- require_plain_map(observed_data, :observed_not_map),
         :ok <- reject_governed_atom_keys(observed_data, @governed_top_atoms),
         {:ok, observed_meta} <- require_observed_metadata(observed_data),
         :ok <- reject_governed_atom_keys(observed_meta, @governed_meta_atoms),
         :ok <- require_plain_map(governed, :governed_shape),
         :ok <- reject_any_atom_key(governed),
         :ok <- closed_keyset(governed, @governed_top_keys, :governed_shape),
         {:ok, governed_meta} <- require_governed_metadata(governed),
         {:ok, template} <- require_template(governed["template"]),
         {:ok, capabilities} <- require_capabilities(governed["initial_capabilities"]),
         {:ok, template_source} <- require_template_source(governed_meta["template_source"]),
         {:ok, validated} <- require_policy_envelope(governed_meta[meta_key]),
         :ok <- bind_authority(validated, template, capabilities, template_source) do
      intended_meta =
        observed_meta
        |> Map.put(meta_key, validated)
        |> Map.put("template_source", template_source)

      intended =
        observed_data
        |> Map.put("template", template)
        |> Map.put("initial_capabilities", capabilities)
        |> Map.put("metadata", intended_meta)

      {:ok, intended}
    end
  end

  @doc """
  Validate governed authority, prepare intended data, then mint a replay
  commitment. Hashing is private and only runs after prepare succeeds.
  """
  @spec commit_prepared_mutation(Record.t(), map()) ::
          {:ok, %{intended_data: map(), commitment: commitment()}} | {:error, atom()}
  def commit_prepared_mutation(%Record{} = observed, governed) do
    with :ok <- admit_durable_record(observed),
         {:ok, intended} <- prepare(observed.data, governed),
         {:ok, commitment} <- build_commitment(observed, intended) do
      {:ok, %{intended_data: intended, commitment: commitment}}
    end
  end

  def commit_prepared_mutation(_, _), do: {:error, :invalid_record}

  @doc """
  Pre-CAS envelope-stability predicate.

  True iff `observed` and `current` are both `%Record{}` and their
  id/key/data/metadata/generation/revision are ALL equal. Timestamps are
  backend-owned and excluded.
  """
  @spec envelope_stable?(Record.t(), term()) :: boolean()
  def envelope_stable?(%Record{} = observed, %Record{} = current) do
    observed.id == current.id and
      observed.key == current.key and
      observed.data == current.data and
      observed.metadata == current.metadata and
      observed.generation == current.generation and
      observed.revision == current.revision
  end

  def envelope_stable?(_observed, _current), do: false

  @doc """
  Classify an ambiguous CAS outcome by authoritative reobservation with live
  intended data (timestamps excluded).
  """
  @spec classify(Record.t(), map(), reobserved()) :: outcome()
  def classify(%Record{} = observed, intended_data, reobserved) do
    case reobserved do
      {:ok, %Record{} = r} ->
        cond do
          r.key != observed.key -> :outcome_unknown
          envelope_stable?(observed, r) -> :not_applied
          intended_successor?(observed, intended_data, r) -> :already_applied
          true -> :conflict
        end

      {:ok, _malformed} ->
        :outcome_unknown

      :not_found ->
        :conflict

      {:error, _reason} ->
        :outcome_unknown
    end
  end

  @doc """
  Restart classifier using only durable commitment + profile CAS + target id.
  """
  @spec classify_restart(String.t(), map(), map(), reobserved()) :: outcome()
  def classify_restart(target_agent_id, profile_cas, commitment, reobserved) do
    with :ok <- require_target_agent_id(target_agent_id),
         {:ok, cas} <- admit_profile_cas(profile_cas),
         {:ok, cmt} <- admit_commitment(commitment) do
      do_classify_restart(target_agent_id, cas, cmt, reobserved)
    else
      _ -> :outcome_unknown
    end
  end

  # ---------------------------------------------------------------------------
  # Restart classification helpers
  # ---------------------------------------------------------------------------

  defp do_classify_restart(target_agent_id, cas, cmt, reobserved) do
    case reobserved do
      {:error, _} ->
        :outcome_unknown

      :not_found ->
        :conflict

      {:ok, %Record{} = r} ->
        classify_restart_record(target_agent_id, cas, cmt, r)

      {:ok, _} ->
        :outcome_unknown

      _ ->
        :outcome_unknown
    end
  end

  defp classify_restart_record(target_agent_id, cas, cmt, r) do
    if r.key !== target_agent_id do
      :outcome_unknown
    else
      case project_envelope(r, r.data, r.revision) do
        {:ok, env} ->
          case {digest_envelope("anchor", env), digest_envelope("successor", env)} do
            {{:ok, anchor_d}, {:ok, succ_d}} ->
              cond do
                anchor_d === cmt["anchor_digest"] and cas_matches_record?(cas, r) ->
                  :not_applied

                succ_d === cmt["successor_digest"] and cas_matches_successor?(cas, r) ->
                  :already_applied

                true ->
                  :conflict
              end

            _ ->
              # Unreadable / non-canonical envelope material fails closed.
              :outcome_unknown
          end

        {:error, _} ->
          :outcome_unknown
      end
    end
  end

  defp intended_successor?(observed, intended_data, r) do
    r.id == observed.id and
      r.key == observed.key and
      r.generation == observed.generation and
      r.revision == observed.revision + 1 and
      r.data == intended_data and
      r.metadata == observed.metadata
  end

  defp cas_matches_record?(cas, r) do
    cas["record_id"] === r.id and cas["generation"] === r.generation and
      cas["revision"] === r.revision
  end

  defp cas_matches_successor?(cas, r) do
    cas["record_id"] === r.id and cas["generation"] === r.generation and
      is_integer(cas["revision"]) and r.revision === cas["revision"] + 1
  end

  # ---------------------------------------------------------------------------
  # Commitment construction (private hashing)
  # ---------------------------------------------------------------------------

  defp build_commitment(%Record{} = observed, intended) do
    with {:ok, anchor} <- project_envelope(observed, observed.data, observed.revision),
         {:ok, successor} <- project_envelope(observed, intended, observed.revision + 1),
         {:ok, anchor_digest} <- digest_envelope("anchor", anchor),
         {:ok, successor_digest} <- digest_envelope("successor", successor) do
      if anchor_digest === successor_digest do
        {:error, :commitment_degenerate}
      else
        {:ok,
         %{
           "version" => @commitment_version,
           "kind" => @commitment_kind,
           "algorithm" => @commitment_algorithm,
           "encoding" => @commitment_encoding,
           "domain" => @commitment_domain,
           "anchor_digest" => anchor_digest,
           "successor_digest" => successor_digest
         }}
      end
    end
  end

  defp project_envelope(%Record{} = r, data, revision) do
    with :ok <- require_plain_map(data, :canonicalization_failed),
         :ok <- require_plain_map(r.metadata, :canonicalization_failed),
         true <- is_binary(r.id) and r.id != "",
         true <- is_binary(r.key) and r.key != "",
         true <- is_integer(r.generation) and r.generation >= 1,
         true <- is_integer(revision) and revision >= 1 and revision <= @max_json_safe_integer do
      {:ok,
       %{
         "id" => r.id,
         "key" => r.key,
         "data" => data,
         "metadata" => r.metadata,
         "generation" => r.generation,
         "revision" => revision
       }}
    else
      {:error, _} = err -> err
      _ -> {:error, :canonicalization_failed}
    end
  end

  defp digest_envelope(role, envelope) when is_binary(role) do
    with {:ok, canonical} <- canonicalize(envelope) do
      preimage = :erlang.term_to_binary({@commitment_domain, role, canonical}, [:deterministic])

      if byte_size(preimage) > @max_preimage_bytes do
        {:error, :oversized}
      else
        digest =
          preimage
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        {:ok, digest}
      end
    end
  end

  defp canonicalize(term) do
    case walk_canonical(term, 0, @max_json_nodes) do
      {:ok, value, _nodes} -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  defp walk_canonical(_term, depth, _nodes) when depth > @max_depth, do: {:error, :oversized}
  defp walk_canonical(_term, _depth, nodes) when nodes <= 0, do: {:error, :oversized}

  defp walk_canonical(nil, _d, n), do: {:ok, nil, n - 1}
  defp walk_canonical(v, _d, n) when is_boolean(v), do: {:ok, v, n - 1}

  defp walk_canonical(v, _d, n) when is_integer(v) do
    if abs(v) <= @max_json_safe_integer, do: {:ok, v, n - 1}, else: {:error, :oversized}
  end

  defp walk_canonical(v, _d, n) when is_float(v) do
    if v == v do
      {:ok, v, n - 1}
    else
      {:error, :canonicalization_failed}
    end
  end

  defp walk_canonical(v, _d, n) when is_binary(v) do
    if String.valid?(v) and byte_size(v) <= @max_string_bytes do
      {:ok, v, n - 1}
    else
      {:error, :canonicalization_failed}
    end
  end

  defp walk_canonical(list, depth, nodes) when is_list(list) do
    walk_list(list, depth, nodes - 1, 0, [])
  end

  defp walk_canonical(map, depth, nodes) when is_map(map) and not is_struct(map) do
    keys = Map.keys(map)

    cond do
      Enum.any?(keys, &(not is_binary(&1))) ->
        {:error, :canonicalization_failed}

      length(keys) > @max_map_keys ->
        {:error, :oversized}

      true ->
        keys
        |> Enum.sort()
        |> walk_map_pairs(map, depth, nodes - 1, [])
    end
  end

  defp walk_canonical(_, _, _), do: {:error, :canonicalization_failed}

  defp walk_list([], _depth, nodes, _len, acc), do: {:ok, Enum.reverse(acc), nodes}

  defp walk_list([h | t], depth, nodes, len, acc) when is_list(t) and len < @max_list_len do
    case walk_canonical(h, depth + 1, nodes) do
      {:ok, ch, left} -> walk_list(t, depth, left, len + 1, [ch | acc])
      {:error, _} = err -> err
    end
  end

  defp walk_list([_ | t], _depth, _nodes, len, _acc) when is_list(t) and len >= @max_list_len,
    do: {:error, :oversized}

  defp walk_list(_, _, _, _, _), do: {:error, :canonicalization_failed}

  defp walk_map_pairs([], _map, _depth, nodes, acc), do: {:ok, Enum.reverse(acc), nodes}

  defp walk_map_pairs([k | rest], map, depth, nodes, acc) do
    case walk_canonical(Map.fetch!(map, k), depth + 1, nodes) do
      {:ok, v, left} -> walk_map_pairs(rest, map, depth, left, [{k, v} | acc])
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Governed admission / Policy bind
  # ---------------------------------------------------------------------------

  defp require_policy_envelope(raw) do
    case TemplateAuthorityPolicy.validate_envelope(raw) do
      {:ok, validated} ->
        if raw === validated do
          {:ok, validated}
        else
          {:error, :policy_invalid}
        end

      {:error, {:template_authority_policy, _}} ->
        {:error, :policy_invalid}

      {:error, _} ->
        {:error, :policy_invalid}

      _ ->
        {:error, :policy_invalid}
    end
  end

  defp bind_authority(validated, template, capabilities, template_source) do
    snap = TemplateAuthorityPolicy.snapshot(validated)
    snap_template = snap["template"]
    snap_caps = TemplateAuthorityPolicy.capabilities(snap)
    snap_prov = TemplateAuthorityPolicy.provenance(snap)

    if snap_template === template and snap_caps === capabilities and
         snap_prov === template_source do
      :ok
    else
      {:error, :authority_inconsistent}
    end
  end

  defp require_template_source(value) do
    with :ok <- require_plain_map(value, :governed_shape),
         :ok <- reject_any_atom_key(value),
         :ok <- closed_keyset(value, @template_source_keys, :governed_shape),
         {:ok, name} <- require_template(value["name"]),
         {:ok, layer} <- require_provenance_layer(value["layer"]) do
      {:ok, %{"name" => name, "layer" => layer}}
    end
  end

  defp require_provenance_layer(layer) when is_binary(layer) do
    if MapSet.member?(@provenance_layers, layer) do
      {:ok, layer}
    else
      {:error, :provenance_layer_invalid}
    end
  end

  defp require_provenance_layer(nil), do: {:error, :provenance_layer_invalid}
  defp require_provenance_layer(_), do: {:error, :provenance_layer_invalid}

  # ---------------------------------------------------------------------------
  # Record / CAS admission
  # ---------------------------------------------------------------------------

  defp admit_durable_record(%Record{} = r) do
    with true <- is_binary(r.id) and r.id != "",
         true <- is_binary(r.key) and r.key != "",
         true <- is_map(r.data) and not is_struct(r.data),
         true <- is_map(r.metadata) and not is_struct(r.metadata),
         true <- is_integer(r.generation) and r.generation >= 1,
         true <- is_integer(r.revision) and r.revision >= 1,
         true <- r.revision + 1 <= @max_json_safe_integer do
      :ok
    else
      _ -> {:error, :invalid_record}
    end
  end

  defp require_target_agent_id(id) when is_binary(id) do
    if id != "" and byte_size(id) <= 256 and Regex.match?(@agent_id_re, id) do
      :ok
    else
      {:error, :invalid_target}
    end
  end

  defp require_target_agent_id(_), do: {:error, :invalid_target}

  defp admit_profile_cas(cas) when is_map(cas) and not is_struct(cas) do
    with :ok <- reject_any_atom_key(cas),
         :ok <- closed_keyset(cas, @profile_cas_keys, :profile_cas_invalid),
         id when is_binary(id) and id != "" <- cas["record_id"],
         gen when is_integer(gen) and gen >= 1 and gen <= @max_json_safe_integer <-
           cas["generation"],
         rev when is_integer(rev) and rev >= 1 and rev <= @max_json_safe_integer <-
           cas["revision"] do
      {:ok, %{"record_id" => id, "generation" => gen, "revision" => rev}}
    else
      {:error, _} = err -> err
      _ -> {:error, :profile_cas_invalid}
    end
  end

  defp admit_profile_cas(_), do: {:error, :profile_cas_invalid}

  defp valid_digest?(digest) when is_binary(digest) do
    byte_size(digest) == 64 and Regex.match?(@digest_re, digest)
  end

  defp valid_digest?(_), do: false

  # ---------------------------------------------------------------------------
  # Container / keyset helpers
  # ---------------------------------------------------------------------------

  defp require_plain_map(value, reason) do
    if is_map(value) and not is_struct(value), do: :ok, else: {:error, reason}
  end

  defp reject_governed_atom_keys(map, atoms) do
    if Enum.any?(atoms, &Map.has_key?(map, &1)) do
      {:error, :ambiguous_keys}
    else
      :ok
    end
  end

  defp reject_any_atom_key(map) do
    if Enum.any?(map, fn {k, _} -> is_atom(k) end) do
      {:error, :ambiguous_keys}
    else
      :ok
    end
  end

  defp closed_keyset(map, allowed, reason) do
    if MapSet.equal?(MapSet.new(Map.keys(map)), allowed), do: :ok, else: {:error, reason}
  end

  defp require_observed_metadata(observed_data) do
    case Map.fetch(observed_data, "metadata") do
      {:ok, value} when is_map(value) and not is_struct(value) ->
        {:ok, value}

      _ ->
        {:error, :malformed_container}
    end
  end

  defp require_governed_metadata(governed) do
    case Map.fetch(governed, "metadata") do
      {:ok, value} ->
        with :ok <- require_plain_map(value, :governed_shape),
             :ok <- reject_any_atom_key(value),
             :ok <- closed_keyset(value, @governed_meta_keys, :governed_shape) do
          {:ok, value}
        end

      :error ->
        {:error, :governed_shape}
    end
  end

  defp require_template(value) do
    cond do
      not is_binary(value) -> {:error, :template_invalid}
      not String.valid?(value) -> {:error, :template_invalid}
      byte_size(value) == 0 -> {:error, :template_invalid}
      byte_size(value) > @max_template_bytes -> {:error, :template_invalid}
      String.contains?(value, <<0>>) -> {:error, :template_invalid}
      true -> {:ok, value}
    end
  end

  defp require_capabilities(value) do
    with :ok <- require_proper_list(value),
         :ok <- validate_each_capability(value, 0) do
      {:ok, value}
    end
  end

  defp validate_each_capability([], _n), do: :ok

  defp validate_each_capability([item | rest], n) do
    if n >= @max_capabilities do
      {:error, :capabilities_invalid}
    else
      with :ok <- require_capability(item) do
        validate_each_capability(rest, n + 1)
      end
    end
  end

  defp require_capability(item) do
    with :ok <- require_plain_map(item, :capabilities_invalid),
         :ok <- reject_governed_atom_keys(item, @cap_item_atoms),
         :ok <- require_present_string(item, "resource", @max_resource_bytes) do
      require_present_plain_map(item, "constraints")
    end
  end

  defp require_present_string(map, key, max_bytes) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        if String.valid?(value) and byte_size(value) > 0 and
             byte_size(value) <= max_bytes and not String.contains?(value, <<0>>) do
          :ok
        else
          {:error, :capabilities_invalid}
        end

      _ ->
        {:error, :capabilities_invalid}
    end
  end

  defp require_present_plain_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) and not is_struct(value) -> :ok
      _ -> {:error, :capabilities_invalid}
    end
  end

  defp require_proper_list(value) when is_list(value) do
    if improper?(value, 0), do: {:error, :capabilities_invalid}, else: :ok
  end

  defp require_proper_list(_), do: {:error, :capabilities_invalid}

  defp improper?([], _n), do: false

  defp improper?([_ | rest], n) when n <= @max_capabilities,
    do: improper?(rest, n + 1)

  defp improper?([_ | _], n) when n > @max_capabilities, do: false
  defp improper?(_, _), do: true
end
