defmodule ConversationKit.Controls do
  @moduledoc """
  Bounded, disposable activity and interaction observations for native hosts.

  Delivery, observed execution, and cancellation remain separate facts. Intents
  describe requests only: the host owns authentication, scope, deadlines, CAS,
  in-flight serialization, and fresh observation before an explicit retry.
  Replacing or projecting this value never requests speech or executes work.
  """

  @activity_keys ~w(command_id delivery_status execution cancellation preview preview_truncated progress)
  @interaction_keys ~w(command_id request_id operation_id revision kind status text choices)
  @delivery ~w(admitted dispatch_started completed uncertain)
  @execution ~w(running queued not_observed)
  @pending_delivery ~w(admitted dispatch_started uncertain)
  @interaction_status ~w(pending responded expired abandoned retired cancelled)
  @progress ~w(pipeline_started pipeline_completed pipeline_failed stage_started stage_completed stage_failed stage_retrying)
  @max_snapshot_bytes 262_144

  def new, do: %{"activities" => [], "interactions" => []}

  @doc "Replace the entire disposable observation with closed, normalized JSON data."
  def replace(_current, snapshot) do
    if valid_snapshot?(snapshot), do: {:ok, snapshot}, else: {:error, :invalid_snapshot}
  end

  @doc "Produce display blocks and current action availability without speech effects."
  def project(snapshot) do
    if valid_snapshot?(snapshot) do
      activities =
        Enum.map(snapshot["activities"], fn activity ->
          activity
          |> Map.put("type", "activity")
          |> Map.put("delivery_text", delivery_text(activity["delivery_status"]))
          |> Map.put("execution_text", execution_text(activity["execution"]))
          |> Map.put("cancellation_text", cancellation_text(activity["cancellation"]["status"]))
          |> Map.put("cancel_actionable", cancellable?(activity))
        end)

      interactions =
        Enum.map(snapshot["interactions"], fn prompt ->
          prompt
          |> Map.put("type", if(prompt["kind"] == "approval", do: "approval", else: "choice"))
          |> Map.put("protected", prompt["kind"] == "approval")
          |> Map.put("actionable", actionable_prompt?(snapshot, prompt))
        end)

      {:ok,
       %{
         "activities" => activities,
         "interactions" => interactions,
         "blocks" => activities ++ interactions,
         "speech" => []
       }}
    else
      {:error, :invalid_snapshot}
    end
  end

  @doc "Validate exact current membership and return intent data, leaving the snapshot unchanged."
  def intent(snapshot, action) do
    if valid_snapshot?(snapshot),
      do: build_intent(snapshot, action),
      else: {:error, :invalid_snapshot}
  end

  defp build_intent(snapshot, %{"kind" => "cancel", "command_id" => id} = action) do
    with true <- exact_keys?(action, ~w(kind command_id)),
         true <- identifier?(id, 128),
         activity when is_map(activity) <- find_activity(snapshot, id),
         true <- cancellable?(activity) do
      {:ok, %{"name" => "conversation.cancel", "input" => %{"command_id" => id}}}
    else
      _ -> {:error, :not_actionable}
    end
  end

  defp build_intent(snapshot, %{"kind" => "choose", "choice_id" => choice_id} = action) do
    with true <-
           exact_keys?(action, ~w(kind command_id request_id operation_id revision choice_id)),
         {:ok, prompt} <- current_prompt(snapshot, action, "choice"),
         true <- Enum.any?(prompt["choices"], &(&1["id"] == choice_id)) do
      {:ok, %{"name" => "interaction.choose", "input" => Map.delete(action, "kind")}}
    else
      _ -> {:error, :not_actionable}
    end
  end

  defp build_intent(
         snapshot,
         %{"kind" => "approve", "decision" => decision, "note" => note} = action
       ) do
    with true <-
           exact_keys?(action, ~w(kind command_id request_id operation_id revision decision note)),
         {:ok, _prompt} <- current_prompt(snapshot, action, "approval"),
         true <- decision in ~w(approved denied rework) and text?(note, 4096) do
      {:ok, %{"name" => "approval.answer", "input" => Map.delete(action, "kind")}}
    else
      _ -> {:error, :not_actionable}
    end
  end

  defp build_intent(_, _), do: {:error, :invalid_action}

  defp current_prompt(snapshot, action, kind) do
    prompt =
      Enum.find(snapshot["interactions"], fn prompt ->
        prompt["kind"] == kind and
          Enum.all?(~w(command_id request_id operation_id revision), &(prompt[&1] == action[&1]))
      end)

    if prompt && actionable_prompt?(snapshot, prompt),
      do: {:ok, prompt},
      else: {:error, :not_actionable}
  end

  defp actionable_prompt?(snapshot, prompt) do
    case find_activity(snapshot, prompt["command_id"]) do
      activity when is_map(activity) -> prompt["status"] == "pending" and cancellable?(activity)
      _ -> false
    end
  end

  defp find_activity(snapshot, id),
    do: Enum.find(snapshot["activities"], &(&1["command_id"] == id))

  defp cancellable?(activity),
    do:
      activity["delivery_status"] in @pending_delivery and
        activity["cancellation"]["status"] == "none"

  defp valid_snapshot?(snapshot) do
    exact_keys?(snapshot, ~w(activities interactions)) and
      bounded_list?(snapshot["activities"], 50) and bounded_list?(snapshot["interactions"], 50) and
      Enum.all?(snapshot["activities"], &valid_activity?/1) and
      Enum.all?(snapshot["interactions"], &valid_interaction?/1) and
      unique?(snapshot["activities"], "command_id") and
      unique?(snapshot["interactions"], "request_id") and
      unique?(snapshot["interactions"], "operation_id") and
      byte_size(JSON.encode!(snapshot)) <= @max_snapshot_bytes
  rescue
    _ -> false
  end

  defp valid_activity?(activity) do
    exact_keys?(activity, @activity_keys) and identifier?(activity["command_id"], 128) and
      activity["delivery_status"] in @delivery and activity["execution"] in @execution and
      exact_keys?(activity["cancellation"], ~w(status)) and
      activity["cancellation"]["status"] in ~w(none requested confirmed) and
      text?(activity["preview"], 32_768) and is_boolean(activity["preview_truncated"]) and
      valid_progress?(activity["progress"])
  end

  defp valid_progress?(nil), do: true

  defp valid_progress?(progress) do
    exact_keys?(progress, ~w(type node_id)) and progress["type"] in @progress and
      (is_nil(progress["node_id"]) or
         identifier?(progress["node_id"], 256, ~r/\A[A-Za-z0-9_.:-]+\z/))
  end

  defp valid_interaction?(prompt) do
    exact_keys?(prompt, @interaction_keys) and identifier?(prompt["command_id"], 128) and
      identifier?(prompt["request_id"], 256) and identifier?(prompt["operation_id"], 256) and
      is_integer(prompt["revision"]) and prompt["revision"] in 1..2_147_483_647 and
      prompt["kind"] in ~w(choice approval) and prompt["status"] in @interaction_status and
      text?(prompt["text"], 4096) and
      valid_choices?(prompt["kind"], prompt["choices"])
  end

  defp valid_choices?("approval", []), do: true

  defp valid_choices?("choice", choices) do
    bounded_list?(choices, 32) and choices != [] and
      Enum.all?(choices, fn choice ->
        exact_keys?(choice, ~w(id label)) and identifier?(choice["id"], 256) and
          text?(choice["label"], 512) and String.trim(choice["label"]) != ""
      end) and unique?(choices, "id")
  end

  defp valid_choices?(_, _), do: false
  defp unique?(values, key), do: length(Enum.uniq_by(values, & &1[key])) == length(values)

  defp exact_keys?(map, keys) when is_map(map) and not is_struct(map),
    do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp exact_keys?(_, _), do: false
  defp bounded_list?([], _remaining), do: true

  defp bounded_list?([_ | tail], remaining) when remaining > 0,
    do: bounded_list?(tail, remaining - 1)

  defp bounded_list?(_, _), do: false

  defp identifier?(value, max, pattern \\ ~r/\A[A-Za-z0-9_-]+\z/),
    do: text?(value, max) and byte_size(value) > 0 and Regex.match?(pattern, value)

  defp text?(value, max),
    do: is_binary(value) and byte_size(value) <= max and String.valid?(value)

  defp delivery_text("admitted"), do: "Delivery admitted"
  defp delivery_text("dispatch_started"), do: "Delivery started; outcome unknown"
  defp delivery_text("completed"), do: "Delivery completed"
  defp delivery_text("uncertain"), do: "Delivery outcome uncertain"
  defp execution_text("running"), do: "Execution observed running"
  defp execution_text("queued"), do: "Execution observed queued"
  defp execution_text("not_observed"), do: "Execution not observed"
  defp cancellation_text("none"), do: "Cancellation not requested"
  defp cancellation_text("requested"), do: "Cancellation requested; termination unconfirmed"
  defp cancellation_text("confirmed"), do: "Cancellation confirmed"
end
