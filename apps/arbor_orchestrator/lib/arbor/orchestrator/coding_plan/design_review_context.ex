defmodule Arbor.Orchestrator.CodingPlan.DesignReviewContext do
  @moduledoc false

  alias Arbor.Contracts.Coding.{CandidateMaterialization, Plan}

  @schema_version 1
  # Keep this in lockstep with DesignCouncilCore's per-section budget so an
  # admitted plan cannot fail only after council egress begins.
  @max_bytes 4_096
  @fingerprint_pattern ~r/\A[0-9a-f]{64}\z/

  @doc "Build the canonical, authority-free Plan fields exposed to design reviewers."
  @spec canonical_json(Plan.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def canonical_json(%Plan{version: 2} = plan, plan_fingerprint)
      when is_binary(plan_fingerprint) do
    with true <- Regex.match?(@fingerprint_pattern, plan_fingerprint),
         {:ok, candidate_identity} <- candidate_identity(plan.candidate_materialization),
         {:ok, encoded} <-
           encode(%{
             "schema_version" => @schema_version,
             "plan_fingerprint" => plan_fingerprint,
             "plan_version" => plan.version,
             "base_ref" => plan.base_ref,
             "task_class" => plan.task_class,
             "workspace_policy" => Map.take(plan.workspace_policy, ["mode", "branch_name"]),
             "worker" =>
               Map.take(plan.worker, ["provider", "model", "permission_mode", "use_pool"]),
             "validation_profile" => plan.validation_profile,
             "review_profile" => plan.review_profile,
             "overlays" => plan.overlays,
             "rework" => plan.rework,
             "budgets" => plan.budgets,
             "output" => plan.output,
             "requested_paths" => plan.requested_paths,
             "work_packet_digest" => plan.work_packet_digest,
             "candidate_materialization" => candidate_identity
           }),
         true <- byte_size(encoded) <= @max_bytes do
      {:ok, encoded}
    else
      false -> {:error, :invalid_design_review_context}
      {:error, _reason} = error -> error
    end
  rescue
    _exception -> {:error, :invalid_design_review_context}
  catch
    _kind, _reason -> {:error, :invalid_design_review_context}
  end

  def canonical_json(_plan, _plan_fingerprint),
    do: {:ok, "{}"}

  defp candidate_identity(nil), do: {:ok, nil}

  defp candidate_identity(descriptor) when is_map(descriptor) do
    with {:ok, digest} <- CandidateMaterialization.digest(descriptor) do
      {:ok,
       %{
         "digest" => digest,
         "source_commit_oid" => descriptor["source_commit_oid"],
         "expected_tree_oid" => descriptor["expected_tree_oid"],
         "entry_count" => length(descriptor["entries"])
       }}
    end
  end

  defp candidate_identity(_descriptor), do: {:error, :invalid_design_review_context}

  defp encode(value) do
    value
    |> canonicalize()
    |> Jason.encode()
    |> case do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :invalid_design_review_context}
    end
  end

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value
end
