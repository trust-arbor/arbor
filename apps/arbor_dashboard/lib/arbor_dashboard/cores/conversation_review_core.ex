defmodule Arbor.Dashboard.ConversationReviewCore do
  @moduledoc "Pure, bounded review drafts scoped to one authenticated conversation and exact prompt."
  @empty %{decision: "", note: ""}
  @fields [:command_id, :request_id, :operation_id, :revision, :decision, :note]

  def new, do: %{scope: nil, drafts: %{}}

  def sync(state, scope, prompts, allowed) do
    if allowed and valid_scope?(scope) and is_list(prompts) and length(prompts) <= 50 do
      retained = if state.scope == scope, do: state.drafts, else: %{}

      drafts =
        for prompt <- prompts,
            is_map(prompt) and not is_struct(prompt),
            prompt["protected"] == true and prompt["actionable"] == true,
            prompt["status"] == "pending",
            key = prompt_key(prompt),
            not is_nil(key),
            into: %{} do
          {key, Map.get(retained, key, @empty)}
        end

      %{scope: scope, drafts: drafts}
    else
      new()
    end
  end

  def edit(state, input) when is_map(input) and not is_struct(input) do
    key = input_key(input)

    if Enum.sort(Map.keys(input)) == Enum.sort(@fields) and
         is_map_key(state.drafts, key) and input.decision in ["", "approved", "denied", "rework"] and
         text?(input.note, 4096) do
      {:ok, %{state | drafts: Map.put(state.drafts, key, Map.take(input, [:decision, :note]))}}
    else
      {:error, :invalid_review_draft}
    end
  end

  def edit(_, _), do: {:error, :invalid_review_draft}
  def show(state, prompt), do: Map.get(state.drafts, prompt_key(prompt), @empty)

  defp valid_scope?({subject, target, engagement}),
    do: Enum.all?([subject, target, engagement], &(text?(&1, 256) and byte_size(&1) > 0))

  defp valid_scope?(_), do: false

  defp prompt_key(prompt) when is_map(prompt),
    do:
      selector(
        prompt["command_id"],
        prompt["request_id"],
        prompt["operation_id"],
        prompt["revision"]
      )

  defp prompt_key(_), do: nil

  defp input_key(input),
    do:
      selector(
        Map.get(input, :command_id),
        Map.get(input, :request_id),
        Map.get(input, :operation_id),
        Map.get(input, :revision)
      )

  defp selector(command, request, operation, revision) do
    if identifier?(command, 128) and identifier?(request, 256) and identifier?(operation, 256) and
         is_integer(revision) and revision in 1..2_147_483_647,
       do: {command, request, operation, revision},
       else: nil
  end

  defp identifier?(value, limit),
    do:
      text?(value, limit) and byte_size(value) > 0 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)

  defp text?(value, limit),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= limit
end
