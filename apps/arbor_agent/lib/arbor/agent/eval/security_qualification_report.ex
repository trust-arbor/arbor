defmodule Arbor.Agent.Eval.SecurityQualificationReport do
  @moduledoc """
  Compose a persisted live journey and reviewed acceptance artifacts for approval.

  External native, recovery and skill evidence remains operator-reviewed evidence.
  This parser checks its closed observations and binds the complete content; it
  does not attest that an arbitrary supplied file is honest. Composition grants
  no execution authority. The Session independently captures the current profile
  and requires an exact signed approval for the complete persisted composition.
  """
  alias Arbor.Agent.Eval.SecurityQualificationReportCore
  alias Arbor.Persistence

  def compose(profile, journey_id, artifacts) do
    id = "security_qualification_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    with true <- :erlang.external_size({profile, artifacts}) <= 2_097_152,
         true <- profile.fingerprint == Persistence.eval_config_fingerprint(profile.projection),
         {:ok, journey} <- Persistence.get_eval_run(journey_id),
         true <- journey_digest_matches?(journey),
         {:ok, prepared} <-
           SecurityQualificationReportCore.new(profile, journey, artifacts, identity(), id)
           |> SecurityQualificationReportCore.show(),
         {:ok, run} <- Persistence.insert_eval_run(prepared.run),
         true <- run.id == id and run.status == "running",
         {:ok, results} <- persist_results(id, prepared.results),
         {:ok, pending} <- Persistence.get_eval_run(id),
         true <- exact_run?(pending, prepared.run, results, "running"),
         {:ok, :transitioned} <-
           Persistence.compare_and_set_eval_run_status(id, "running", %{
             status: "completed",
             sample_count: length(results)
           }),
         {:ok, completed} <- Persistence.get_eval_run(id),
         true <- exact_run?(completed, prepared.run, results, "completed") do
      {:ok,
       %{
         run_id: id,
         profile_fingerprint: profile.fingerprint,
         status: :completed,
         approval: :required
       }}
    else
      _ -> {:error, :security_qualification_persistence_or_evidence_failed}
    end
  rescue
    _ -> {:error, :security_qualification_persistence_or_evidence_failed}
  catch
    _, _ -> {:error, :security_qualification_persistence_or_evidence_failed}
  end

  def required_artifact_observations, do: SecurityQualificationReportCore.required_observations()

  defp identity do
    implementation =
      Enum.map([__MODULE__, SecurityQualificationReportCore], fn module ->
        Code.ensure_loaded!(module)

        %{
          "module" => Atom.to_string(module),
          "loaded_md5" => Base.encode16(module.module_info(:md5), case: :lower)
        }
      end)

    %{
      "producer" => "Arbor.Agent.Eval.SecurityQualificationReport",
      "digest" => Persistence.eval_config_fingerprint(%{"implementation" => implementation})
    }
  end

  defp journey_digest_matches?(%{results: [result]}) do
    metadata = result.metadata
    metadata["artifact_digest"] == Persistence.eval_config_fingerprint(metadata["observations"])
  end

  defp journey_digest_matches?(_), do: false

  defp persist_results(run_id, results) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, saved} ->
      metadata =
        Map.put(
          result.metadata,
          "artifact_digest",
          Persistence.eval_config_fingerprint(result.metadata["observations"])
        )

      attrs =
        result
        |> Map.put(:metadata, metadata)
        |> Map.put(:run_id, run_id)
        |> Map.put(:id, run_id <> "_" <> result.sample_id)

      case Persistence.insert_eval_result(attrs) do
        {:ok, stored} ->
          if exact_result?(stored, attrs),
            do: {:cont, {:ok, [attrs | saved]}},
            else: {:halt, {:error, :result_ack_mismatch}}

        _ ->
          {:halt, {:error, :result_persistence_failed}}
      end
    end)
  end

  defp exact_run?(run, attrs, expected_results, status) do
    run.id == attrs.id and run.status == status and run.domain == attrs.domain and
      run.config_fingerprint == attrs.config_fingerprint and run.config == attrs.config and
      run.metadata == attrs.metadata and
      run.sample_count == if(status == "running", do: 0, else: length(expected_results)) and
      is_list(run.results) and length(run.results) == length(expected_results) and
      Enum.all?(expected_results, fn expected ->
        case Enum.filter(run.results, &(&1.id == expected.id)) do
          [actual] -> exact_result?(actual, expected)
          _ -> false
        end
      end)
  end

  defp exact_result?(actual, attrs) do
    Enum.all?(attrs, fn {key, value} -> Map.get(actual, key) == value end)
  end
end
