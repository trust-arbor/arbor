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

  # async: false — several tests mutate the global
  # `:arbor_orchestrator, :ollama`/`:lm_studio` Application env to verify
  # the hardcoded localhost fallback (CI sets ARBOR_OLLAMA_BASE_URL, which
  # runtime.exs threads into that config key).
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.ContentPart
  alias Arbor.LLM.Message
  alias Arbor.LLM.Request
  alias Arbor.LLM.Response

  # Clear any operator/CI-supplied `:arbor_orchestrator, :ollama` config
  # (set from ARBOR_OLLAMA_BASE_URL via runtime.exs) so a test can assert
  # the hardcoded localhost fallback. Restores the original value on_exit.
  defp clear_orchestrator_ollama_config do
    original = Application.get_env(:arbor_orchestrator, :ollama)
    Application.delete_env(:arbor_orchestrator, :ollama)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:arbor_orchestrator, :ollama)
        v -> Application.put_env(:arbor_orchestrator, :ollama, v)
      end
    end)
  end

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
    test "joins provider and model into a dispatchable spec" do
      req = %Request{provider: "anthropic", model: "claude-3-5-sonnet"}
      # Catalog-known → "provider:model" string (attaches pricing); catalog-miss →
      # a bare dispatchable struct (so fresh models still run). Either way it must
      # target the right provider + model.
      assert {:ok, spec} = Adapter.build_model_spec(req)

      assert spec == "anthropic:claude-3-5-sonnet" or
               match?(%LLMDB.Model{provider: :anthropic, id: "claude-3-5-sonnet"}, spec)
    end

    test "Arbor uses req_llm names directly — 'google' is the gemini provider" do
      # Pre-Session-6.6 Arbor mapped historical "gemini" → ":google".
      # Session 6.6 dropped that aliasing; callers now use the req_llm
      # name "google" directly. The old historical name is no longer
      # recognized.
      req = %Request{provider: "google", model: "gemini-2.0-flash"}
      assert {:ok, "google:gemini-2.0-flash"} = Adapter.build_model_spec(req)

      historical = %Request{provider: "gemini", model: "gemini-2.0-flash"}
      assert {:ok, "gemini:gemini-2.0-flash"} = Adapter.build_model_spec(historical)
      # "gemini" passes through as an unknown provider — req_llm will
      # then return :unknown_provider at dispatch time.
    end

    test "local-LM Arbor providers return an LLMDB.Model struct (bypasses catalog lookup)" do
      # Operator-pulled local models aren't in llm_db's catalog. Passing
      # `"openai:nomic-embed-text"` as a string would fail with
      # `:not_found` before reaching the network. The struct path
      # constructs a minimal Model that req_llm dispatches against the
      # configured base_url.
      assert {:ok, %LLMDB.Model{provider: :openai, id: "llama-3.2-3b", model: "llama-3.2-3b"}} =
               Adapter.build_model_spec(%Request{provider: "lm_studio", model: "llama-3.2-3b"})

      assert {:ok, %LLMDB.Model{provider: :openai, id: "nomic-embed-text"}} =
               Adapter.build_model_spec(%Request{provider: "ollama", model: "nomic-embed-text"})
    end

    test "operator escape hatch — provider+model still produce a dispatchable spec" do
      req = %Request{provider: "amazon_bedrock", model: "claude-via-bedrock"}
      # Passthrough string when catalog-known, dispatchable struct otherwise.
      assert {:ok, spec} = Adapter.build_model_spec(req)

      assert spec == "amazon_bedrock:claude-via-bedrock" or
               match?(%LLMDB.Model{provider: :amazon_bedrock, id: "claude-via-bedrock"}, spec)
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

  describe "default_base_url_for/1 — local LMs" do
    test "lm_studio default points at localhost:1234" do
      assert "http://localhost:1234/v1" = Adapter.default_base_url_for("lm_studio")
    end

    test "ollama default points at localhost:11434 (no operator override)" do
      # `default_base_url_for/1` reads `config :arbor_orchestrator, :ollama`
      # (base_url) and falls back to the hardcoded localhost default when
      # unset. CI sets ARBOR_OLLAMA_BASE_URL → runtime.exs populates that
      # config key with the homelab URL, so we clear it here to assert the
      # *fallback*, then restore on_exit.
      clear_orchestrator_ollama_config()
      assert "http://localhost:11434/v1" = Adapter.default_base_url_for("ollama")
    end

    test "cloud providers return nil (api.openai.com et al stay default)" do
      assert nil == Adapter.default_base_url_for("openai")
      assert nil == Adapter.default_base_url_for("anthropic")
      assert nil == Adapter.default_base_url_for("gemini")
    end

    test "operator-configured base_url wins over hardcoded default" do
      original = Application.get_env(:arbor_orchestrator, :lm_studio)
      Application.put_env(:arbor_orchestrator, :lm_studio, base_url: "http://192.168.1.5:1234/v1")

      try do
        assert "http://192.168.1.5:1234/v1" = Adapter.default_base_url_for("lm_studio")
      after
        case original do
          nil -> Application.delete_env(:arbor_orchestrator, :lm_studio)
          v -> Application.put_env(:arbor_orchestrator, :lm_studio, v)
        end
      end
    end
  end

  describe "build_req_opts/2 — local-LM base_url defaulting" do
    test "lm_studio request gets localhost base_url injected automatically" do
      req = %Request{provider: "lm_studio", model: "llama-3.2-3b"}
      opts = Adapter.build_req_opts(req, [])
      assert opts[:base_url] == "http://localhost:1234/v1"
    end

    test "ollama request gets localhost base_url injected automatically (no operator override)" do
      # See default_base_url_for note above — clear the CI-set override so
      # we assert the hardcoded localhost fallback, not the homelab URL.
      clear_orchestrator_ollama_config()
      req = %Request{provider: "ollama", model: "qwen2.5-coder"}
      opts = Adapter.build_req_opts(req, [])
      assert opts[:base_url] == "http://localhost:11434/v1"
    end

    test "caller-supplied base_url wins over the local-LM default" do
      req = %Request{provider: "ollama", model: "x"}
      opts = Adapter.build_req_opts(req, base_url: "http://10.0.0.5:11434/v1")
      assert opts[:base_url] == "http://10.0.0.5:11434/v1"
    end

    test "cloud provider request gets no base_url injected" do
      req = %Request{provider: "openai", model: "gpt-4o-mini"}
      opts = Adapter.build_req_opts(req, [])
      refute Keyword.has_key?(opts, :base_url)
    end

    test "security regression: production dispatch rejects repaired or widened base_url authorities" do
      request = %Request{
        provider: "lm_studio",
        model: "bounded-model",
        messages: [Message.new(:user, "hello")]
      }

      for endpoint <- [
            "http://host:abc/v1",
            "http://host:/v1",
            "http://[::1]x/v1",
            "http://user@host/v1",
            "http://host:80:90/v1"
          ] do
        assert {:error, {:invalid_base_url, _reason}} =
                 Adapter.complete(request, base_url: endpoint)

        assert {:error, {:invalid_base_url, _reason}} =
                 Adapter.stream(request, base_url: endpoint)

        assert {:error, {:invalid_base_url, _reason}} =
                 Adapter.embed(["hello"], "bounded-embedding",
                   provider: "ollama",
                   base_url: endpoint
                 )
      end
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

    test "translates :assistant with Arbor content parts (text + tool_call) into a message with tool_calls" do
      # Regression: build_assistant_message (the tool-use continuation) emits
      # %{kind: :text}/%{kind: :tool_call} maps. Passing them raw to
      # ReqLLM.Context.assistant raised KeyError :type (text part has no :type).
      content = [
        ContentPart.text("Let me search."),
        ContentPart.tool_call("call_1", "web_search", %{"query" => "x"})
      ]

      [translated] = Adapter.translate_messages([Message.new(:assistant, content)])
      assert translated.role == :assistant
      assert is_list(translated.tool_calls) and length(translated.tool_calls) == 1
    end

    test "translates :tool with STRING content into a ReqLLM content part (no 'expected a map')" do
      # Regression: build_tool_messages produces a STRING; a bare string as
      # ReqLLM message content raised "expected a map, got: <string>".
      msg = %Message{
        role: :tool,
        content: "raw tool result text",
        metadata: %{"tool_call_id" => "c1"}
      }

      [translated] = Adapter.translate_messages([msg])
      assert translated.role == :tool
      assert [%ReqLLM.Message.ContentPart{type: :text}] = translated.content
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
      refute Keyword.has_key?(opts, :receive_timeout)
    end

    test "receive_timeout forwards to req_llm when set on the Request" do
      req = %Request{provider: "openai", model: "gpt-4", receive_timeout: 300_000}
      opts = Adapter.build_req_opts(req, [])
      assert opts[:receive_timeout] == 300_000
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

    test "reasoning text is also exposed on the top-level :reasoning_content field" do
      # For reasoning-tuned models (gemma reasoning, deepseek-r1, openai
      # o-series, etc.), consumers may want direct access to the CoT
      # without walking content_parts. The Response struct exposes it
      # via :reasoning_content alongside the rest of the response fields.

      req = %Request{provider: "openai", model: "lm_studio/gemma-4-e4b-it"}

      reasoning_detail = %ReqLLM.Message.ReasoningDetails{
        text: "Walking through the algorithm step by step...",
        signature: nil,
        encrypted?: false,
        provider: :openai,
        format: nil,
        index: 0,
        provider_data: %{}
      }

      msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "result"}],
        reasoning_details: [reasoning_detail]
      }

      req_resp = %ReqLLM.Response{
        id: "test",
        model: "lm_studio/gemma-4-e4b-it",
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

      assert arbor_resp.reasoning_content =~ "Walking through the algorithm"
      assert arbor_resp.text == "result"
    end

    test "reasoning_content is nil when the provider didn't return any" do
      req = %Request{provider: "anthropic", model: "claude-3-5-sonnet"}
      req_resp = build_req_llm_response("plain response, no CoT")
      arbor_resp = Adapter.translate_response(req_resp, req)
      assert arbor_resp.reasoning_content == nil
    end

    test "regression: :thinking content parts surface as reasoning_content" do
      # Some providers (notably Ollama for kimi-k2.6:cloud and the
      # gemma-thinking variants) put chain-of-thought into the
      # message's CONTENT as `%ReqLLM.Message.ContentPart{type: :thinking}`
      # instead of into the top-level `reasoning_details` field.
      # Pre-fix, `extract_reasoning_text/1` only looked at
      # `reasoning_details` so this path was silently dropped — the
      # reasoning_content came back nil even when the model HAD
      # emitted reasoning. Surfaced 2026-06-05 when the code-review
      # pipeline switched to `kimi-k2.6:cloud` and got an empty
      # response with no clue why.

      req = %Request{provider: "ollama", model: "kimi-k2.6:cloud"}

      msg = %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{
            type: :thinking,
            text: "Let me think about this. The user wants 2+2."
          },
          %ReqLLM.Message.ContentPart{type: :text, text: "4"}
        ],
        reasoning_details: nil
      }

      req_resp = %ReqLLM.Response{
        id: "test",
        model: "ollama/kimi-k2.6:cloud",
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

      assert arbor_resp.text == "4"
      assert arbor_resp.reasoning_content =~ "Let me think about this"
    end

    test "regression: :thinking parts surface even when no :text part exists" do
      # The diagnostic case from the code-review pipeline failure:
      # a reasoning model can emit only thinking and run out of
      # budget before producing a final answer. Without surfacing
      # the thinking as reasoning_content, the caller sees an empty
      # response with NO signal that the model was reasoning.

      req = %Request{provider: "ollama", model: "kimi-k2.6:cloud"}

      msg = %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{
            type: :thinking,
            text: "I need to think very carefully about this complex problem..."
          }
        ],
        reasoning_details: nil
      }

      req_resp = %ReqLLM.Response{
        id: "test",
        model: "ollama/kimi-k2.6:cloud",
        context: ReqLLM.Context.new([]),
        message: msg,
        stream?: false,
        stream: nil,
        usage: %{},
        finish_reason: :length,
        provider_meta: %{},
        error: nil
      }

      arbor_resp = Adapter.translate_response(req_resp, req)

      assert arbor_resp.text == ""
      assert arbor_resp.reasoning_content =~ "think very carefully"
      assert arbor_resp.finish_reason == :length
    end

    test "joins multiple :thinking content parts" do
      req = %Request{provider: "ollama", model: "kimi-k2.6:cloud"}

      msg = %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{type: :thinking, text: "First idea"},
          %ReqLLM.Message.ContentPart{type: :thinking, text: "Second idea"},
          %ReqLLM.Message.ContentPart{type: :text, text: "answer"}
        ],
        reasoning_details: nil
      }

      req_resp = %ReqLLM.Response{
        id: "test",
        model: "ollama/kimi-k2.6:cloud",
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

      assert arbor_resp.reasoning_content == "First idea\nSecond idea"
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

  describe "translate_tool_choice/1" do
    test "OpenAI-spec strings 'auto'/'none'/'required' are dropped" do
      assert Adapter.translate_tool_choice("auto") == nil
      assert Adapter.translate_tool_choice("none") == nil
      assert Adapter.translate_tool_choice("required") == nil
    end

    test "atom forms of the same are dropped" do
      assert Adapter.translate_tool_choice(:auto) == nil
      assert Adapter.translate_tool_choice(:none) == nil
      assert Adapter.translate_tool_choice(:required) == nil
    end

    test "nil / empty string pass through as nil" do
      assert Adapter.translate_tool_choice(nil) == nil
      assert Adapter.translate_tool_choice("") == nil
    end

    test "map-shape pins a specific tool — passed through unchanged" do
      req_llm_form = %{type: "tool", name: "get_weather"}
      assert Adapter.translate_tool_choice(req_llm_form) == req_llm_form

      openai_form = %{"type" => "function", "function" => %{"name" => "get_weather"}}
      assert Adapter.translate_tool_choice(openai_form) == openai_form
    end

    test "unknown shapes default to nil (don't crash req_llm downstream)" do
      assert Adapter.translate_tool_choice(123) == nil
      assert Adapter.translate_tool_choice([]) == nil
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

    test "tool_choice 'auto' is NOT forwarded — providers default to auto when tools present" do
      # Live-traffic bug surfaced 2026-06-02: req_llm's openai provider
      # only handles map-shape tool_choice; the OpenAI-spec string
      # "auto" crashes with BadMapError. Translation drops it.
      req = %Request{
        provider: "openai",
        model: "gpt-4",
        tools: [tool_map("a")],
        tool_choice: "auto"
      }

      opts = Adapter.build_req_opts(req, [])
      refute Keyword.has_key?(opts, :tool_choice)
    end

    test "map-shape tool_choice (pinning a specific tool) is forwarded" do
      req = %Request{
        provider: "openai",
        model: "gpt-4",
        tools: [tool_map("a")],
        tool_choice: %{type: "tool", name: "a"}
      }

      opts = Adapter.build_req_opts(req, [])
      assert opts[:tool_choice] == %{type: "tool", name: "a"}
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

  test "security regression: generic Req complete halts a chunked oversized body early" do
    previous_options = Req.default_options()
    parent = self()
    on_exit(fn -> Req.default_options(previous_options) end)

    Req.default_options(
      adapter: fn request ->
        response = Req.Response.new(status: 200, headers: %{})

        {request, response} =
          Enum.reduce_while(1..10_000, {request, response}, fn index, acc ->
            send(parent, {:req_chunk, index})

            case request.into.({:data, String.duplicate("x", 600)}, acc) do
              {:cont, next} -> {:cont, next}
              {:halt, next} -> {:halt, next}
            end
          end)

        {request, response}
      end
    )

    request = %Request{
      provider: "lm_studio",
      model: "local-model",
      messages: [%Message{role: :user, content: "hello"}]
    }

    assert Adapter.complete(request, max_response_bytes: 1_024) ==
             {:error, {:response_bytes_exceeded, 1_024}}

    assert_receive {:req_chunk, 1}
    assert_receive {:req_chunk, 2}
    refute_receive {:req_chunk, 3}
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
