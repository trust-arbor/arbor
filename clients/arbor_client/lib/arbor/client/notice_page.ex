defmodule Arbor.Client.NoticePage do
  @moduledoc """
  Closed, bounded decoding for the separately authenticated notice stream.

  Envelope hashes bind original recipient, scope and content. They are data
  consistency checks, not publication authority or proof of server identity.
  Authentication and the current conversation fence remain the host's job.
  """
  @page_keys ~w(owner_id target_agent_id engagement_id notices head through has_older next_before complete)
  @notice_keys ~w(notice_id recipient_subject_id kind text provenance ordinal created_at)
  @envelope_keys ~w(version payload_encoding payload_sha256 taint)
  @taint_keys ~w(level sensitivity sanitizations confidence source chain)
  @maximum_ordinal 9_223_372_036_854_775_807
  @frame_bytes 131_072
  @page_bytes 129_024

  def decode_frame(binary) when is_binary(binary) and byte_size(binary) <= @frame_bytes do
    with {:ok, ordered} <- Jason.decode(binary, objects: :ordered_objects),
         {:ok, %{"type" => "conversation_notices", "data" => data} = frame} <-
           unique_json(ordered, 0),
         true <- map_size(frame) == 2,
         {:ok, page} <- decode(data) do
      {:ok, page}
    else
      _ -> {:error, :invalid_notice_response}
    end
  rescue
    _ -> {:error, :invalid_notice_response}
  end

  def decode_frame(_), do: {:error, :invalid_notice_response}

  @doc "Validate data only; optional expected fields pin previously established scope."
  def decode(data, expected \\ %{}) do
    with true <- exact?(data, @page_keys),
         true <- scope?(data),
         true <- expected_scope?(data, expected),
         true <- ordinal?(data["head"]) and ordinal?(data["through"]),
         true <- data["through"] <= data["head"] and data["complete"] === true,
         true <- is_boolean(data["has_older"]),
         true <- is_list(data["notices"]) and length(data["notices"]) <= 50,
         true <- byte_size(Jason.encode!(data)) <= @page_bytes,
         true <- Enum.all?(data["notices"], &notice?(&1, data)),
         true <- ordered?(data["notices"]),
         true <- cursor?(data) do
      {:ok, data}
    else
      _ -> {:error, :invalid_notice_response}
    end
  rescue
    _ -> {:error, :invalid_notice_response}
  end

  defp scope?(page) do
    identifier?(page["owner_id"], ~r/\Ahuman_[A-Za-z0-9_-]+\z/) and
      identifier?(page["target_agent_id"], ~r/\Aagent_[A-Za-z0-9_-]+\z/) and
      identifier?(page["engagement_id"], ~r/\Aeng_[0-9a-f]{32}\z/)
  end

  defp expected_scope?(page, expected) when is_map(expected) and not is_struct(expected) do
    Enum.all?(expected, fn
      {key, value} when key in [:owner_id, :target_agent_id, :engagement_id] ->
        is_binary(value) and page[Atom.to_string(key)] == value

      _ ->
        false
    end)
  end

  defp expected_scope?(_, _), do: false

  defp notice?(notice, page) do
    exact?(notice, @notice_keys) and
      identifier?(notice["notice_id"], ~r/\Anotice_[0-9a-f]{32}\z/) and
      identifier?(notice["recipient_subject_id"], ~r/\Ahuman_[A-Za-z0-9_-]+\z/) and
      notice["kind"] in ["notification", "progress"] and text?(notice["text"]) and
      ordinal?(notice["ordinal"]) and notice["ordinal"] > 0 and
      notice["ordinal"] <= page["through"] and timestamp?(notice["created_at"]) and
      provenance?(notice, page)
  end

  defp provenance?(notice, page) do
    provenance = notice["provenance"]

    with true <- exact?(provenance, ~w(origin taint)),
         true <- provenance["origin"] == "native_action",
         true <- byte_size(Jason.encode!(provenance)) <= 4_096,
         envelope = provenance["taint"],
         true <- exact?(envelope, @envelope_keys),
         true <- envelope["version"] === 1,
         true <- envelope["payload_encoding"] == "canonical_json_v1",
         true <- retained_taint?(envelope["taint"]) do
      # This version's payload is a fixed array of UTF-8 strings. Jason encoding
      # is identical to the server's canonical_json_v1 for this closed shape.
      payload = [
        "arbor.notice.provenance.v1",
        page["owner_id"],
        page["target_agent_id"],
        page["engagement_id"],
        notice["recipient_subject_id"],
        notice["notice_id"],
        notice["kind"],
        notice["text"]
      ]

      digest = payload |> Jason.encode!() |> then(&:crypto.hash(:sha256, &1))
      envelope["payload_sha256"] == Base.encode16(digest, case: :lower)
    else
      _ -> false
    end
  end

  defp retained_taint?(taint) do
    exact?(taint, @taint_keys) and taint["level"] in ["untrusted", "hostile"] and
      taint["sensitivity"] in ["internal", "confidential", "restricted"] and
      taint["sanitizations"] === 0 and taint["confidence"] == "unverified" and
      taint["source"] == "native_conversation_notice" and taint["chain"] === []
  end

  defp ordered?(notices) do
    ids = Enum.map(notices, & &1["notice_id"])
    ordinals = Enum.map(notices, & &1["ordinal"])

    length(ids) == length(Enum.uniq(ids)) and
      Enum.all?(Enum.chunk_every(ordinals, 2, 1, :discard), fn [a, b] -> a > b end)
  end

  defp cursor?(%{"notices" => []} = page),
    do: page["has_older"] === false and page["next_before"] === nil

  defp cursor?(page) do
    if page["has_older"],
      do: page["next_before"] === List.last(page["notices"])["ordinal"],
      else: page["next_before"] === nil
  end

  defp ordinal?(value), do: is_integer(value) and value in 0..@maximum_ordinal

  defp text?(value),
    do:
      is_binary(value) and byte_size(value) in 1..32_768 and String.valid?(value) and
        String.trim(value) != ""

  defp timestamp?(value) when is_binary(value) and byte_size(value) <= 32 do
    case DateTime.from_iso8601(value) do
      {:ok, %{microsecond: {_, 6}}, 0} -> String.ends_with?(value, "Z")
      _ -> false
    end
  end

  defp timestamp?(_), do: false

  defp identifier?(value, pattern),
    do:
      is_binary(value) and byte_size(value) in 1..256 and String.valid?(value) and
        Regex.match?(pattern, value)

  defp exact?(value, keys) when is_map(value) and not is_struct(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp exact?(_, _), do: false

  defp unique_json(_, depth) when depth > 12, do: :invalid

  defp unique_json(%Jason.OrderedObject{values: pairs}, depth) do
    if length(pairs) <= 16 and length(pairs) == length(Enum.uniq_by(pairs, &elem(&1, 0))) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, result} ->
        case unique_json(value, depth + 1) do
          {:ok, decoded} -> {:cont, {:ok, Map.put(result, key, decoded)}}
          _ -> {:halt, :invalid}
        end
      end)
    else
      :invalid
    end
  end

  defp unique_json(values, depth) when is_list(values) and length(values) <= 50 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, result} ->
      case unique_json(value, depth + 1) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | result]}}
        _ -> {:halt, :invalid}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      other -> other
    end
  end

  defp unique_json(values, _) when is_list(values), do: :invalid
  defp unique_json(value, _), do: {:ok, value}
end
