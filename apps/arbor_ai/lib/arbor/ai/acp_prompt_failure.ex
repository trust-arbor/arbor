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
           fetch_claude_sdk_meta(meta),
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

  # ex_mcp restructured adapter `_meta` from a flat dotted key to a nested map:
  #
  #     %{"ex_mcp.claude_sdk" => %{...}}          # <= 1.0.x
  #     %{"ex_mcp" => %{"claude_sdk" => %{...}}}  # 1.3.0
  #
  # Only the SHAPE moved — every attested field (resultSubtype, text, sessionId,
  # totalCostUsd) is still present. Reading only the flat key silently failed
  # attestation, which downgraded a real Claude monthly-spend-limit hit from
  # `:provider_account_exhausted` (a delivery receipt the caller can act on) to
  # `:acp_protocol_failure` (an error the caller retries). Accept both so a
  # mixed-version upgrade window does not reintroduce the same silent downgrade.
  defp fetch_claude_sdk_meta(meta) do
    case Map.fetch(meta, "ex_mcp.claude_sdk") do
      {:ok, flat} when is_map(flat) and not is_struct(flat) ->
        {:ok, flat}

      _ ->
        with {:ok, ex_mcp} when is_map(ex_mcp) and not is_struct(ex_mcp) <-
               Map.fetch(meta, "ex_mcp"),
             {:ok, nested} when is_map(nested) and not is_struct(nested) <-
               Map.fetch(ex_mcp, "claude_sdk") do
          {:ok, nested}
        else
          _ -> :error
        end
    end
  end

  defp zero_claude_usage?(usage) do
    map_size(usage) == length(@claude_usage_keys) and
      Enum.all?(@claude_usage_keys, &(Map.get(usage, &1) === 0))
  end
end
