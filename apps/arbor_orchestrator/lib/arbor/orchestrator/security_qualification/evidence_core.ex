defmodule Arbor.Orchestrator.SecurityQualification.EvidenceCore do
  @moduledoc "Pure admission of a complete, profile-bound security evidence composition."
  @schema "arbor.security.qualification.v1"
  @kinds ~w(hostile_export_journey audit_restart native_containment skill_revocation)

  def new(profile, run), do: %{profile: profile, run: run}

  def show(%{profile: %{fingerprint: fingerprint}, run: run}) do
    results = Map.get(run, :results)
    metadata = Map.get(run, :metadata, %{})

    with true <- valid_digest?(fingerprint),
         true <- Map.get(run, :domain) == "security_verify",
         true <- Map.get(run, :status) == "completed",
         true <- Map.get(run, :config_fingerprint) == fingerprint,
         true <- is_map(metadata) and metadata["qualification_schema"] == @schema,
         true <- metadata["live_model_status"] in ["passed", "safe_without_export"],
         true <- is_list(results) and length(results) == length(@kinds),
         true <- Map.get(run, :sample_count) == length(@kinds),
         true <- Enum.sort(Enum.map(results, &Map.get(&1, :sample_id))) == Enum.sort(@kinds),
         true <- Enum.all?(results, &admissible_result?(&1, fingerprint)) do
      {:ok,
       %{
         "id" => run.id,
         "profile_fingerprint" => fingerprint,
         "metadata" => metadata,
         "results" => results |> Enum.map(&result_projection/1) |> Enum.sort_by(& &1["sample_id"])
       }}
    else
      _ -> {:error, :incomplete_security_qualification}
    end
  end

  def show(_), do: {:error, :incomplete_security_qualification}

  defp admissible_result?(result, fingerprint) do
    metadata = Map.get(result, :metadata, %{})

    is_map(metadata) and Map.get(result, :passed) == true and
      Map.get(result, :precondition_met) == true and
      metadata["kind"] == Map.get(result, :sample_id) and
      metadata["profile_fingerprint"] == fingerprint and
      is_binary(metadata["producer"]) and byte_size(metadata["producer"]) in 1..128 and
      valid_digest?(metadata["producer_digest"]) and valid_digest?(metadata["artifact_digest"]) and
      is_map(metadata["observations"]) and map_size(metadata["observations"]) > 0
  end

  defp result_projection(result) do
    %{
      "id" => result.id,
      "sample_id" => result.sample_id,
      "passed" => result.passed,
      "precondition_met" => result.precondition_met,
      "metadata" => result.metadata,
      "actual" => Map.get(result, :actual)
    }
  end

  defp valid_digest?("sha256:" <> digest), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)
  defp valid_digest?(_), do: false
end
