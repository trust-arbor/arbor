defmodule ConversationKit.Arbor.NoticeCodec do
  @moduledoc false
  # Local host adapters intentionally do not depend on the remote SDK or Mint.
  # These fixed-shape consistency checks grant no publication/read authority.
  @page ~w(owner_id target_agent_id engagement_id notices head through has_older next_before complete)
  @notice ~w(notice_id recipient_subject_id kind text provenance ordinal created_at)
  @provenance ~w(origin taint)
  @envelope ~w(version payload_encoding payload_sha256 taint)
  @taint ~w(level sensitivity sanitizations confidence source chain)
  @maximum 9_223_372_036_854_775_807

  def options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(opts, fn
           {key, value} when key in [:before, :through] -> positive?(value)
           {:limit, value} -> is_integer(value) and value in 1..50
           _ -> false
         end),
       do: :ok,
       else: {:error, :invalid_notice_request}
  end

  def options(_), do: {:error, :invalid_notice_request}

  def page(raw, expected, opts) do
    with {:ok, page} <- closed(raw, @page),
         true <- scope?(page),
         true <- ordinal?(page["head"]) and ordinal?(page["through"]),
         true <- page["through"] <= page["head"] and page["complete"] === true,
         true <- is_boolean(page["has_older"]),
         true <- is_list(page["notices"]) and length(page["notices"]) <= opts[:limit],
         {:ok, notices} <- records(page["notices"], page),
         page = Map.put(page, "notices", notices),
         true <- byte_size(JSON.encode!(page)) <= 129_024,
         true <- ordered?(notices) and cursor?(page),
         true <- bounds?(page, opts),
         :ok <- expected_scope(page, expected) do
      semantic =
        Enum.map(notices, fn notice ->
          %{
            "id" => notice["notice_id"],
            "kind" => notice["kind"],
            "text" => notice["text"],
            "timestamp" => notice["created_at"],
            "ordinal" => notice["ordinal"]
          }
        end)

      {:ok, page, semantic}
    else
      {:error, :conversation_scope_changed} = error -> error
      _ -> {:error, :invalid_notice_response}
    end
  rescue
    _ -> {:error, :invalid_notice_response}
  end

  defp records(values, page) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case notice(value, page) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _ -> {:halt, :invalid}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      _ -> :invalid
    end
  end

  defp notice(raw, page) do
    with {:ok, notice} <- closed(raw, @notice),
         true <- identifier?(notice["notice_id"], ~r/\Anotice_[0-9a-f]{32}\z/),
         true <- identifier?(notice["recipient_subject_id"], ~r/\Ahuman_[A-Za-z0-9_-]+\z/),
         kind = enum(notice["kind"]),
         true <- kind in ["notification", "progress"],
         true <- text?(notice["text"]),
         true <- positive?(notice["ordinal"]) and notice["ordinal"] <= page["through"],
         true <- timestamp?(notice["created_at"]),
         {:ok, provenance} <- provenance(notice["provenance"]),
         notice = notice |> Map.put("kind", kind) |> Map.put("provenance", provenance),
         true <- provenance["taint"]["payload_sha256"] == digest(page, notice) do
      {:ok, notice}
    else
      _ -> :invalid
    end
  end

  defp provenance(raw) do
    with {:ok, value} <- closed(raw, @provenance),
         true <- enum(value["origin"]) == "native_action",
         {:ok, envelope} <- closed(value["taint"], @envelope),
         true <- envelope["version"] === 1,
         true <- enum(envelope["payload_encoding"]) == "canonical_json_v1",
         true <-
           is_binary(envelope["payload_sha256"]) and byte_size(envelope["payload_sha256"]) == 64,
         {:ok, taint} <- closed(envelope["taint"], @taint),
         true <- enum(taint["level"]) in ["untrusted", "hostile"],
         true <- enum(taint["sensitivity"]) in ["internal", "confidential", "restricted"],
         true <- taint["sanitizations"] === 0 and enum(taint["confidence"]) == "unverified",
         true <- enum(taint["source"]) == "native_conversation_notice" and taint["chain"] === [] do
      taint = Map.new(taint, fn {key, value} -> {key, enum(value)} end)

      value = %{
        "origin" => "native_action",
        "taint" => %{
          "version" => 1,
          "payload_encoding" => "canonical_json_v1",
          "payload_sha256" => envelope["payload_sha256"],
          "taint" => taint
        }
      }

      if byte_size(JSON.encode!(value)) <= 4_096, do: {:ok, value}, else: :invalid
    else
      _ -> :invalid
    end
  end

  defp digest(page, notice) do
    [
      "arbor.notice.provenance.v1",
      page["owner_id"],
      page["target_agent_id"],
      page["engagement_id"],
      notice["recipient_subject_id"],
      notice["notice_id"],
      notice["kind"],
      notice["text"]
    ]
    |> JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp scope?(page),
    do:
      identifier?(page["owner_id"], ~r/\Ahuman_[A-Za-z0-9_-]+\z/) and
        identifier?(page["target_agent_id"], ~r/\Aagent_[A-Za-z0-9_-]+\z/) and
        identifier?(page["engagement_id"], ~r/\Aeng_[0-9a-f]{32}\z/)

  defp expected_scope(page, expected) do
    if Enum.all?(expected, fn {key, value} -> page[Atom.to_string(key)] == value end),
      do: :ok,
      else: {:error, :conversation_scope_changed}
  end

  defp bounds?(page, opts) do
    (not Keyword.has_key?(opts, :through) or page["through"] == opts[:through]) and
      (Keyword.has_key?(opts, :through) or page["through"] == page["head"]) and
      Enum.all?(page["notices"], fn value ->
        not Keyword.has_key?(opts, :before) or value["ordinal"] < opts[:before]
      end)
  end

  defp ordered?(records) do
    length(records) == length(Enum.uniq_by(records, & &1["notice_id"])) and
      Enum.all?(Enum.chunk_every(records, 2, 1, :discard), fn [a, b] ->
        a["ordinal"] > b["ordinal"]
      end)
  end

  defp cursor?(%{"notices" => []} = page),
    do: page["has_older"] === false and page["next_before"] === nil

  defp cursor?(page),
    do:
      if(page["has_older"],
        do: page["next_before"] === List.last(page["notices"])["ordinal"],
        else: page["next_before"] === nil
      )

  defp closed(value, keys) when is_map(value) and not is_struct(value) do
    if map_size(value) == length(keys) do
      result =
        Enum.reduce_while(value, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
          name = if is_atom(key), do: Atom.to_string(key), else: key

          if name in keys and not Map.has_key?(acc, name),
            do: {:cont, {:ok, Map.put(acc, name, value)}},
            else: {:halt, :invalid}
        end)

      result
    else
      :invalid
    end
  end

  defp closed(_, _), do: :invalid

  defp enum(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp enum(value), do: value
  defp ordinal?(value), do: is_integer(value) and value in 0..@maximum
  defp positive?(value), do: ordinal?(value) and value > 0

  defp text?(value),
    do:
      is_binary(value) and byte_size(value) in 1..32_768 and String.valid?(value) and
        String.trim(value) != ""

  defp identifier?(value, pattern),
    do:
      is_binary(value) and byte_size(value) in 1..256 and String.valid?(value) and
        Regex.match?(pattern, value)

  defp timestamp?(value) when is_binary(value) and byte_size(value) <= 32 do
    case DateTime.from_iso8601(value) do
      {:ok, %{microsecond: {_, 6}}, 0} -> String.ends_with?(value, "Z")
      _ -> false
    end
  end

  defp timestamp?(_), do: false
end
