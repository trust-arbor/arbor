defmodule Arbor.Actions.Coding.BranchAuditCore do
  @moduledoc """
  Pure policy and manifest functions for the historical coding-branch audit.

  This module only consumes JSON-clean observations. Git, the retention registry,
  and all effects belong to `Arbor.Actions.Coding.BranchAudit`.
  """

  alias Arbor.Actions.Git

  @format "arbor.coding.branch_audit"
  @version 1
  @max_manifest_bytes 32 * 1024 * 1024
  @max_branch_entries 4096
  @max_reason_bytes 1024
  @max_proof_commits 256
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @proof_keys ~w(
    method base_commit candidate_commit destination_ref destination_commit
    candidate_commit_count audit
  )
  @patch_audit_keys ~w(
    representation candidate_range_count destination_range_count
    matched_candidate_patch_count candidate_patches destination_patches
    aggregate_destination
  )
  @protected_classes ~w(destination checked_out retained explicitly_preserved)
  @retained_reasons ~w(
    active_workspace_ref active_orphaned_workspace_ref creating_workspace_ref
    discarding_workspace_ref dormant_workspace_ref retained_workspace_ref
  )
  @retention_lifecycles ~w(retained active creating discarding)
  @discard_phases ~w(archive worktree branch)
  @deterministic_range_sides [:candidate, :destination, :patch_bytes, :patch_evidence_bytes]
  @known_config_codes ~w(
    invalid_config_output empty_match_output malformed_config_output malformed_config_record
    invalid_config_entries unsafe_git_configuration invalid_worktree_config
  )

  @type json :: map() | list() | String.t() | number() | boolean() | nil

  @spec format() :: String.t()
  def format, do: @format

  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Classify an exact branch inventory using already-observed proof results."
  @spec classify([map()], map(), map(), map(), map()) :: [map()]
  def classify(branches, destination, protections, proofs, opts \\ %{})

  def classify(branches, destination, protections, proofs, opts)
      when is_list(branches) and is_map(destination) and is_map(protections) and
             is_map(proofs) and is_map(opts) do
    survivors = duplicate_survivors(branches, protections, destination)

    branches
    |> Enum.sort_by(& &1["ref"])
    |> Enum.map(fn branch ->
      ref = branch["ref"]

      case policy_protection(ref, destination) || Map.get(protections, ref) do
        %{class: class, reason: reason} ->
          entry(branch, class, reason, "preserve")

        nil ->
          classify_unprotected(branch, destination, proofs, survivors, opts)
      end
    end)
  end

  @doc "Build a deterministic, JSON-clean manifest body and bind its digest."
  @spec manifest(map(), map(), [map()], [String.t()], map()) :: {:ok, map()} | {:error, term()}
  def manifest(repository, destination, branches, errors, limits)
      when is_map(repository) and is_map(destination) and is_list(branches) and
             is_list(errors) and is_map(limits) do
    body = %{
      "format" => @format,
      "version" => @version,
      "repository" => repository,
      "destination" => destination,
      "branches" => Enum.sort_by(branches, & &1["ref"]),
      "errors" => Enum.sort(errors),
      "limits" => limits
    }

    with :ok <- validate_body(body),
         digest <- digest(body) do
      {:ok, Map.put(body, "manifest_sha256", digest)}
    end
  end

  @doc "Validate the exact closed schema of a reviewed manifest."
  @spec validate_manifest(map()) :: {:ok, map()} | {:error, term()}
  def validate_manifest(manifest) when is_map(manifest) and not is_struct(manifest) do
    with :ok <- validate_json(manifest),
         :ok <- require_string_keys(manifest),
         :ok <-
           exact_keys(
             manifest,
             ~w(format version repository destination branches errors limits manifest_sha256)
           ),
         true <- manifest["format"] == @format,
         true <- manifest["version"] == @version,
         :ok <- validate_repository(manifest["repository"]),
         :ok <- validate_destination(manifest["destination"]),
         :ok <- validate_limits(manifest["limits"]),
         :ok <- validate_errors(manifest["errors"]),
         :ok <-
           validate_branches(
             manifest["branches"],
             manifest["destination"],
             manifest["limits"]["max_branch_count"],
             manifest["errors"]
           ),
         true <- is_binary(manifest["manifest_sha256"]),
         true <- Regex.match?(@sha256, manifest["manifest_sha256"]),
         {:ok, _canonical} <- canonical_manifest(manifest),
         true <- digest(manifest) == manifest["manifest_sha256"] do
      {:ok, manifest}
    else
      false -> {:error, :invalid_branch_audit_manifest}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_branch_audit_manifest}
    end
  end

  def validate_manifest(_manifest), do: {:error, :invalid_branch_audit_manifest}

  @doc "Return canonical JSON bytes for a manifest without its digest field."
  @spec canonical_manifest(map()) :: {:ok, String.t()} | {:error, term()}
  def canonical_manifest(manifest) when is_map(manifest) do
    body = Map.delete(manifest, "manifest_sha256")

    with :ok <- validate_json(body),
         :ok <- require_string_keys(body) do
      {:ok, canonical_json(body)}
    end
  end

  @doc "Decode one manifest JSON document while rejecting duplicate object keys."
  @spec decode_manifest_json(binary()) :: {:ok, map()} | {:error, term()}
  def decode_manifest_json(bytes)
      when is_binary(bytes) and byte_size(bytes) <= @max_manifest_bytes do
    case Jason.decode(bytes, objects: :ordered_objects) do
      {:ok, ordered} ->
        case normalize_ordered_json(ordered) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          {:ok, _other} -> {:error, :invalid_branch_audit_manifest}
          {:error, _reason} = error -> error
        end

      {:error, _reason} ->
        {:error, :invalid_branch_audit_json}
    end
  end

  def decode_manifest_json(_bytes), do: {:error, :manifest_size_exceeded}

  @doc "Compute the digest of a manifest body without `manifest_sha256`."
  @spec digest(map()) :: String.t()
  def digest(body) when is_map(body) do
    body
    |> Map.delete("manifest_sha256")
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Expose canonical bytes for the Mix task and focused tests."
  @spec canonical_json(json()) :: String.t()
  def canonical_json(value), do: IO.iodata_to_binary(do_canonical_json(value))

  @doc "Validate one adoption proof against the exact branch and destination observations."
  @spec validate_adoption_proof(map(), map(), map()) :: :ok | {:error, term()}
  def validate_adoption_proof(proof, branch, destination)
      when is_map(proof) and is_map(branch) and is_map(destination) do
    if valid_adoption_proof?(proof, proof["method"], branch, destination),
      do: :ok,
      else: {:error, :invalid_adoption_proof}
  end

  def validate_adoption_proof(_proof, _branch, _destination),
    do: {:error, :invalid_adoption_proof}

  @doc "Return bounded, JSON-clean status for a proof failure without retaining raw terms."
  @spec proof_failure(term()) :: map()
  def proof_failure({:not_adopted, _reason}),
    do:
      failure_status("not_adopted", "patch_not_represented_on_destination", "not_adopted", false)

  def proof_failure({:range_too_large, side, limit})
      when side in @deterministic_range_sides and is_integer(limit) and limit > 0,
      do: failure_status("range_too_large", Atom.to_string(side), Integer.to_string(limit), false)

  def proof_failure(
        {:invalid_input, {:git_storage_validation_failed, _operation, exit_code, _stderr}}
      )
      when is_integer(exit_code),
      do:
        failure_status(
          "git_storage_validation_failed",
          "invalid_input",
          "exit_" <> Integer.to_string(exit_code),
          true
        )

  def proof_failure({:invalid_input, {:git_command_failed, exit_code}})
      when is_integer(exit_code),
      do:
        failure_status("git_command_failed", "invalid_input", Integer.to_string(exit_code), true)

  def proof_failure({:invalid_input, {:git_storage_identity_changed, _path}}),
    do: failure_status("git_storage_identity_changed", "storage", "identity_changed", true)

  def proof_failure({:git_storage_identity_changed, _path}),
    do: failure_status("git_storage_identity_changed", "storage", "identity_changed", true)

  def proof_failure({:invalid_input, {:invalid_git_storage_path, _option, _output}}),
    do: failure_status("invalid_git_storage_path", "storage", "path_rejected", true)

  def proof_failure({:invalid_git_storage_path, _option, _output}),
    do: failure_status("invalid_git_storage_path", "storage", "path_rejected", true)

  def proof_failure({:invalid_input, {:invalid_git_storage_directory, _path}}),
    do: failure_status("invalid_git_storage_directory", "storage", "directory_rejected", true)

  def proof_failure({:invalid_git_storage_directory, _path}),
    do: failure_status("invalid_git_storage_directory", "storage", "directory_rejected", true)

  def proof_failure({:invalid_input, {:git_config_audit_failed, code, _output}}),
    do: failure_status("git_config_audit_failed", "config", categorical_code(code), true)

  def proof_failure({:git_config_audit_failed, code, _output}),
    do: failure_status("git_config_audit_failed", "config", categorical_code(code), true)

  def proof_failure({:invalid_input, {:git_config_audit_failed, code}}),
    do: failure_status("git_config_audit_failed", "config", categorical_code(code), true)

  def proof_failure({:git_config_audit_failed, code}),
    do: failure_status("git_config_audit_failed", "config", categorical_code(code), true)

  def proof_failure({:invalid_input, {:unsafe_git_configuration, _entries}}),
    do: failure_status("unsafe_git_configuration", "config", "unsafe_configuration", true)

  def proof_failure({:unsafe_git_configuration, _entries}),
    do: failure_status("unsafe_git_configuration", "config", "unsafe_configuration", true)

  def proof_failure({:invalid_input, :invalid_git_output}),
    do: failure_status("invalid_git_output", "git_output", "malformed", true)

  def proof_failure(:invalid_git_output),
    do: failure_status("invalid_git_output", "git_output", "malformed", true)

  def proof_failure({:invalid_input, :output_limit}),
    do: failure_status("output_limit", "git_output", "limit_exceeded", true)

  def proof_failure(:output_limit),
    do: failure_status("output_limit", "git_output", "limit_exceeded", true)

  def proof_failure({:git_command_failed, exit_code}) when is_integer(exit_code),
    do:
      failure_status(
        "git_command_failed",
        "git_command_failed",
        Integer.to_string(exit_code),
        true
      )

  def proof_failure({:timeout, _detail}),
    do: failure_status("timeout", "proof_timeout", "timeout", true)

  def proof_failure(:timeout), do: failure_status("timeout", "proof_timeout", "timeout", true)

  def proof_failure(_reason), do: failure_status("unknown", "unknown", "unknown", true)

  defp classify_unprotected(branch, destination, proofs, survivors, opts) do
    ref = branch["ref"]

    case Map.get(survivors, ref) do
      {:survivor, survivor_ref} ->
        entry(branch, "duplicate_tip", "deterministic_survivor:#{survivor_ref}", "preserve")

      {:duplicate, survivor_ref} ->
        entry(branch, "duplicate_tip", "duplicate_tip_of:#{survivor_ref}", "archive_and_retire")

      nil ->
        classify_proof(branch, destination, Map.get(proofs, ref), opts)
    end
  end

  defp classify_proof(branch, _destination, {:ok, proof}, _opts)
       when is_map(proof) do
    case proof["method"] do
      "ancestry" ->
        entry(branch, "merged", "tip_is_ancestor_of_destination", "archive_and_retire", proof)

      "patch_equivalence" ->
        entry(
          branch,
          "patch_equivalent",
          "bounded_patch_equivalence",
          "archive_and_retire",
          proof
        )

      _ ->
        entry(branch, "unclassified", "invalid_proof_method", "preserve")
    end
  end

  defp classify_proof(branch, _destination, {:error, {:not_adopted, _reason}}, _opts),
    do: entry(branch, "unique", "patch_not_represented_on_destination", "preserve")

  defp classify_proof(branch, _destination, {:error, reason}, _opts),
    do: entry(branch, "unclassified", proof_error_reason(reason), "preserve")

  defp classify_proof(branch, _destination, :not_attempted, _opts),
    do: entry(branch, "unclassified", "proof_budget_exhausted", "preserve")

  defp classify_proof(branch, _destination, _proof, _opts),
    do: entry(branch, "unclassified", "proof_not_observed", "preserve")

  defp duplicate_survivors(branches, protections, destination) do
    branches
    |> Enum.group_by(& &1["oid"])
    |> Enum.reduce(%{}, fn {_oid, group}, acc ->
      if length(group) < 2 do
        acc
      else
        protected = Enum.filter(group, &protected_ref?(&1["ref"], protections, destination))
        survivor = Enum.min_by(if(protected == [], do: group, else: protected), & &1["ref"])

        Enum.reduce(group, acc, fn branch, next ->
          kind = if branch["ref"] == survivor["ref"], do: :survivor, else: :duplicate
          Map.put(next, branch["ref"], {kind, survivor["ref"]})
        end)
      end
    end)
  end

  defp protected_ref?(ref, protections, destination),
    do: Map.has_key?(protections, ref) or not is_nil(policy_protection(ref, destination))

  defp policy_protection(ref, destination) do
    cond do
      ref == destination["ref"] ->
        %{class: "destination", reason: "destination_ref"}

      ref == "refs/heads/main" ->
        %{class: "explicitly_preserved", reason: "main_ref"}

      ref == "refs/heads/eval/do-not-merge/security-audit-fixes" ->
        %{class: "explicitly_preserved", reason: "security_audit_ref"}

      String.starts_with?(ref, "refs/heads/preserve/") ->
        %{class: "explicitly_preserved", reason: "preserve_namespace"}

      true ->
        nil
    end
  end

  defp entry(branch, class, reason, action, proof \\ nil) do
    base = %{
      "ref" => branch["ref"],
      "oid" => branch["oid"],
      "class" => class,
      "reason" => reason,
      "action" => action
    }

    if is_map(proof), do: Map.put(base, "proof", proof), else: base
  end

  defp proof_error_reason({:proof_failure, failure}), do: render_failure_reason(failure)

  defp proof_error_reason(reason) do
    render_failure_reason(proof_failure(reason))
  end

  defp render_failure_reason(%{
         "category" => category,
         "detail" => detail,
         "code" => code
       }) do
    cond do
      category == "unknown" and detail == "unknown" and code == "unknown" ->
        "proof_error:unknown"

      category in ["git_storage_validation_failed", "git_command_failed"] and
          detail == "invalid_input" ->
        "proof_error:invalid_input:#{category}:#{code}"

      true ->
        "proof_error:" <> Enum.join([category, detail, code], ":")
    end
  end

  defp failure_status(category, detail, code, retryable),
    do: %{
      "category" => category,
      "detail" => detail,
      "code" => code,
      "retryable" => retryable
    }

  defp categorical_code(code) when code in @known_config_codes, do: Atom.to_string(code)

  defp categorical_code(code) when is_integer(code) and code >= 0 and code <= 255,
    do: "exit_" <> Integer.to_string(code)

  defp categorical_code(_code), do: "unknown"

  defp validate_body(body) do
    with :ok <- validate_json(body),
         :ok <- require_string_keys(body),
         :ok <-
           exact_keys(
             body,
             ~w(format version repository destination branches errors limits)
           ),
         :ok <- validate_repository(body["repository"]),
         :ok <- validate_destination(body["destination"]),
         :ok <- validate_limits(body["limits"]),
         :ok <- validate_errors(body["errors"]),
         :ok <-
           validate_branches(
             body["branches"],
             body["destination"],
             body["limits"]["max_branch_count"],
             body["errors"]
           ) do
      :ok
    end
  end

  defp validate_repository(repository) when is_map(repository) and not is_struct(repository) do
    with :ok <- exact_keys(repository, ~w(identity path)),
         true <- bounded_string?(repository["identity"], 1, 4096),
         true <- bounded_string?(repository["path"], 1, 4096) do
      :ok
    else
      false -> {:error, :invalid_branch_audit_repository}
      {:error, _reason} = error -> error
    end
  end

  defp validate_repository(_), do: {:error, :invalid_branch_audit_repository}

  defp validate_destination(destination)
       when is_map(destination) and not is_struct(destination) do
    with :ok <- exact_keys(destination, ~w(ref oid)),
         true <- valid_local_branch_ref?(destination["ref"]),
         true <- valid_oid?(destination["oid"]) do
      :ok
    else
      false -> {:error, :invalid_branch_audit_destination}
      {:error, _reason} = error -> error
    end
  end

  defp validate_destination(_), do: {:error, :invalid_branch_audit_destination}

  defp validate_branches(branches, destination, max_entries, errors)
       when is_list(branches) and is_map(destination) and is_integer(max_entries) and
              is_list(errors) do
    bounded_count = min(max_entries, @max_branch_entries)
    manifest_size_fallback? = errors == ["manifest_bytes_limit"]

    with true <- list_within_limit?(branches, bounded_count),
         true <- Enum.all?(branches, &(is_map(&1) and not is_struct(&1))),
         refs <- Enum.map(branches, & &1["ref"]),
         true <- refs == Enum.sort(refs),
         true <- length(refs) == length(Enum.uniq(refs)),
         true <-
           Enum.all?(
             branches,
             &valid_branch_entry?(&1, destination, manifest_size_fallback?)
           ),
         :ok <- validate_duplicate_groups(branches, manifest_size_fallback?) do
      :ok
    else
      false -> {:error, :invalid_branch_audit_branches}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_branch_audit_branches}
    end
  end

  defp validate_branches(_branches, _destination, _max_entries, _errors),
    do: {:error, :invalid_branch_audit_branches}

  defp valid_branch_entry?(entry, destination, manifest_size_fallback?) when is_map(entry) do
    valid_shape? =
      exact_keys?(entry, ~w(ref oid class reason action)) or
        exact_keys?(entry, ~w(ref oid class reason action proof))

    valid_shape? and valid_local_branch_ref?(entry["ref"]) and valid_oid?(entry["oid"]) and
      bounded_string?(entry["class"], 1, 64) and
      bounded_string?(entry["action"], 1, 64) and
      bounded_string?(entry["reason"], 1, @max_reason_bytes) and
      valid_entry_semantics?(entry, destination, manifest_size_fallback?)
  end

  defp valid_branch_entry?(_entry, _destination, _manifest_size_fallback?), do: false

  defp valid_entry_semantics?(
         %{
           "class" => "unclassified",
           "reason" => "manifest_bytes_limit",
           "action" => "preserve"
         } = entry,
         _destination,
         true
       ),
       do: no_proof?(entry)

  defp valid_entry_semantics?(_entry, _destination, true), do: false

  defp valid_entry_semantics?(entry, destination, false) do
    case policy_protection(entry["ref"], destination) do
      %{class: class, reason: reason} ->
        no_proof?(entry) and entry["class"] == class and entry["reason"] == reason and
          entry["action"] == "preserve"

      nil ->
        valid_unprotected_entry_semantics?(entry, destination)
    end
  end

  defp valid_unprotected_entry_semantics?(
         %{"class" => "checked_out", "reason" => "checked_out_ref", "action" => "preserve"} =
           entry,
         _destination
       ),
       do: no_proof?(entry)

  defp valid_unprotected_entry_semantics?(
         %{"class" => "retained", "reason" => reason, "action" => "preserve"} = entry,
         _destination
       ),
       do: no_proof?(entry) and retained_reason?(reason)

  defp valid_unprotected_entry_semantics?(
         %{
           "class" => "unique",
           "reason" => "patch_not_represented_on_destination",
           "action" => "preserve"
         } = entry,
         _destination
       ),
       do: no_proof?(entry)

  defp valid_unprotected_entry_semantics?(
         %{"class" => "unclassified", "reason" => reason, "action" => "preserve"} = entry,
         _destination
       ),
       do: no_proof?(entry) and unclassified_reason?(reason)

  defp valid_unprotected_entry_semantics?(
         %{
           "class" => "merged",
           "reason" => "tip_is_ancestor_of_destination",
           "action" => "archive_and_retire",
           "proof" => proof
         } = entry,
         destination
       ),
       do: valid_adoption_proof?(proof, "ancestry", entry, destination)

  defp valid_unprotected_entry_semantics?(
         %{
           "class" => "patch_equivalent",
           "reason" => "bounded_patch_equivalence",
           "action" => "archive_and_retire",
           "proof" => proof
         } = entry,
         destination
       ),
       do: valid_adoption_proof?(proof, "patch_equivalence", entry, destination)

  defp valid_unprotected_entry_semantics?(
         %{"class" => "duplicate_tip", "reason" => reason, "action" => action} = entry,
         _destination
       ) do
    no_proof?(entry) and
      case {action,
            reason_ref(reason, "deterministic_survivor:") ||
              reason_ref(reason, "duplicate_tip_of:")} do
        {"preserve", {:deterministic_survivor, _ref}} -> true
        {"archive_and_retire", {:duplicate_tip_of, _ref}} -> true
        _other -> false
      end
  end

  defp valid_unprotected_entry_semantics?(_entry, _destination), do: false

  defp retained_reason?(reason) when reason in @retained_reasons, do: true

  defp retained_reason?("discarding_workspace_ref:" <> phase), do: phase in @discard_phases

  defp retained_reason?("dormant_workspace_ref:" <> lifecycle),
    do: lifecycle in @retention_lifecycles

  defp retained_reason?(_reason), do: false

  defp unclassified_reason?(reason)
       when reason in [
              "invalid_proof_method",
              "manifest_bytes_limit",
              "proof_budget_exhausted",
              "proof_not_observed"
            ],
       do: true

  defp unclassified_reason?("proof_error:" <> detail),
    do:
      byte_size(detail) in 1..512 and
        Regex.match?(~r/\A[A-Za-z0-9_.:\/-]+\z/, detail)

  defp unclassified_reason?(_reason), do: false

  defp valid_adoption_proof?(proof, method, entry, destination)
       when is_map(proof) and not is_struct(proof) do
    with true <- exact_keys?(proof, @proof_keys),
         true <- proof["method"] == method,
         true <- valid_oid?(proof["base_commit"]),
         true <- proof["candidate_commit"] == entry["oid"],
         true <- proof["destination_ref"] == destination["ref"],
         true <- proof["destination_commit"] == destination["oid"],
         true <- same_oid_width?(proof["base_commit"], entry["oid"]),
         true <- same_oid_width?(destination["oid"], entry["oid"]),
         true <- bounded_integer?(proof["candidate_commit_count"], 0, @max_proof_commits) do
      valid_proof_audit?(method, proof["audit"], proof["candidate_commit_count"], entry["oid"])
    else
      _other -> false
    end
  end

  defp valid_adoption_proof?(_proof, _method, _entry, _destination), do: false

  defp valid_proof_audit?("ancestry", audit, candidate_count, _oid)
       when is_map(audit) and not is_struct(audit),
       do:
         exact_keys?(audit, ["candidate_range_count"]) and
           audit["candidate_range_count"] == candidate_count

  defp valid_proof_audit?("patch_equivalence", audit, candidate_count, oid)
       when is_map(audit) and not is_struct(audit) do
    candidate_patches = audit["candidate_patches"]
    destination_patches = audit["destination_patches"]

    exact_keys?(audit, @patch_audit_keys) and candidate_count > 0 and
      audit["candidate_range_count"] == candidate_count and
      bounded_integer?(audit["destination_range_count"], 0, @max_proof_commits) and
      bounded_integer?(audit["matched_candidate_patch_count"], 0, candidate_count) and
      valid_patch_evidence_list?(candidate_patches, candidate_count, oid, :exact) and
      valid_patch_evidence_list?(
        destination_patches,
        audit["destination_range_count"],
        oid,
        :at_most
      ) and
      valid_patch_representation?(audit, candidate_count)
  end

  defp valid_proof_audit?(_method, _audit, _candidate_count, _oid), do: false

  defp valid_patch_evidence_list?(patches, limit, oid, cardinality)
       when is_list(patches) and is_integer(limit) do
    if list_within_limit?(patches, @max_proof_commits) do
      count = length(patches)
      cardinality_valid? = if cardinality == :exact, do: count == limit, else: count <= limit

      commits =
        Enum.map(patches, fn
          evidence when is_map(evidence) -> Map.get(evidence, "commit")
          _other -> nil
        end)

      cardinality_valid? and length(commits) == length(Enum.uniq(commits)) and
        Enum.all?(patches, &valid_patch_evidence?(&1, oid))
    else
      false
    end
  end

  defp valid_patch_evidence_list?(_patches, _limit, _oid, _cardinality), do: false

  defp valid_patch_evidence?(evidence, oid)
       when is_map(evidence) and not is_struct(evidence),
       do:
         exact_keys?(evidence, ~w(commit patch_id)) and valid_oid?(evidence["commit"]) and
           same_oid_width?(evidence["commit"], oid) and valid_oid?(evidence["patch_id"])

  defp valid_patch_evidence?(_evidence, _oid), do: false

  defp valid_patch_representation?(%{"representation" => "cherry_pick"} = audit, candidate_count) do
    audit["matched_candidate_patch_count"] == candidate_count and
      is_nil(audit["aggregate_destination"]) and
      patch_multiset_subset?(audit["candidate_patches"], audit["destination_patches"])
  end

  defp valid_patch_representation?(%{"representation" => "squash"} = audit, _candidate_count) do
    aggregate = audit["aggregate_destination"]

    audit["matched_candidate_patch_count"] == 0 and is_map(aggregate) and
      Enum.member?(audit["destination_patches"], aggregate)
  end

  defp valid_patch_representation?(_audit, _candidate_count), do: false

  defp patch_multiset_subset?(candidate_patches, destination_patches) do
    available = destination_patches |> Enum.map(& &1["patch_id"]) |> Enum.frequencies()

    Enum.reduce_while(candidate_patches, available, fn patch, remaining ->
      patch_id = patch["patch_id"]

      case Map.get(remaining, patch_id, 0) do
        count when count > 0 -> {:cont, Map.put(remaining, patch_id, count - 1)}
        _other -> {:halt, :missing}
      end
    end) != :missing
  end

  defp validate_duplicate_groups(_branches, true), do: :ok

  defp validate_duplicate_groups(branches, false) do
    branches
    |> Enum.group_by(& &1["oid"])
    |> Enum.reduce_while(:ok, fn {_oid, group}, :ok ->
      case validate_duplicate_group(group) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_duplicate_group(group) do
    duplicate_entries = Enum.filter(group, &(&1["class"] == "duplicate_tip"))
    retired = Enum.filter(duplicate_entries, &(&1["action"] == "archive_and_retire"))
    survivors = Enum.filter(duplicate_entries, &(&1["action"] == "preserve"))
    protected = Enum.filter(group, &(&1["class"] in @protected_classes))

    cond do
      duplicate_entries == [] and
          (length(group) == 1 or Enum.all?(group, &(&1["class"] in @protected_classes))) ->
        :ok

      duplicate_entries == [] ->
        {:error, :invalid_branch_audit_duplicate_group}

      length(group) < 2 or length(survivors) > 1 or retired == [] ->
        {:error, :invalid_branch_audit_duplicate_group}

      protected != [] and survivors != [] ->
        {:error, :invalid_branch_audit_duplicate_group}

      protected == [] and length(survivors) != 1 ->
        {:error, :invalid_branch_audit_duplicate_group}

      true ->
        validate_duplicate_targets(group, retired, survivors, protected)
    end
  end

  defp validate_duplicate_targets(group, retired, survivors, protected) do
    expected_survivor =
      case protected do
        [] -> hd(survivors)
        entries -> Enum.min_by(entries, & &1["ref"])
      end

    unprotected = Enum.reject(group, &(&1["class"] in @protected_classes))

    expected_retired_count =
      if protected == [], do: length(group) - 1, else: length(group) - length(protected)

    with true <-
           protected != [] or
             expected_survivor["ref"] == (group |> Enum.min_by(& &1["ref"]))["ref"],
         true <- length(retired) == expected_retired_count,
         true <-
           Enum.all?(unprotected, fn entry ->
             entry["class"] == "duplicate_tip" and
               (protected == [] or entry["action"] == "archive_and_retire")
           end),
         true <-
           Enum.all?(retired, fn entry ->
             case reason_ref(entry["reason"], "duplicate_tip_of:") do
               {:duplicate_tip_of, target_ref} ->
                 target_ref != entry["ref"] and target_ref == expected_survivor["ref"] and
                   expected_survivor["oid"] == entry["oid"] and
                   expected_survivor["action"] == "preserve"

               _other ->
                 false
             end
           end),
         true <-
           Enum.all?(survivors, fn entry ->
             reason_ref(entry["reason"], "deterministic_survivor:") ==
               {:deterministic_survivor, entry["ref"]}
           end) do
      :ok
    else
      false -> {:error, :invalid_branch_audit_duplicate_group}
    end
  end

  defp reason_ref(reason, "deterministic_survivor:") when is_binary(reason) do
    case reason do
      "deterministic_survivor:" <> ref ->
        if valid_local_branch_ref?(ref), do: {:deterministic_survivor, ref}, else: nil

      _other ->
        nil
    end
  end

  defp reason_ref(reason, "duplicate_tip_of:") when is_binary(reason) do
    case reason do
      "duplicate_tip_of:" <> ref ->
        if valid_local_branch_ref?(ref), do: {:duplicate_tip_of, ref}, else: nil

      _other ->
        nil
    end
  end

  defp reason_ref(_reason, _prefix), do: nil

  defp no_proof?(entry), do: exact_keys?(entry, ~w(ref oid class reason action))

  defp valid_local_branch_ref?("refs/heads/" <> branch) when branch != "",
    do: Git.validate_branch_name(branch) == :ok

  defp valid_local_branch_ref?(_ref), do: false

  defp same_oid_width?(left, right),
    do: valid_oid?(left) and valid_oid?(right) and byte_size(left) == byte_size(right)

  defp bounded_string?(value, min, max),
    do: is_binary(value) and String.valid?(value) and byte_size(value) in min..max

  defp list_within_limit?(list, max) when is_list(list) and is_integer(max) and max >= 0,
    do: length(Enum.take(list, max + 1)) <= max

  defp validate_errors(errors) when is_list(errors) do
    if list_within_limit?(errors, @max_branch_entries) and errors == Enum.sort(errors) and
         length(errors) == length(Enum.uniq(errors)) and
         Enum.all?(errors, &bounded_string?(&1, 1, @max_reason_bytes)),
       do: :ok,
       else: {:error, :invalid_branch_audit_errors}
  end

  defp validate_errors(_), do: {:error, :invalid_branch_audit_errors}

  defp validate_limits(limits) when is_map(limits) do
    with :ok <- exact_keys(limits, ~w(max_branch_count max_proof_attempts max_manifest_bytes)),
         true <- bounded_integer?(limits["max_branch_count"], 1, 4096),
         true <- bounded_integer?(limits["max_proof_attempts"], 1, 4096),
         true <- bounded_integer?(limits["max_manifest_bytes"], 1024, 32 * 1024 * 1024) do
      :ok
    else
      false -> {:error, :invalid_branch_audit_limits}
      {:error, _reason} = error -> error
    end
  end

  defp validate_limits(_), do: {:error, :invalid_branch_audit_limits}

  defp bounded_integer?(value, min, max), do: is_integer(value) and value >= min and value <= max

  defp valid_oid?(oid),
    do: is_binary(oid) and Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, oid)

  defp exact_keys(map, keys) do
    if MapSet.new(Map.keys(map)) == MapSet.new(keys),
      do: :ok,
      else: {:error, :invalid_branch_audit_schema}
  end

  defp exact_keys?(map, keys), do: exact_keys(map, keys) == :ok

  defp validate_json(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      if is_binary(key) and String.valid?(key) do
        case validate_json(item) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      else
        {:halt, {:error, :non_string_json_key}}
      end
    end)
  end

  defp validate_json(value) when is_list(value),
    do:
      Enum.reduce_while(value, :ok, fn item, :ok ->
        case validate_json(item) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

  defp validate_json(value) when is_binary(value),
    do: if(String.valid?(value), do: :ok, else: {:error, :invalid_json_string})

  defp validate_json(value) when is_number(value) or is_boolean(value) or is_nil(value), do: :ok
  defp validate_json(_), do: {:error, :non_json_manifest_value}

  defp require_string_keys(value) when is_map(value) do
    if Enum.all?(value, fn {key, item} -> is_binary(key) and require_string_keys(item) == :ok end),
       do: :ok,
       else: {:error, :non_string_json_key}
  end

  defp require_string_keys(value) when is_list(value),
    do:
      if(Enum.all?(value, &(require_string_keys(&1) == :ok)),
        do: :ok,
        else: {:error, :non_string_json_key}
      )

  defp require_string_keys(_), do: :ok

  defp normalize_ordered_json(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) != length(Enum.uniq(keys)) do
      {:error, :duplicate_manifest_key}
    else
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        with true <- is_binary(key), {:ok, normalized} <- normalize_ordered_json(value) do
          {:cont, {:ok, Map.put(acc, key, normalized)}}
        else
          false -> {:halt, {:error, :non_string_json_key}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp normalize_ordered_json(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_ordered_json(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_ordered_json(value), do: {:ok, value}

  defp do_canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _} -> to_string(key) end)
      |> Enum.map(fn {key, item} ->
        [Jason.encode!(to_string(key)), ":", do_canonical_json(item)]
      end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp do_canonical_json(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &do_canonical_json/1), ","), "]"]

  defp do_canonical_json(value), do: Jason.encode!(value)
end
