defmodule Arbor.AI.Runtime.AcpTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.AI.Runtime.Acp, as: RuntimeAcp
  alias Arbor.LLM.Request

  describe "profile/0" do
    test "declares ACP's downgrades from arbor baseline" do
      profile = RuntimeAcp.profile()
      assert profile.runtime_id == :acp
      assert profile.display_name =~ "subprocess"

      # The CLI owns the loop and history. Arbor mirrors history into
      # its own stores but isn't the canonical owner.
      refute profile.owns_model_loop
      refute profile.owns_thread_history

      # Jido + native tools + hooks + context engine don't compose
      # through the CLI subprocess.
      refute profile.supports_jido_actions
      refute profile.supports_action_hooks
      refute profile.supports_native_tools
      refute profile.runs_context_engine
      refute profile.exposes_compaction_data

      # All of the not-supported features show up in the deny list so
      # supports?/2 fails closed regardless of which side a caller asks.
      assert :jido_actions in profile.unsupported_features
      assert :action_hooks in profile.unsupported_features
      assert :native_tools in profile.unsupported_features
      assert :context_engine in profile.unsupported_features
      assert :compaction_data in profile.unsupported_features
    end
  end

  describe "prepare/2 — CLI resolution" do
    test "anthropic → :claude CLI (success)" do
      request = %Request{provider: "anthropic", model: "claude-opus-4-6"}
      assert {:ok, ^request} = RuntimeAcp.prepare(request, [])
    end

    test "openai → :codex CLI (success)" do
      request = %Request{provider: "openai", model: "gpt-5-nano"}
      assert {:ok, ^request} = RuntimeAcp.prepare(request, [])
    end

    test "google → :gemini CLI (success)" do
      request = %Request{provider: "google", model: "gemini-2.0-flash"}
      assert {:ok, ^request} = RuntimeAcp.prepare(request, [])
    end

    test "google_vertex_anthropic → :claude (cross-cloud route)" do
      request = %Request{provider: "google_vertex_anthropic", model: "claude-opus-4-6"}
      assert {:ok, ^request} = RuntimeAcp.prepare(request, [])
    end

    test "provider with no CLI mapping errors (does not guess)" do
      request = %Request{provider: "openrouter", model: "openai/gpt-5"}
      assert {:error, {:no_cli_for_provider, "openrouter"}} = RuntimeAcp.prepare(request, [])
    end

    test "provider with no CLI mapping (bedrock) errors" do
      request = %Request{provider: "amazon_bedrock", model: "anthropic.claude-3-haiku"}

      assert {:error, {:no_cli_for_provider, "amazon_bedrock"}} =
               RuntimeAcp.prepare(request, [])
    end
  end

  describe "format_response/2 — thinking + session_id surfacing (Phase 3d)" do
    # format_response/2 is private but exercised here by feeding shaped
    # AcpSession.send_message results through a helper. Once Phase 3d
    # migrates Claude.query to use Dispatch, integration tests will
    # cover the full end-to-end path.

    test "extracts sessionId from string-keyed ACP result" do
      shaped = %{
        "text" => "hello",
        "stopReason" => "end_turn",
        "usage" => %{"input_tokens" => 100, "output_tokens" => 50},
        "sessionId" => "sess_001"
      }

      response = call_format(shaped, :claude)
      assert response.session_id == "sess_001"
      assert response.text == "hello"
    end

    test "extracts thinking blocks from string-keyed ACP result" do
      shaped = %{
        "text" => "answer",
        "stopReason" => "end_turn",
        "usage" => %{},
        "thinking" => [
          %{"text" => "I should consider...", "signature" => "sig_abc"},
          %{"text" => "Then I'll respond.", "signature" => nil}
        ]
      }

      response = call_format(shaped, :claude)
      assert is_list(response.thinking)
      assert length(response.thinking) == 2
      [first, second] = response.thinking
      assert first.text == "I should consider..."
      assert first.signature == "sig_abc"
      assert second.signature == nil
    end

    test "thinking is nil when ACP result has no thinking field" do
      shaped = %{"text" => "answer", "stopReason" => "end_turn", "usage" => %{}}
      response = call_format(shaped, :claude)
      assert response.thinking == nil
    end

    test "thinking is nil when empty list" do
      shaped = %{
        "text" => "answer",
        "stopReason" => "end_turn",
        "usage" => %{},
        "thinking" => []
      }

      response = call_format(shaped, :claude)
      assert response.thinking == nil
    end

    test "session_id is nil when ACP result omits sessionId" do
      shaped = %{"text" => "answer", "stopReason" => "end_turn", "usage" => %{}}
      response = call_format(shaped, :claude)
      assert response.session_id == nil
    end

    test "accepts atom-keyed shapes for backwards-compat" do
      shaped = %{text: "x", stop_reason: "end_turn", usage: %{}, session_id: "atom_session"}
      response = call_format(shaped, :claude)
      assert response.session_id == "atom_session"
    end

    defp call_format(result, cli), do: Arbor.AI.Runtime.Acp.format_response(result, cli)
  end

  describe "build_checkout_opts/2 — provider_options plumbing" do
    test "tool_modules from provider_options flows to checkout opts" do
      request = %Request{
        provider: "anthropic",
        model: "claude-opus-4-6",
        provider_options: %{
          "tool_modules" => [Arbor.Actions.File.Read, Arbor.Actions.Shell.Execute]
        }
      }

      checkout_opts = RuntimeAcp.build_checkout_opts(request, [])

      assert Keyword.get(checkout_opts, :tool_modules) == [
               Arbor.Actions.File.Read,
               Arbor.Actions.Shell.Execute
             ]
    end

    test "tool_modules absent from provider_options produces no :tool_modules key" do
      request = %Request{
        provider: "anthropic",
        model: "claude-opus-4-6",
        provider_options: %{}
      }

      checkout_opts = RuntimeAcp.build_checkout_opts(request, [])
      refute Keyword.has_key?(checkout_opts, :tool_modules)
    end

    test "workspace + agent_id + tool_modules all plumb in one pass" do
      request = %Request{
        provider: "anthropic",
        model: "claude-opus-4-6",
        provider_options: %{
          "workspace" => "/tmp/wkspc",
          "agent_id" => "agent_abc",
          "tool_modules" => [Arbor.Actions.File.Read]
        }
      }

      checkout_opts = RuntimeAcp.build_checkout_opts(request, [])
      assert Keyword.get(checkout_opts, :workspace) == "/tmp/wkspc"
      assert Keyword.get(checkout_opts, :agent_id) == "agent_abc"
      assert Keyword.get(checkout_opts, :tool_modules) == [Arbor.Actions.File.Read]
    end
  end

  describe "execute/3 — pool unavailability" do
    test "returns :pool_not_available when AcpPool isn't running" do
      # AcpPool isn't started in the unit test environment. execute/3
      # should soft-fail with :pool_not_available rather than crash.
      request = %Request{
        provider: "anthropic",
        model: "claude-opus-4-6",
        messages: []
      }

      assert {:error, :pool_not_available} = RuntimeAcp.execute(request, %{}, [])
    end
  end
end
