defmodule Arbor.AI.AcpPromptFailure do
  @moduledoc false

  @claude_monthly_limit_notice "You've hit your monthly spend limit · raise it at claude.ai/settings/usage?from=cc_cli_limit_message"
  @claude_usage_keys ~w(inputTokens outputTokens cacheReadTokens cacheCreationTokens)

  @type provider_account_exhausted ::
          {:provider_account_exhausted,
           %{
             provider: String.t(),
             http_status: 429,
             provider_session_id: String.t()
           }}

  @type protocol_failure ::
          {:acp_protocol_failure,
           %{
             provider: String.t(),
             reason: :unattested_provider_account_exhaustion
           }}

  @type failure :: provider_account_exhausted() | protocol_failure()

  @spec classify(term()) :: failure() | :none
  def classify(%{"text" => @claude_monthly_limit_notice} = result)
      when not is_struct(result) do
    case classify_attested_claude_exhaustion(result) do
      {:ok, session_id} ->
        {:provider_account_exhausted,
         %{
           provider: "claude",
           http_status: 429,
           provider_session_id: session_id
         }}

      :error ->
        {:acp_protocol_failure,
         %{
           provider: "claude",
           reason: :unattested_provider_account_exhaustion
         }}
    end
  end

  def classify(_result), do: :none

  defp classify_attested_claude_exhaustion(result) do
    with {:ok, text} <- Map.fetch(result, "text"),
         {:ok, "end_turn"} <- Map.fetch(result, "stopReason"),
         {:ok, usage} when is_map(usage) and not is_struct(usage) <-
           Map.fetch(result, "usage"),
         true <- zero_claude_usage?(usage),
         {:ok, meta} when is_map(meta) and not is_struct(meta) <-
           Map.fetch(result, "_meta"),
         {:ok, claude_meta} when is_map(claude_meta) and not is_struct(claude_meta) <-
           Map.fetch(meta, "ex_mcp.claude_sdk"),
         {:ok, "success"} <- Map.fetch(claude_meta, "resultSubtype"),
         {:ok, ^text} <- Map.fetch(claude_meta, "text"),
         {:ok, session_id} when is_binary(session_id) and session_id != "" <-
           Map.fetch(claude_meta, "sessionId"),
         true <- byte_size(session_id) <= 256 and String.valid?(session_id),
         {:ok, total_cost} when total_cost in [0, 0.0] <-
           Map.fetch(claude_meta, "totalCostUsd"),
         false <- Map.has_key?(claude_meta, "authError") do
      {:ok, session_id}
    else
      _ -> :error
    end
  end

  defp zero_claude_usage?(usage) do
    map_size(usage) == length(@claude_usage_keys) and
      Enum.all?(@claude_usage_keys, &(Map.get(usage, &1) === 0))
  end
end
