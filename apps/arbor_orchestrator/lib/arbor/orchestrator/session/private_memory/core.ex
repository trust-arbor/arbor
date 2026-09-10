defmodule Arbor.Orchestrator.Session.PrivateMemory.Core do
  @moduledoc false

  @proof_key "private_memory_source"
  @max_rows 1_000

  def proof_key, do: @proof_key

  def proof(nil), do: nil
  def proof(source), do: Map.take(source, ["descriptor", "stamp"])

  # This selects observed complete pairs only. Root authenticity and current
  # same-owner admission are checked by Memory before any text can be embedded.
  def sources(rows, session_id) when is_list(rows) do
    rows
    |> Enum.take(@max_rows)
    |> Enum.reduce(%{}, fn row, grouped ->
      with true <- is_map(row),
           metadata when is_map(metadata) <- Map.get(row, :metadata),
           proof when is_map(proof) <- metadata[@proof_key],
           true <- map_size(proof) == 2 and Enum.sort(Map.keys(proof)) == ["descriptor", "stamp"],
           descriptor when is_map(descriptor) <- proof["descriptor"],
           true <- descriptor["session_id"] == session_id,
           id when is_binary(id) and byte_size(id) in 1..256 <- descriptor["source_id"] do
        Map.update(grouped, id, [row], &[row | &1])
      else
        _ -> grouped
      end
    end)
    |> Enum.sort_by(fn {source_id, _rows} -> source_id end)
    |> Enum.flat_map(fn {_id, pair} -> complete_source(pair) end)
  end

  def sources(_, _), do: []

  defp complete_source([first, second]) do
    pair = Enum.sort_by([first, second], &role/1)

    with [assistant, user] <- pair,
         true <- role(assistant) == "assistant" and role(user) == "user",
         proof <- user.metadata[@proof_key],
         true <- assistant.metadata[@proof_key] === proof,
         true <- user.metadata["engagement_id"] == proof["descriptor"]["engagement_id"],
         true <- assistant.metadata["engagement_id"] == proof["descriptor"]["engagement_id"],
         true <- is_binary(user.content) and is_binary(assistant.content),
         user_ordinal when is_integer(user_ordinal) <- Map.get(user, :entry_ordinal),
         true <- Map.get(assistant, :entry_ordinal) == user_ordinal + 1 do
      [
        Map.merge(proof, %{
          "user_content" => user.content,
          "assistant_content" => assistant.content
        })
      ]
    else
      _ -> []
    end
  end

  defp complete_source(_), do: []
  defp role(%{role: value}) when value in [:user, "user"], do: "user"
  defp role(%{role: value}) when value in [:assistant, "assistant"], do: "assistant"
  defp role(_), do: "invalid"
end
