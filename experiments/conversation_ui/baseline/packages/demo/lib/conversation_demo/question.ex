defmodule ConversationDemo.Question do
  @moduledoc """
  Pure presentation of a bounded, non-security question carried in an
  authoritative assistant transcript entry. It emits ordinary chat text; the
  host remains responsible for admitting and settling that delivery.
  """

  @question_prefix "@conversation-question/v1 "
  @answer_prefix "@conversation-answer/v1 "

  def sync(previous, snapshot) do
    if snapshot.private_cleared do
      nil
    else
      current =
        snapshot.projection["messages"]
        |> Enum.reverse()
        |> Enum.find_value(&decode/1)

      current =
        if current && previous && identity(current) == identity(previous),
          do: Map.merge(current, Map.take(previous, [:selected, :status, :command_id, :error])),
          else: current

      if current do
        delivery =
          snapshot.projection["deliveries"]
          |> Enum.reverse()
          |> Enum.find(fn item ->
            case answer(item["input_text"]) do
              %{"question_id" => id, "revision" => revision, "option_id" => option} ->
                id == current.id and revision == current.revision and
                  Enum.any?(current.options, &(&1["id"] == option)) and
                  eligible_answer?(current, item, option, snapshot.projection["messages"])

              _ ->
                false
            end
          end)

        cond do
          delivery ->
            chosen = answer(delivery["input_text"])["option_id"]

            %{
              current
              | selected: chosen,
                command_id: delivery["id"],
                error: nil,
                status: delivery_status(delivery["status"])
            }

          snapshot.pending_id && current.status in ["submitting", "uncertain"] ->
            %{current | command_id: snapshot.pending_id, status: "uncertain"}

          current.status in ["submitting", "uncertain"] && is_nil(snapshot.pending_id) ->
            %{current | status: "pending", command_id: nil}

          true ->
            current
        end
      end
    end
  end

  def choose(question, params, allowed) do
    if current?(question, params) && allowed && question.status == "pending" &&
         Enum.any?(question.options, &(&1["id"] == params["option_id"])) do
      %{question | selected: params["option_id"], error: nil}
    else
      question
    end
  end

  def confirm(question, params, allowed) do
    if current?(question, params) && allowed && question.status == "pending" &&
         Enum.any?(question.options, &(&1["id"] == question.selected)) do
      {:ok, %{question | status: "submitting", error: nil}, encode_answer(question)}
    else
      {:error, :question_not_actionable}
    end
  end

  def cycle(nil, _allowed), do: nil

  def cycle(question, allowed) do
    ids = Enum.map(question.options, & &1["id"])
    index = Enum.find_index(ids, &(&1 == question.selected))
    option = Enum.at(ids, if(index, do: rem(index + 1, length(ids)), else: 0))
    choose(question, Map.put(params(question), "option_id", option), allowed)
  end

  def params(nil), do: %{}

  def params(question),
    do: %{
      "question_id" => question.id,
      "revision" => question.revision,
      "source_message_id" => question.source_message_id
    }

  def encode_answer(question) do
    @answer_prefix <>
      "{\"question_id\":" <>
      Jason.encode!(question.id) <>
      ",\"revision\":" <>
      Jason.encode!(question.revision) <>
      ",\"option_id\":" <> Jason.encode!(question.selected) <> "}"
  end

  def encode_question(data), do: @question_prefix <> Jason.encode!(data)

  def decode(%{
        "role" => "assistant",
        "id" => source,
        "text" => @question_prefix <> json,
        "ordinal" => ordinal
      })
      when is_binary(source) and is_integer(ordinal) do
    with true <- byte_size(json) <= 8_192,
         {:ok, data} <- Jason.decode(json),
         true <- exact?(data, ~w(id revision prompt options)),
         true <- identifier?(data["id"]),
         true <- is_integer(data["revision"]) and data["revision"] in 1..1_000_000,
         true <- text?(data["prompt"], 1_000),
         true <- is_list(data["options"]) and length(data["options"]) == 3,
         true <- Enum.all?(data["options"], &option?/1),
         true <- length(Enum.uniq_by(data["options"], & &1["id"])) == 3 do
      %{
        id: data["id"],
        revision: data["revision"],
        prompt: data["prompt"],
        options: data["options"],
        source_message_id: source,
        source_ordinal: ordinal,
        selected: nil,
        status: "pending",
        command_id: nil,
        error: nil
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def decode(_), do: nil

  def answer(@answer_prefix <> json) do
    with true <- byte_size(json) <= 1_024,
         {:ok, data} <- Jason.decode(json),
         true <- exact?(data, ~w(question_id revision option_id)),
         true <- identifier?(data["question_id"]) and identifier?(data["option_id"]),
         true <- is_integer(data["revision"]) and data["revision"] in 1..1_000_000,
         true <-
           @answer_prefix <>
             "{\"question_id\":" <>
             Jason.encode!(data["question_id"]) <>
             ",\"revision\":" <>
             Jason.encode!(data["revision"]) <>
             ",\"option_id\":" <> Jason.encode!(data["option_id"]) <> "}" ==
             @answer_prefix <> json do
      data
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def answer(_), do: nil

  defp delivery_status("completed"), do: "completed"
  defp delivery_status("uncertain"), do: "uncertain"
  defp delivery_status(_), do: "accepted"

  defp eligible_answer?(question, delivery, option, messages) do
    question.command_id == delivery["id"] or
      (question.status == "submitting" and question.selected == option) or
      Enum.any?(messages, fn message ->
        message["role"] == "user" and message["text"] == delivery["input_text"] and
          message["ordinal"] > question.source_ordinal
      end)
  end

  defp current?(nil, _), do: false
  defp current?(_, params) when not is_map(params), do: false

  defp current?(question, params),
    do:
      params["question_id"] == question.id and
        params["source_message_id"] == question.source_message_id and
        params["revision"] in [question.revision, Integer.to_string(question.revision)]

  defp identity(question), do: {question.id, question.revision, question.source_message_id}

  defp option?(option),
    do: exact?(option, ~w(id label)) and identifier?(option["id"]) and text?(option["label"], 200)

  defp exact?(map, keys),
    do: is_map(map) and map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))

  defp identifier?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and
        Regex.match?(~r/\A[A-Za-z0-9._:-]+\z/, value)

  defp text?(value, max),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..max and
        String.trim(value) != ""
end
