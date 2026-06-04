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
