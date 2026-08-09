defmodule Arbor.Agent.TemplateAuthorityPreviewCore do
  @moduledoc """
  Pure ownership classification, status precedence, and report composition for
  template-authority reconciliation **preview**.

  Does not grant, revoke, write trust/profile state, or call Security/Trust.
  Callers supply already-read observations; this module classifies managed
  authority and builds a bounded JSON-clean report with a deterministic
  reconciliation digest.
  """

  alias Arbor.Agent.TemplateAuthorityCapabilityProjection
  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Agent.TemplateAuthorityReconciliationCore

  @version 1
  @kind "template_authority_preview"
  @statuses ~w(current drifted unmanaged invalid unavailable)
  # Fail-closed severity: invalid > unavailable > drifted > unmanaged > current
  @status_rank %{
    "invalid" => 5,
    "unavailable" => 4,
    "drifted" => 3,
    "unmanaged" => 2,
    "current" => 1
  }

  @authority_source "template_authority_policy"
  @ownership_classes ~w(authority_tagged legacy preserved)
  @marker_states ~w(absent valid invalid stale current unavailable)

  @max_preserved_resources 64
  @max_ownership_rows 512
  @max_resource_bytes 512
  @max_string_bytes 512
  @max_template_name_bytes 256
  @max_json_nodes 4_096
  @max_depth 12
  @max_list_len 256
  @max_map_keys 128
  @max_json_safe_integer 9_007_199_254_740_991
  @max_input_string_bytes 65_536
  @max_summary_code_bytes 64

  # Domain-separated digests — version/kind are bound into reconciliation CAS
  # material so preview digests never collide with other authority digests.
  @digest_domain_reconciliation "template_authority_preview.reconciliation.v1"
  @digest_domain_preserved "template_authority_preview.preserved.v1"

  @top_keys MapSet.new([
              "version",
              "kind",
              "status",
              "target_agent_id",
              "template",
              "desired_declaration_digest",
              "stored_marker",
              "effective_managed_diff",
              "preserved_unmanaged",
              "summary",
              "profile_version",
              "reconciliation_digest"
            ])

  @template_keys MapSet.new([
                   "name",
                   "desired_provenance",
                   "persisted_provenance",
                   "stored_provenance"
                 ])

  @marker_keys MapSet.new(["state", "digest"])

  @preserved_keys MapSet.new(["count", "resources", "semantic_digest"])

  @summary_complete_keys MapSet.new([
                           "status",
                           "managed_capability_count",
                           "managed_actual_capability_count",
                           "authority_tagged_count",
                           "legacy_count",
                           "preserved_unmanaged_count",
                           "diff_unchanged",
                           "ownership"
                         ])

  @summary_diagnostic_keys MapSet.new([
                             "status",
                             "managed_capability_count",
                             "preserved_unmanaged_count",
                             "diff_unchanged",
                             "code"
                           ])

  @summary_count_keys ~w(
    managed_capability_count
    managed_actual_capability_count
    authority_tagged_count
    legacy_count
  )

  @observation_read_keys [:profile, :template, :capabilities, :trust, :repo_root]
  @observation_fact_keys [:ownership, :desired, :marker]

  @provenance_keys MapSet.new(["name", "layer"])
  @provenance_layers MapSet.new(["user", "shipped", "legacy_json"])
  @trust_modes ~w(block ask allow auto)

  @type json_scalar :: String.t() | number() | boolean() | nil
  @type json_value :: json_scalar() | [json_value()] | %{optional(String.t()) => json_value()}
  @type report :: %{optional(String.t()) => json_value()}

  @doc "Compose a closed preview report from already-gathered observations."
  @spec compose(map()) :: {:ok, report()} | {:error, term()}
  def compose(facts) when is_map(facts) do
    target_agent_id = string_or_nil(Map.get(facts, :target_agent_id))
    profile_version = non_neg_or_nil(Map.get(facts, :profile_version))

    with {:ok, observation} <- admit_observation(facts),
         {:ok, report} <- build_report(observation, target_agent_id, profile_version) do
      assert_report(report)
    end
  end

  def compose(_), do: error(:invalid_compose_input)

  @doc """
  Classify live grants into authority-tagged, legacy, and preserved rows.

  Managed (authority-tagged) only when a standing unscoped grant carries a
  **closed** `template_authority_policy` ownership marker:

    * `source` = `"template_authority_policy"` (atom or string; no conflicts)
    * `version` = `1`
    * `template` = nonblank bounded template name
    * `template_digest` = exact 64 lowercase hex declaration digest

  A syntactically valid marker with a stale digest or different template name
  remains authority-managed. Missing/wrong-type/empty/nonhex/wrong-length
  digests, atom/string conflicts, or lookalike source claims are **invalid**.

  Another explicit `source` (e.g. `exact_template_policy`, `baseline`,
  `external`) is **preserved** and never falls through to legacy matching.

  Legacy managed only when there is **no** source claim and the normalized
  standing unscoped resource+constraints exactly match the effective projection
  of `profile.initial_capabilities`.

  Scoped / temporary / delegated grants are always preserved (even when the
  resource matches legacy), unless their authority marker is malformed — then
  the observation is invalid. Any malformed live grant is invalid (no synthetic
  `"unknown"` fallback). Ambiguous duplicate live resources fail closed even
  when constraints match.
  """
  @spec classify_ownership([term()], [map()]) ::
          {:ok, map()} | {:error, term()}
  def classify_ownership(live_grants, legacy_effective_specs)
      when is_list(live_grants) and is_list(legacy_effective_specs) do
    with {:ok, legacy_by_resource} <- legacy_index(legacy_effective_specs),
         {:ok, rows} <- classify_list(live_grants, legacy_by_resource, 0, []),
         :ok <- reject_ambiguous_duplicates(rows) do
      {:ok, ownership_result(rows)}
    end
  end

  def classify_ownership(_live, _legacy), do: error(:invalid_ownership_input)

  @doc "Closed report validation for facade / tests."
  @spec assert_report(term()) :: {:ok, report()} | {:error, term()}
  def assert_report(report) when is_map(report) do
    # Bounded JSON admission first — reject improper/oversized/non-JSON spines
    # before any structural validator walks report fields.
    with true <- json_clean?(report),
         :ok <- validate_top_level(report),
         :ok <- validate_status_fields(report),
         :ok <- validate_template_block(report["template"]),
         :ok <- validate_stored_marker(report["stored_marker"], report["status"]),
         :ok <- validate_preserved_block(report["preserved_unmanaged"], report["status"]),
         :ok <- validate_diff_block(report["effective_managed_diff"], report["status"]),
         :ok <- validate_summary(report),
         :ok <- validate_digests(report) do
      {:ok, report}
    else
      _ -> error(:invalid_report)
    end
  end

  def assert_report(_), do: error(:invalid_report)

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec kind() :: String.t()
  def kind, do: @kind

  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Deterministic status precedence (higher wins)."
  @spec prefer_status(String.t(), String.t()) :: String.t()
  def prefer_status(a, b) when a in @statuses and b in @statuses do
    if Map.fetch!(@status_rank, a) >= Map.fetch!(@status_rank, b), do: a, else: b
  end

  def prefer_status(a, _b) when a in @statuses, do: a
  def prefer_status(_a, b) when b in @statuses, do: b
  def prefer_status(_, _), do: "invalid"

  @doc "Build a fail-closed unavailable/invalid report without collaborator details."
  @spec diagnostic_report(keyword() | map()) :: report()
  def diagnostic_report(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)
    status = normalize_diagnostic_status(Map.get(attrs, :status, "unavailable"))

    %{
      "version" => @version,
      "kind" => @kind,
      "status" => status,
      "target_agent_id" => string_or_nil(Map.get(attrs, :target_agent_id)),
      "template" => %{
        "name" => string_or_nil(Map.get(attrs, :template_name)),
        "desired_provenance" => nil,
        "persisted_provenance" => nil,
        "stored_provenance" => nil
      },
      "desired_declaration_digest" => nil,
      "stored_marker" => %{
        "state" => marker_state_or(Map.get(attrs, :marker_state), status),
        "digest" => nil
      },
      "effective_managed_diff" => nil,
      "preserved_unmanaged" => %{
        "count" => 0,
        "resources" => [],
        "semantic_digest" => nil
      },
      "summary" => %{
        "status" => status,
        "managed_capability_count" => 0,
        "preserved_unmanaged_count" => 0,
        "diff_unchanged" => nil,
        "code" => bound_code(Map.get(attrs, :code, status))
      },
      "profile_version" => non_neg_or_nil(Map.get(attrs, :profile_version)),
      # Incomplete observations never receive a CAS reconciliation digest.
      "reconciliation_digest" => nil
    }
  end

  # ---------------------------------------------------------------------------
  # Observation admission + report build
  # ---------------------------------------------------------------------------

  defp admit_observation(facts) when is_map(facts) do
    # Malformed non-map reads must not reach Map.get/3 (raises on non-maps).
    case Map.get(facts, :reads) do
      nil ->
        admit_observation_with_reads(facts, %{})

      reads when is_map(reads) and not is_struct(reads) ->
        admit_observation_with_reads(facts, reads)

      _malformed ->
        {:ok, {:invalid, facts}}
    end
  end

  defp admit_observation_with_reads(facts, reads) when is_map(facts) and is_map(reads) do
    invalid? =
      status_present?(reads, @observation_read_keys, :invalid) or
        status_present?(facts, @observation_fact_keys, :invalid)

    unavailable? = status_present?(reads, @observation_read_keys, :unavailable)

    # Invalid outranks unavailable: malformed admitted data is more severe than
    # a missing collaborator read, and both leave reconciliation_digest nil.
    cond do
      invalid? ->
        {:ok, {:invalid, facts}}

      unavailable? ->
        {:ok, {:unavailable, facts}}

      true ->
        admit_complete_observation(facts)
    end
  end

  defp status_present?(map, keys, status) do
    Enum.any?(keys, &(Map.get(map, &1) == status))
  end

  # Fail closed on incomplete or malformed complete observations *before*
  # semantic traversal (diff / ownership counts / digest). Never raise on
  # missing keys or improper list spines.
  defp admit_complete_observation(facts) when is_map(facts) do
    desired_view = Map.get(facts, :desired_view)
    managed_actual_view = Map.get(facts, :managed_actual_view)
    ownership_rows = Map.get(facts, :ownership_rows, [])
    desired_envelope = Map.get(facts, :desired_envelope)

    cond do
      not is_map(desired_view) or is_struct(desired_view) ->
        {:ok, {:invalid, facts}}

      not is_map(managed_actual_view) or is_struct(managed_actual_view) ->
        {:ok, {:invalid, facts}}

      not is_nil(desired_envelope) and
          (not is_map(desired_envelope) or is_struct(desired_envelope)) ->
        {:ok, {:invalid, facts}}

      not is_list(ownership_rows) ->
        {:ok, {:invalid, facts}}

      true ->
        case admit_bounded_list_spine(ownership_rows, @max_ownership_rows) do
          :ok -> {:ok, {:observed, facts}}
          :too_many -> {:ok, {:invalid, facts}}
          :improper -> {:ok, {:invalid, facts}}
        end
    end
  end

  # Single-pass proper-list admission: reject improper tails and oversize
  # without calling length/1 on untrusted spines.
  defp admit_bounded_list_spine(list, max) when is_list(list) and is_integer(max) and max >= 0 do
    admit_bounded_list_spine(list, max, 0)
  end

  defp admit_bounded_list_spine(_other, _max), do: :improper

  defp admit_bounded_list_spine([], _max, _count), do: :ok

  defp admit_bounded_list_spine([_h | t], max, count) when count < max do
    admit_bounded_list_spine(t, max, count + 1)
  end

  defp admit_bounded_list_spine([_h | _t], _max, _count), do: :too_many
  defp admit_bounded_list_spine(_improper, _max, _count), do: :improper

  defp build_report({:unavailable, facts}, target_agent_id, profile_version) do
    {:ok,
     diagnostic_report(
       status: "unavailable",
       target_agent_id: target_agent_id,
       profile_version: profile_version,
       template_name: Map.get(facts, :template_name),
       code: "observation_unavailable",
       marker_state: "unavailable"
     )}
  end

  defp build_report({:invalid, facts}, target_agent_id, profile_version) do
    {:ok,
     diagnostic_report(
       status: "invalid",
       target_agent_id: target_agent_id,
       profile_version: profile_version,
       template_name: Map.get(facts, :template_name),
       code: "observation_invalid",
       marker_state: "invalid"
     )}
  end

  defp build_report({:observed, facts}, target_agent_id, profile_version) do
    desired_view = Map.get(facts, :desired_view)
    managed_actual_view = Map.get(facts, :managed_actual_view)
    ownership_rows = Map.get(facts, :ownership_rows) || []
    marker = Map.get(facts, :stored_marker) || %{state: "absent", digest: nil, envelope: nil}
    desired_envelope = Map.get(facts, :desired_envelope)
    template_name = Map.get(facts, :template_name)
    desired_provenance = Map.get(facts, :desired_provenance)
    persisted_provenance = Map.get(facts, :persisted_provenance)
    ownership = Map.get(facts, :ownership_class) || "clean"

    with {:ok, desired_view} <- admit_authority_view(desired_view),
         {:ok, managed_actual_view} <- admit_authority_view(managed_actual_view),
         {:ok, diff} <-
           TemplateAuthorityReconciliationCore.diff(desired_view, managed_actual_view),
         {:ok, ownership_rows} <- normalize_ownership_rows(ownership_rows) do
      desired_prov = sanitize_provenance(desired_provenance)
      persisted_prov = sanitize_provenance(persisted_provenance)
      stored_prov = sanitize_provenance(marker_provenance(marker))
      desired_digest = envelope_digest(desired_envelope)
      stored_digest = marker_digest(marker)
      unchanged? = TemplateAuthorityReconciliationCore.unchanged?(diff)

      marker_state =
        marker_state(marker, desired_digest, desired_prov, persisted_prov, stored_prov)

      status =
        decide_status(%{
          marker_state: marker_state,
          unchanged?: unchanged?,
          ownership: ownership
        })

      preserved_rows = Enum.filter(ownership_rows, &(&1["class"] == "preserved"))
      tagged_count = Enum.count(ownership_rows, &(&1["class"] == "authority_tagged"))
      legacy_count = Enum.count(ownership_rows, &(&1["class"] == "legacy"))
      preserved_report = bound_preserved(preserved_rows)

      desired_cap_count = length(desired_view["capabilities"] || [])
      actual_cap_count = length(managed_actual_view["capabilities"] || [])

      report = %{
        "version" => @version,
        "kind" => @kind,
        "status" => status,
        "target_agent_id" => target_agent_id,
        "template" => %{
          "name" => string_or_nil(template_name),
          "desired_provenance" => desired_prov,
          "persisted_provenance" => persisted_prov,
          "stored_provenance" => stored_prov
        },
        "desired_declaration_digest" => desired_digest,
        "stored_marker" => %{
          "state" => marker_state,
          "digest" => stored_digest
        },
        "effective_managed_diff" => diff,
        "preserved_unmanaged" => preserved_report,
        "summary" => %{
          "status" => status,
          "managed_capability_count" => desired_cap_count,
          "managed_actual_capability_count" => actual_cap_count,
          "authority_tagged_count" => tagged_count,
          "legacy_count" => legacy_count,
          "preserved_unmanaged_count" => preserved_report["count"],
          "diff_unchanged" => unchanged?,
          "ownership" => ownership
        },
        "profile_version" => profile_version,
        "reconciliation_digest" => nil
      }

      # CAS material is domain-separated and binds version + kind plus the full
      # desired / actual / marker / provenance / trust / ownership / preserved
      # semantic surface (not the truncated display resource list).
      recon_digest =
        digest(@digest_domain_reconciliation, %{
          "version" => @version,
          "kind" => @kind,
          "target_agent_id" => target_agent_id,
          "profile_version" => profile_version,
          "desired_declaration_digest" => desired_digest,
          "stored_marker_state" => marker_state,
          "stored_marker_digest" => stored_digest,
          "desired_provenance" => desired_prov,
          "persisted_provenance" => persisted_prov,
          "stored_provenance" => stored_prov,
          "effective_desired" => desired_view,
          "managed_actual" => managed_actual_view,
          "live_trust" => managed_actual_view["trust_preset"],
          "ownership" => ownership,
          "ownership_rows" => ownership_rows,
          "preserved_count" => preserved_report["count"],
          "preserved_semantic_digest" => preserved_report["semantic_digest"]
        })

      {:ok, Map.put(report, "reconciliation_digest", recon_digest)}
    else
      {:error, _} ->
        {:ok,
         diagnostic_report(
           status: "invalid",
           target_agent_id: target_agent_id,
           profile_version: profile_version,
           template_name: template_name,
           code: "diff_invalid",
           marker_state: "invalid"
         )}
    end
  end

  defp admit_authority_view(view) when is_map(view) and not is_struct(view) do
    case TemplateAuthorityPolicy.normalize_authority_view(view) do
      {:ok, admitted} ->
        {:ok, admitted}

      {:error, {:template_authority_policy, reason}} ->
        error(reason)

      {:error, reason} ->
        error(reason)
    end
  end

  defp admit_authority_view(_view), do: error(:invalid_authority_view)

  defp decide_status(%{ownership: "invalid"}), do: "invalid"

  defp decide_status(%{marker_state: marker_state, unchanged?: unchanged?}) do
    cond do
      marker_state == "invalid" ->
        "invalid"

      marker_state == "absent" ->
        "unmanaged"

      marker_state == "current" and unchanged? ->
        "current"

      true ->
        # valid/stale marker with drift, or current marker with content drift
        "drifted"
    end
  end

  # ---------------------------------------------------------------------------
  # Ownership classification helpers
  # ---------------------------------------------------------------------------

  defp legacy_index(specs) when is_list(specs) do
    case admit_bounded_list_spine(specs, @max_ownership_rows) do
      :ok ->
        case TemplateAuthorityPolicy.normalize_capabilities(specs) do
          {:ok, normalized} ->
            {:ok, Map.new(normalized, &{&1["resource"], &1})}

          {:error, {:template_authority_policy, reason}} ->
            error(reason)

          {:error, reason} ->
            error(reason)
        end

      :too_many ->
        error(:ownership_too_many)

      :improper ->
        error(:invalid_ownership_input)
    end
  end

  defp legacy_index(_specs), do: error(:invalid_ownership_input)

  # Bounded single-pass classification — never length/1 on untrusted spines.
  defp classify_list([], _legacy_by_resource, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp classify_list([grant | rest], legacy_by_resource, count, acc)
       when count < @max_ownership_rows do
    case classify_one(grant, legacy_by_resource) do
      {:ok, row} ->
        classify_list(rest, legacy_by_resource, count + 1, [row | acc])

      {:error, :invalid} ->
        {:error, :ownership_invalid}

      {:error, reason} ->
        error(reason)
    end
  end

  defp classify_list([_grant | _rest], _legacy_by_resource, _count, _acc),
    do: error(:ownership_too_many)

  defp classify_list(_improper, _legacy_by_resource, _count, _acc),
    do: error(:invalid_ownership_input)

  defp classify_one(grant, legacy_by_resource) do
    with {:ok, cap_map} <- grant_to_map(grant),
         {:ok, standing?} <- standing_unscoped?(cap_map),
         {:ok, source_kind} <- source_claim(cap_map),
         {:ok, normalized} <- normalize_live_cap(cap_map) do
      cond do
        source_kind == :malformed ->
          {:error, :invalid}

        source_kind == :tagged and standing? ->
          {:ok, row(normalized, "authority_tagged")}

        source_kind == :tagged and not standing? ->
          # Scoped grant with a valid authority marker is still preserved —
          # authority ownership applies only to standing unscoped grants.
          # (Malformed markers already failed above regardless of scope.)
          {:ok, row(normalized, "preserved")}

        source_kind == :explicit_other ->
          # Another explicit source never falls through to legacy matching.
          {:ok, row(normalized, "preserved")}

        standing? and source_kind == :none ->
          case Map.get(legacy_by_resource, normalized["resource"]) do
            ^normalized ->
              {:ok, row(normalized, "legacy")}

            _other ->
              {:ok, row(normalized, "preserved")}
          end

        true ->
          # Scoped / temporary / delegated without authority marker — preserved
          # even when the resource matches the legacy projection.
          {:ok, row(normalized, "preserved")}
      end
    else
      {:error, :invalid} ->
        {:error, :invalid}

      {:error, _} ->
        # Malformed live grant is invalid, never a synthetic "unknown" preserved.
        {:error, :invalid}
    end
  end

  defp row(%{"resource" => resource, "constraints" => constraints}, class)
       when class in @ownership_classes do
    %{
      "resource" => resource,
      "constraints" => constraints,
      "class" => class
    }
  end

  defp grant_to_map(%{__struct__: _} = struct), do: {:ok, Map.from_struct(struct)}
  defp grant_to_map(map) when is_map(map), do: {:ok, map}
  defp grant_to_map(_), do: {:error, :invalid}

  defp standing_unscoped?(cap) do
    with {:ok, expires_at} <- fetch_optional_grant_field(cap, :expires_at),
         {:ok, not_before} <- fetch_optional_grant_field(cap, :not_before),
         {:ok, parent} <- fetch_optional_grant_field(cap, :parent_capability_id),
         {:ok, max_uses} <- fetch_optional_grant_field(cap, :max_uses),
         {:ok, session_id} <- fetch_optional_grant_field(cap, :session_id),
         {:ok, task_id} <- fetch_optional_grant_field(cap, :task_id),
         {:ok, principal_scope} <- fetch_optional_grant_field(cap, :principal_scope) do
      standing? =
        is_nil(expires_at) and is_nil(not_before) and is_nil(parent) and is_nil(max_uses) and
          is_nil(session_id) and is_nil(task_id) and is_nil(principal_scope)

      {:ok, standing?}
    end
  end

  defp source_claim(cap) do
    with {:ok, metadata} <- fetch_optional_grant_field(cap, :metadata) do
      cond do
        is_nil(metadata) ->
          {:ok, :none}

        not is_map(metadata) or is_struct(metadata) ->
          {:error, :invalid}

        true ->
          classify_source_metadata(metadata)
      end
    end
  end

  defp classify_source_metadata(metadata) do
    with {:ok, source} <- fetch_meta_unique(metadata, "source") do
      case source do
        :error ->
          # No source claim — allow legacy matching (after other checks).
          # Reject orphan lookalike marker fields without a source.
          case orphan_marker_fields?(metadata) do
            true -> {:error, :invalid}
            false -> {:ok, :none}
          end

        {:ok, value} ->
          classify_source_value(value, metadata)
      end
    end
  end

  defp classify_source_value(source, metadata) do
    if authority_source?(source) do
      validate_authority_marker(metadata)
    else
      # Admit the token *before* lookalike String.contains?/2 or explicit-other
      # acceptance. nil / booleans / blank / oversized / invalid-UTF-8 / NUL
      # fail closed; only bounded nonblank binaries and non-nil/non-boolean
      # atoms may become preserved explicit-other claims.
      case admit_source_token(source) do
        {:ok, binary} ->
          if lookalike_authority_source_binary?(binary) do
            {:error, :invalid}
          else
            {:ok, :explicit_other}
          end

        :error ->
          {:error, :invalid}
      end
    end
  end

  defp authority_source?(source)
       when source in [:template_authority_policy, "template_authority_policy"],
       do: true

  defp authority_source?(_), do: false

  # Binary source tokens must be nonblank, valid UTF-8, bounded, and NUL-free
  # before any substring lookalike check.
  defp admit_source_token(source) when is_binary(source) do
    if source != "" and byte_size(source) <= @max_string_bytes and String.valid?(source) and
         not String.contains?(source, <<0>>) do
      {:ok, source}
    else
      :error
    end
  end

  # Explicit-other atoms: reject nil/true/false; bound the atom string form.
  defp admit_source_token(source)
       when is_atom(source) and not is_nil(source) and not is_boolean(source) do
    binary = Atom.to_string(source)

    if binary != "" and byte_size(binary) <= @max_string_bytes and
         not String.contains?(binary, <<0>>) do
      {:ok, binary}
    else
      :error
    end
  end

  defp admit_source_token(_source), do: :error

  defp lookalike_authority_source_binary?(source) when is_binary(source) do
    source != @authority_source and String.contains?(source, "template_authority")
  end

  defp validate_authority_marker(metadata) do
    with {:ok, version_fetch} <- fetch_meta_unique(metadata, "version"),
         {:ok, template_fetch} <- fetch_meta_unique(metadata, "template"),
         {:ok, digest_fetch} <- fetch_meta_unique(metadata, "template_digest"),
         {:ok, version} <- unwrap_required(version_fetch),
         {:ok, template} <- unwrap_required(template_fetch),
         {:ok, digest} <- unwrap_required(digest_fetch),
         :ok <- validate_marker_version(version),
         :ok <- validate_marker_template(template),
         :ok <- validate_marker_digest(digest) do
      {:ok, :tagged}
    else
      _ -> {:error, :invalid}
    end
  end

  defp unwrap_required(:error), do: {:error, :invalid}
  defp unwrap_required({:ok, value}), do: {:ok, value}

  defp validate_marker_version(1), do: :ok
  defp validate_marker_version(_), do: {:error, :invalid}

  defp validate_marker_template(template) when is_binary(template) do
    if template != "" and byte_size(template) <= @max_template_name_bytes and
         String.valid?(template) and
         not String.contains?(template, <<0>>) do
      :ok
    else
      {:error, :invalid}
    end
  end

  defp validate_marker_template(_), do: {:error, :invalid}

  defp validate_marker_digest(digest) when is_binary(digest) do
    if valid_digest?(digest), do: :ok, else: {:error, :invalid}
  end

  defp validate_marker_digest(_), do: {:error, :invalid}

  defp orphan_marker_fields?(metadata) do
    Enum.any?(~w(version template template_digest), fn key ->
      case fetch_meta_unique(metadata, key) do
        {:ok, {:ok, _}} -> true
        {:ok, :error} -> false
        {:error, _} -> true
      end
    end)
  end

  # Fetch a metadata field admitting atom or string keys, but fail closed on
  # conflicting atom/string pairs for the same logical key.
  defp fetch_meta_unique(map, key) when is_map(map) and is_binary(key) do
    string_present? = Map.has_key?(map, key)

    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    atom_present? = is_atom(atom_key) and Map.has_key?(map, atom_key)

    cond do
      string_present? and atom_present? ->
        string_val = Map.get(map, key)
        atom_val = Map.get(map, atom_key)

        if values_conflict?(key, string_val, atom_val) do
          {:error, :invalid}
        else
          {:ok, {:ok, normalize_meta_value(key, string_val)}}
        end

      string_present? ->
        {:ok, {:ok, Map.get(map, key)}}

      atom_present? ->
        {:ok, {:ok, Map.get(map, atom_key)}}

      true ->
        {:ok, :error}
    end
  end

  defp values_conflict?("source", a, b) do
    normalize_source_token(a) != normalize_source_token(b)
  end

  defp values_conflict?("version", a, b), do: a != b
  defp values_conflict?("template", a, b), do: a != b
  defp values_conflict?("template_digest", a, b), do: a != b
  defp values_conflict?(_key, a, b), do: a != b

  defp normalize_source_token(v) when is_atom(v), do: Atom.to_string(v)
  defp normalize_source_token(v) when is_binary(v), do: v
  defp normalize_source_token(v), do: v

  defp normalize_meta_value("source", v) when is_atom(v), do: v
  defp normalize_meta_value(_key, v), do: v

  defp normalize_live_cap(cap_map) when is_map(cap_map) do
    with {:ok, resource} <- admit_grant_resource(cap_map),
         {:ok, constraints} <- admit_grant_constraints(cap_map) do
      case TemplateAuthorityPolicy.normalize_capabilities([
             %{"resource" => resource, "constraints" => constraints}
           ]) do
        {:ok, [normalized]} -> {:ok, normalized}
        {:ok, []} -> {:error, :invalid}
        {:error, _} -> {:error, :invalid}
      end
    end
  end

  defp normalize_live_cap(_), do: {:error, :invalid}

  # Live grants expose resource_uri (Capability) or resource. Atom/string forms
  # of each key and the resource/resource_uri alias pair must agree.
  defp admit_grant_resource(cap_map) when is_map(cap_map) do
    with {:ok, resource} <- fetch_grant_field(cap_map, "resource", :resource),
         {:ok, resource_uri} <- fetch_grant_field(cap_map, "resource_uri", :resource_uri) do
      case {resource, resource_uri} do
        {:absent, :absent} ->
          {:error, :invalid}

        {{:present, value}, :absent} ->
          {:ok, value}

        {:absent, {:present, value}} ->
          {:ok, value}

        {{:present, left}, {:present, right}} ->
          if left === right, do: {:ok, left}, else: {:error, :invalid}
      end
    end
  end

  defp admit_grant_constraints(cap_map) when is_map(cap_map) do
    case fetch_grant_field(cap_map, "constraints", :constraints) do
      {:ok, :absent} -> {:ok, %{}}
      {:ok, {:present, value}} when is_map(value) and not is_struct(value) -> {:ok, value}
      {:ok, {:present, _}} -> {:error, :invalid}
      {:error, _} -> {:error, :invalid}
    end
  end

  defp fetch_grant_field(map, string_key, atom_key)
       when is_map(map) and is_binary(string_key) and is_atom(atom_key) do
    string_present? = Map.has_key?(map, string_key)
    atom_present? = Map.has_key?(map, atom_key)

    cond do
      string_present? and atom_present? ->
        string_val = Map.fetch!(map, string_key)
        atom_val = Map.fetch!(map, atom_key)

        if string_val === atom_val do
          {:ok, {:present, string_val}}
        else
          {:error, :invalid}
        end

      string_present? ->
        {:ok, {:present, Map.fetch!(map, string_key)}}

      atom_present? ->
        {:ok, {:present, Map.fetch!(map, atom_key)}}

      true ->
        {:ok, :absent}
    end
  end

  defp fetch_optional_grant_field(map, atom_key) when is_atom(atom_key) do
    case fetch_grant_field(map, Atom.to_string(atom_key), atom_key) do
      {:ok, :absent} -> {:ok, nil}
      {:ok, {:present, value}} -> {:ok, value}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  # Ambiguous duplicate live resources fail closed even when constraints match.
  # Ownership evidence must not silently dedupe.
  defp reject_ambiguous_duplicates(rows) do
    rows
    |> Enum.reduce_while(MapSet.new(), fn row, seen ->
      resource = row["resource"]

      if MapSet.member?(seen, resource) do
        {:halt, {:error, :ownership_invalid}}
      else
        {:cont, MapSet.put(seen, resource)}
      end
    end)
    |> case do
      {:error, :ownership_invalid} -> {:error, :ownership_invalid}
      %MapSet{} -> :ok
    end
  end

  defp ownership_result(rows) do
    managed =
      rows
      |> Enum.filter(&(&1["class"] in ["authority_tagged", "legacy"]))
      |> Enum.sort_by(& &1["resource"])
      |> Enum.map(&strip_to_resource_constraints/1)

    preserved =
      rows
      |> Enum.filter(&(&1["class"] == "preserved"))
      |> Enum.sort_by(& &1["resource"])
      |> Enum.map(&strip_to_resource_constraints/1)

    sorted_rows = Enum.sort_by(rows, &{&1["class"], &1["resource"]})

    %{
      "ownership" => "clean",
      "managed" => managed,
      "preserved" => preserved,
      "rows" => sorted_rows
    }
  end

  defp strip_to_resource_constraints(%{"resource" => resource, "constraints" => constraints}) do
    %{"resource" => resource, "constraints" => constraints}
  end

  defp normalize_ownership_rows(rows) when is_list(rows) do
    case normalize_ownership_rows(rows, 0, []) do
      {:ok, admitted} ->
        {:ok, Enum.sort_by(admitted, &{&1["class"], &1["resource"]})}

      failure ->
        failure
    end
  end

  defp normalize_ownership_rows(_), do: {:error, :invalid}

  defp normalize_ownership_rows([], _count, acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_ownership_rows([row | rest], count, acc) when count < @max_ownership_rows do
    case admit_ownership_row(row) do
      {:ok, admitted} -> normalize_ownership_rows(rest, count + 1, [admitted | acc])
      {:error, _} = failure -> failure
    end
  end

  defp normalize_ownership_rows([_row | _rest], _count, _acc), do: {:error, :ownership_too_many}
  defp normalize_ownership_rows(_improper, _count, _acc), do: {:error, :invalid}

  defp admit_ownership_row(%{
         "resource" => resource,
         "constraints" => constraints,
         "class" => class
       })
       when class in @ownership_classes and is_binary(resource) and is_map(constraints) do
    case TemplateAuthorityPolicy.normalize_capabilities([
           %{"resource" => resource, "constraints" => constraints}
         ]) do
      {:ok, [normalized]} ->
        {:ok,
         %{
           "resource" => normalized["resource"],
           "constraints" => normalized["constraints"],
           "class" => class
         }}

      _ ->
        {:error, :invalid}
    end
  end

  defp admit_ownership_row(_), do: {:error, :invalid}

  # ---------------------------------------------------------------------------
  # Marker helpers
  # ---------------------------------------------------------------------------

  defp marker_state(marker, desired_digest, desired_prov, persisted_prov, stored_prov) do
    state = marker_raw_state(marker)

    case state do
      "absent" ->
        "absent"

      "invalid" ->
        "invalid"

      "unavailable" ->
        "unavailable"

      "valid" ->
        # Current only when declaration digest, marker provenance, and
        # persisted profile provenance all agree with the desired template.
        if is_binary(desired_digest) and marker_digest(marker) == desired_digest and
             desired_prov == stored_prov and desired_prov == persisted_prov and
             not is_nil(desired_prov) do
          "current"
        else
          "stale"
        end

      other when is_binary(other) ->
        other

      _ ->
        "invalid"
    end
  end

  defp marker_raw_state(%{state: state}) when is_atom(state), do: Atom.to_string(state)
  defp marker_raw_state(%{state: state}) when is_binary(state), do: state
  defp marker_raw_state(%{"state" => state}) when is_atom(state), do: Atom.to_string(state)
  defp marker_raw_state(%{"state" => state}) when is_binary(state), do: state
  defp marker_raw_state(_), do: "invalid"

  defp marker_digest(%{digest: digest}) when is_binary(digest), do: digest
  defp marker_digest(%{"digest" => digest}) when is_binary(digest), do: digest

  defp marker_digest(%{envelope: envelope}) when is_map(envelope),
    do: TemplateAuthorityPolicy.digest(envelope)

  defp marker_digest(%{"envelope" => envelope}) when is_map(envelope),
    do: TemplateAuthorityPolicy.digest(envelope)

  defp marker_digest(_), do: nil

  defp marker_provenance(%{envelope: envelope}) when is_map(envelope),
    do: envelope_provenance(envelope)

  defp marker_provenance(%{"envelope" => envelope}) when is_map(envelope),
    do: envelope_provenance(envelope)

  defp marker_provenance(_), do: nil

  defp envelope_digest(nil), do: nil

  defp envelope_digest(envelope) when is_map(envelope),
    do: TemplateAuthorityPolicy.digest(envelope)

  defp envelope_digest(_), do: nil

  defp envelope_provenance(nil), do: nil

  defp envelope_provenance(envelope) when is_map(envelope) do
    case TemplateAuthorityPolicy.snapshot(envelope) do
      snap when is_map(snap) -> TemplateAuthorityPolicy.provenance(snap)
      _ -> nil
    end
  end

  defp envelope_provenance(_), do: nil

  defp sanitize_provenance(nil), do: nil

  defp sanitize_provenance(prov) when is_map(prov) do
    name = string_or_nil(Map.get(prov, "name") || Map.get(prov, :name))
    layer = Map.get(prov, "layer") || Map.get(prov, :layer)
    layer = if is_atom(layer), do: Atom.to_string(layer), else: layer

    layer =
      if is_binary(layer) and MapSet.member?(@provenance_layers, layer), do: layer, else: nil

    # Never carry path or other keys.
    %{"name" => name, "layer" => layer}
  end

  defp sanitize_provenance(_), do: nil

  defp bound_preserved(preserved_rows) when is_list(preserved_rows) do
    # Full semantic material (resource + constraints + class) for the digest —
    # never hash only the truncated display list.
    semantic_rows =
      preserved_rows
      |> Enum.map(fn row ->
        %{
          "resource" => row["resource"],
          "constraints" => row["constraints"] || %{},
          "class" => "preserved"
        }
      end)
      |> Enum.sort_by(& &1["resource"])

    count = length(semantic_rows)

    resources =
      semantic_rows
      |> Enum.map(fn %{"resource" => resource} ->
        utf8_truncate(resource, @max_resource_bytes)
      end)
      |> Enum.take(@max_preserved_resources)

    %{
      "count" => count,
      "resources" => resources,
      "semantic_digest" =>
        digest(@digest_domain_preserved, %{"rows" => semantic_rows, "count" => count})
    }
  end

  defp bound_preserved(_) do
    %{
      "count" => 0,
      "resources" => [],
      "semantic_digest" => digest(@digest_domain_preserved, %{"rows" => [], "count" => 0})
    }
  end

  # ---------------------------------------------------------------------------
  # assert_report validators (small named helpers)
  # ---------------------------------------------------------------------------

  defp validate_top_level(report) do
    if closed_keyset?(report, @top_keys) and report["kind"] == @kind and
         report["version"] == @version and report["status"] in @statuses and
         id_or_nil?(report["target_agent_id"]) and
         non_neg_or_nil_ok?(report["profile_version"]) do
      :ok
    else
      :error
    end
  end

  defp validate_status_fields(report) do
    status = report["status"]

    cond do
      status in ~w(invalid unavailable) ->
        if is_nil(report["reconciliation_digest"]) and
             is_nil(report["desired_declaration_digest"]) and
             is_nil(report["effective_managed_diff"]) do
          :ok
        else
          :error
        end

      status in ~w(current drifted unmanaged) ->
        if valid_digest?(report["reconciliation_digest"]) and
             valid_digest?(report["desired_declaration_digest"]) and
             is_map(report["effective_managed_diff"]) do
          :ok
        else
          :error
        end

      true ->
        :error
    end
  end

  defp validate_template_block(template) when is_map(template) do
    if closed_keyset?(template, @template_keys) and
         name_or_nil?(template["name"]) and
         provenance_or_nil?(template["desired_provenance"]) and
         provenance_or_nil?(template["persisted_provenance"]) and
         provenance_or_nil?(template["stored_provenance"]) do
      :ok
    else
      :error
    end
  end

  defp validate_template_block(_), do: :error

  defp validate_stored_marker(marker, status) when is_map(marker) do
    state = marker["state"]
    digest = marker["digest"]

    cond do
      not closed_keyset?(marker, @marker_keys) ->
        :error

      state not in @marker_states ->
        :error

      status in ~w(invalid unavailable) and not is_nil(digest) ->
        :error

      is_nil(digest) or valid_digest?(digest) ->
        :ok

      true ->
        :error
    end
  end

  defp validate_stored_marker(_, _), do: :error

  defp validate_preserved_block(block, status) when is_map(block) do
    count = block["count"]
    resources = block["resources"]
    semantic = block["semantic_digest"]

    cond do
      not closed_keyset?(block, @preserved_keys) ->
        :error

      not (is_integer(count) and count >= 0 and count <= @max_ownership_rows) ->
        :error

      not is_list(resources) ->
        :error

      length(resources) > @max_preserved_resources ->
        :error

      length(resources) > count ->
        :error

      not Enum.all?(resources, &resource_string?/1) ->
        :error

      status in ~w(invalid unavailable) ->
        if is_nil(semantic), do: :ok, else: :error

      status in ~w(current drifted unmanaged) ->
        if valid_digest?(semantic), do: :ok, else: :error

      true ->
        :error
    end
  end

  defp validate_preserved_block(_, _), do: :error

  defp validate_diff_block(nil, status) when status in ~w(invalid unavailable), do: :ok
  defp validate_diff_block(nil, _), do: :error

  defp validate_diff_block(diff, status)
       when is_map(diff) and status in ~w(current drifted unmanaged) do
    validate_phase4a_diff(diff)
  end

  defp validate_diff_block(_, _), do: :error

  # Phase 4A schema is owned by ReconciliationCore + Policy. Validate by
  # reassembling desired/actual views from the buckets and requiring an exact
  # re-diff match — no local reimplementation of bucket/summary keysets.
  defp validate_phase4a_diff(diff) when is_map(diff) do
    with true <- diff["version"] == TemplateAuthorityReconciliationCore.version(),
         true <- diff["kind"] == TemplateAuthorityReconciliationCore.kind(),
         {:ok, desired} <- reassemble_authority_view(diff, :desired),
         {:ok, actual} <- reassemble_authority_view(diff, :actual),
         {:ok, recomputed} <- TemplateAuthorityReconciliationCore.diff(desired, actual),
         true <- recomputed == diff do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_phase4a_diff(_), do: :error

  defp reassemble_authority_view(diff, side) do
    with {:ok, capabilities} <- reassemble_capabilities(diff["capabilities"], side),
         {:ok, trust_preset} <- reassemble_trust_preset(diff["trust"], side) do
      {:ok, %{"capabilities" => capabilities, "trust_preset" => trust_preset}}
    end
  end

  defp reassemble_capabilities(caps, side) when is_map(caps) do
    with {:ok, retained} <- capability_entries(caps["retained"]),
         {:ok, side_only} <-
           capability_entries(if(side == :desired, do: caps["added"], else: caps["removed"])),
         {:ok, changed} <- changed_capability_entries(caps["changed"], side),
         true <- length(retained) + length(side_only) + length(changed) <= @max_list_len do
      {:ok, retained ++ side_only ++ changed}
    else
      _ -> {:error, :invalid}
    end
  end

  defp reassemble_capabilities(_, _), do: {:error, :invalid}

  defp capability_entries(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"resource" => resource, "constraints" => constraints}, {:ok, acc}
      when is_binary(resource) and is_map(constraints) ->
        {:cont, {:ok, [%{"resource" => resource, "constraints" => constraints} | acc]}}

      _other, _acc ->
        {:halt, {:error, :invalid}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      failure -> failure
    end
  end

  defp capability_entries(_), do: {:error, :invalid}

  defp changed_capability_entries(list, side)
       when is_list(list) and side in [:desired, :actual] do
    Enum.reduce_while(list, {:ok, []}, fn
      %{
        "resource" => resource,
        "desired" => %{"constraints" => desired_c},
        "actual" => %{"constraints" => actual_c}
      },
      {:ok, acc}
      when is_binary(resource) and is_map(desired_c) and is_map(actual_c) ->
        constraints = if side == :desired, do: desired_c, else: actual_c
        {:cont, {:ok, [%{"resource" => resource, "constraints" => constraints} | acc]}}

      _other, _acc ->
        {:halt, {:error, :invalid}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      failure -> failure
    end
  end

  defp changed_capability_entries(_, _), do: {:error, :invalid}

  defp reassemble_trust_preset(trust, side) when is_map(trust) do
    with {:ok, baseline} <- trust_baseline_mode(trust["baseline"], side),
         {:ok, rules} <- reassemble_trust_rules(trust["rules"], side) do
      {:ok, %{"baseline" => baseline, "rules" => rules}}
    end
  end

  defp reassemble_trust_preset(_, _), do: {:error, :invalid}

  defp trust_baseline_mode(%{"desired" => desired, "actual" => actual}, side)
       when side in [:desired, :actual] do
    mode = if side == :desired, do: desired, else: actual

    if mode in @trust_modes do
      {:ok, mode}
    else
      {:error, :invalid}
    end
  end

  defp trust_baseline_mode(_, _), do: {:error, :invalid}

  defp reassemble_trust_rules(rules, side) when is_map(rules) do
    with {:ok, retained} <- trust_rule_entries(rules["retained"]),
         {:ok, side_only} <-
           trust_rule_entries(if(side == :desired, do: rules["added"], else: rules["removed"])),
         {:ok, changed} <- changed_trust_rule_entries(rules["changed"], side) do
      merged = retained ++ side_only ++ changed

      if length(merged) > @max_list_len do
        {:error, :invalid}
      else
        case Map.new(merged, fn %{"uri" => uri, "mode" => mode} -> {uri, mode} end) do
          map when map_size(map) == length(merged) ->
            {:ok, map}

          _duplicates ->
            {:error, :invalid}
        end
      end
    end
  end

  defp reassemble_trust_rules(_, _), do: {:error, :invalid}

  defp trust_rule_entries(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"uri" => uri, "mode" => mode}, {:ok, acc}
      when is_binary(uri) and mode in @trust_modes ->
        {:cont, {:ok, [%{"uri" => uri, "mode" => mode} | acc]}}

      _other, _acc ->
        {:halt, {:error, :invalid}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      failure -> failure
    end
  end

  defp trust_rule_entries(_), do: {:error, :invalid}

  defp changed_trust_rule_entries(list, side)
       when is_list(list) and side in [:desired, :actual] do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"uri" => uri, "desired" => desired, "actual" => actual}, {:ok, acc}
      when is_binary(uri) and desired in @trust_modes and actual in @trust_modes ->
        mode = if side == :desired, do: desired, else: actual
        {:cont, {:ok, [%{"uri" => uri, "mode" => mode} | acc]}}

      _other, _acc ->
        {:halt, {:error, :invalid}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      failure -> failure
    end
  end

  defp changed_trust_rule_entries(_, _), do: {:error, :invalid}

  defp validate_summary(report) do
    summary = report["summary"]
    status = report["status"]

    cond do
      not is_map(summary) ->
        :error

      status in ~w(invalid unavailable) ->
        validate_diagnostic_summary(summary, status)

      status in ~w(current drifted unmanaged) ->
        validate_complete_summary(summary, status, report)

      true ->
        :error
    end
  end

  defp validate_diagnostic_summary(summary, status) do
    if closed_keyset?(summary, @summary_diagnostic_keys) and
         summary["status"] == status and
         summary["managed_capability_count"] == 0 and
         summary["preserved_unmanaged_count"] == 0 and
         is_nil(summary["diff_unchanged"]) and
         code_string?(summary["code"]) do
      :ok
    else
      :error
    end
  end

  defp validate_complete_summary(summary, status, report) do
    preserved_count = get_in(report, ["preserved_unmanaged", "count"]) || 0

    if closed_keyset?(summary, @summary_complete_keys) and
         summary["status"] == status and
         Enum.all?(@summary_count_keys, &non_negative_integer?(summary[&1])) and
         summary["preserved_unmanaged_count"] == preserved_count and
         is_boolean(summary["diff_unchanged"]) and
         is_binary(summary["ownership"]) do
      :ok
    else
      :error
    end
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp validate_digests(report) do
    # Top-level digests already checked in validate_status_fields /
    # validate_stored_marker / validate_preserved_block.
    if report["status"] in ~w(current drifted unmanaged) do
      if valid_digest?(report["reconciliation_digest"]) and
           valid_digest?(report["desired_declaration_digest"]) do
        :ok
      else
        :error
      end
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Digest / JSON hygiene
  # ---------------------------------------------------------------------------

  # Domain-separated deterministic digest. The domain string prevents
  # accidental cross-purpose digest reuse (reconciliation CAS vs preserved
  # semantics vs other authority digests).
  defp digest(domain, term) when is_binary(domain) do
    [domain, canonical_term(term)]
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_term(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonical_term(v)} end)
    |> Enum.sort()
  end

  defp canonical_term(list) when is_list(list), do: Enum.map(list, &canonical_term/1)
  defp canonical_term(value), do: value

  defp closed_keyset?(map, expected) when is_map(map) do
    keys = Map.keys(map) |> MapSet.new()
    MapSet.equal?(keys, expected) and Enum.all?(Map.keys(map), &is_binary/1)
  end

  defp closed_keyset?(_, _), do: false

  defp json_clean?(value), do: match?({:ok, _}, walk_json(value, 0, @max_depth, @max_json_nodes))

  defp walk_json(_value, _depth, _max_depth, nodes_left) when nodes_left <= 0, do: :error
  defp walk_json(nil, _d, _m, n), do: {:ok, n - 1}
  defp walk_json(v, _d, _m, n) when is_boolean(v), do: {:ok, n - 1}

  defp walk_json(v, _d, _m, n) when is_integer(v) do
    if abs(v) <= @max_json_safe_integer, do: {:ok, n - 1}, else: :error
  end

  defp walk_json(v, _d, _m, n) when is_float(v), do: {:ok, n - 1}

  defp walk_json(v, _d, _m, n) when is_binary(v) do
    if byte_size(v) <= @max_input_string_bytes and String.valid?(v),
      do: {:ok, n - 1},
      else: :error
  end

  defp walk_json(list, depth, max_depth, nodes_left)
       when is_list(list) and depth < max_depth do
    # Bounded proper-list recursion — never length/1 or Enum on untrusted spines.
    walk_json_list(list, depth, max_depth, nodes_left - 1, 0)
  end

  defp walk_json(list, depth, max_depth, _n) when is_list(list) and depth >= max_depth,
    do: :error

  defp walk_json(map, depth, max_depth, nodes_left)
       when is_map(map) and not is_struct(map) and depth < max_depth do
    remaining = nodes_left - 1

    if remaining < 0 or map_size(map) > @max_map_keys or map_size(map) > remaining do
      :error
    else
      walk_json_map(Map.to_list(map), depth, max_depth, remaining)
    end
  end

  defp walk_json(map, depth, max_depth, _n)
       when is_map(map) and not is_struct(map) and depth >= max_depth,
       do: :error

  defp walk_json(_, _, _, _), do: :error

  defp walk_json_list(_list, _depth, _max_depth, nodes_left, _count) when nodes_left < 0,
    do: :error

  defp walk_json_list([], _depth, _max_depth, nodes_left, _count), do: {:ok, nodes_left}

  defp walk_json_list([item | rest], depth, max_depth, nodes_left, count)
       when count < @max_list_len do
    case walk_json(item, depth + 1, max_depth, nodes_left) do
      {:ok, next} -> walk_json_list(rest, depth, max_depth, next, count + 1)
      :error -> :error
    end
  end

  defp walk_json_list([_item | _rest], _depth, _max_depth, _nodes_left, _count), do: :error
  defp walk_json_list(_improper, _depth, _max_depth, _nodes_left, _count), do: :error

  defp walk_json_map([], _depth, _max_depth, nodes_left), do: {:ok, nodes_left}

  defp walk_json_map([{k, v} | rest], depth, max_depth, nodes_left) do
    if is_binary(k) and byte_size(k) <= 256 and String.valid?(k) do
      case walk_json(v, depth + 1, max_depth, nodes_left) do
        {:ok, next} -> walk_json_map(rest, depth, max_depth, next)
        :error -> :error
      end
    else
      :error
    end
  end

  defp walk_json_map(_other, _depth, _max_depth, _nodes_left), do: :error

  defp valid_digest?(digest) when is_binary(digest) do
    byte_size(digest) == 64 and String.match?(digest, ~r/^[0-9a-f]{64}$/)
  end

  defp valid_digest?(_), do: false

  defp string_or_nil(v) when is_binary(v) do
    if byte_size(v) > 0 and byte_size(v) <= @max_string_bytes and String.valid?(v) do
      v
    else
      nil
    end
  end

  defp string_or_nil(v) when is_atom(v) and not is_nil(v), do: string_or_nil(Atom.to_string(v))
  defp string_or_nil(_), do: nil

  defp non_neg_or_nil(n) when is_integer(n) and n >= 0 and n <= @max_json_safe_integer, do: n
  defp non_neg_or_nil(_), do: nil

  defp non_neg_or_nil_ok?(nil), do: true

  defp non_neg_or_nil_ok?(n) when is_integer(n) and n >= 0 and n <= @max_json_safe_integer,
    do: true

  defp non_neg_or_nil_ok?(_), do: false

  defp id_or_nil?(nil), do: true

  defp id_or_nil?(id) when is_binary(id) do
    byte_size(id) > 0 and byte_size(id) <= @max_string_bytes and String.valid?(id)
  end

  defp id_or_nil?(_), do: false

  defp name_or_nil?(nil), do: true

  defp name_or_nil?(name) when is_binary(name) do
    byte_size(name) > 0 and byte_size(name) <= @max_template_name_bytes and String.valid?(name)
  end

  defp name_or_nil?(_), do: false

  defp provenance_or_nil?(nil), do: true

  defp provenance_or_nil?(prov) when is_map(prov) do
    closed_keyset?(prov, @provenance_keys) and
      name_or_nil?(prov["name"]) and
      (is_nil(prov["layer"]) or
         (is_binary(prov["layer"]) and MapSet.member?(@provenance_layers, prov["layer"])))
  end

  defp provenance_or_nil?(_), do: false

  defp resource_string?(s) when is_binary(s) do
    s != "" and byte_size(s) <= @max_resource_bytes and String.valid?(s)
  end

  defp resource_string?(_), do: false

  defp code_string?(code) when is_binary(code) do
    code != "" and byte_size(code) <= @max_summary_code_bytes and String.valid?(code)
  end

  defp code_string?(_), do: false

  defp normalize_diagnostic_status(s) when s in ~w(invalid unavailable), do: s

  defp normalize_diagnostic_status(s) when is_atom(s),
    do: normalize_diagnostic_status(Atom.to_string(s))

  defp normalize_diagnostic_status(_), do: "unavailable"

  defp marker_state_or(s, "invalid") when s in @marker_states, do: s
  defp marker_state_or(s, "unavailable") when s in @marker_states, do: s
  defp marker_state_or(s, status) when is_atom(s), do: marker_state_or(Atom.to_string(s), status)
  defp marker_state_or(_, "invalid"), do: "invalid"
  defp marker_state_or(_, _), do: "unavailable"

  defp bound_code(code) when is_binary(code), do: utf8_truncate(code, @max_summary_code_bytes)
  defp bound_code(code) when is_atom(code), do: bound_code(Atom.to_string(code))
  defp bound_code(_), do: "unknown"

  defp utf8_truncate(string, max_bytes)
       when is_binary(string) and is_integer(max_bytes) and max_bytes > 0 do
    cond do
      byte_size(string) > @max_resource_bytes -> ""
      not String.valid?(string) -> ""
      byte_size(string) <= max_bytes -> string
      true -> do_utf8_truncate(string, max_bytes, 0, [])
    end
  end

  defp do_utf8_truncate("", _max_bytes, _size, acc),
    do: acc |> Enum.reverse() |> :erlang.iolist_to_binary()

  defp do_utf8_truncate(string, max_bytes, size, acc) do
    case String.next_grapheme(string) do
      {grapheme, rest} when size + byte_size(grapheme) <= max_bytes ->
        do_utf8_truncate(rest, max_bytes, size + byte_size(grapheme), [grapheme | acc])

      _ ->
        acc |> Enum.reverse() |> :erlang.iolist_to_binary()
    end
  end

  defp error(reason), do: {:error, {:template_authority_preview, reason}}

  defdelegate project_effective(capabilities, agent_id, opts \\ []),
    to: TemplateAuthorityCapabilityProjection,
    as: :project_normalized
end
