defmodule Arbor.AI.Runtime.ArborTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.AI.Runtime.Arbor, as: RuntimeArbor

  describe "profile/0" do
    test "declares full Arbor support" do
      profile = RuntimeArbor.profile()
      assert profile.runtime_id == :arbor
      assert profile.display_name =~ "BEAM-native"

      # All eight questions YES for arbor — the runtime that owns
      # everything Arbor-native.
      assert profile.owns_model_loop
      assert profile.owns_thread_history
      assert profile.supports_jido_actions
      assert profile.supports_action_hooks
      assert profile.supports_native_tools
      assert profile.runs_context_engine
      assert profile.exposes_compaction_data
      assert profile.unsupported_features == []
    end
  end

  describe "prepare/2" do
    test "returns the request unchanged (pass-through)" do
      request = %Arbor.LLM.Request{model: "claude-opus-4-6", provider: "anthropic"}
      assert {:ok, ^request} = RuntimeArbor.prepare(request, [])
    end
  end

  describe "execute/3 — streaming callbacks (Phase 4)" do
    # Use a fake adapter to drive controlled stream events through
    # execute/3 and assert the per-event callback dispatch table.

    defmodule FakeStreamAdapter do
      @moduledoc false
      @behaviour Arbor.LLM.ProviderAdapter

      alias Arbor.LLM.StreamEvent

      @impl true
      def provider, do: "fake_stream"

      @impl true
      def complete(_req, _opts) do
        {:ok, %Arbor.LLM.Response{text: "non-streaming", finish_reason: :stop}}
      end

      @impl true
      def stream(_req, _opts) do
        {:ok,
         [
           %StreamEvent{type: :delta, data: %{"text" => "hello "}},
           %StreamEvent{type: :delta, data: %{"text" => "world"}},
           %StreamEvent{type: :tool_call, data: %{"id" => "t1", "name" => "test_tool"}},
           %StreamEvent{type: :finish, data: %{usage: %{input_tokens: 5, output_tokens: 2}}}
         ]}
      end
    end

    defmodule NonStreamAdapter do
      @moduledoc false
      @behaviour Arbor.LLM.ProviderAdapter

      @impl true
      def provider, do: "no_stream"

      @impl true
      def complete(_req, _opts) do
        {:ok, %Arbor.LLM.Response{text: "complete-only", finish_reason: :stop}}
      end

      @impl true
      def stream(_req, _opts), do: {:error, {:stream_not_supported, "no_stream"}}
    end

    setup do
      streaming_client =
        Arbor.LLM.Client.new(
          adapters: %{"fake_stream" => FakeStreamAdapter},
          default_provider: "fake_stream"
        )

      non_streaming_client =
        Arbor.LLM.Client.new(
          adapters: %{"no_stream" => NonStreamAdapter},
          default_provider: "no_stream"
        )

      %{streaming_client: streaming_client, non_streaming_client: non_streaming_client}
    end

    test "no callbacks → routes through Client.complete", %{
      streaming_client: streaming_client
    } do
      request = %Arbor.LLM.Request{provider: "fake_stream", model: "fake-1", messages: []}

      assert {:ok, response} = RuntimeArbor.execute(request, %{}, client: streaming_client)
      assert response.text == "non-streaming"
    end

    test "on_text_delta callback receives each text chunk", %{
      streaming_client: streaming_client
    } do
      pid = self()
      callbacks = %{on_text_delta: fn chunk -> send(pid, {:text, chunk}) end}

      request = %Arbor.LLM.Request{provider: "fake_stream", model: "fake-1", messages: []}

      assert {:ok, response} = RuntimeArbor.execute(request, callbacks, client: streaming_client)
      assert response.text == "hello world"

      assert_receive {:text, "hello "}, 200
      assert_receive {:text, "world"}, 200
    end

    test "on_tool_call callback receives tool_call events", %{
      streaming_client: streaming_client
    } do
      pid = self()

      callbacks = %{
        on_text_delta: fn _ -> :ok end,
        on_tool_call: fn data -> send(pid, {:tool, data}) end
      }

      request = %Arbor.LLM.Request{provider: "fake_stream", model: "fake-1", messages: []}
      assert {:ok, _} = RuntimeArbor.execute(request, callbacks, client: streaming_client)

      assert_receive {:tool, %{"id" => "t1", "name" => "test_tool"}}, 200
    end

    test "on_usage callback receives usage from finish event", %{
      streaming_client: streaming_client
    } do
      pid = self()

      callbacks = %{
        on_text_delta: fn _ -> :ok end,
        on_usage: fn usage -> send(pid, {:usage, usage}) end
      }

      request = %Arbor.LLM.Request{provider: "fake_stream", model: "fake-1", messages: []}
      assert {:ok, _} = RuntimeArbor.execute(request, callbacks, client: streaming_client)

      assert_receive {:usage, %{input_tokens: 5, output_tokens: 2}}, 200
    end

    test "stream_not_supported falls back to Client.complete (best-effort)", %{
      non_streaming_client: non_streaming_client
    } do
      pid = self()
      callbacks = %{on_text_delta: fn _ -> send(pid, :should_not_fire) end}

      request = %Arbor.LLM.Request{provider: "no_stream", model: "fake-2", messages: []}

      assert {:ok, response} =
               RuntimeArbor.execute(request, callbacks, client: non_streaming_client)

      assert response.text == "complete-only"
      refute_receive :should_not_fire, 100
    end

    test "callbacks subset (only one set) still works", %{streaming_client: streaming_client} do
      pid = self()
      callbacks = %{on_text_delta: fn chunk -> send(pid, {:text, chunk}) end}

      request = %Arbor.LLM.Request{provider: "fake_stream", model: "fake-1", messages: []}
      assert {:ok, _} = RuntimeArbor.execute(request, callbacks, client: streaming_client)

      # Only on_text_delta is set — :tool_call and :usage events are
      # silently dispatched-but-dropped, no crash.
      assert_receive {:text, _}, 200
    end
  end
end
