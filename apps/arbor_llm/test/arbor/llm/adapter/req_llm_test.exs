defmodule Arbor.LLM.Adapter.ReqLLMTest do
  @moduledoc """
  Unit tests for the generic ReqLLM adapter — the pure translation
  layers (Arbor → ReqLLM and ReqLLM → Arbor) plus error mapping.

  Live HTTP integration tests against actual providers belong in a
  `:llm` or `:integration` tagged file (gated on env-var presence)
  added in a follow-up — Session 3 lands the standalone adapter and
  proves the translation surface; Session 4 wires it into Client
  routing and adds the live coverage.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.ContentPart
  alias Arbor.LLM.Message
  alias Arbor.LLM.Request
  alias Arbor.LLM.Response

  describe "provider/0 + behaviour" do
    test "implements Arbor.LLM.ProviderAdapter" do
      behaviours =
        Adapter.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Arbor.LLM.ProviderAdapter in behaviours
    end

    test "provider/0 returns the sentinel" do
      assert Adapter.provider() == "req_llm_generic"
    end

    test "runtime_contract/0 returns a contract" do
      contract = Adapter.runtime_contract()
      assert contract.provider == "req_llm_generic"
      assert contract.type == :api
      assert contract.capabilities.thinking == true
    end
  end

  describe "build_model_spec/1" do
    test "joins provider and model with a colon" do
      req = %Request{provider: "anthropic", model: "claude-3-5-sonnet"}
      assert {:ok, "anthropic:claude-3-5-sonnet"} = Adapter.build_model_spec(req)
    end

    test "rejects missing provider" do
      req = %Request{provider: nil, model: "foo"}
      assert {:error, {:invalid_request, :missing_provider}} = Adapter.build_model_spec(req)
    end

    test "rejects missing model (empty string is invalid)" do
      req = %Request{provider: "openai", model: nil}
      assert {:error, {:invalid_request, :missing_model}} = Adapter.build_model_spec(req)
    end
  end

  describe "translate_messages/1" do
    test "translates :user role to ReqLLM.Context.user shape" do
      msgs = [Message.new(:user, "hello")]
      [translated] = Adapter.translate_messages(msgs)
      assert translated.role == :user
    end

    test "translates :assistant role" do
      msgs = [Message.new(:assistant, "hi back")]
      [translated] = Adapter.translate_messages(msgs)
      assert translated.role == :assistant
    end

    test "translates :system role" do
      msgs = [Message.new(:system, "you are helpful")]
      [translated] = Adapter.translate_messages(msgs)
      assert translated.role == :system
    end

    test "translates :developer role to :system on the req_llm side" do
      msgs = [Message.new(:developer, "dev instructions")]
      [translated] = Adapter.translate_messages(msgs)
      assert translated.role == :system
    end

    test "translates :tool role with metadata-supplied tool_call_id" do
      msg = %Message{
        role: :tool,
        content: [%{kind: :text, text: "result data"}],
        metadata: %{"tool_call_id" => "call_xyz"}
      }

      [translated] = Adapter.translate_messages([msg])
      assert translated.role == :tool
      assert translated.tool_call_id == "call_xyz"
    end

    test "preserves message order" do
      msgs = [
        Message.new(:system, "S"),
        Message.new(:user, "U1"),
        Message.new(:assistant, "A1"),
        Message.new(:user, "U2")
      ]

      assert [%{role: :system}, %{role: :user}, %{role: :assistant}, %{role: :user}] =
               Adapter.translate_messages(msgs)
    end
  end

  describe "build_req_opts/2" do
    test "forwards temperature, max_tokens, reasoning_effort when set" do
      req = %Request{
        provider: "openai",
        model: "gpt-4",
        temperature: 0.7,
        max_tokens: 1000,
        reasoning_effort: "high"
      }

      opts = Adapter.build_req_opts(req, [])
      assert opts[:temperature] == 0.7
      assert opts[:max_tokens] == 1000
      assert opts[:reasoning_effort] == "high"
    end

    test "omits nil knobs (doesn't force defaults onto req_llm)" do
      req = %Request{provider: "openai", model: "gpt-4"}
      opts = Adapter.build_req_opts(req, [])
      refute Keyword.has_key?(opts, :temperature)
      refute Keyword.has_key?(opts, :max_tokens)
      refute Keyword.has_key?(opts, :reasoning_effort)
    end

    test "request provider_options pass through as keyword list" do
      req = %Request{
        provider: "openai",
        model: "llama-3.2-3b",
        provider_options: %{num_ctx: 8192, repeat_penalty: 1.1}
      }

      opts = Adapter.build_req_opts(req, [])
      provider_opts = Keyword.get(opts, :provider_options)
      assert is_list(provider_opts)
      assert Keyword.get(provider_opts, :num_ctx) == 8192
      assert Keyword.get(provider_opts, :repeat_penalty) == 1.1
    end

    test "caller's base_url opt is forwarded (local-LM override)" do
      req = %Request{provider: "openai", model: "llama-3.2-3b"}
      opts = Adapter.build_req_opts(req, base_url: "http://localhost:11434/v1")
      assert opts[:base_url] == "http://localhost:11434/v1"
    end

    test "caller's provider_options override request's" do
      req = %Request{
        provider: "openai",
        model: "x",
        provider_options: %{num_ctx: 4096}
      }

      opts = Adapter.build_req_opts(req, provider_options: [num_ctx: 16384])
      assert Keyword.get(opts, :provider_options) == [num_ctx: 16384]
    end
  end

  describe "translate_response/2 — without reasoning, without wrapped JSON" do
    test "plain text response → single text part" do
      req = %Request{provider: "anthropic", model: "claude-3-5-sonnet"}
      req_resp = build_req_llm_response("Hello, world!")
      arbor_resp = Adapter.translate_response(req_resp, req)

      assert %Response{
               text: "Hello, world!",
               finish_reason: :stop,
               content_parts: [%{kind: :text, text: "Hello, world!"}]
             } = arbor_resp
    end

    test "finish_reason is mapped through" do
      req = %Request{provider: "openai", model: "gpt-4"}

      for {req_llm_reason, arbor_reason} <- [
            {:stop, :stop},
            {:length, :length},
            {:tool_calls, :tool_calls},
            {:content_filter, :content_filter}
          ] do
        resp = build_req_llm_response("ok", finish_reason: req_llm_reason)
        assert Adapter.translate_response(resp, req).finish_reason == arbor_reason
      end
    end

    test "raw response is preserved in the :raw field" do
      req = %Request{provider: "openai", model: "gpt-4"}
      req_resp = build_req_llm_response("hi")
      arbor_resp = Adapter.translate_response(req_resp, req)
      assert arbor_resp.raw[:req_llm_response] == req_resp
    end
  end

  describe "translate_response/2 — wrapped-JSON envelope via PostProcessors" do
    test "wrapped envelope content is parsed into thinking + text parts" do
      req = %Request{provider: "openai", model: "gpt-oss-heretic"}

      req_resp =
        build_req_llm_response(~s({"thinking":"deciding","output":"the answer"}))

      arbor_resp = Adapter.translate_response(req_resp, req)

      assert Enum.any?(
               arbor_resp.content_parts,
               &(&1.kind == :thinking and &1.text == "deciding")
             )

      assert Enum.any?(
               arbor_resp.content_parts,
               &(&1.kind == :text and &1.text == "the answer")
             )
    end

    test "plain content fall-through still works after PostProcessors" do
      req = %Request{provider: "anthropic", model: "claude-3-5-sonnet"}
      req_resp = build_req_llm_response("just a plain answer")
      arbor_resp = Adapter.translate_response(req_resp, req)
      assert arbor_resp.content_parts == [ContentPart.text("just a plain answer")]
    end
  end

  describe "translate_response/2 — reasoning_details extraction" do
    test "ReqLLM reasoning_details promotes to a thinking part" do
      req = %Request{provider: "anthropic", model: "claude-3-7"}

      reasoning_detail = %ReqLLM.Message.ReasoningDetails{
        text: "Let me work through this.",
        signature: nil,
        encrypted?: false,
        provider: :anthropic,
        format: nil,
        index: 0,
        provider_data: %{}
      }

      msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "The answer is 7."}],
        reasoning_details: [reasoning_detail]
      }

      req_resp = %ReqLLM.Response{
        id: "test",
        model: "claude-3-7",
        context: ReqLLM.Context.new([]),
        message: msg,
        stream?: false,
        stream: nil,
        usage: %{},
        finish_reason: :stop,
        provider_meta: %{},
        error: nil
      }

      arbor_resp = Adapter.translate_response(req_resp, req)

      assert Enum.any?(
               arbor_resp.content_parts,
               &(&1.kind == :thinking and &1.text == "Let me work through this.")
             )
    end
  end

  describe "translate_tools/1 — Session 4 parity" do
    test "returns nil for nil or empty" do
      assert Adapter.translate_tools(nil) == nil
      assert Adapter.translate_tools([]) == nil
    end

    test "translates a single OpenAI-format tool into %ReqLLM.Tool{}" do
      tool = %{
        "type" => "function",
        "function" => %{
          "name" => "get_weather",
          "description" => "Get the current weather",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"location" => %{"type" => "string"}},
            "required" => ["location"]
          }
        }
      }

      [translated] = Adapter.translate_tools([tool])

      assert %ReqLLM.Tool{name: "get_weather", description: "Get the current weather"} =
               translated

      assert is_function(translated.callback, 1)
      assert translated.parameter_schema == tool["function"]["parameters"]
    end

    test "translates multiple tools in order" do
      tools = [
        tool_map("a"),
        tool_map("b"),
        tool_map("c")
      ]

      assert ["a", "b", "c"] = Adapter.translate_tools(tools) |> Enum.map(& &1.name)
    end

    test "drops malformed tool entries rather than crashing" do
      tools = [
        tool_map("good"),
        %{"type" => "function"},
        nil
      ]

      result = Adapter.translate_tools(tools)
      assert is_list(result)
      assert Enum.map(result, & &1.name) == ["good"]
    end

    test "callback is a no-op /1 function (req_llm never auto-invokes it)" do
      [translated] = Adapter.translate_tools([tool_map("x")])
      assert translated.callback.(%{}) == {:ok, %{}}
    end
  end

  describe "build_req_opts/2 — tools wiring" do
    test "request.tools end up as :tools opt with %ReqLLM.Tool{} structs" do
      req = %Request{
        provider: "anthropic",
        model: "claude-3-5",
        tools: [tool_map("search")]
      }

      opts = Adapter.build_req_opts(req, [])
      assert [%ReqLLM.Tool{name: "search"}] = opts[:tools]
    end

    test "request.tool_choice is forwarded when set" do
      req = %Request{
        provider: "openai",
        model: "gpt-4",
        tools: [tool_map("a")],
        tool_choice: "auto"
      }

      opts = Adapter.build_req_opts(req, [])
      assert opts[:tool_choice] == "auto"
    end

    test "empty tools list does not add :tools to opts" do
      req = %Request{provider: "openai", model: "gpt-4", tools: []}
      opts = Adapter.build_req_opts(req, [])
      refute Keyword.has_key?(opts, :tools)
    end
  end

  describe "translate_response/2 — tool_calls extraction" do
    test "promotes message.tool_calls into ContentPart.tool_call parts (before text)" do
      req = %Request{provider: "openai", model: "gpt-4"}

      tool_call = %ReqLLM.ToolCall{
        id: "call_abc",
        type: "function",
        function: %{"name" => "get_weather", "arguments" => %{"location" => "NYC"}}
      }

      msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Let me check."}],
        tool_calls: [tool_call]
      }

      req_resp = %ReqLLM.Response{
        id: "test",
        model: "gpt-4",
        context: ReqLLM.Context.new([]),
        message: msg,
        stream?: false,
        stream: nil,
        usage: %{},
        finish_reason: :tool_calls,
        provider_meta: %{},
        error: nil
      }

      arbor_resp = Adapter.translate_response(req_resp, req)

      assert arbor_resp.finish_reason == :tool_calls

      [first, second] = arbor_resp.content_parts
      assert first.kind == :tool_call
      assert first.id == "call_abc"
      assert first.name == "get_weather"
      assert first.arguments == %{"location" => "NYC"}
      assert second.kind == :text
      assert second.text == "Let me check."
    end

    test "no tool_calls field produces text-only content_parts (no regression)" do
      req = %Request{provider: "openai", model: "gpt-4"}

      msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "hi"}],
        tool_calls: nil
      }

      req_resp = build_req_llm_response_struct(msg)
      arbor_resp = Adapter.translate_response(req_resp, req)
      assert arbor_resp.content_parts == [ContentPart.text("hi")]
    end

    test "empty tool_calls list is treated as no tool calls" do
      req = %Request{provider: "openai", model: "gpt-4"}

      msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "hi"}],
        tool_calls: []
      }

      req_resp = build_req_llm_response_struct(msg)
      arbor_resp = Adapter.translate_response(req_resp, req)
      assert arbor_resp.content_parts == [ContentPart.text("hi")]
    end
  end

  describe "translate_stream_chunk/1 — Session 4 streaming" do
    test "content chunk → :delta event with :text" do
      chunk = %ReqLLM.StreamChunk{type: :content, text: "hello"}

      assert %Arbor.LLM.StreamEvent{type: :delta, data: %{text: "hello"}} =
               Adapter.translate_stream_chunk(chunk)
    end

    test "thinking chunk → :delta with :thinking" do
      chunk = %ReqLLM.StreamChunk{type: :thinking, text: "let me think"}

      assert %Arbor.LLM.StreamEvent{type: :delta, data: %{thinking: "let me think"}} =
               Adapter.translate_stream_chunk(chunk)
    end

    test "tool_call chunk → :tool_call event with name + arguments" do
      chunk = %ReqLLM.StreamChunk{
        type: :tool_call,
        name: "get_weather",
        arguments: %{"location" => "NYC"}
      }

      assert %Arbor.LLM.StreamEvent{
               type: :tool_call,
               data: %{name: "get_weather", arguments: %{"location" => "NYC"}}
             } = Adapter.translate_stream_chunk(chunk)
    end

    test "meta chunk → :step_finish with metadata as data" do
      chunk = %ReqLLM.StreamChunk{type: :meta, metadata: %{finish_reason: :stop}}

      assert %Arbor.LLM.StreamEvent{type: :step_finish, data: %{finish_reason: :stop}} =
               Adapter.translate_stream_chunk(chunk)
    end
  end

  describe "embed/3 — Session 4 input validation" do
    test "requires provider in opts (no inference yet)" do
      assert {:error, {:invalid_request, :missing_provider_for_embedding}} =
               Adapter.embed(["hello"], "voyage-large-2", [])
    end

    test "rejects empty text list" do
      assert {:error, {:invalid_request, :empty_input}} =
               Adapter.embed([], "voyage-large-2", provider: "voyage")
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp tool_map(name) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => "test tool",
        "parameters" => %{"type" => "object", "properties" => %{}}
      }
    }
  end

  defp build_req_llm_response_struct(%ReqLLM.Message{} = msg) do
    %ReqLLM.Response{
      id: "test",
      model: "test-model",
      context: ReqLLM.Context.new([]),
      message: msg,
      stream?: false,
      stream: nil,
      usage: %{},
      finish_reason: :stop,
      provider_meta: %{},
      error: nil
    }
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp build_req_llm_response(text, opts \\ []) do
    msg = %ReqLLM.Message{
      role: :assistant,
      content: [%ReqLLM.Message.ContentPart{type: :text, text: text}],
      reasoning_details: Keyword.get(opts, :reasoning_details)
    }

    %ReqLLM.Response{
      id: Keyword.get(opts, :id, "resp_test"),
      model: Keyword.get(opts, :model, "test-model"),
      context: ReqLLM.Context.new([]),
      message: msg,
      stream?: false,
      stream: nil,
      usage: Keyword.get(opts, :usage, %{}),
      finish_reason: Keyword.get(opts, :finish_reason, :stop),
      provider_meta: %{},
      error: nil
    }
  end
end
