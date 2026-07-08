defmodule Arbor.Agent.Orchestration.TaskArtifacts do
  @moduledoc """
  Normalizes async orchestration task outputs into stable artifact shapes.

  The task store stays generic: runners may return plain values, chat
  responses, or raw action maps. This module upgrades known coding-agent
  outputs into the Slice-2 reviewable-change artifact shape while preserving a
  generic fallback for ordinary chat/value tasks.
  """

  @coding_statuses MapSet.new(~w(
    change_committed
    declined
    human_review_required
    no_changes
    pr_created
    pr_failed
    review_failed
    review_rejected
    review_requires_rework
    validation_failed
  ))

  @coding_tool_names MapSet.new(~w(
    coding_produce_reviewable_change
    coding.produce_reviewable_change
    produce_reviewable_change
  ))

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
    %{
      result_type: :coding_change,
      payload:
        %{
          branch: value(raw, :branch),
          commit: value(raw, :commit),
          diff: value(raw, :diff),
          files: files(raw),
          report: report(raw),
          verdict: verdict(raw),
          repo_path: value(raw, :repo_path),
          worktree_path: value(raw, :worktree_path),
          pr_url: value(raw, :pr_url)
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

    is_binary(status) and
      MapSet.member?(@coding_statuses, status) and
      Enum.any?(
        [:branch, :commit, :worktree_path, :validation, :review],
        &present?(value(map, &1))
      )
  end

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

  defp report(raw) do
    review = value(raw, :review)

    %{
      status: value(raw, :status),
      validation: value(raw, :validation),
      response_text: value(raw, :response_text),
      pr_url: value(raw, :pr_url),
      review: review,
      review_recommendation: value(raw, :review_recommendation) || value(review, :recommendation),
      tier_decision: value(raw, :tier_decision) || value(review, :tier_decision),
      human_required: value(raw, :human_required) || value(review, :human_required),
      security_veto: value(raw, :security_veto) || value(review, :security_veto),
      blast_radius: value(raw, :blast_radius) || value(review, :blast_radius),
      error: value(raw, :error) || value(raw, :review_error)
    }
    |> reject_nil_values()
  end

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

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp empty_to_nil(map) when is_map(map) and map_size(map) == 0, do: nil
  defp empty_to_nil(value), do: value
end
