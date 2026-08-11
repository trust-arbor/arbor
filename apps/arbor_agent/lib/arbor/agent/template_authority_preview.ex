defmodule Arbor.Agent.TemplateAuthorityPreview do
  @moduledoc false

  # Imperative read-only shell for target-scoped template-authority preview.
  # Fixed production collaborators only on the public path. Tests may inject via
  # project_with_deps/3; public opts never select modules/clocks/stores.
  #
  # Collaborators (reads only):
  #   ProfileStore.load_profile_authority_readonly/1
  #   TemplateStore.get_current/1
  #   Arbor.Security.list_capabilities/2
  #   Arbor.Trust.get_trust_profile/1
  #
  # Never reserves tasks, warms template cache, grants/revokes capabilities,
  # writes trust/profile state, creates workspace/branch/lease, or persists markers.

  alias Arbor.Agent.ProfileStore
  alias Arbor.Agent.TemplateAuthorityCapabilityProjection
  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Agent.TemplateAuthorityPreparation
  alias Arbor.Agent.TemplateAuthorityPreviewCore, as: Core
  alias Arbor.Agent.TemplateStore
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security
  alias Arbor.Trust

  @provenance_layers MapSet.new(["user", "shipped", "legacy_json"])
  @max_name_bytes 256
  @max_repo_root_bytes 1_024
  # Match TemplateAuthorityPreviewCore ownership row bound so live grants never
  # exceed what classify_ownership admits.
  @max_live_capabilities 512
  @digest_re ~r/\A[0-9a-f]{64}\z/

  @type deps :: %{
          optional(:profile_store) => module(),
          optional(:template_store) => module(),
          optional(:security) => module(),
          optional(:trust) => module(),
          optional(:repo_root) => String.t() | (-> term()),
          optional(:authority_snapshot) => (String.t() -> term())
        }

  @spec project(String.t(), keyword() | map()) :: {:ok, map()}
  def project(target_agent_id, opts \\ []) do
    project_with_deps(target_agent_id, opts, production_deps())
  end

  @doc false
  @spec project_with_deps(String.t(), keyword() | map(), deps()) :: {:ok, map()}
  def project_with_deps(target_agent_id, _opts, deps) when is_map(deps) do
    # Injected collaborators fully replace production ones for that key — never
    # fall back to ambient production modules or File.cwd after an injection.
    deps = merge_deps(deps)

    try do
      facts = gather_and_classify(target_agent_id, deps)

      case Core.compose(facts) do
        {:ok, report} ->
          {:ok, report}

        {:error, _} ->
          {:ok,
           Core.diagnostic_report(
             status: "invalid",
             target_agent_id: target_agent_id,
             code: "compose_failed"
           )}
      end
    rescue
      _ ->
        {:ok,
         Core.diagnostic_report(
           status: "unavailable",
           target_agent_id: target_agent_id,
           code: "projection_failed"
         )}
    catch
      _, _ ->
        {:ok,
         Core.diagnostic_report(
           status: "unavailable",
           target_agent_id: target_agent_id,
           code: "projection_failed"
         )}
    end
  end

  @doc false
  @spec prepare_authoritative(String.t(), String.t()) ::
          {:ok, map(), TemplateAuthorityPreparation.t()} | {:error, atom()}
  def prepare_authoritative(target_agent_id, expected_reconciliation_digest)
      when is_binary(target_agent_id) and is_binary(expected_reconciliation_digest) do
    prepare_authoritative_with_deps(
      target_agent_id,
      expected_reconciliation_digest,
      production_preparation_deps()
    )
  end

  def prepare_authoritative(_, _), do: {:error, :invalid_request}

  @doc false
  @spec prepare_authoritative_with_deps(String.t(), String.t(), deps()) ::
          {:ok, map(), TemplateAuthorityPreparation.t()} | {:error, atom()}
  def prepare_authoritative_with_deps(target_agent_id, expected_digest, deps)
      when is_binary(target_agent_id) and is_binary(expected_digest) and is_map(deps) do
    # Preparation never merges ambient production profile-store fallbacks for
    # the snapshot seam: only the fixed authority_snapshot collaborator is used.
    deps = merge_preparation_deps(deps)

    if not valid_expected_digest?(expected_digest) do
      {:error, :digest_invalid}
    else
      do_prepare_authoritative(target_agent_id, expected_digest, deps)
    end
  rescue
    _ -> {:error, :projection_failed}
  catch
    _, _ -> {:error, :projection_failed}
  end

  def prepare_authoritative_with_deps(_, _, _), do: {:error, :invalid_request}

  defp production_deps do
    %{
      profile_store: ProfileStore,
      template_store: TemplateStore,
      security: Security,
      trust: Trust,
      repo_root: &default_repo_root/0
    }
  end

  defp production_preparation_deps do
    production_deps()
    |> Map.put(:authority_snapshot, &ProfileStore.authority_mutation_snapshot/1)
  end

  defp merge_deps(deps) do
    # Only fill missing keys from production. Present keys (including an
    # explicit nil/function) stay as injected — no silent production fallback.
    Map.merge(production_deps(), deps, fn _k, _prod, injected -> injected end)
  end

  defp merge_preparation_deps(deps) do
    # Fixed production collaborators for non-snapshot reads. Snapshot is always
    # the injected or production authority_snapshot — never load_profile_* /
    # legacy/cache. Present keys stay as injected.
    Map.merge(production_preparation_deps(), deps, fn _k, _prod, injected -> injected end)
  end

  defp valid_expected_digest?(digest) when is_binary(digest) do
    byte_size(digest) == 64 and Regex.match?(@digest_re, digest)
  end

  defp valid_expected_digest?(_), do: false

  defp do_prepare_authoritative(target_agent_id, expected_digest, deps) do
    with {:ok, %Record{} = record} <- read_authority_snapshot(deps, target_agent_id),
         {:ok, profile_map} <- admit_record_data(record),
         facts <- gather_and_classify_from_profile_map(target_agent_id, deps, profile_map),
         {:ok, report} <- compose_preparation_report(facts),
         :ok <- require_exact_digest(report, expected_digest),
         {:ok, preparation} <- build_preparation(record, facts, report) do
      {:ok, report, preparation}
    end
  end

  defp compose_preparation_report(facts) do
    case Core.compose(facts) do
      {:ok, report} when is_map(report) ->
        {:ok, report}

      {:error, _} ->
        {:error, :observation_invalid}

      _ ->
        {:error, :projection_failed}
    end
  rescue
    _ -> {:error, :projection_failed}
  end

  defp require_exact_digest(report, expected) when is_map(report) do
    status = report["status"]
    digest = report["reconciliation_digest"]

    cond do
      status in ~w(invalid) ->
        {:error, :observation_invalid}

      status in ~w(unavailable) ->
        {:error, :observation_unavailable}

      not is_binary(digest) or digest == "" or is_nil(digest) ->
        {:error, :observation_incomplete}

      digest === expected ->
        :ok

      true ->
        {:error, :digest_stale}
    end
  end

  defp build_preparation(%Record{} = record, facts, _report) when is_map(facts) do
    with {:ok, profile_cas} <- profile_cas_from_record(record),
         {:ok, desired_authority} <- desired_authority_from_facts(facts),
         {:ok, repo_root} <- repo_root_from_facts(facts),
         {:ok, caps} <- effective_caps_from_facts(facts, desired_authority, repo_root) do
      case TemplateAuthorityPreparation.new(%{
             record: record,
             profile_cas: profile_cas,
             desired_authority: desired_authority,
             repo_root: repo_root,
             effective_capabilities: caps
           }) do
        {:ok, _} = ok -> ok
        {:error, _} -> {:error, :observation_invalid}
      end
    end
  end

  defp profile_cas_from_record(%Record{} = record) do
    id = record.id
    gen = record.generation
    rev = record.revision

    if is_binary(id) and id != "" and is_integer(gen) and gen >= 1 and is_integer(rev) and
         rev >= 1 do
      {:ok, %{"record_id" => id, "generation" => gen, "revision" => rev}}
    else
      {:error, :invalid_record}
    end
  end

  defp desired_authority_from_facts(facts) do
    envelope = Map.get(facts, :desired_envelope)

    with true <- is_map(envelope) and not is_struct(envelope),
         {:ok, validated} <- TemplateAuthorityPolicy.validate_envelope(envelope),
         true <- envelope === validated,
         digest when is_binary(digest) <- TemplateAuthorityPolicy.digest(validated),
         {:ok, prov} <- derived_desired_provenance(validated) do
      {:ok,
       %{
         "envelope" => validated,
         "declaration_digest" => digest,
         "provenance" => prov
       }}
    else
      _ -> {:error, :observation_invalid}
    end
  end

  defp derived_desired_provenance(validated) do
    snap = TemplateAuthorityPolicy.snapshot(validated)
    prov = TemplateAuthorityPolicy.provenance(snap)
    name = Map.get(prov, "name") || Map.get(snap, "template")
    layer = Map.get(prov, "layer")

    if is_binary(name) and name != "" and
         (is_nil(layer) or layer in ["user", "shipped", "legacy_json"]) do
      {:ok, %{"name" => name, "layer" => layer}}
    else
      :error
    end
  end

  defp repo_root_from_facts(facts) do
    # The complete observation path already admitted the root via the shared
    # primitive during gather; re-admit and require exact equality so whitespace
    # / trailing-slash aliases never freeze.
    case resolve_repo_root_from_observation(facts) do
      {:ok, root} when is_binary(root) ->
        case TemplateAuthorityCapabilityProjection.admit_canonical_repo_root(root) do
          {:ok, admitted} when admitted === root -> {:ok, admitted}
          _ -> {:error, :observation_invalid}
        end

      _ ->
        {:error, :observation_incomplete}
    end
  end

  defp resolve_repo_root_from_observation(facts) do
    # desired_view capabilities were projected with the admitted root; recover
    # the root only from the gather path's successful resolve stored implicitly
    # via re-resolving is not available. Prefer an explicit key if present.
    cond do
      is_binary(Map.get(facts, :repo_root)) ->
        {:ok, Map.get(facts, :repo_root)}

      is_binary(Map.get(facts, "repo_root")) ->
        {:ok, Map.get(facts, "repo_root")}

      true ->
        :error
    end
  end

  defp effective_caps_from_facts(facts, desired_authority, repo_root) do
    target = Map.get(facts, :target_agent_id)
    envelope = desired_authority["envelope"]

    with true <- is_binary(target) and target != "",
         snap when is_map(snap) <- TemplateAuthorityPolicy.snapshot(envelope),
         declared when is_list(declared) <- TemplateAuthorityPolicy.capabilities(snap),
         {:ok, derived} <-
           TemplateAuthorityCapabilityProjection.project_normalized(declared, target,
             repo_root: repo_root
           ),
         %{"capabilities" => caps} when is_list(caps) <- Map.get(facts, :desired_view),
         true <- caps === derived do
      # Composed desired_view must already carry the exact independent
      # projection — never silently prefer re-derived caps over a mismatch.
      {:ok, derived}
    else
      _ -> {:error, :observation_invalid}
    end
  end

  # ---------------------------------------------------------------------------
  # Fact gather + ownership (before ReconciliationCore)
  # ---------------------------------------------------------------------------

  defp gather_and_classify(target_agent_id, deps) do
    profile_read = read_profile(deps, target_agent_id)
    classify_profile_read(target_agent_id, deps, profile_read)
  end

  defp gather_and_classify_from_profile_map(target_agent_id, deps, profile_map)
       when is_map(profile_map) do
    classify_profile_read(target_agent_id, deps, {:ok, profile_map})
  end

  defp classify_profile_read(target_agent_id, deps, profile_read) do
    case profile_read do
      {:ok, profile} ->
        case admit_profile(profile, target_agent_id) do
          {:ok, fields} ->
            gather_from_profile(target_agent_id, deps, fields)

          {:invalid, _} ->
            %{
              target_agent_id: target_agent_id,
              profile_version: nil,
              template_name: nil,
              reads: %{profile: :invalid}
            }
        end

      {:unavailable, _reason} ->
        %{
          target_agent_id: target_agent_id,
          profile_version: nil,
          template_name: nil,
          reads: %{profile: :unavailable}
        }

      {:invalid, _} ->
        %{
          target_agent_id: target_agent_id,
          profile_version: nil,
          template_name: nil,
          reads: %{profile: :invalid}
        }
    end
  end

  defp gather_from_profile(target_agent_id, deps, fields) do
    %{
      template_name: template_name,
      profile_version: profile_version,
      metadata: metadata,
      initial_caps: initial_caps,
      persisted_provenance: persisted_provenance
    } = fields

    # Always invoke every collaborator and admit the authority marker before
    # rank so invalid marker/trust/cap observations outrank peer unavailable.
    marker = read_marker(metadata)
    template_read = read_template(deps, template_name)

    caps_read =
      deps
      |> read_capabilities(target_agent_id)
      |> admit_capability_observation(target_agent_id)

    trust_read =
      deps
      |> read_trust(target_agent_id)
      |> admit_trust_observation(target_agent_id)

    repo_root_read = resolve_repo_root(deps)

    reads = %{
      profile: :ok,
      template: read_status(template_read),
      capabilities: read_status(caps_read),
      trust: read_status(trust_read),
      repo_root: read_status(repo_root_read)
    }

    base = %{
      target_agent_id: target_agent_id,
      profile_version: profile_version,
      template_name: template_name,
      persisted_provenance: persisted_provenance,
      reads: reads
    }

    base = maybe_put_marker_invalid(base, marker)

    case observation_rank(reads, marker) do
      :invalid ->
        base

      :unavailable ->
        base

      :ok ->
        {:ok, template_data} = ok_payload(template_read)
        {:ok, live_caps} = ok_payload(caps_read)
        {:ok, live_trust} = ok_payload(trust_read)
        {:ok, repo_root} = ok_payload(repo_root_read)

        # Keep the admitted canonical root on the facts so preparation can
        # freeze the same value without re-deriving from ambient cwd.
        base = Map.put(base, :repo_root, repo_root)

        with {:ok, base, _desired} <-
               build_desired(base, template_name, template_data, target_agent_id, repo_root),
             {:ok, base, legacy_specs} <-
               project_legacy(base, initial_caps, target_agent_id, repo_root),
             {:ok, base, ownership} <- classify(base, live_caps, legacy_specs),
             {:ok, base} <- attach_marker(base, marker),
             {:ok, base} <- attach_actual_view(base, ownership, live_trust) do
          base
        else
          {:unavailable, facts} -> facts
          {:invalid, facts} -> facts
        end
    end
  end

  defp read_status({:ok, _}), do: :ok
  defp read_status({:unavailable, _}), do: :unavailable
  defp read_status({:invalid, _}), do: :invalid

  defp ok_payload({:ok, value}), do: {:ok, value}

  defp maybe_put_marker_invalid(base, {:error, _}), do: Map.put(base, :marker, :invalid)
  defp maybe_put_marker_invalid(base, _), do: base

  # Invalid outranks unavailable. Malformed authority markers participate in
  # the same rank so they are never skipped when a collaborator is unavailable.
  defp observation_rank(reads, marker) when is_map(reads) do
    statuses = Map.values(reads)
    marker_invalid? = match?({:error, _}, marker)

    cond do
      marker_invalid? or Enum.any?(statuses, &(&1 == :invalid)) -> :invalid
      Enum.any?(statuses, &(&1 == :unavailable)) -> :unavailable
      true -> :ok
    end
  end

  defp admit_profile(profile, target_agent_id) do
    with :ok <- admit_profile_principal(profile, target_agent_id) do
      extract_profile_fields(profile)
    end
  rescue
    _ -> {:invalid, :malformed_profile}
  end

  defp admit_profile_principal(profile, target_agent_id) do
    case profile_agent_id(profile) do
      ^target_agent_id -> :ok
      nil -> {:invalid, :profile_principal_missing}
      _other -> {:invalid, :profile_principal_mismatch}
    end
  end

  defp profile_agent_id(profile) do
    map = profile_as_map(profile)

    case fetch_unique_field(map, "agent_id") do
      {:ok, {:ok, id}} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp profile_as_map(%{__struct__: _} = struct), do: Map.from_struct(struct)
  defp profile_as_map(map) when is_map(map), do: map
  defp profile_as_map(_), do: %{}

  defp extract_profile_fields(profile) do
    map = profile_as_map(profile)

    with {:ok, template_name} <- admit_template_name_field(map),
         {:ok, version} <- admit_profile_version_field(map),
         {:ok, metadata} <- admit_profile_metadata_field(map),
         {:ok, initial_caps} <- admit_initial_capabilities_field(map),
         {:ok, provenance} <- admit_persisted_provenance(metadata) do
      {:ok,
       %{
         template_name: template_name,
         profile_version: version,
         metadata: metadata,
         initial_caps: initial_caps,
         persisted_provenance: provenance
       }}
    end
  end

  defp admit_template_name_field(map) do
    case fetch_unique_field(map, "template") do
      {:ok, {:ok, name}} when is_binary(name) and name != "" ->
        if byte_size(name) <= @max_name_bytes and String.valid?(name) and
             not String.contains?(name, <<0>>) do
          {:ok, name}
        else
          {:invalid, :template_name_invalid}
        end

      {:ok, {:ok, name}} when is_atom(name) and not is_nil(name) ->
        admit_template_name_field(%{"template" => Atom.to_string(name)})

      {:ok, :absent} ->
        {:invalid, :template_name_missing}

      {:ok, {:ok, nil}} ->
        {:invalid, :template_name_missing}

      {:ok, {:ok, _}} ->
        {:invalid, :template_name_invalid}

      {:error, _} ->
        {:invalid, :template_name_conflict}
    end
  end

  # Positive integer only — never coerce missing/nil/0 to a synthetic version.
  defp admit_profile_version_field(map) do
    case fetch_unique_field(map, "version") do
      {:ok, {:ok, v}} when is_integer(v) and v > 0 ->
        {:ok, v}

      {:ok, :absent} ->
        {:invalid, :profile_version_missing}

      {:ok, {:ok, nil}} ->
        {:invalid, :profile_version_missing}

      {:ok, {:ok, _}} ->
        {:invalid, :profile_version_invalid}

      {:error, _} ->
        {:invalid, :profile_version_conflict}
    end
  end

  # Metadata must be an explicit map — nil/missing never become %{} silently.
  defp admit_profile_metadata_field(map) do
    case fetch_unique_field(map, "metadata") do
      {:ok, {:ok, metadata}} when is_map(metadata) and not is_struct(metadata) ->
        {:ok, metadata}

      {:ok, :absent} ->
        {:invalid, :metadata_missing}

      {:ok, {:ok, nil}} ->
        {:invalid, :metadata_missing}

      {:ok, {:ok, _}} ->
        {:invalid, :metadata_invalid}

      {:error, _} ->
        {:invalid, :metadata_conflict}
    end
  end

  # initial_capabilities must be an explicit proper list — nil/missing never [].
  defp admit_initial_capabilities_field(map) do
    case fetch_unique_field(map, "initial_capabilities") do
      {:ok, {:ok, caps}} when is_list(caps) ->
        case walk_proper_list_bound(caps, 0, @max_live_capabilities) do
          :ok -> {:ok, caps}
          {:invalid, _} = failure -> failure
        end

      {:ok, :absent} ->
        {:invalid, :initial_capabilities_missing}

      {:ok, {:ok, nil}} ->
        {:invalid, :initial_capabilities_missing}

      {:ok, {:ok, _}} ->
        {:invalid, :initial_capabilities_invalid}

      {:error, _} ->
        {:invalid, :initial_capabilities_conflict}
    end
  end

  # Bounded proper-list walker — rejects improper tails and oversize lists
  # before any Enum traversal that would raise or loop.
  defp walk_proper_list_bound([], _n, _max), do: :ok

  defp walk_proper_list_bound([_head | tail], n, max)
       when is_list(tail) and n < max do
    walk_proper_list_bound(tail, n + 1, max)
  end

  defp walk_proper_list_bound([_head | tail], n, max)
       when is_list(tail) and n >= max do
    {:invalid, :list_too_long}
  end

  defp walk_proper_list_bound([_head | _improper], _n, _max),
    do: {:invalid, :improper_list}

  defp walk_proper_list_bound(_other, _n, _max), do: {:invalid, :not_a_list}

  # Admit successful capability lists with a bounded proper-list walker so
  # principal binding failures dominate peer unavailable reads, and improper
  # or oversized lists never reach Enum.
  defp admit_capability_observation({:ok, caps}, target_agent_id) do
    case walk_capability_principals(caps, target_agent_id, 0, []) do
      {:ok, admitted} -> {:ok, Enum.reverse(admitted)}
      {:invalid, _} = failure -> failure
    end
  end

  defp admit_capability_observation(other, _target_agent_id), do: other

  defp walk_capability_principals([], _target, _n, acc), do: {:ok, acc}

  defp walk_capability_principals([cap | rest], target, n, acc)
       when is_list(rest) and n < @max_live_capabilities do
    case capability_principal(cap) do
      ^target ->
        walk_capability_principals(rest, target, n + 1, [cap | acc])

      _other ->
        {:invalid, :principal_invalid}
    end
  end

  defp walk_capability_principals([_cap | rest], _target, n, _acc)
       when is_list(rest) and n >= @max_live_capabilities do
    {:invalid, :capabilities_too_many}
  end

  defp walk_capability_principals([_cap | _improper], _target, _n, _acc),
    do: {:invalid, :improper_capabilities}

  defp walk_capability_principals(_other, _target, _n, _acc),
    do: {:invalid, :malformed_capabilities}

  defp capability_principal(%{__struct__: _} = struct),
    do: capability_principal(Map.from_struct(struct))

  defp capability_principal(cap) when is_map(cap) do
    case fetch_unique_field(cap, "principal_id") do
      {:ok, {:ok, id}} when is_binary(id) and id != "" ->
        if byte_size(id) <= @max_name_bytes and String.valid?(id) and
             not String.contains?(id, <<0>>) do
          id
        else
          :invalid
        end

      {:ok, :absent} ->
        :missing

      {:ok, {:ok, _}} ->
        :invalid

      {:error, _} ->
        :invalid
    end
  end

  defp capability_principal(_), do: :invalid

  # Admit successful trust payloads: principal binding + trust-preset shape.
  defp admit_trust_observation({:ok, trust}, target_agent_id) when is_map(trust) do
    with :ok <- check_trust_principal(trust, target_agent_id),
         {:ok, _preset} <- normalize_live_trust(trust) do
      {:ok, trust}
    else
      {:error, _} -> {:invalid, :malformed_trust}
    end
  end

  defp admit_trust_observation({:ok, _}, _target_agent_id), do: {:invalid, :malformed_trust}
  defp admit_trust_observation(other, _target_agent_id), do: other

  defp check_trust_principal(trust, target_agent_id) when is_map(trust) do
    case fetch_unique_field(trust, "agent_id") do
      {:ok, {:ok, ^target_agent_id}} -> :ok
      {:ok, :absent} -> {:error, :trust_principal_missing}
      {:ok, {:ok, nil}} -> {:error, :trust_principal_missing}
      {:ok, {:ok, _}} -> {:error, :trust_principal_mismatch}
      {:error, _} -> {:error, :trust_principal_conflict}
    end
  end

  defp build_desired(base, template_name, template_data, target_agent_id, repo_root) do
    case TemplateAuthorityPolicy.build(template_name, template_data) do
      {:ok, envelope} ->
        snap = TemplateAuthorityPolicy.snapshot(envelope)
        declared = TemplateAuthorityPolicy.capabilities(snap)
        trust = TemplateAuthorityPolicy.trust_preset(snap)
        provenance = TemplateAuthorityPolicy.provenance(snap)

        case TemplateAuthorityCapabilityProjection.project_normalized(
               declared,
               target_agent_id,
               repo_root: repo_root
             ) do
          {:ok, effective_caps} ->
            desired_view = %{
              "capabilities" => effective_caps,
              "trust_preset" => trust
            }

            {:ok,
             Map.merge(base, %{
               desired_envelope: envelope,
               desired_view: desired_view,
               desired_provenance: provenance
             }), desired_view}

          {:error, _} ->
            {:invalid, Map.put(base, :desired, :invalid)}
        end

      {:error, _} ->
        {:invalid, Map.put(base, :desired, :invalid)}
    end
  end

  defp project_legacy(base, initial_caps, target_agent_id, repo_root) do
    case TemplateAuthorityCapabilityProjection.project_normalized(
           initial_caps,
           target_agent_id,
           repo_root: repo_root
         ) do
      {:ok, specs} ->
        {:ok, base, specs}

      {:error, _} ->
        if is_list(initial_caps) and initial_caps == [] do
          {:ok, base, []}
        else
          # Malformed initial_capabilities is invalid profile authority state.
          {:invalid, Map.put(base, :desired, :invalid)}
        end
    end
  end

  defp classify(base, live_caps, legacy_specs) do
    case Core.classify_ownership(live_caps, legacy_specs) do
      {:ok, ownership} ->
        {:ok, base, ownership}

      {:error, :ownership_invalid} ->
        {:invalid, Map.put(base, :ownership, :invalid)}

      {:error, _} ->
        {:invalid, Map.put(base, :ownership, :invalid)}
    end
  end

  defp attach_marker(base, :not_marked) do
    {:ok, Map.put(base, :stored_marker, %{state: "absent", digest: nil, envelope: nil})}
  end

  defp attach_marker(base, {:ok, envelope}) when is_map(envelope) do
    {:ok,
     Map.put(base, :stored_marker, %{
       state: "valid",
       digest: TemplateAuthorityPolicy.digest(envelope),
       envelope: envelope
     })}
  end

  defp attach_marker(base, {:error, _}) do
    {:invalid, Map.put(base, :marker, :invalid)}
  end

  defp attach_actual_view(base, ownership, live_trust) do
    managed_caps = ownership["managed"] || []
    preserved = ownership["preserved"] || []
    rows = ownership["rows"] || []

    case normalize_live_trust(live_trust) do
      {:ok, trust_preset} ->
        managed_actual_view = %{
          "capabilities" => managed_caps,
          "trust_preset" => trust_preset
        }

        {:ok,
         Map.merge(base, %{
           managed_actual_view: managed_actual_view,
           preserved: preserved,
           ownership_rows: rows,
           ownership_class: ownership["ownership"] || "clean"
         })}

      {:error, _} ->
        {:invalid, %{base | reads: Map.put(base.reads, :trust, :invalid)}}
    end
  end

  defp normalize_live_trust(trust) when is_map(trust) do
    with {:ok, baseline_fetch} <- fetch_unique_field(trust, "baseline"),
         {:ok, rules_fetch} <- fetch_unique_field(trust, "rules"),
         {:ok, baseline} <- require_present(baseline_fetch, :baseline_missing),
         {:ok, rules} <- optional_map(rules_fetch) do
      case TemplateAuthorityPolicy.normalize_trust_preset(%{
             "baseline" => baseline,
             "rules" => rules
           }) do
        {:ok, preset} -> {:ok, preset}
        {:error, _} = failure -> failure
      end
    else
      {:error, _} = failure -> failure
    end
  end

  defp normalize_live_trust(_), do: {:error, :invalid_trust}

  defp require_present(:absent, reason), do: {:error, reason}
  defp require_present({:ok, value}, _reason), do: {:ok, value}

  defp optional_map(:absent), do: {:ok, %{}}
  defp optional_map({:ok, rules}) when is_map(rules) and not is_struct(rules), do: {:ok, rules}
  defp optional_map({:ok, nil}), do: {:ok, %{}}
  defp optional_map({:ok, _}), do: {:error, :invalid_trust_rules}

  # ---------------------------------------------------------------------------
  # Collaborator reads (never raise into gather — rescue at each boundary)
  # ---------------------------------------------------------------------------

  defp read_profile(deps, agent_id) do
    store = Map.get(deps, :profile_store)

    if is_atom(store) and function_exported?(store, :load_profile_authority_readonly, 1) do
      case store.load_profile_authority_readonly(agent_id) do
        {:ok, profile} when is_map(profile) and not is_struct(profile) ->
          {:ok, profile}

        {:error, :not_found} ->
          {:unavailable, :not_found}

        {:error, _} ->
          {:unavailable, :profile_read_failed}

        _ ->
          {:invalid, :malformed_profile}
      end
    else
      {:unavailable, :profile_collaborator_missing}
    end
  rescue
    _ -> {:unavailable, :profile_read_failed}
  catch
    _, _ -> {:unavailable, :profile_read_failed}
  end

  defp read_template(_deps, nil), do: {:unavailable, :no_template_name}

  defp read_template(deps, name) when is_binary(name) do
    store = Map.get(deps, :template_store)

    if is_atom(store) and function_exported?(store, :get_current, 1) do
      case store.get_current(name) do
        {:ok, data} when is_map(data) ->
          {:ok, data}

        {:error, :not_found} ->
          {:unavailable, :not_found}

        {:error, _} ->
          {:unavailable, :template_read_failed}

        _ ->
          {:invalid, :malformed_template}
      end
    else
      {:unavailable, :template_collaborator_missing}
    end
  rescue
    _ -> {:unavailable, :template_read_failed}
  catch
    _, _ -> {:unavailable, :template_read_failed}
  end

  # Preserve the injected template_store for atom template names — convert the
  # name only, never swap the collaborator or warm a production cache.
  defp read_template(deps, name) when is_atom(name),
    do: read_template(deps, Atom.to_string(name))

  defp read_capabilities(deps, agent_id) do
    security = Map.get(deps, :security)

    cond do
      is_atom(security) and function_exported?(security, :list_capabilities, 2) ->
        case security.list_capabilities(agent_id, []) do
          {:ok, caps} when is_list(caps) -> {:ok, caps}
          {:error, _} -> {:unavailable, :capabilities_read_failed}
          _ -> {:invalid, :malformed_capabilities}
        end

      is_atom(security) and function_exported?(security, :list_capabilities, 1) ->
        case security.list_capabilities(agent_id) do
          {:ok, caps} when is_list(caps) -> {:ok, caps}
          {:error, _} -> {:unavailable, :capabilities_read_failed}
          _ -> {:invalid, :malformed_capabilities}
        end

      true ->
        {:unavailable, :security_collaborator_missing}
    end
  rescue
    _ -> {:unavailable, :capabilities_read_failed}
  catch
    _, _ -> {:unavailable, :capabilities_read_failed}
  end

  defp read_trust(deps, agent_id) do
    trust = Map.get(deps, :trust)

    if is_atom(trust) and function_exported?(trust, :get_trust_profile, 1) do
      case trust.get_trust_profile(agent_id) do
        {:ok, profile} when is_map(profile) or is_struct(profile) ->
          {:ok, profile_to_map(profile)}

        {:error, :not_found} ->
          # Missing trust profile is unavailable — never invent synthetic ask/empty.
          {:unavailable, :trust_not_found}

        {:error, _} ->
          {:unavailable, :trust_read_failed}

        _ ->
          {:invalid, :malformed_trust}
      end
    else
      {:unavailable, :trust_collaborator_missing}
    end
  rescue
    _ -> {:unavailable, :trust_read_failed}
  catch
    _, _ -> {:unavailable, :trust_read_failed}
  end

  defp profile_to_map(%{__struct__: _} = struct), do: Map.from_struct(struct)
  defp profile_to_map(map) when is_map(map), do: map

  defp read_marker(metadata) when is_map(metadata) do
    TemplateAuthorityPolicy.from_metadata(metadata)
  end

  defp read_marker(_), do: :not_marked

  # Persisted provenance is profile metadata.template_source only — never the
  # stored authority marker envelope provenance (that is stored_provenance).
  # Absent/nil template_source → nil. A present map must carry an explicit
  # bounded name and an explicit layer in user|shipped|legacy_json. Name may
  # differ from profile.template (drift evidence for the pure core).
  defp admit_persisted_provenance(metadata) when is_map(metadata) do
    case fetch_unique_field(metadata, "template_source") do
      {:ok, :absent} ->
        {:ok, nil}

      {:ok, {:ok, nil}} ->
        {:ok, nil}

      {:ok, {:ok, source}} when is_map(source) and not is_struct(source) ->
        admit_provenance_map(source)

      {:ok, {:ok, _}} ->
        {:invalid, :provenance_invalid}

      {:error, _} ->
        {:invalid, :provenance_conflict}
    end
  end

  defp admit_persisted_provenance(_), do: {:invalid, :provenance_invalid}

  defp admit_provenance_map(source) do
    with {:ok, name_fetch} <- fetch_unique_field(source, "name"),
         {:ok, layer_fetch} <- fetch_unique_field(source, "layer"),
         {:ok, name} <- require_provenance_name(name_fetch),
         {:ok, layer} <- require_provenance_layer(layer_fetch) do
      # Absolute source paths are intentionally dropped — never enter the report.
      {:ok, %{"name" => name, "layer" => layer}}
    else
      {:invalid, _} = failure -> failure
      {:error, _} -> {:invalid, :provenance_invalid}
    end
  end

  defp require_provenance_name(:absent), do: {:invalid, :provenance_name_missing}
  defp require_provenance_name({:ok, nil}), do: {:invalid, :provenance_name_missing}

  defp require_provenance_name({:ok, name}) when is_atom(name),
    do: require_provenance_name({:ok, Atom.to_string(name)})

  defp require_provenance_name({:ok, name}) when is_binary(name) do
    if name != "" and byte_size(name) <= @max_name_bytes and String.valid?(name) and
         not String.contains?(name, <<0>>) do
      {:ok, name}
    else
      {:invalid, :provenance_name_invalid}
    end
  end

  defp require_provenance_name(_), do: {:invalid, :provenance_name_invalid}

  # Present provenance maps require an explicit closed layer — never nil/absent.
  defp require_provenance_layer(:absent), do: {:invalid, :provenance_layer_missing}
  defp require_provenance_layer({:ok, nil}), do: {:invalid, :provenance_layer_missing}

  defp require_provenance_layer({:ok, layer}) when is_atom(layer),
    do: require_provenance_layer({:ok, Atom.to_string(layer)})

  defp require_provenance_layer({:ok, layer}) when is_binary(layer) do
    if MapSet.member?(@provenance_layers, layer) do
      {:ok, layer}
    else
      {:invalid, :provenance_layer_invalid}
    end
  end

  defp require_provenance_layer(_), do: {:invalid, :provenance_layer_invalid}

  # Fetch admitting atom or string keys; fail closed on conflicting pairs.
  defp fetch_unique_field(map, key) when is_map(map) and is_binary(key) do
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

        if values_conflict?(string_val, atom_val) do
          {:error, :conflict}
        else
          {:ok, {:ok, string_val}}
        end

      string_present? ->
        {:ok, {:ok, Map.get(map, key)}}

      atom_present? ->
        {:ok, {:ok, Map.get(map, atom_key)}}

      true ->
        {:ok, :absent}
    end
  end

  defp values_conflict?(a, b) when is_atom(a) and is_binary(b), do: Atom.to_string(a) != b
  defp values_conflict?(a, b) when is_binary(a) and is_atom(b), do: a != Atom.to_string(b)
  defp values_conflict?(a, b), do: a != b

  # Injected repo_root collaborator failures never fall back to File.cwd or
  # production ambient resolution.
  defp resolve_repo_root(deps) do
    case Map.fetch(deps, :repo_root) do
      {:ok, fun} when is_function(fun, 0) ->
        case invoke_repo_root_fun(fun) do
          {:ok, root} when is_binary(root) ->
            admit_repo_root_string(root)

          {:ok, _} ->
            {:invalid, :repo_root_invalid}

          {:error, :raised} ->
            {:unavailable, :repo_root_failed}

          {:error, _} ->
            {:unavailable, :repo_root_failed}
        end

      {:ok, root} when is_binary(root) ->
        admit_repo_root_string(root)

      {:ok, _} ->
        {:invalid, :repo_root_invalid}

      :error ->
        {:unavailable, :repo_root_missing}
    end
  end

  defp invoke_repo_root_fun(fun) do
    {:ok, fun.()}
  rescue
    _ -> {:error, :raised}
  catch
    _, _ -> {:error, :raised}
  end

  # Shared pure admission with CapabilityProjection / OperationCore — never a
  # second local path normalizer.
  defp admit_repo_root_string(root) when is_binary(root) and byte_size(root) <= @max_repo_root_bytes do
    case TemplateAuthorityCapabilityProjection.admit_canonical_repo_root(root) do
      {:ok, admitted} -> {:ok, admitted}
      {:error, _} -> {:invalid, :repo_root_invalid}
    end
  end

  defp admit_repo_root_string(_root), do: {:invalid, :repo_root_invalid}

  # ---------------------------------------------------------------------------
  # Authoritative snapshot (preparation only — never ordinary preview)
  # ---------------------------------------------------------------------------

  defp read_authority_snapshot(deps, agent_id) do
    fun = Map.get(deps, :authority_snapshot)

    cond do
      is_function(fun, 1) ->
        case fun.(agent_id) do
          {:ok, %Record{} = record} ->
            {:ok, record}

          {:error, :not_found} ->
            {:error, :not_found}

          {:error, :authority_not_durable} ->
            {:error, :authority_not_durable}

          {:error, :invalid_record} ->
            {:error, :invalid_record}

          {:error, :backend_unavailable} ->
            {:error, :backend_unavailable}

          {:error, :invalid_request} ->
            {:error, :invalid_request}

          {:error, _} ->
            {:error, :snapshot_unavailable}

          _ ->
            {:error, :snapshot_unavailable}
        end

      is_atom(fun) and function_exported?(fun, :authority_mutation_snapshot, 1) ->
        read_authority_snapshot(%{deps | authority_snapshot: &fun.authority_mutation_snapshot/1}, agent_id)

      true ->
        {:error, :snapshot_unavailable}
    end
  rescue
    _ -> {:error, :snapshot_unavailable}
  catch
    _, _ -> {:error, :snapshot_unavailable}
  end

  defp admit_record_data(%Record{data: data}) when is_map(data) and not is_struct(data) do
    {:ok, data}
  end

  defp admit_record_data(_), do: {:error, :invalid_record}

  # Production-only ambient resolution. Spelling matches Lifecycle's
  # repo_root_for_capabilities/0 exactly (Path.expand + umbrella walk +
  # trim_trailing("/"), no SafePath.resolve_real). Never consulted after an
  # injected repo_root collaborator is present in deps.
  defp default_repo_root do
    cwd = File.cwd!() |> Path.expand()

    root =
      cwd
      |> ancestor_paths()
      |> Enum.find(&umbrella_root?/1)

    (root || cwd)
    |> String.trim_trailing("/")
  end

  defp umbrella_root?(path) do
    File.exists?(Path.join(path, "mix.exs")) and File.dir?(Path.join(path, "apps"))
  end

  defp ancestor_paths(path), do: ancestor_paths(path, [])

  defp ancestor_paths(path, acc) do
    parent = Path.dirname(path)

    if parent == path do
      Enum.reverse([path | acc])
    else
      ancestor_paths(parent, [path | acc])
    end
  end
end
