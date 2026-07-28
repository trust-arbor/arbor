defmodule Arbor.AI.AcpPromptFailureTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.AI

  @claude_monthly_limit_notice "You've hit your monthly spend limit · raise it at claude.ai/settings/usage?from=cc_cli_limit_message"
  @prompt_id "prompt-spend-limit"
  @provider_session_id "claude-provider-session"

  describe "AcpPromptFailure.classify/1" do
    test "returns :none for ordinary ACP text" do
      assert :none == AI.classify_acp_prompt_failure(%{"text" => "normal assistant output"})
    end

    test "returns protocol failure when Claude spend signal is not provider-attested" do
      {response, stream_text} = claude_reduce_message_result()
      unattested = Map.delete(response, "_meta") |> with_reassembled_text(stream_text)

      assert {:acp_protocol_failure,
              %{provider: "claude", reason: :unattested_provider_account_exhaustion}} =
               AI.classify_acp_prompt_failure(unattested)
    end

    test "returns provider account exhaustion when Claude spend signal is fully attested" do
      {response, stream_text} = claude_reduce_message_result()
      attested = with_reassembled_text(response, stream_text)

      assert {:provider_account_exhausted,
              %{
                provider: "claude",
                http_status: 429,
                provider_session_id: @provider_session_id
              }} = AI.classify_acp_prompt_failure(attested)
    end
  end

  defp with_reassembled_text(result, stream_text) when is_binary(stream_text) do
    existing_text = Map.get(result, "text") || Map.get(result, :text) || ""

    if existing_text == "" do
      Map.put(result, "text", stream_text)
    else
      result
    end
  end

  defp claude_reduce_message_result do
    raw_result = %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => true,
      "terminal_reason" => "api_error",
      "api_error_status" => 429,
      "stop_reason" => "stop_sequence",
      "session_id" => @provider_session_id,
      "total_cost_usd" => 0,
      "usage" => %{
        "input_tokens" => 0,
        "output_tokens" => 0,
        "cache_read_input_tokens" => 0,
        "cache_creation_input_tokens" => 0
      },
      "result" => @claude_monthly_limit_notice
    }

    state = %ExMCP.ACP.Adapters.ClaudeSDK{
      pending_prompt_id: @prompt_id,
      session_id: @provider_session_id
    }

    {messages, [], _state} = ExMCP.ACP.Adapters.ClaudeSDK.Mapper.reduce_message(raw_result, state)

    response =
      messages
      |> Enum.find(fn message -> Map.get(message, "id") == @prompt_id end)
      |> case do
        %{"result" => response} when is_map(response) ->
          response

        _ ->
          flunk("Expected reduce_message to include prompt response for #{@prompt_id}")
      end

    stream_text =
      messages
      |> Enum.find(fn message ->
        get_in(message, ["params", "update", "sessionUpdate"]) == "agent_message_chunk"
      end)
      |> case do
        %{"content" => %{"text" => text}} when is_binary(text) ->
          text

        %{"params" => %{"update" => %{"content" => %{"text" => text}}}} when is_binary(text) ->
          text

        _ ->
          flunk(
            "Expected reduce_message to emit an agent_message_chunk containing streamed content for reassembly"
          )
      end

    {response, stream_text}
  end
end
