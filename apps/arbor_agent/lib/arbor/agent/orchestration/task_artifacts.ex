defmodule Arbor.Agent.Orchestration.TaskArtifacts do
  @moduledoc """
  Normalizes async orchestration task outputs into stable artifact shapes.

  The task store stays generic: runners may return plain values, chat
  responses, or raw action maps. This module upgrades known coding-agent
  outputs into the Slice-2 reviewable-change artifact shape while preserving a
  generic fallback for ordinary chat/value tasks.
  """

  @coding_statuses MapSet.new(~w(
    approval_denied
    change_committed
    declined
    human_review_required
    no_changes
    pipeline_error
    pr_created
    pr_failed
    review_failed
    review_rejected
    review_requires_rework
    rework_exhausted
    validation_failed
  ))

  @coding_tool_names MapSet.new(~w(
    coding_produce_reviewable_change
    coding.produce_reviewable_change
    produce_reviewable_change
  ))

  @coding_artifact_required_keys MapSet.new(~w(
                                   coding_plan_path
                                   coding_pipeline_path
                                   compile_manifest_path
                                   compiler_version
                                   graph_hash
                                 ))
  @coding_artifact_optional_keys MapSet.new(~w(
                                   acp_transcript
                                   adoption_evidence
                                   task_evidence
                                   workspace_release
                                 ))
  @coding_artifact_path_keys ~w(
    coding_plan_path
    coding_pipeline_path
    compile_manifest_path
  )
  @lowercase_sha256 ~r/\A[0-9a-f]{64}\z/
  @max_metrics_depth 16
  @max_provider_session_id_length 200

  alias Arbor.Contracts.Comms.ApprovalAnswer

  alias Arbor.Contracts.Coding.{
    TaskEvidenceDescriptor,
    TranscriptDescriptor,
    WorkspaceReleaseDescriptor
  }

  @doc "Normalize a runner result into the public task-result artifact shape."
  @spec normalize(term()) :: map()
  def normalize(result) do
    case find_coding_result(result) do
      {:ok, coding_result} ->
        coding_change_result(coding_result, result)

      :error ->
        generic_result(result)
    end
  end

  defp coding_change_result(raw, original) do
    artifacts = coding_artifacts(raw)
    metrics = coding_metrics(raw)

    %{
      result_type: :coding_change,
      payload:
        %{
          branch: value(raw, :branch),
          branch_provenance: value(raw, :branch_provenance),
          base_commit: value(raw, :base_commit),
          commit: value(raw, :commit),
          diff: value(raw, :diff),
          files: files(raw),
          report: report(raw, artifacts, metrics),
          verdict: verdict(raw),
          artifacts: artifacts,
          metrics: metrics,
          repo_path: value(raw, :repo_path),
          worktree_path: value(raw, :worktree_path),
          pr_url: value(raw, :pr_url),
          evidence_ref: value(raw, :evidence_ref),
          adoption: value(raw, :adoption),
          worker_provider_session_id:
            bounded_provider_session_id(value(raw, :worker_provider_session_id))
        }
        |> reject_nil_values(),
      raw: raw,
      source: source(original)
    }
  end

  defp generic_result(%{result_type: _type, payload: _payload} = result), do: result
  defp generic_result(%{"result_type" => _type, "payload" => _payload} = result), do: result

  defp generic_result(text) when is_binary(text) do
    %{
      result_type: :chat,
      payload: %{text: text},
      raw: text
    }
  end

  defp generic_result(%{} = result) do
    text = value(result, :text) || value(result, :content)

    if is_binary(text) do
      %{
        result_type: :chat,
        payload:
          %{
            text: text,
            tool_calls: value(result, :tool_calls),
            tool_rounds: value(result, :tool_rounds),
            usage: value(result, :usage)
          }
          |> reject_nil_values(),
        raw: result
      }
    else
      %{
        result_type: :value,
        payload: %{value: result},
        raw: result
      }
    end
  end

  defp generic_result(result) do
    %{
      result_type: :value,
      payload: %{value: result},
      raw: result
    }
  end

  defp find_coding_result(result), do: find_coding_result(result, 0)

  defp find_coding_result(_result, depth) when depth > 6, do: :error

  defp find_coding_result({:ok, result}, depth), do: find_coding_result(result, depth + 1)
  defp find_coding_result({:error, _reason}, _depth), do: :error

  defp find_coding_result(text, depth) when is_binary(text) do
    text
    |> decode_json_object()
    |> case do
      {:ok, decoded} -> find_coding_result(decoded, depth + 1)
      :error -> :error
    end
  end

  defp find_coding_result(%{} = map, depth) do
    cond do
      coding_result?(map) ->
        {:ok, map}

      true ->
        [
          value(map, :result),
          value(map, :payload),
          value(map, :raw),
          value(map, :text),
          value(map, :content)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.find_value(fn candidate ->
          case find_coding_result(candidate, depth + 1) do
            {:ok, _} = ok -> ok
            :error -> nil
          end
        end)
        |> case do
          {:ok, _} = ok -> ok
          nil -> find_coding_tool_result(map, depth + 1)
        end
    end
  end

  defp find_coding_result(list, depth) when is_list(list) do
    Enum.find_value(list, :error, fn item ->
      case find_coding_result(item, depth + 1) do
        {:ok, _} = ok -> ok
        :error -> nil
      end
    end)
  end

  defp find_coding_result(_result, _depth), do: :error

  defp find_coding_tool_result(map, depth) do
    [value(map, :tool_calls), value(map, :tool_history)]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(fn calls ->
      calls
      |> List.wrap()
      |> Enum.find_value(fn call -> coding_tool_result(call, depth + 1) end)
    end)
    |> case do
      {:ok, _} = ok -> ok
      nil -> :error
    end
  end

  defp coding_tool_result(%{} = call, depth) do
    name = value(call, :name) || value(call, :tool) || value(call, :tool_name)

    if coding_tool_name?(name) do
      [
        value(call, :result),
        value(call, :output),
        value(call, :content),
        value(call, :text),
        value(call, :response)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.find_value(fn candidate ->
        case find_coding_result(candidate, depth + 1) do
          {:ok, _} = ok -> ok
          :error -> nil
        end
      end)
    else
      case find_coding_result(Map.drop(call, [:arguments, "arguments"]), depth + 1) do
        {:ok, _} = ok -> ok
        :error -> nil
      end
    end
  end

  defp coding_tool_result(_call, _depth), do: nil

  defp coding_tool_name?(name) when is_atom(name), do: coding_tool_name?(Atom.to_string(name))
  defp coding_tool_name?(name) when is_binary(name), do: MapSet.member?(@coding_tool_names, name)
  defp coding_tool_name?(_name), do: false

  defp coding_result?(%{} = map) do
    status = value(map, :status)
    artifacts = value(map, :artifacts)

    is_binary(status) and
      MapSet.member?(@coding_statuses, status) and
      (Enum.any?(
         [:branch, :commit, :worktree_path, :validation, :review],
         &present?(value(map, &1))
       ) or valid_coding_artifacts?(artifacts) or pipeline_error?(map, status))
  end

  defp pipeline_error?(map, "pipeline_error") do
    Enum.any?(
      [:error, :workspace_id, :worker_session_id, :worker_provider_session_id],
      &present?(value(map, &1))
    )
  end

  defp pipeline_error?(_map, _status), do: false

  defp files(raw) do
    cond do
      list = value(raw, :files) ->
        normalize_files(list)

      review = value(raw, :review) ->
        review |> value(:files) |> normalize_files()

      true ->
        []
    end
  end

  defp normalize_files(files) when is_list(files) do
    files
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_files(_files), do: []

  defp report(raw, artifacts, metrics) do
    review = value(raw, :review)

    %{
      status: value(raw, :status),
      canonical_status: value(raw, :canonical_status),
      validation: value(raw, :validation),
      response_text: value(raw, :response_text),
      pr_url: value(raw, :pr_url),
      review: review,
      review_recommendation: value(raw, :review_recommendation) || value(review, :recommendation),
      tier_decision: value(raw, :tier_decision) || value(review, :tier_decision),
      human_required: value(raw, :human_required) || value(review, :human_required),
      security_veto: value(raw, :security_veto) || value(review, :security_veto),
      blast_radius: value(raw, :blast_radius) || value(review, :blast_radius),
      artifacts: artifacts,
      metrics: metrics,
      error: value(raw, :error) || value(raw, :review_error),
      # Stable, bounded operator-approval scalars only (never raw metadata maps).
      approval_request_id: bounded_approval_request_id(value(raw, :approval_request_id)),
      approval_note: bounded_approval_note(value(raw, :approval_note)),
      worker_provider_session_id:
        bounded_provider_session_id(value(raw, :worker_provider_session_id))
    }
    |> reject_nil_values()
  end

  defp bounded_approval_request_id(id) when is_binary(id) do
    case ApprovalAnswer.validate_request_id(id) do
      {:ok, valid} -> valid
      {:error, _} -> nil
    end
  end

  defp bounded_approval_request_id(_), do: nil

  defp bounded_approval_note(note) when is_binary(note) do
    case ApprovalAnswer.validate_note(note, truncate: true, drop_invalid: true) do
      {:ok, ""} -> nil
      {:ok, bounded} -> bounded
      {:error, _} -> nil
    end
  end

  defp bounded_approval_note(_), do: nil

  # Provider session ids are opaque provider data, so retain only a bounded,
  # JSON-clean scalar rather than imposing provider-specific identifier syntax.
  defp bounded_provider_session_id(id) when is_binary(id) do
    if String.valid?(id) and String.trim(id) != "" and
         String.length(id) <= @max_provider_session_id_length and
         not String.match?(id, ~r/[\x00-\x1F\x7F]/) do
      id
    end
  end

  defp bounded_provider_session_id(_), do: nil

  defp verdict(raw) do
    review = value(raw, :review)

    (value(raw, :verdict) ||
       (is_map(review) && value(review, :verdict)) ||
       %{
         status: value(raw, :status),
         recommendation: value(raw, :review_recommendation) || value(review, :recommendation),
         tier_decision: value(raw, :tier_decision) || value(review, :tier_decision),
         human_required: value(raw, :human_required) || value(review, :human_required),
         security_veto: value(raw, :security_veto) || value(review, :security_veto),
         blast_radius: value(raw, :blast_radius) || value(review, :blast_radius)
       })
    |> case do
      map when is_map(map) -> reject_nil_values(map)
      other -> other
    end
    |> empty_to_nil()
  end

  defp source(original) do
    cond do
      is_map(original) and (value(original, :tool_calls) || value(original, :tool_history)) ->
        :tool_history

      is_binary(original) ->
        :json_text

      true ->
        :structured_result
    end
  end

  defp decode_json_object(text) do
    trimmed = String.trim(text)

    if String.starts_with?(trimmed, "{") do
      case Jason.decode(trimmed) do
        {:ok, %{} = map} -> {:ok, map}
        _ -> :error
      end
    else
      :error
    end
  end

  defp value(term, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp value(_term, _key, default), do: default

  defp present?(value), do: value not in [nil, "", []]

  defp coding_artifacts(raw) do
    case value(raw, :artifacts) do
      artifacts when is_map(artifacts) ->
        if valid_coding_artifacts?(artifacts), do: normalize_coding_artifacts(artifacts)

      _other ->
        nil
    end
  end

  defp valid_coding_artifacts?(artifacts)
       when is_map(artifacts) and not is_struct(artifacts) do
    keys = Map.keys(artifacts) |> MapSet.new()
    required_ok? = MapSet.subset?(@coding_artifact_required_keys, keys)

    unknown =
      MapSet.difference(
        keys,
        MapSet.union(@coding_artifact_required_keys, @coding_artifact_optional_keys)
      )

    required_ok? and MapSet.size(unknown) == 0 and
      Enum.all?(@coding_artifact_path_keys, &nonblank_string?(Map.get(artifacts, &1))) and
      nonblank_string?(Map.get(artifacts, "compiler_version")) and
      lowercase_sha256?(Map.get(artifacts, "graph_hash")) and
      optional_artifact_fields_valid?(artifacts)
  end

  defp valid_coding_artifacts?(_artifacts), do: false

  defp optional_artifact_fields_valid?(artifacts) do
    Enum.all?(@coding_artifact_optional_keys, fn key ->
      case Map.fetch(artifacts, key) do
        :error -> true
        {:ok, value} -> valid_optional_artifact_field?(key, value)
      end
    end)
  end

  defp valid_optional_artifact_field?("acp_transcript", value),
    do: TranscriptDescriptor.valid?(value)

  defp valid_optional_artifact_field?("adoption_evidence", value),
    do: TaskEvidenceDescriptor.valid?(value)

  defp valid_optional_artifact_field?("task_evidence", value),
    do: TaskEvidenceDescriptor.valid?(value)

  defp valid_optional_artifact_field?("workspace_release", value),
    do: WorkspaceReleaseDescriptor.valid?(value)

  defp valid_optional_artifact_field?(_key, _value), do: false

  defp normalize_coding_artifacts(artifacts) do
    # Preserve required compile descriptors and validated optional evidence only.
    normalized =
      Map.take(
        artifacts,
        MapSet.to_list(@coding_artifact_required_keys) ++
          MapSet.to_list(@coding_artifact_optional_keys)
      )

    normalized
    |> normalize_optional_artifact("acp_transcript", TranscriptDescriptor)
    |> normalize_optional_artifact("adoption_evidence", TaskEvidenceDescriptor)
    |> normalize_optional_artifact("task_evidence", TaskEvidenceDescriptor)
    |> normalize_optional_artifact("workspace_release", WorkspaceReleaseDescriptor)
  end

  defp normalize_optional_artifact(artifacts, key, contract) do
    case Map.fetch(artifacts, key) do
      {:ok, descriptor} ->
        {:ok, projected} = contract.normalize(descriptor)
        Map.put(artifacts, key, projected)

      :error ->
        artifacts
    end
  end

  defp coding_metrics(raw) do
    case value(raw, :metrics) do
      metrics when is_map(metrics) and not is_struct(metrics) ->
        if valid_metrics?(metrics), do: metrics

      _other ->
        nil
    end
  end

  defp valid_metrics?(metrics) do
    with :ok <- validate_metric_map(metrics, 0),
         {:ok, _encoded} <- Jason.encode(metrics) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp validate_metric_map(_map, depth) when depth > @max_metrics_depth, do: :error

  defp validate_metric_map(map, depth) do
    map
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {key, metric_value}, {:ok, keys} ->
      with {:ok, clean_key} <- validate_metric_key(key),
           false <- MapSet.member?(keys, clean_key),
           :ok <- validate_metric_value(metric_value, depth + 1) do
        {:cont, {:ok, MapSet.put(keys, clean_key)}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, _keys} -> :ok
      :error -> :error
    end
  end

  defp validate_metric_key(key) when is_atom(key),
    do: {:ok, Atom.to_string(key)}

  defp validate_metric_key(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: :error
  end

  defp validate_metric_key(_key), do: :error

  defp validate_metric_value(_value, depth) when depth > @max_metrics_depth, do: :error

  defp validate_metric_value(value, _depth)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp validate_metric_value(value, _depth) when is_binary(value) do
    if String.valid?(value), do: :ok, else: :error
  end

  defp validate_metric_value(%_{}, _depth), do: :error
  defp validate_metric_value(map, depth) when is_map(map), do: validate_metric_map(map, depth)

  defp validate_metric_value(list, depth) when is_list(list) do
    Enum.reduce_while(list, :ok, fn value, :ok ->
      case validate_metric_value(value, depth + 1) do
        :ok -> {:cont, :ok}
        :error -> {:halt, :error}
      end
    end)
  end

  defp validate_metric_value(_value, _depth), do: :error

  defp nonblank_string?(value) when is_binary(value),
    do: String.valid?(value) and String.trim(value) != ""

  defp nonblank_string?(_value), do: false

  defp lowercase_sha256?(value) when is_binary(value),
    do: String.valid?(value) and Regex.match?(@lowercase_sha256, value)

  defp lowercase_sha256?(_value), do: false

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp empty_to_nil(map) when is_map(map) and map_size(map) == 0, do: nil
  defp empty_to_nil(value), do: value
end
