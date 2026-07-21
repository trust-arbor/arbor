defmodule Arbor.Actions.Coding.BranchAudit do
  @moduledoc """
  Imperative shell for the dry-run-first historical coding-branch audit.

  All policy and manifest bytes are delegated to `BranchAuditCore`. This module
  only obtains bounded observations, invokes the existing Git proof/archive/CAS
  primitives, and reports conservative residue.
  """

  alias Arbor.Actions.Coding.BranchAuditCore, as: Core
  alias Arbor.Actions.Coding.BranchAuditCheckpoint
  alias Arbor.Actions.Coding.BranchAuditCheckpointCore, as: CheckpointCore
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Coding.WorkspaceRetentionInventory
  alias Arbor.Actions.Git

  @default_max_branches 2048
  @default_max_proofs 1024
  @default_max_manifest_bytes 8 * 1024 * 1024
  @max_branches 4096
  @max_proofs 4096
  @max_manifest_bytes 32 * 1024 * 1024
  @checkpoint_cadence 16
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @doc "Bounded number of proof attempts between durable checkpoint writes."
  @spec checkpoint_cadence() :: pos_integer()
  def checkpoint_cadence, do: @checkpoint_cadence

  @spec audit(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def audit(repo_path, destination, opts \\ [])

  def audit(repo_path, destination, opts)
      when is_binary(repo_path) and is_binary(destination) and is_list(opts) do
    limits = limits(opts)

    with {:ok, repository} <- Git.repository_identity(repo_path),
         {:ok, destination_observation} <- observe_destination(repository["path"], destination),
         {:ok, branches} <-
           Git.list_local_branch_refs(repository["path"], limits["max_branch_count"]),
         {:ok, protections} <-
           protections(repository["path"], destination_observation, limits, opts) do
      with {:ok, proofs} <-
             proofs(
               repository,
               destination_observation,
               branches,
               protections,
               limits,
               opts
             ) do
        entries = Core.classify(branches, destination_observation, protections, proofs, limits)
        build_manifest(repository, destination_observation, entries, [], limits)
      end
    else
      {:error, {:branch_inventory_overflow, _} = reason} ->
        blocked_manifest(repo_path, destination, limits, [reason_string(reason)])

      {:error, reason} ->
        {:error, reason}
    end
  end

  def audit(_repo_path, _destination, _opts), do: {:error, :invalid_branch_audit_request}

  @spec settle(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def settle(manifest, expected_sha256, opts \\ [])

  def settle(manifest, expected_sha256, opts)
      when is_map(manifest) and is_binary(expected_sha256) and is_list(opts) do
    with :ok <- validate_expected_digest(expected_sha256),
         {:ok, reviewed} <- normalize_reviewed_manifest(manifest),
         true <- reviewed["manifest_sha256"] == expected_sha256,
         true <-
           byte_size(Core.canonical_json(reviewed)) <= reviewed["limits"]["max_manifest_bytes"],
         true <- reviewed["errors"] == [],
         {:ok, repository} <- Git.repository_identity(reviewed["repository"]["path"]),
         true <- repository == reviewed["repository"],
         :ok <- verify_destination(reviewed["destination"], repository["path"]),
         {:ok, report} <- settle_entries(reviewed, repository, opts) do
      {:ok, report}
    else
      false -> {:error, :reviewed_branch_audit_drift}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_reviewed_branch_audit}
    end
  end

  def settle(_manifest, _expected_sha256, _opts),
    do: {:error, :invalid_reviewed_branch_audit}

  defp limits(opts) do
    %{
      "max_branch_count" =>
        bounded_opt(opts, :max_branch_count, @default_max_branches, @max_branches),
      "max_proof_attempts" =>
        bounded_opt(opts, :max_proof_attempts, @default_max_proofs, @max_proofs),
      "max_manifest_bytes" =>
        bounded_opt(opts, :max_manifest_bytes, @default_max_manifest_bytes, @max_manifest_bytes)
    }
  end

  defp bounded_opt(opts, key, default, max) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 -> min(value, max)
      _ -> default
    end
  end

  defp observe_destination(repo_path, destination) do
    branch =
      if String.starts_with?(destination, "refs/heads/"),
        do: String.replace_prefix(destination, "refs/heads/", ""),
        else: destination

    with {:ok, {:present, oid}} <- Git.observe_branch_ref(repo_path, branch) do
      {:ok, %{"ref" => "refs/heads/" <> branch, "oid" => oid}}
    else
      {:ok, :absent} -> {:error, :destination_ref_absent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp protections(repo_path, destination, limits, opts) do
    with {:ok, checked_out} <- Git.checked_out_branch_refs(repo_path, limits["max_branch_count"]),
         {:ok, workspace_refs} <- workspace_protection(repo_path, limits, opts) do
      fixed =
        [
          {"refs/heads/main", "main_ref"},
          {"refs/heads/eval/do-not-merge/security-audit-fixes", "security_audit_ref"}
        ]
        |> Enum.reduce(%{}, fn {ref, reason}, acc ->
          Map.put(acc, ref, %{class: "explicitly_preserved", reason: reason})
        end)

      checked_out =
        Enum.reduce(checked_out, %{}, fn ref, acc ->
          Map.put(acc, ref, %{class: "checked_out", reason: "checked_out_ref"})
        end)

      workspace_refs =
        Enum.reduce(workspace_refs, %{}, fn %{"ref" => ref, "reason" => reason}, acc ->
          Map.put(acc, ref, %{class: "retained", reason: reason})
        end)

      protections = Map.merge(fixed, checked_out) |> Map.merge(workspace_refs)

      {:ok,
       Map.put(protections, destination["ref"], %{class: "destination", reason: "destination_ref"})}
    end
  end

  defp workspace_protection(repo_path, limits, opts) do
    max_entries = min(limits["max_branch_count"], 256)
    registry_opts = [max_entries: max_entries]

    registry_opts =
      case Keyword.get(opts, :registry_server) do
        nil -> registry_opts
        server -> Keyword.put(registry_opts, :server, server)
      end

    case WorkspaceLeaseRegistry.branch_protection_inventory(repo_path, registry_opts) do
      {:ok, inventory} ->
        {:ok, inventory}

      {:error, :registry_unavailable} ->
        WorkspaceRetentionInventory.snapshot(repo_path,
          journal_path:
            Keyword.get(
              opts,
              :journal_path,
              Arbor.Actions.Config.workspace_retention_journal_path()
            )
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp proofs(repository, destination, branches, protections, limits, opts) do
    targets =
      branches
      |> Enum.reject(
        &(Map.has_key?(protections, &1["ref"]) or policy_protected?(&1["ref"], destination))
      )
      |> Enum.group_by(& &1["oid"])
      |> Enum.filter(fn {_oid, group} -> length(group) == 1 end)
      |> Enum.map(fn {_oid, [branch]} -> branch end)
      |> Enum.sort_by(& &1["ref"])

    scope = %{
      "policy_version" => CheckpointCore.policy_version(),
      "repository" => repository,
      "destination" => destination
    }

    with {:ok, cache, _cache_state} <- load_checkpoint(opts, scope),
         cache <- prune_stale_entries(cache, targets),
         {:ok, cached_entries} <- validate_cached_entries(cache, targets, destination),
         {:ok, proofs, next_cache} <-
           prove_targets(
             targets,
             repository["path"],
             destination,
             cached_entries,
             cache,
             limits,
             opts
           ),
         :ok <- persist_checkpoint(opts, next_cache) do
      {:ok, proofs}
    end
  end

  defp load_checkpoint(opts, scope) do
    case checkpoint_path(opts) do
      nil ->
        {:ok, CheckpointCore.empty(scope["repository"], scope["destination"], %{}), :disabled}

      path ->
        BranchAuditCheckpoint.load(path, scope)
    end
  end

  defp validate_cached_entries(cache, targets, destination) do
    target_by_ref = Map.new(targets, &{&1["ref"], &1})

    Enum.reduce_while(cache["entries"], {:ok, %{}}, fn cached, {:ok, acc} ->
      case Map.get(target_by_ref, cached["ref"]) do
        nil ->
          {:cont, {:ok, acc}}

        branch ->
          case cached["status"] do
            "verified_proof" ->
              case Core.validate_adoption_proof(cached["proof"], branch, destination) do
                :ok -> {:cont, {:ok, Map.put(acc, branch["ref"], cached)}}
                {:error, _reason} -> {:halt, {:error, :invalid_checkpoint_proof}}
              end

            "deterministic_preserve" ->
              {:cont, {:ok, Map.put(acc, branch["ref"], cached)}}

            "transient_failure" ->
              {:cont, {:ok, Map.put(acc, branch["ref"], cached)}}

            _status ->
              {:halt, {:error, :invalid_checkpoint_entry}}
          end
      end
    end)
  end

  defp prune_stale_entries(cache, targets) do
    target_by_ref = Map.new(targets, &{&1["ref"], &1})

    entries =
      Enum.filter(cache["entries"], fn entry ->
        case Map.get(target_by_ref, entry["ref"]) do
          %{"oid" => oid} -> entry["oid"] == oid
          nil -> false
        end
      end)

    Map.put(cache, "entries", entries)
  end

  defp prove_targets(targets, repo_path, destination, cached_entries, cache, limits, opts) do
    proof_fun = Keyword.get(opts, :proof_fun, &prove_branch/3)
    callback = Keyword.get(opts, :progress)
    total = length(targets)

    initial = %{
      "completed" => 0,
      "total" => total,
      "cache_hits" => 0,
      "retried" => 0,
      "attempts" => 0,
      "skipped" => 0,
      "attempts_since_checkpoint" => 0,
      "failure_categories" => %{}
    }

    {results, final_cache, _state} =
      Enum.reduce_while(targets, {%{}, cache, initial}, fn branch,
                                                           {results, current_cache, state} ->
        cached = Map.get(cached_entries, branch["ref"])

        case cached do
          %{"status" => "verified_proof", "proof" => proof} ->
            next_state = progress_state(state, :cache_hit, nil)
            emit_progress(callback, next_state)
            {:cont, {Map.put(results, branch["ref"], {:ok, proof}), current_cache, next_state}}

          %{"status" => "deterministic_preserve", "failure" => failure} ->
            next_state = progress_state(state, :cache_hit, failure)
            emit_progress(callback, next_state)

            {:cont,
             {
               Map.put(results, branch["ref"], cached_failure_result(failure)),
               current_cache,
               next_state
             }}

          _ ->
            if state["attempts"] < limits["max_proof_attempts"] do
              result = run_proof(proof_fun, repo_path, branch, destination)

              {next_cache, normalized_result} =
                cache_result(current_cache, branch, result, destination)

              next_state =
                progress_state(
                  state,
                  if(cached == nil, do: :attempt, else: :retry),
                  failure_for_result(normalized_result)
                )

              with {:ok, next_state} <- checkpoint_after_attempt(opts, next_cache, next_state) do
                emit_progress(callback, next_state)

                {:cont,
                 {Map.put(results, branch["ref"], normalized_result), next_cache, next_state}}
              else
                {:error, _reason} = error -> {:halt, {error, current_cache, state}}
              end
            else
              next_state = progress_state(state, :skipped, nil)
              emit_progress(callback, next_state)

              {:cont,
               {Map.put(results, branch["ref"], :not_attempted), current_cache, next_state}}
            end
        end
      end)

    case results do
      {:error, _reason} = error -> error
      _ -> {:ok, results, final_cache}
    end
  end

  defp run_proof(proof_fun, repo_path, branch, destination) when is_function(proof_fun, 3) do
    result = proof_fun.(repo_path, branch, destination)

    case result do
      {:ok, proof} when is_map(proof) ->
        case Core.validate_adoption_proof(proof, branch, destination) do
          :ok -> {:ok, proof}
          {:error, _reason} -> {:error, {:invalid_input, :invalid_adoption_proof}}
        end

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :unknown_proof_result}
    end
  end

  defp run_proof(_proof_fun, _repo_path, _branch, _destination),
    do: {:error, :invalid_proof_function}

  defp cache_result(cache, branch, {:ok, proof} = result, _destination) do
    {:ok, next_cache} =
      CheckpointCore.upsert(cache, branch, "verified_proof", %{"proof" => proof})

    {next_cache, result}
  end

  defp cache_result(cache, branch, {:error, reason} = result, _destination) do
    failure = Core.proof_failure(reason)

    status =
      if failure["retryable"] == false,
        do: "deterministic_preserve",
        else: "transient_failure"

    {:ok, next_cache} = CheckpointCore.upsert(cache, branch, status, %{"failure" => failure})
    {next_cache, result}
  end

  defp cached_failure_result(%{"category" => "not_adopted"}),
    do: {:error, {:not_adopted, :cached}}

  defp cached_failure_result(failure), do: {:error, {:proof_failure, failure}}

  defp failure_for_result({:error, {:not_adopted, _reason}}),
    do: Core.proof_failure({:not_adopted, :cached})

  defp failure_for_result({:error, reason}), do: Core.proof_failure(reason)
  defp failure_for_result(_result), do: nil

  defp progress_state(state, kind, nil) do
    next = Map.update!(state, "completed", &(&1 + 1))

    case kind do
      :cache_hit ->
        Map.update!(next, "cache_hits", &(&1 + 1))

      :retry ->
        next
        |> Map.update!("attempts", &(&1 + 1))
        |> Map.update!("retried", &(&1 + 1))
        |> Map.update!("attempts_since_checkpoint", &(&1 + 1))

      :skipped ->
        next
        |> Map.update!("skipped", &(&1 + 1))
        |> Map.update!(
          "failure_categories",
          &Map.update(&1, "not_attempted", 1, fn count -> count + 1 end)
        )

      :attempt ->
        next
        |> Map.update!("attempts", &(&1 + 1))
        |> Map.update!("attempts_since_checkpoint", &(&1 + 1))
    end
  end

  defp progress_state(state, kind, failure) do
    next = progress_state(state, kind, nil)
    category = failure["category"]

    Map.update!(
      next,
      "failure_categories",
      &Map.update(&1, category, 1, fn count -> count + 1 end)
    )
  end

  defp emit_progress(callback, state) when is_function(callback, 1) do
    snapshot = %{
      "completed" => state["completed"],
      "total" => state["total"],
      "cache_hits" => state["cache_hits"],
      "retried" => state["retried"],
      "skipped" => state["skipped"],
      "failure_categories" =>
        state["failure_categories"]
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {category, count} -> %{"category" => category, "count" => count} end)
    }

    try do
      callback.(snapshot)
    rescue
      _error -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp emit_progress(_callback, _state), do: :ok

  defp checkpoint_after_attempt(opts, cache, state) do
    case checkpoint_path(opts) do
      nil ->
        {:ok, state}

      path ->
        if state["attempts_since_checkpoint"] < @checkpoint_cadence do
          {:ok, state}
        else
          with :ok <- write_checkpoint(opts, path, cache) do
            {:ok, Map.put(state, "attempts_since_checkpoint", 0)}
          end
        end
    end
  end

  defp persist_checkpoint(opts, cache) do
    case checkpoint_path(opts) do
      nil -> :ok
      path -> write_checkpoint(opts, path, cache)
    end
  end

  defp write_checkpoint(opts, path, cache) do
    case Keyword.get(opts, :checkpoint_writer) do
      writer when is_function(writer, 2) -> writer.(path, cache)
      _other -> BranchAuditCheckpoint.write(path, cache)
    end
  end

  defp checkpoint_path(opts) do
    case Keyword.get(opts, :checkpoint, Keyword.get(opts, :checkpoint_path)) do
      path when is_binary(path) and byte_size(path) > 0 -> path
      _other -> nil
    end
  end

  defp prove_branch(repo_path, branch, destination) do
    with {:ok, ancestor} <-
           Git.verified_common_ancestor(repo_path, branch["oid"], destination["oid"]),
         {:ok, proof} <-
           Git.compute_adoption_proof(repo_path, ancestor, branch["oid"], destination["ref"]) do
      {:ok, proof}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_manifest(repository, destination, entries, errors, limits) do
    with {:ok, manifest} <- Core.manifest(repository, destination, entries, errors, limits),
         true <- byte_size(Core.canonical_json(manifest)) <= limits["max_manifest_bytes"] do
      {:ok, manifest}
    else
      false ->
        conservative_entries =
          Enum.map(entries, fn entry ->
            entry
            |> Map.delete("proof")
            |> Map.put("class", "unclassified")
            |> Map.put("action", "preserve")
            |> Map.put("reason", "manifest_bytes_limit")
          end)

        with {:ok, fallback} <-
               Core.manifest(
                 repository,
                 destination,
                 conservative_entries,
                 ["manifest_bytes_limit"],
                 limits
               ),
             true <- byte_size(Core.canonical_json(fallback)) <= limits["max_manifest_bytes"] do
          {:ok, fallback}
        else
          _ -> {:error, :manifest_size_exceeded}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp blocked_manifest(repo_path, destination, limits, errors) do
    with {:ok, repository} <- Git.repository_identity(repo_path),
         {:ok, destination_observation} <- observe_destination(repository["path"], destination),
         {:ok, manifest} <- Core.manifest(repository, destination_observation, [], errors, limits) do
      {:ok, manifest}
    end
  end

  defp normalize_reviewed_manifest(manifest) do
    with {:ok, _validated} <- Core.validate_manifest(manifest),
         {:ok, encoded} <- Jason.encode(manifest),
         {:ok, decoded} <- Core.decode_manifest_json(encoded),
         {:ok, reviewed} <- Core.validate_manifest(decoded) do
      {:ok, reviewed}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_reviewed_branch_audit}
    end
  end

  defp validate_expected_digest(digest) do
    if Regex.match?(@sha256, digest), do: :ok, else: {:error, :invalid_manifest_digest}
  end

  defp verify_destination(%{"ref" => ref, "oid" => expected_oid}, repo_path) do
    with "refs/heads/" <> branch <- ref,
         {:ok, {:present, ^expected_oid}} <- Git.observe_branch_ref(repo_path, branch) do
      :ok
    else
      _ -> {:error, :destination_drift}
    end
  end

  defp settle_entries(manifest, repository, opts) do
    entries = Enum.filter(manifest["branches"], &(&1["action"] == "archive_and_retire"))

    results =
      Enum.map(entries, fn entry -> settle_entry(entry, manifest, repository, opts) end)

    {:ok,
     %{
       "format" => "arbor.coding.branch_settlement",
       "version" => 1,
       "manifest_sha256" => manifest["manifest_sha256"],
       "entries" => results
     }}
  end

  defp settle_entry(entry, manifest, repository, opts) do
    ref = entry["ref"]
    branch = String.replace_prefix(ref, "refs/heads/", "")
    ids = migration_ids(repository["identity"], ref, entry["oid"])

    with :ok <- verify_destination(manifest["destination"], repository["path"]),
         {:ok, current_repository} <- Git.repository_identity(repository["path"]),
         true <- current_repository == repository,
         {:ok, protections} <-
           protections(repository["path"], manifest["destination"], manifest["limits"], opts),
         false <-
           Map.has_key?(protections, ref) or policy_protected?(ref, manifest["destination"]),
         {:ok, observation} <- Git.observe_branch_ref(repository["path"], branch),
         {:ok, result} <-
           archive_and_delete(entry, {:ok, observation}, branch, ids, manifest, repository, opts) do
      result
    else
      true -> residue(entry, "protection_drift")
      false -> residue(entry, "repository_identity_drift")
      {:error, :destination_drift} -> residue(entry, "destination_drift")
      {:error, :branch_ref_oid_mismatch} -> residue(entry, "branch_tip_changed")
      {:error, reason} -> residue(entry, reason_string(reason))
      _other -> residue(entry, "entry_drift")
    end
  end

  defp archive_and_delete(entry, {:ok, :absent}, _branch, ids, _manifest, repository, _opts) do
    case Git.verify_archived_evidence_ref(
           repository["path"],
           ids.task_id,
           ids.workspace_id,
           entry["oid"]
         ) do
      {:ok, %{hidden_ref: hidden_ref}} -> {:ok, settled(entry, hidden_ref, "already_archived")}
      {:error, _reason} -> {:ok, residue(entry, "branch_absent_without_matching_evidence")}
    end
  end

  defp archive_and_delete(
         entry,
         {:ok, {:present, expected_oid}},
         branch,
         ids,
         manifest,
         repository,
         opts
       ) do
    if expected_oid != entry["oid"] do
      {:ok, residue(entry, "branch_tip_changed")}
    else
      with :ok <- verify_entry_proof(entry, repository["path"]),
           {:ok, %{hidden_ref: hidden_ref}} <-
             Git.archive_branch_evidence_ref(
               repository["path"],
               branch,
               ids.task_id,
               ids.workspace_id,
               entry["oid"]
             ),
           {:ok, %{hidden_ref: ^hidden_ref}} <-
             Git.verify_archived_evidence_ref(
               repository["path"],
               ids.task_id,
               ids.workspace_id,
               entry["oid"]
             ),
           {:ok, current_repository} <- Git.repository_identity(repository["path"]),
           true <- current_repository == repository,
           :ok <- verify_destination(manifest["destination"], repository["path"]),
           {:ok, protections} <-
             protections(repository["path"], manifest["destination"], manifest["limits"], opts),
           false <-
             Map.has_key?(protections, entry["ref"]) or
               policy_protected?(entry["ref"], manifest["destination"]),
           {:ok, {:present, ^expected_oid}} <- Git.observe_branch_ref(repository["path"], branch),
           :ok <- verify_entry_proof(entry, repository["path"]),
           :ok <- Git.delete_branch_ref(repository["path"], branch, entry["oid"]) do
        _ = opts
        {:ok, settled(entry, hidden_ref, "archived_and_retired")}
      else
        true -> {:ok, residue(entry, "protection_drift_after_archive")}
        false -> {:ok, residue(entry, "repository_identity_drift_after_archive")}
        {:error, reason} -> {:ok, residue(entry, reason_string(reason))}
        _other -> {:ok, residue(entry, "cas_delete_race")}
      end
    end
  end

  defp verify_entry_proof(%{"proof" => proof}, repo_path),
    do: Git.verify_adoption_proof(repo_path, proof)

  defp verify_entry_proof(
         %{
           "class" => "duplicate_tip",
           "reason" => "duplicate_tip_of:" <> survivor_ref,
           "oid" => oid
         },
         repo_path
       ) do
    with "refs/heads/" <> survivor_branch <- survivor_ref,
         {:ok, {:present, ^oid}} <- Git.observe_branch_ref(repo_path, survivor_branch) do
      :ok
    else
      _ -> {:error, :duplicate_survivor_drift}
    end
  end

  defp verify_entry_proof(%{"class" => class}, _repo_path)
       when class in ["merged", "patch_equivalent"], do: {:error, :missing_adoption_proof}

  defp verify_entry_proof(_entry, _repo_path), do: :ok

  defp policy_protected?(ref, destination) do
    ref == destination["ref"] or ref == "refs/heads/main" or
      ref == "refs/heads/eval/do-not-merge/security-audit-fixes" or
      String.starts_with?(ref, "refs/heads/preserve/")
  end

  defp migration_ids(identity, ref, oid) do
    digest =
      :crypto.hash(:sha256, identity <> "\n" <> ref <> "\n" <> oid)
      |> Base.encode16(case: :lower)

    %{task_id: "branch-audit-" <> digest, workspace_id: "migration-" <> digest}
  end

  defp settled(entry, hidden_ref, reason),
    do: %{
      "ref" => entry["ref"],
      "oid" => entry["oid"],
      "status" => "settled",
      "reason" => reason,
      "evidence_ref" => hidden_ref
    }

  defp residue(entry, reason),
    do: %{
      "ref" => entry["ref"],
      "oid" => entry["oid"],
      "status" => "preserved",
      "reason" => reason
    }

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_string({tag, nested}) when is_atom(tag),
    do: Atom.to_string(tag) <> ":" <> reason_string(nested)

  defp reason_string(reason) when is_binary(reason), do: reason
  defp reason_string(_reason), do: "unknown"
end
