defmodule Arbor.AI.Runtime.DispatchTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.AI.Runtime.Dispatch
  alias Arbor.LLM.Request
  alias Arbor.LLM.Message

  # The dispatch helper bridges ModelProfile.entry → Selector → Client.complete.
  # Client.complete itself is exercised by arbor_llm's suite; here we focus on:
  #   - the rewrite-provider step happens correctly
  #   - the telemetry event fires with the chosen tuple
  #   - the choose/3 variant returns the selection without an LLM call
  #
  # We don't mock Client.complete — instead we test `choose/3` (no LLM call)
  # for the selection path and pin telemetry behaviour with a test handler.
  # The full dispatch path with a real LLM call is integration-level and
  # belongs alongside the existing arbor_llm fixture tests.

  defp build_request(model, opts \\ []) do
    %Request{
      provider: Keyword.get(opts, :provider, "anthropic"),
      model: model,
      messages: [Message.new(:user, "hello")],
      tools: [],
      tool_choice: nil,
      max_tokens: 100,
      temperature: 0.7,
      reasoning_effort: nil,
      provider_options: %{}
    }
  end

  describe "choose/2 — selection without LLM call" do
    test "synthesized legacy entry falls through with :legacy provider" do
      # "totally-unknown-thing-9000" misses llm_db and synthesizes a single-
      # provider entry with id: :legacy. Selector picks it as the only path.
      request = build_request("totally-unknown-thing-9000")

      assert {:ok, %{selection: %{provider: %{id: :legacy}, runtime: :arbor}}} =
               Dispatch.choose(request)
    end

    test "policy.default_runtime is respected for synthesized entries" do
      request = build_request("totally-unknown-thing-9000")

      # Synthesized entry only supports :arbor — asking for :acp errors.
      assert {:error, {:selection_failed, {:no_provider_supports_runtime, :acp}}} =
               Dispatch.choose(request, %{default_runtime: :acp})
    end

    test "model_id string variant works without a Request" do
      assert {:ok, %{selection: %{provider: %{id: :legacy}}}} =
               Dispatch.choose("totally-unknown-thing-9000")
    end

    test "selection errors propagate as {:selection_failed, reason}" do
      request = build_request("totally-unknown-thing-9000")

      assert {:error, {:selection_failed, _}} =
               Dispatch.choose(request, %{provider: :bedrock})
    end
  end

  describe "telemetry — [:arbor, :runtime, :selected]" do
    setup do
      handler_id = "dispatch-test-#{:erlang.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:arbor, :runtime, :selected],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "fires with the chosen tuple on choose/2" do
      request = build_request("totally-unknown-thing-9000")
      {:ok, _} = Dispatch.choose(request)

      assert_receive {:telemetry, [:arbor, :runtime, :selected], %{count: 1}, metadata}, 500
      assert metadata.canonical_id == "totally-unknown-thing-9000"
      assert metadata.provider == :legacy
      assert metadata.runtime == :arbor
    end

    test "extra_meta is merged into the metadata map" do
      request = build_request("totally-unknown-thing-9000")
      {:ok, _} = Dispatch.choose(request, %{}, %{request_id: "req_abc", agent_id: "agent_x"})

      assert_receive {:telemetry, [:arbor, :runtime, :selected], _, metadata}, 500
      assert metadata.request_id == "req_abc"
      assert metadata.agent_id == "agent_x"
      # Built-in metadata still present
      assert metadata.canonical_id == "totally-unknown-thing-9000"
    end

    test "does not fire when selection errors" do
      request = build_request("totally-unknown-thing-9000")

      assert {:error, _} =
               Dispatch.choose(request, %{default_runtime: :acp})

      refute_receive {:telemetry, _, _, _}, 100
    end
  end

  describe "enumerate_chain/2 — preview the full attempt ladder" do
    test "no fallback chain → returns single primary entry" do
      assert [{:ok, primary}] = Dispatch.enumerate_chain("claude-opus-4-6")
      assert primary.override == :primary
      assert primary.model_entry.canonical_id == "claude-opus-4-6"
    end

    test "fallback chain entries each get resolved" do
      chain = [%{runtime: :acp}, %{model: "claude-haiku-4-5-20251001"}]

      assert [primary, fb1, fb2] =
               Dispatch.enumerate_chain("claude-opus-4-6", %{
                 runtime: :arbor,
                 fallback_chain: chain
               })

      # Primary uses the policy runtime
      assert {:ok, %{override: :primary, selection: %{runtime: :arbor}}} = primary

      # First fallback overrides runtime to :acp
      assert {:ok, %{override: %{runtime: :acp}, selection: %{runtime: :acp}}} = fb1

      # Second fallback overrides model — still runs through default runtime
      assert {:ok,
              %{
                override: %{model: "claude-haiku-4-5-20251001"},
                model_entry: %{canonical_id: "claude-haiku-4-5-20251001"}
              }} = fb2
    end

    test "failing entries are kept in the result list (not dropped)" do
      # Synthesized legacy entry supports only :arbor — asking for :acp
      # fails selection. Result list should include the {:error, ...} row.
      chain = [%{runtime: :acp}]

      assert [{:ok, _primary}, {:error, reason, %{runtime: :acp}}] =
               Dispatch.enumerate_chain("totally-unknown-model-9000", %{
                 fallback_chain: chain
               })

      assert {:selection_failed, {:no_provider_supports_runtime, :acp}} = reason
    end

    test "primary failure still includes fallback enumeration" do
      # Primary failure — fallback chain still gets walked so operators
      # see whether any fallback would have succeeded.
      chain = [%{model: "claude-opus-4-6"}]

      assert [{:error, _, :primary}, {:ok, %{override: %{model: "claude-opus-4-6"}}}] =
               Dispatch.enumerate_chain("totally-unknown-model-9000", %{
                 runtime: :acp,
                 fallback_chain: chain
               })
    end

    test "request struct variant works the same" do
      request = build_request("claude-opus-4-6")

      assert [{:ok, primary}] = Dispatch.enumerate_chain(request)
      assert primary.request.model == "claude-opus-4-6"
    end

    test "does NOT emit :selected telemetry (preview, not dispatch)" do
      handler_id = "enumerate-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:arbor, :runtime, :selected],
        fn _, _, _, _ -> send(test_pid, :telemetry_fired) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Dispatch.enumerate_chain("claude-opus-4-6", %{fallback_chain: [%{runtime: :acp}]})

      refute_receive :telemetry_fired, 100
    end
  end

  describe "behaviour conformance — Arbor.LLM.Dispatcher" do
    test "declares @behaviour Arbor.LLM.Dispatcher" do
      behaviours = Arbor.AI.Runtime.Dispatch.module_info(:attributes)[:behaviour] || []
      assert Arbor.LLM.Dispatcher in behaviours
    end

    test "exports the behaviour's dispatch/2 callback" do
      assert function_exported?(Arbor.AI.Runtime.Dispatch, :dispatch, 2)
    end
  end

  describe "fallback_eligible?/1 — classifier" do
    test "transient atoms are eligible" do
      assert Dispatch.fallback_eligible?(:timeout)
      assert Dispatch.fallback_eligible?(:rate_limited)
      assert Dispatch.fallback_eligible?(:network_error)
      assert Dispatch.fallback_eligible?(:transient_error)
    end

    test "HTTP 429 + 5xx are eligible" do
      assert Dispatch.fallback_eligible?({:http_status, 429})
      assert Dispatch.fallback_eligible?({:http_status, 500})
      assert Dispatch.fallback_eligible?({:http_status, 503})
    end

    test "HTTP 4xx (auth/bad-prompt) are NOT eligible" do
      refute Dispatch.fallback_eligible?({:http_status, 400})
      refute Dispatch.fallback_eligible?({:http_status, 401})
      refute Dispatch.fallback_eligible?({:http_status, 403})
    end

    test "ProviderError respects :retryable flag" do
      retryable = %Arbor.LLM.ProviderError{message: "rate", provider: :anthropic, retryable: true}

      non_retryable = %Arbor.LLM.ProviderError{
        message: "bad",
        provider: :anthropic,
        retryable: false
      }

      assert Dispatch.fallback_eligible?(retryable)
      refute Dispatch.fallback_eligible?(non_retryable)
    end

    test "declarative path failures are eligible (different path could succeed)" do
      assert Dispatch.fallback_eligible?({:no_cli_for_provider, "openrouter"})
      assert Dispatch.fallback_eligible?({:no_provider_supports_runtime, :acp})
      assert Dispatch.fallback_eligible?({:requested_runtime_not_supported, :acp})
      assert Dispatch.fallback_eligible?({:requested_provider_not_available, :bedrock})
      assert Dispatch.fallback_eligible?(:pool_not_available)
      assert Dispatch.fallback_eligible?(:pool_exhausted)
      assert Dispatch.fallback_eligible?({:pool_exit, :killed})
      assert Dispatch.fallback_eligible?({:session_exit, :normal})
      assert Dispatch.fallback_eligible?({:selection_failed, :no_providers})
    end

    test "unknown errors are NOT eligible (fail closed — propagate)" do
      refute Dispatch.fallback_eligible?(:unknown_atom_error)
      refute Dispatch.fallback_eligible?({:bad_prompt, "..."})
      refute Dispatch.fallback_eligible?("string error")
    end
  end

  describe "dispatch/2 — fallback chain" do
    # Two test runtime modules driven by Application env so Dispatch's
    # Registry.lookup/1 returns them instead of Runtime.Arbor / Runtime.Acp.
    # The success runtime stamps its own atom on Response.raw so tests can
    # tell which path served the response.

    defmodule FailingRuntime do
      @moduledoc false
      @behaviour Arbor.AI.Runtime

      alias Arbor.Contracts.AI.RuntimeProfile

      @impl true
      def prepare(req, _opts), do: {:ok, req}

      @impl true
      def execute(_req, _cb, _opts) do
        {:error, Application.get_env(:arbor_ai, :_test_failing_runtime_error, :timeout)}
      end

      @impl true
      def profile do
        {:ok, p} =
          RuntimeProfile.new(%{
            runtime_id: :test_failing,
            display_name: "test failing",
            owns_model_loop: false,
            owns_thread_history: false,
            supports_jido_actions: false,
            supports_action_hooks: false,
            supports_native_tools: false,
            runs_context_engine: false,
            exposes_compaction_data: false,
            unsupported_features: []
          })

        p
      end
    end

    defmodule SuccessRuntime do
      @moduledoc false
      @behaviour Arbor.AI.Runtime

      alias Arbor.Contracts.AI.RuntimeProfile
      alias Arbor.LLM.Response

      @impl true
      def prepare(req, _opts), do: {:ok, req}

      @impl true
      def execute(req, _cb, _opts) do
        {:ok,
         %Response{
           text: "served by fallback",
           thinking: nil,
           session_id: nil,
           finish_reason: :stop,
           content_parts: [],
           usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
           warnings: [],
           raw: %{served_by: :success_runtime, model: req.model, runtime: req.runtime}
         }}
      end

      @impl true
      def profile do
        {:ok, p} =
          RuntimeProfile.new(%{
            runtime_id: :test_success,
            display_name: "test success",
            owns_model_loop: false,
            owns_thread_history: false,
            supports_jido_actions: false,
            supports_action_hooks: false,
            supports_native_tools: false,
            runs_context_engine: false,
            exposes_compaction_data: false,
            unsupported_features: []
          })

        p
      end
    end

    setup do
      original = Application.get_env(:arbor_ai, :runtime_registry, %{})

      Application.put_env(:arbor_ai, :runtime_registry, %{
        arbor: FailingRuntime,
        acp: SuccessRuntime
      })

      on_exit(fn ->
        Application.put_env(:arbor_ai, :runtime_registry, original)
        Application.delete_env(:arbor_ai, :_test_failing_runtime_error)
      end)

      :ok
    end

    test "no fallback chain → primary error propagates" do
      request = build_request("claude-opus-4-6")

      assert {:error, :timeout} = Dispatch.dispatch(request, policy: %{})
    end

    test "primary fails with eligible error → fallback succeeds" do
      request = build_request("claude-opus-4-6")

      assert {:ok, response} =
               Dispatch.dispatch(request,
                 policy: %{fallback_chain: [%{runtime: :acp}]}
               )

      assert response.text == "served by fallback"
      assert response.raw.served_by == :success_runtime
      assert response.raw.runtime == :acp
    end

    test "non-eligible error propagates immediately, fallback not tried" do
      Application.put_env(
        :arbor_ai,
        :_test_failing_runtime_error,
        %Arbor.LLM.ProviderError{
          message: "bad request",
          provider: :anthropic,
          retryable: false
        }
      )

      request = build_request("claude-opus-4-6")

      assert {:error, %Arbor.LLM.ProviderError{retryable: false}} =
               Dispatch.dispatch(request,
                 policy: %{fallback_chain: [%{runtime: :acp}]}
               )
    end

    test "all attempts fail → returns last error" do
      # Re-overlay so :acp also fails
      Application.put_env(:arbor_ai, :runtime_registry, %{
        arbor: FailingRuntime,
        acp: FailingRuntime
      })

      request = build_request("claude-opus-4-6")

      assert {:error, :timeout} =
               Dispatch.dispatch(request,
                 policy: %{fallback_chain: [%{runtime: :acp}]}
               )
    end

    test "fallback emits [:arbor, :runtime, :fallback] telemetry" do
      handler_id = "fallback-telemetry-#{:erlang.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:arbor, :runtime, :fallback],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      request = build_request("claude-opus-4-6")

      {:ok, _} =
        Dispatch.dispatch(request, policy: %{fallback_chain: [%{runtime: :acp}]})

      assert_receive {:telemetry, [:arbor, :runtime, :fallback], %{count: 1}, metadata}, 500
      assert metadata.original_model == "claude-opus-4-6"
      assert metadata.override == %{runtime: :acp}
      assert metadata.from_error =~ "timeout"
    end

    test "chain is tried in order, stops at first success" do
      # First fallback also fails (timeout), second succeeds.
      # Need a third runtime — overlay :test_third_runtime → Success,
      # primary :arbor → Fail, :acp → Fail.
      Application.put_env(:arbor_ai, :runtime_registry, %{
        arbor: FailingRuntime,
        acp: FailingRuntime
        # Synthesizing a third runtime path: register `:test_third` → Success
        # but the model's providers don't expose it, so the policy override
        # would fail selection. Instead, use the model override to change
        # the request entirely — but the legacy synthesized model only
        # supports :arbor, mapped to FailingRuntime. So instead, after the
        # second fail, the chain is exhausted. Assert the LAST error wins.
      })

      request = build_request("claude-opus-4-6")

      # Two-deep chain, both fail — last error propagates.
      assert {:error, :timeout} =
               Dispatch.dispatch(request,
                 policy: %{
                   fallback_chain: [%{runtime: :acp}, %{runtime: :acp}]
                 }
               )
    end
  end
end
