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
    # O(1) size gate before any key enumeration / atom scan.
    with :ok <-
           require_exact_map_size(
             commitment,
             MapSet.size(@commitment_keys),
             :commitment_shape
           ),
         :ok <- reject_any_atom_key(commitment),
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
         :ok <-
           require_exact_map_size(governed, MapSet.size(@governed_top_keys), :governed_shape),
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
      # walk_canonical already enforces a cumulative ETF upper bound; allocate
      # only after that budget passes, then re-check the real binary size.
      term = {@commitment_domain, role, canonical}
      preimage = :erlang.term_to_binary(term, [:deterministic])

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

  # Cumulative byte budget tracks a conservative ETF upper bound of the
  # domain-separated preimage (domain + role + canonical envelope) so oversized
  # payloads fail during the walk rather than after a large allocation.
  defp canonicalize(term) do
    # Domain atom/binary + role binary overhead reserved up front.
    initial_budget = @max_preimage_bytes - preimage_header_budget()

    if initial_budget < 0 do
      {:error, :oversized}
    else
      case walk_canonical(term, 0, @max_json_nodes, initial_budget) do
        {:ok, value, _nodes, _budget} -> {:ok, value}
        {:error, _} = err -> err
      end
    end
  end

  defp preimage_header_budget do
    # Small fixed ETF overhead for {@commitment_domain, role, _canonical}.
    # Domain and role are closed constants; keep a generous constant ceiling.
    256
  end

  defp walk_canonical(_term, depth, _nodes, _budget) when depth > @max_depth,
    do: {:error, :oversized}

  defp walk_canonical(_term, _depth, nodes, _budget) when nodes <= 0, do: {:error, :oversized}

  defp walk_canonical(nil, _d, n, budget), do: charge_scalar(nil, n, budget, 6)
  defp walk_canonical(v, _d, n, budget) when is_boolean(v), do: charge_scalar(v, n, budget, 6)

  defp walk_canonical(v, _d, n, budget) when is_integer(v) do
    # Compare to bounds directly — never abs/1 on arbitrary bignums.
    if v >= -@max_json_safe_integer and v <= @max_json_safe_integer do
      # Safe integers fit well under a 12-byte ETF charge.
      charge_scalar(v, n, budget, 12)
    else
      {:error, :oversized}
    end
  end

  defp walk_canonical(v, _d, n, budget) when is_float(v) do
    if finite_float?(v) do
      # NEW_FLOAT_EXT is 9 bytes.
      charge_scalar(v, n, budget, 9)
    else
      {:error, :canonicalization_failed}
    end
  end

  defp walk_canonical(v, _d, n, budget) when is_binary(v) do
    size = byte_size(v)

    cond do
      size > @max_string_bytes ->
        {:error, :oversized}

      # Byte ceiling first — never UTF-8-scan an overlong binary.
      not String.valid?(v) ->
        {:error, :canonicalization_failed}

      true ->
        # BINARY_EXT header (5) + payload.
        charge_scalar(v, n, budget, size + 5)
    end
  end

  # Explicit empty / cons shapes only — never is_list/1 (that walks the whole
  # tail to prove properness and is unbounded / can be quadratic under guards).
  defp walk_canonical([], _depth, nodes, budget) do
    case charge_budget(budget, 6) do
      {:ok, budget} -> {:ok, [], nodes - 1, budget}
      {:error, _} = err -> err
    end
  end

  defp walk_canonical([_ | _] = list, depth, nodes, budget) do
    case charge_budget(budget, 6) do
      {:ok, budget} -> walk_list(list, depth, nodes - 1, budget, 0, [])
      {:error, _} = err -> err
    end
  end

  defp walk_canonical(map, depth, nodes, budget) when is_map(map) and not is_struct(map) do
    # Fixed-size check BEFORE materializing keys (never Map.keys/1 on wide maps).
    size = map_size(map)

    cond do
      size > @max_map_keys ->
        {:error, :oversized}

      true ->
        case charge_budget(budget, 6) do
          {:ok, budget} ->
            keys = Map.keys(map)

            if Enum.any?(keys, &(not is_binary(&1))) do
              {:error, :canonicalization_failed}
            else
              keys
              |> Enum.sort()
              |> walk_map_pairs(map, depth, nodes - 1, budget, [])
            end

          {:error, _} = err ->
            err
        end
    end
  end

  defp walk_canonical(_, _, _, _), do: {:error, :canonicalization_failed}

  defp walk_list([], _depth, nodes, budget, _len, acc),
    do: {:ok, Enum.reverse(acc), nodes, budget}

  # Bounded walk: no is_list/1 on the tail. Improper tails are classified when
  # the next recursion fails to match [] or [h | t].
  defp walk_list([h | t], depth, nodes, budget, len, acc) when len < @max_list_len do
    case walk_canonical(h, depth + 1, nodes, budget) do
      {:ok, ch, left, budget2} -> walk_list(t, depth, left, budget2, len + 1, [ch | acc])
      {:error, _} = err -> err
    end
  end

  # Length ceiling hit: fail immediately without scanning the remainder.
  defp walk_list([_ | _], _depth, _nodes, _budget, len, _acc) when len >= @max_list_len,
    do: {:error, :oversized}

  # Improper list tail (neither [] nor cons cell).
  defp walk_list(_improper, _depth, _nodes, _budget, _len, _acc),
    do: {:error, :canonicalization_failed}

  defp walk_map_pairs([], _map, _depth, nodes, budget, acc),
    do: {:ok, Enum.reverse(acc), nodes, budget}

  defp walk_map_pairs([k | rest], map, depth, nodes, budget, acc) do
    key_size = byte_size(k)

    cond do
      key_size > @max_string_bytes ->
        {:error, :oversized}

      not String.valid?(k) ->
        {:error, :canonicalization_failed}

      true ->
        # Charge key binary + small tuple/list pair overhead, then value.
        case charge_budget(budget, key_size + 5 + 4) do
          {:ok, budget2} ->
            case walk_canonical(Map.fetch!(map, k), depth + 1, nodes, budget2) do
              {:ok, v, left, budget3} ->
                walk_map_pairs(rest, map, depth, left, budget3, [{k, v} | acc])

              {:error, _} = err ->
                err
            end

          {:error, _} = err ->
            err
        end
    end
  end

  defp charge_scalar(value, nodes, budget, amount) do
    case charge_budget(budget, amount) do
      {:ok, budget2} -> {:ok, value, nodes - 1, budget2}
      {:error, _} = err -> err
    end
  end

  defp charge_budget(budget, amount)
       when is_integer(budget) and is_integer(amount) and amount >= 0 do
    if budget >= amount, do: {:ok, budget - amount}, else: {:error, :oversized}
  end

  defp charge_budget(_, _), do: {:error, :oversized}

  # Reject NaN and both infinities. `v == v` fails only for NaN; infinity must
  # be rejected via float_to_binary. Compact form is already lowercase.
  defp finite_float?(v) when is_float(v) do
    v == v and
      case :erlang.float_to_binary(v, [:compact]) do
        bin when is_binary(bin) ->
          not (String.contains?(bin, "nan") or String.contains?(bin, "inf"))
      end
  rescue
    _ -> false
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
         :ok <-
           require_exact_map_size(
             value,
             MapSet.size(@template_source_keys),
             :governed_shape
           ),
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
    with :ok <-
           require_exact_map_size(cas, MapSet.size(@profile_cas_keys), :profile_cas_invalid),
         :ok <- reject_any_atom_key(cas),
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

  defp require_exact_map_size(map, expected, reason)
       when is_map(map) and is_integer(expected) and expected >= 0 do
    if map_size(map) == expected, do: :ok, else: {:error, reason}
  end

  defp require_exact_map_size(_map, _expected, reason), do: {:error, reason}

  defp reject_governed_atom_keys(map, atoms) do
    # Fixed small atom list — O(1) Map.has_key? probes, no key enumeration.
    if Enum.any?(atoms, &Map.has_key?(map, &1)) do
      {:error, :ambiguous_keys}
    else
      :ok
    end
  end

  # Caller must O(1)-bound map_size (exact closed size or max) before this.
  defp reject_any_atom_key(map) when is_map(map) do
    if Enum.any?(map, fn {k, _} -> is_atom(k) end) do
      {:error, :ambiguous_keys}
    else
      :ok
    end
  end

  defp reject_any_atom_key(_), do: {:error, :ambiguous_keys}

  defp closed_keyset(map, allowed, reason) when is_map(map) do
    expected = MapSet.size(allowed)

    # O(1) size equality before Map.keys / MapSet.new.
    if map_size(map) != expected do
      {:error, reason}
    else
      if MapSet.equal?(MapSet.new(Map.keys(map)), allowed), do: :ok, else: {:error, reason}
    end
  end

  defp closed_keyset(_map, _allowed, reason), do: {:error, reason}

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
             :ok <-
               require_exact_map_size(
                 value,
                 MapSet.size(@governed_meta_keys),
                 :governed_shape
               ),
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
      byte_size(value) == 0 -> {:error, :template_invalid}
      byte_size(value) > @max_template_bytes -> {:error, :template_invalid}
      not String.valid?(value) -> {:error, :template_invalid}
      String.contains?(value, <<0>>) -> {:error, :template_invalid}
      true -> {:ok, value}
    end
  end

  # Walk with [] / [h | t] only — no is_list/1 properness scan.
  defp require_capabilities(value) do
    case validate_each_capability(value, 0) do
      :ok -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  defp validate_each_capability([], _n), do: :ok

  defp validate_each_capability([item | rest], n) when n < @max_capabilities do
    with :ok <- require_capability(item) do
      validate_each_capability(rest, n + 1)
    end
  end

  # Capacity ceiling: stop without scanning the remainder.
  defp validate_each_capability([_ | _], n) when n >= @max_capabilities,
    do: {:error, :capabilities_invalid}

  # Improper tail or non-list.
  defp validate_each_capability(_, _), do: {:error, :capabilities_invalid}

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
        size = byte_size(value)

        cond do
          size == 0 -> {:error, :capabilities_invalid}
          size > max_bytes -> {:error, :capabilities_invalid}
          not String.valid?(value) -> {:error, :capabilities_invalid}
          String.contains?(value, <<0>>) -> {:error, :capabilities_invalid}
          true -> :ok
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
end
