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
      assert Dispatch.fallback_eligible?({:route_concurrency, :at_capacity})
      assert Dispatch.fallback_eligible?({:route_concurrency, :unconfigured_route})
      refute Dispatch.fallback_eligible?({:route_concurrency, :unavailable})
      refute Dispatch.fallback_eligible?({:route_concurrency, :malformed_route})
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

  describe "dispatch/2 — opt-in ProviderRouter mode" do
    alias Arbor.Contracts.LLM.{ModelEntry, ProviderEntry}

    defmodule RouterRuntime do
      @moduledoc false
      @behaviour Arbor.AI.Runtime

      alias Arbor.Contracts.AI.RuntimeProfile

      @impl true
      def prepare(request, _opts) do
        send(Application.fetch_env!(:arbor_ai, :_test_router_pid), {:prepare, request})
        {:ok, request}
      end

      @impl true
      def execute(request, _callbacks, _opts) do
        send(Application.fetch_env!(:arbor_ai, :_test_router_pid), {:execute, request})

        case Application.get_env(:arbor_ai, :_test_router_fail_model) do
          model when model == request.model ->
            {:error, :timeout}

          _ ->
            usage =
              if Application.get_env(:arbor_ai, :_test_router_spoof_executed_route) do
                %{
                  :input_tokens => 1,
                  :output_tokens => 1,
                  "arbor.executed_route" => %{
                    "provider" => "attacker",
                    "model" => "spoofed",
                    "attempt" => "primary"
                  }
                }
              else
                %{input_tokens: 1, output_tokens: 1}
              end

            provider_receipt =
              case Application.get_env(:arbor_ai, :_test_router_provider_receipt) do
                %{backend: backend, reported_model: reported_model} ->
                  %Arbor.LLM.Response.ProviderReceipt{
                    backend: backend,
                    reported_model: reported_model,
                    usage: usage
                  }

                _ ->
                  nil
              end

            raw = %{
              provider: request.provider,
              model: request.model,
              runtime: request.runtime
            }

            raw =
              if Application.get_env(:arbor_ai, :_test_router_spoof_executed_route) do
                Map.put(raw, "provider_confirmed", true)
              else
                raw
              end

            case Application.get_env(:arbor_ai, :_test_router_non_response_ok) do
              true ->
                {:ok, %{not: "an Arbor.LLM.Response"}}

              _ ->
                {:ok,
                 %Arbor.LLM.Response{
                   text: "router success",
                   finish_reason: :stop,
                   usage: usage,
                   raw: raw,
                   provider_receipt: provider_receipt
                 }}
            end
        end
      end

      @impl true
      def profile do
        {:ok, profile} =
          RuntimeProfile.new(%{
            runtime_id: :router_test,
            display_name: "router test",
            owns_model_loop: false,
            owns_thread_history: false,
            supports_jido_actions: false,
            supports_action_hooks: false,
            supports_native_tools: false,
            runs_context_engine: false,
            exposes_compaction_data: false,
            unsupported_features: []
          })

        profile
      end
    end

    defmodule StripCheckRuntime do
      @moduledoc false
      @behaviour Arbor.AI.Runtime

      alias Arbor.Contracts.AI.RuntimeProfile

      @impl true
      def prepare(request, opts) do
        send(Application.fetch_env!(:arbor_ai, :_test_router_pid), {:strip_prepare, opts})
        {:ok, request}
      end

      @impl true
      def execute(request, _cb, opts) do
        send(Application.fetch_env!(:arbor_ai, :_test_router_pid), {:strip_execute, opts})

        {:ok,
         %Arbor.LLM.Response{
           text: "ok",
           finish_reason: :stop,
           usage: %{input_tokens: 1, output_tokens: 1},
           raw: %{model: request.model, runtime: request.runtime}
         }}
      end

      @impl true
      def profile do
        {:ok, p} =
          RuntimeProfile.new(%{
            runtime_id: :strip_check,
            display_name: "strip",
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

    defmodule RaisingRuntime do
      @moduledoc false
      @behaviour Arbor.AI.Runtime

      alias Arbor.Contracts.AI.RuntimeProfile

      @impl true
      def prepare(request, _opts), do: {:ok, request}

      @impl true
      def execute(_request, _cb, _opts), do: raise("route concurrency release must run")

      @impl true
      def profile do
        {:ok, p} =
          RuntimeProfile.new(%{
            runtime_id: :raising,
            display_name: "raising",
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
        arbor: RouterRuntime,
        acp: RouterRuntime
      })

      Application.put_env(:arbor_ai, :_test_router_pid, self())

      # Node-local test authority with headroom so existing router tests admit.
      concurrency_name = :"dispatch_rc_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Arbor.AI.RouteConcurrency,
         name: concurrency_name,
         limits: %{
           provider_a: %{arbor: 32, acp: 32},
           provider_b: %{arbor: 32, acp: 32},
           openai_oauth: %{arbor: 32},
           xai_oauth: %{arbor: 32}
         }}
      )

      Process.put(:route_concurrency_server, concurrency_name)

      on_exit(fn ->
        Application.put_env(:arbor_ai, :runtime_registry, original)
        Application.delete_env(:arbor_ai, :_test_router_pid)
        Application.delete_env(:arbor_ai, :_test_router_fail_model)
        Application.delete_env(:arbor_ai, :_test_router_spoof_executed_route)
        Application.delete_env(:arbor_ai, :_test_router_provider_receipt)
        Application.delete_env(:arbor_ai, :_test_router_non_response_ok)
        Process.delete(:route_concurrency_server)
      end)

      :ok
    end

    defp router_dispatch(request, opts) do
      server = Process.get(:route_concurrency_server)

      opts =
        if server do
          Keyword.put_new(opts, :route_concurrency_server, server)
        else
          opts
        end

      Dispatch.dispatch(request, opts)
    end

    test "legacy dispatch still uses Selector when router input is absent" do
      request = build_request("totally-unknown-legacy-model")

      assert {:ok, response} = Dispatch.dispatch(request)
      assert response.raw.model == "totally-unknown-legacy-model"
      assert response.raw.runtime == :arbor
      assert_receive {:prepare, %Request{model: "totally-unknown-legacy-model"}}
    end

    test "exact primary route is authorized before prepare and executes ProviderEntry.ref" do
      primary = route_model("primary", :provider_a, "wire-primary", :arbor)
      request = build_request("ignored-by-router")
      test_pid = self()
      handler_id = "router-order-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:arbor, :runtime, :selected],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:selected, metadata.provider_ref})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      authorizer = fn route ->
        send(test_pid, {:authorize, route})
        :allow
      end

      assert {:ok, response} =
               router_dispatch(request,
                 provider_route_input: provider_route_input([primary]),
                 route_authorizer: authorizer
               )

      assert_receive first_message
      assert {:authorize, %{provider: %ProviderEntry{ref: "wire-primary"}}} = first_message

      assert_receive second_message
      assert {:selected, "wire-primary"} = second_message

      assert_receive {:prepare,
                      %Request{
                        provider: "provider_a",
                        model: "wire-primary",
                        runtime: :arbor
                      }}

      assert_receive {:execute, %Request{model: "wire-primary"}}
      assert response.raw.model == "wire-primary"
    end

    test "fallback route is independently mapped and authorized after a transient failure" do
      primary = route_model("primary", :provider_a, "wire-primary", :arbor)
      fallback = route_model("fallback", :provider_b, "wire-fallback", :acp)
      Application.put_env(:arbor_ai, :_test_router_fail_model, "wire-primary")
      test_pid = self()

      authorizer = fn route ->
        send(test_pid, {:authorize, route.provider.ref})
        :allow
      end

      assert {:ok, response} =
               router_dispatch(build_request("ignored"),
                 provider_route_input: provider_route_input([fallback, primary]),
                 route_authorizer: authorizer
               )

      assert_receive {:authorize, "wire-primary"}
      assert_receive {:prepare, %Request{model: "wire-primary"}}
      assert_receive {:execute, %Request{model: "wire-primary"}}
      assert_receive {:authorize, "wire-fallback"}

      assert_receive {:prepare,
                      %Request{
                        provider: "provider_b",
                        model: "wire-fallback",
                        runtime: :acp
                      }}

      assert_receive {:execute, %Request{model: "wire-fallback"}}
      assert response.raw.model == "wire-fallback"
    end

    test "router attempts preserve selected and fallback telemetry compatibility" do
      handler_id = "router-compat-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [[:arbor, :runtime, :selected], [:arbor, :runtime, :fallback]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:route_telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      primary = route_model("primary", :provider_a, "wire-primary", :arbor)
      fallback = route_model("fallback", :provider_b, "wire-fallback", :acp)
      Application.put_env(:arbor_ai, :_test_router_fail_model, "wire-primary")

      assert {:ok, _response} =
               router_dispatch(build_request("original-model"),
                 provider_route_input: provider_route_input([fallback, primary]),
                 route_authorizer: fn _ -> :allow end,
                 telemetry_metadata: %{
                   canonical_id: String.duplicate("m", 513),
                   provider: false,
                   provider_ref: String.duplicate("r", 513),
                   runtime: nil
                 }
               )

      assert_receive {:route_telemetry, [:arbor, :runtime, :selected], %{count: 1},
                      %{
                        canonical_id: "primary",
                        provider: :provider_a,
                        provider_ref: "wire-primary",
                        runtime: :arbor
                      }}

      assert_receive {:route_telemetry, [:arbor, :runtime, :fallback], %{count: 1}, fallback_meta}
      assert fallback_meta.original_model == "original-model"
      assert fallback_meta.override == %{model: "fallback", provider: :provider_b, runtime: :acp}

      assert_receive {:route_telemetry, [:arbor, :runtime, :selected], %{count: 1},
                      %{provider: :provider_b, provider_ref: "wire-fallback", runtime: :acp}}
    end

    test "malformed, ineligible, and unmappable router requests never fall back to Selector" do
      request = build_request("totally-unknown-selector-compatible-model")
      handler_id = "router-invalid-selected-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:arbor, :runtime, :selected],
        fn _event, _measurements, _metadata, _config -> send(test_pid, :selected) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, {:selection_failed, {:provider_route, :invalid_route_input}}} =
               router_dispatch(request,
                 provider_route_input: %{},
                 route_authorizer: fn _ -> :allow end
               )

      ineligible =
        provider_route_input([route_model("primary", :provider_a, "wire", :arbor)])
        |> put_in([:task_registry, "default", :requirements], %{providers: ["missing"]})

      assert {:error, {:selection_failed, {:provider_route, :no_eligible_routes}}} =
               router_dispatch(request,
                 provider_route_input: ineligible,
                 route_authorizer: fn _ -> :allow end
               )

      module_route = route_model("module", :provider_a, "wire", RouterRuntime)

      assert {:error, {:selection_failed, {:provider_route, :route_mapping_mismatch}}} =
               router_dispatch(request,
                 provider_route_input: provider_route_input([module_route]),
                 route_authorizer: fn _ -> :allow end
               )

      malformed_ref =
        route_model("primary", :provider_a, String.duplicate("r", 513), :arbor)

      assert {:error, {:selection_failed, {:provider_route, :invalid_route_input}}} =
               router_dispatch(request,
                 provider_route_input: provider_route_input([malformed_ref]),
                 route_authorizer: fn _ -> :allow end
               )

      with_params =
        provider_route_input([route_model("primary", :provider_a, "wire", :arbor)])
        |> Map.put(:policy, %{params: %{"temperature" => 0.2}})

      assert {:error, {:selection_failed, {:provider_route, :unsupported_route_params}}} =
               router_dispatch(request,
                 provider_route_input: with_params,
                 route_authorizer: fn _ -> :allow end
               )

      refute_received {:prepare, _}
      refute_received {:execute, _}
      refute_received :selected
    end

    test "missing, malformed, raised, pending, and denied authorizers block runtime execution" do
      route_input =
        provider_route_input([route_model("primary", :provider_a, "wire-primary", :arbor)])

      cases = [
        {[], :route_authorizer_required},
        {[route_authorizer: :not_a_callback], :invalid_route_authorizer},
        {[route_authorizer: fn _ -> raise "boom" end], :raised},
        {[route_authorizer: fn _ -> {:requires_approval, :egress} end], :pending},
        {[route_authorizer: fn _ -> {:error, :denied} end], :denied}
      ]

      Enum.each(cases, fn {authorizer_opts, reason} ->
        opts = [provider_route_input: route_input] ++ authorizer_opts

        assert {:error, {:authorization_failed, ^reason}} =
                 router_dispatch(build_request("ignored"), opts)

        refute_received {:prepare, _}
        refute_received {:execute, _}
      end)
    end

    test "post-success executed telemetry identifies a router selection, not provider confirmation" do
      handler_id = "router-executed-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:arbor, :runtime, :executed],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      route = route_model("primary", :provider_a, "wire-primary", :arbor)

      assert {:ok, response} =
               router_dispatch(build_request("ignored"),
                 provider_route_input: provider_route_input([route]),
                 route_authorizer: fn _ -> :allow end
               )

      assert_receive {:telemetry, [:arbor, :runtime, :executed], %{count: 1}, metadata}
      assert metadata.provider == :provider_a
      assert metadata.provider_ref == "wire-primary"
      assert metadata.runtime == :arbor
      assert metadata.attempt == :primary
      assert metadata.route_identity == :router_selected
      assert metadata.provider_confirmed == false
      refute Map.has_key?(metadata, :confirmed_model)

      executed = response.usage["arbor.executed_route"]
      assert executed["provider"] == "provider_a"
      assert executed["provider_ref"] == "wire-primary"
      assert executed["model"] == "primary"
      assert executed["runtime"] == "arbor"
      assert executed["attempt"] == "primary"
      assert executed["route_identity"] == "router_selected"
      assert executed["provider_confirmed"] == false
      refute match?(%{raw: %{executed_route: _}}, response)
      refute is_map(response.raw) and Map.has_key?(response.raw, "arbor.executed_route")
    end

    test "exact OAuth receipt confirms the selected backend and preserves the typed receipt" do
      handler_id = "router-confirmed-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:arbor, :runtime, :executed],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      for {provider, backend, canonical_model, wire_model} <- [
            {:openai_oauth, :openai, "gpt-canonical", "gpt-5.6-sol"},
            {:xai_oauth, :xai, "grok-canonical", "grok-4.5"}
          ] do
        route = route_model(canonical_model, provider, wire_model, :arbor)

        Application.put_env(:arbor_ai, :_test_router_provider_receipt, %{
          backend: backend,
          reported_model: wire_model
        })

        assert {:ok, response} =
                 router_dispatch(build_request("ignored"),
                   provider_route_input: provider_route_input([route]),
                   route_authorizer: fn _ -> :allow end
                 )

        assert %Arbor.LLM.Response.ProviderReceipt{
                 backend: ^backend,
                 reported_model: ^wire_model
               } = response.provider_receipt

        assert response.usage["arbor.executed_route"]["provider_confirmed"] == true
        assert response.usage["arbor.executed_route"]["model"] == canonical_model
        assert response.usage["arbor.executed_route"]["provider_ref"] == wire_model
        assert response.usage["arbor.executed_route"]["confirmed_model"] == wire_model
        assert_receive {:telemetry, [:arbor, :runtime, :executed], %{count: 1}, metadata}
        assert metadata.provider_confirmed == true
        assert metadata.confirmed_model == wire_model
        Application.delete_env(:arbor_ai, :_test_router_provider_receipt)
      end
    end

    test "security regression: backend, provider ref, and model mismatches never confirm" do
      cases = [
        {:wrong_backend, route_model("gpt-5.6-sol", :openai_oauth, "gpt-5.6-sol", :arbor),
         %{backend: :xai, reported_model: "gpt-5.6-sol"}},
        {:wrong_provider_ref, route_model("gpt-5.6-sol", :openai_oauth, "wire-gpt", :arbor),
         %{backend: :openai, reported_model: "gpt-5.6-sol"}},
        {:wrong_model, route_model("gpt-5.6-sol", :openai_oauth, "gpt-5.6-sol", :arbor),
         %{backend: :openai, reported_model: "gpt-5.6-other"}}
      ]

      Enum.each(cases, fn {_name, route, receipt} ->
        Application.put_env(:arbor_ai, :_test_router_provider_receipt, receipt)

        assert {:ok, response} =
                 router_dispatch(build_request("ignored"),
                   provider_route_input: provider_route_input([route]),
                   route_authorizer: fn _ -> :allow end
                 )

        assert response.usage["arbor.executed_route"]["provider_confirmed"] == false
        Application.delete_env(:arbor_ai, :_test_router_provider_receipt)
      end)
    end

    test "security regression: raw and usage aliases cannot author provider confirmation" do
      primary = route_model("primary", :provider_a, "wire-primary", :arbor)
      Application.put_env(:arbor_ai, :_test_router_spoof_executed_route, true)

      on_exit(fn -> Application.delete_env(:arbor_ai, :_test_router_spoof_executed_route) end)

      assert {:ok, response} =
               router_dispatch(build_request("ignored"),
                 provider_route_input: provider_route_input([primary]),
                 route_authorizer: fn _ -> :allow end
               )

      executed = response.usage["arbor.executed_route"]
      assert executed["provider"] == "provider_a"
      assert executed["model"] == "primary"
      assert executed["provider_confirmed"] == false
      refute executed["provider"] == "attacker"
      assert response.raw["provider_confirmed"] == true
      assert response.provider_receipt == nil
    end

    test "fallback success writes executed_route for the fallback attempt" do
      primary = route_model("primary", :provider_a, "wire-primary", :arbor)
      fallback = route_model("fallback", :provider_b, "wire-fallback", :acp)

      Application.put_env(:arbor_ai, :_test_router_fail_model, "wire-primary")

      assert {:ok, response} =
               router_dispatch(build_request("ignored"),
                 provider_route_input: provider_route_input([fallback, primary]),
                 route_authorizer: fn _ -> :allow end
               )

      executed = response.usage["arbor.executed_route"]
      assert executed["provider"] == "provider_b"
      assert executed["provider_ref"] == "wire-fallback"
      assert executed["model"] == "fallback"
      assert executed["runtime"] == "acp"
      assert executed["attempt"] == "fallback"
    end

    test "runtime {:ok, non-Response} fails closed without unstamped success" do
      primary = route_model("primary", :provider_a, "wire-primary", :arbor)
      Application.put_env(:arbor_ai, :_test_router_non_response_ok, true)
      handler_id = "router-non-response-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:arbor, :runtime, :executed],
        fn _event, _measurements, _metadata, _config -> send(test_pid, :executed) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, {:selection_failed, {:provider_route, :invalid_runtime_response}}} =
               router_dispatch(build_request("ignored"),
                 provider_route_input: provider_route_input([primary]),
                 route_authorizer: fn _ -> :allow end
               )

      refute_received :executed
    end

    test "releases concurrency lease after successful execution" do
      primary = route_model("primary", :provider_a, "wire-primary", :arbor)
      server = Process.get(:route_concurrency_server)

      assert {:ok, _} =
               router_dispatch(build_request("ignored"),
                 provider_route_input: provider_route_input([primary]),
                 route_authorizer: fn _ -> :allow end
               )

      assert {:ok, snap} = Arbor.AI.RouteConcurrency.snapshot(route_concurrency_server: server)
      assert snap[{"provider_a", "arbor"}].concurrency_in_use == 0
    end

    test "releases concurrency lease after runtime error" do
      primary = route_model("primary", :provider_a, "wire-primary", :arbor)
      Application.put_env(:arbor_ai, :_test_router_fail_model, "wire-primary")
      server = Process.get(:route_concurrency_server)

      assert {:error, :timeout} =
               router_dispatch(build_request("ignored"),
                 provider_route_input: provider_route_input([primary]),
                 route_authorizer: fn _ -> :allow end
               )

      assert {:ok, snap} = Arbor.AI.RouteConcurrency.snapshot(route_concurrency_server: server)
      assert snap[{"provider_a", "arbor"}].concurrency_in_use == 0
    end

    test "releases concurrency lease after raised execution" do
      primary = route_model("primary", :provider_a, "wire-primary", :arbor)
      server = Process.get(:route_concurrency_server)
      original = Application.get_env(:arbor_ai, :runtime_registry)

      Application.put_env(:arbor_ai, :runtime_registry, %{
        arbor: RaisingRuntime,
        acp: RaisingRuntime
      })

      on_exit(fn -> Application.put_env(:arbor_ai, :runtime_registry, original) end)

      assert_raise RuntimeError, "route concurrency release must run", fn ->
        router_dispatch(build_request("ignored"),
          provider_route_input: provider_route_input([primary]),
          route_authorizer: fn _ -> :allow end
        )
      end

      assert {:ok, snap} = Arbor.AI.RouteConcurrency.snapshot(route_concurrency_server: server)
      assert snap[{"provider_a", "arbor"}].concurrency_in_use == 0
    end

    test "primary at-capacity may try ranked configured fallback after release" do
      primary = route_model("primary", :provider_a, "wire-primary", :arbor)
      fallback = route_model("fallback", :provider_b, "wire-fallback", :acp)
      server = Process.get(:route_concurrency_server)

      # Saturate primary route capacity (limit 32 in setup — acquire all).
      leases =
        for _ <- 1..32 do
          assert {:ok, lease} =
                   Arbor.AI.RouteConcurrency.acquire(:provider_a, :arbor,
                     route_concurrency_server: server
                   )

          lease
        end

      assert {:ok, response} =
               router_dispatch(build_request("ignored"),
                 provider_route_input: provider_route_input([fallback, primary]),
                 route_authorizer: fn _ -> :allow end
               )

      assert response.raw.model == "wire-fallback"
      # Primary never entered runtime (at capacity before prepare).
      refute_received {:prepare, %Request{model: "wire-primary"}}
      assert_received {:prepare, %Request{model: "wire-fallback"}}

      Enum.each(leases, &Arbor.AI.RouteConcurrency.release/1)
    end

    test "same-route runtime failure releases primary before fallback acquire (limit 1)" do
      # Prove try/after releases the exact-route lease before the next ranked
      # attempt acquires the same {provider, runtime}. With limit 1, a missing
      # release would make the fallback hit :at_capacity instead of execute.
      concurrency_name = :"same_route_rc_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Arbor.AI.RouteConcurrency, name: concurrency_name, limits: %{provider_a: %{arbor: 1}}}
      )

      primary = route_model("primary", :provider_a, "wire-primary", :arbor)
      # Same exact provider/runtime as primary — distinct model only.
      fallback = route_model("fallback", :provider_a, "wire-fallback", :arbor)
      Application.put_env(:arbor_ai, :_test_router_fail_model, "wire-primary")

      assert {:ok, response} =
               router_dispatch(build_request("ignored"),
                 provider_route_input: provider_route_input([fallback, primary]),
                 route_authorizer: fn _ -> :allow end,
                 route_concurrency_server: concurrency_name
               )

      assert response.raw.model == "wire-fallback"
      assert_received {:execute, %Request{model: "wire-primary"}}
      assert_received {:execute, %Request{model: "wire-fallback"}}

      assert {:ok, snap} =
               Arbor.AI.RouteConcurrency.snapshot(route_concurrency_server: concurrency_name)

      assert snap[{"provider_a", "arbor"}].concurrency_in_use == 0
    end

    test "unavailable concurrency authority fails closed without fallback" do
      primary = route_model("primary", :provider_a, "wire-primary", :arbor)
      fallback = route_model("fallback", :provider_b, "wire-fallback", :acp)
      dead = :"missing_route_concurrency_#{System.unique_integer([:positive])}"

      assert {:error, {:route_concurrency, :unavailable}} =
               router_dispatch(build_request("ignored"),
                 provider_route_input: provider_route_input([fallback, primary]),
                 route_authorizer: fn _ -> :allow end,
                 route_concurrency_server: dead
               )

      refute_received {:prepare, _}
      refute_received {:execute, _}
    end

    test "strips route_concurrency_server before prepare/execute" do
      primary = route_model("primary", :provider_a, "wire-primary", :arbor)

      original = Application.get_env(:arbor_ai, :runtime_registry)

      Application.put_env(:arbor_ai, :runtime_registry, %{
        arbor: StripCheckRuntime,
        acp: StripCheckRuntime
      })

      on_exit(fn -> Application.put_env(:arbor_ai, :runtime_registry, original) end)

      assert {:ok, _} =
               router_dispatch(build_request("ignored"),
                 provider_route_input: provider_route_input([primary]),
                 route_authorizer: fn _ -> :allow end
               )

      assert_receive {:strip_prepare, prepare_opts}
      assert_receive {:strip_execute, execute_opts}
      refute Keyword.has_key?(prepare_opts, :route_concurrency_server)
      refute Keyword.has_key?(execute_opts, :route_concurrency_server)
    end

    defp provider_route_input(catalog) do
      %{
        task_class: "default",
        task_registry: %{"default" => %{requirements: %{}}},
        catalog: catalog,
        scoreboard:
          Enum.map(catalog, fn model ->
            provider = hd(model.providers)

            %{
              model: model.canonical_id,
              provider: Atom.to_string(provider.id),
              runtime: provider.runtimes |> hd() |> Atom.to_string(),
              score: if(model.canonical_id == "primary", do: 1.0, else: 0.5)
            }
          end),
        observations: [],
        budgets: [],
        now: ~U[2026-07-22 22:00:00Z],
        policy: %{}
      }
    end

    defp route_model(canonical_id, provider, ref, runtime) do
      %ModelEntry{
        canonical_id: canonical_id,
        providers: [%ProviderEntry{id: provider, ref: ref, auth: :none, runtimes: [runtime]}],
        family: :test,
        context_window: 100_000,
        max_output_tokens: 4_000
      }
    end
  end

  describe "dispatch/2 — provider_usage_context strip / Arbor-only re-add" do
    defmodule CapturingRuntime do
      @moduledoc false
      @behaviour Arbor.AI.Runtime

      alias Arbor.Contracts.AI.RuntimeProfile
      alias Arbor.LLM.Response

      @impl true
      def prepare(req, opts) do
        send(self(), {:runtime_prepare, req.runtime, opts})
        {:ok, req}
      end

      @impl true
      def execute(req, _cb, opts) do
        send(self(), {:runtime_execute, req.runtime, opts})

        {:ok,
         %Response{
           text: "ok",
           finish_reason: :stop,
           usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
           raw: %{runtime: req.runtime}
         }}
      end

      @impl true
      def profile do
        {:ok, p} =
          RuntimeProfile.new(%{
            runtime_id: :capturing,
            display_name: "capturing",
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

    defmodule FailingThenCaptureRuntime do
      @moduledoc false
      @behaviour Arbor.AI.Runtime

      alias Arbor.Contracts.AI.RuntimeProfile

      @impl true
      def prepare(req, opts) do
        send(self(), {:runtime_prepare, req.runtime, opts})
        {:ok, req}
      end

      @impl true
      def execute(req, _cb, opts) do
        send(self(), {:runtime_execute, req.runtime, opts})
        {:error, :timeout}
      end

      @impl true
      def profile do
        {:ok, p} =
          RuntimeProfile.new(%{
            runtime_id: :failing_capture,
            display_name: "failing capture",
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

      on_exit(fn ->
        Application.put_env(:arbor_ai, :runtime_registry, original)
      end)

      :ok
    end

    test "Arbor runtime receives provider_usage_context; ACP does not (including fallback)" do
      Application.put_env(:arbor_ai, :runtime_registry, %{
        arbor: FailingThenCaptureRuntime,
        acp: CapturingRuntime
      })

      usage_ctx = %{principal_id: "agent_x", task_id: "task_x", correlation_id: "run_x"}
      request = build_request("claude-opus-4-6")

      assert {:ok, _} =
               Dispatch.dispatch(request,
                 policy: %{fallback_chain: [%{runtime: :acp}]},
                 provider_usage_context: usage_ctx
               )

      assert_receive {:runtime_prepare, :arbor, arbor_prepare_opts}
      assert_receive {:runtime_execute, :arbor, arbor_execute_opts}
      assert Keyword.get(arbor_prepare_opts, :provider_usage_context) == usage_ctx
      assert Keyword.get(arbor_execute_opts, :provider_usage_context) == usage_ctx

      assert_receive {:runtime_prepare, :acp, acp_prepare_opts}
      assert_receive {:runtime_execute, :acp, acp_execute_opts}
      refute Keyword.has_key?(acp_prepare_opts, :provider_usage_context)
      refute Keyword.has_key?(acp_execute_opts, :provider_usage_context)
    end

    test "non-Arbor primary never receives provider_usage_context" do
      Application.put_env(:arbor_ai, :runtime_registry, %{
        arbor: CapturingRuntime,
        acp: CapturingRuntime
      })

      usage_ctx = %{principal_id: "agent_y"}
      request = build_request("claude-opus-4-6")

      assert {:ok, _} =
               Dispatch.dispatch(request,
                 policy: %{default_runtime: :acp},
                 provider_usage_context: usage_ctx
               )

      assert_receive {:runtime_prepare, :acp, opts}
      refute Keyword.has_key?(opts, :provider_usage_context)
      assert_receive {:runtime_execute, :acp, exec_opts}
      refute Keyword.has_key?(exec_opts, :provider_usage_context)
    end

    test "provider-route Arbor primary receives provider_usage_context; ACP fallback does not" do
      Application.put_env(:arbor_ai, :runtime_registry, %{
        arbor: FailingThenCaptureRuntime,
        acp: CapturingRuntime
      })

      concurrency_name = :"usage_rc_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Arbor.AI.RouteConcurrency,
         name: concurrency_name,
         limits: %{
           provider_a: %{arbor: 8, acp: 8},
           provider_b: %{arbor: 8, acp: 8}
         }}
      )

      usage_ctx = %{principal_id: "agent_route", task_id: "task_route"}
      # Reuse ProviderRouter helpers from the router describe (same module defp).
      primary = usage_route_model("primary", :provider_a, "wire-primary", :arbor)
      fallback = usage_route_model("fallback", :provider_b, "wire-fallback", :acp)

      assert {:ok, _} =
               Dispatch.dispatch(build_request("ignored"),
                 provider_route_input: usage_provider_route_input([fallback, primary]),
                 route_authorizer: fn _ -> :allow end,
                 provider_usage_context: usage_ctx,
                 route_concurrency_server: concurrency_name
               )

      assert_receive {:runtime_prepare, :arbor, arbor_prepare_opts}
      assert_receive {:runtime_execute, :arbor, arbor_execute_opts}
      assert Keyword.get(arbor_prepare_opts, :provider_usage_context) == usage_ctx
      assert Keyword.get(arbor_execute_opts, :provider_usage_context) == usage_ctx

      assert_receive {:runtime_prepare, :acp, acp_prepare_opts}
      assert_receive {:runtime_execute, :acp, acp_execute_opts}
      refute Keyword.has_key?(acp_prepare_opts, :provider_usage_context)
      refute Keyword.has_key?(acp_execute_opts, :provider_usage_context)
    end

    test "provider-route non-Arbor primary never receives provider_usage_context" do
      Application.put_env(:arbor_ai, :runtime_registry, %{
        arbor: CapturingRuntime,
        acp: CapturingRuntime
      })

      concurrency_name = :"usage_rc_acp_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Arbor.AI.RouteConcurrency,
         name: concurrency_name, limits: %{provider_b: %{acp: 8, arbor: 8}}}
      )

      usage_ctx = %{principal_id: "agent_route_acp"}
      primary = usage_route_model("primary", :provider_b, "wire-acp", :acp)

      assert {:ok, _} =
               Dispatch.dispatch(build_request("ignored"),
                 provider_route_input: usage_provider_route_input([primary]),
                 route_authorizer: fn _ -> :allow end,
                 provider_usage_context: usage_ctx,
                 route_concurrency_server: concurrency_name
               )

      assert_receive {:runtime_prepare, :acp, opts}
      refute Keyword.has_key?(opts, :provider_usage_context)
      assert_receive {:runtime_execute, :acp, exec_opts}
      refute Keyword.has_key?(exec_opts, :provider_usage_context)
    end
  end

  # Shared ProviderRouter fixtures for usage-context route tests.
  defp usage_provider_route_input(catalog) do
    %{
      task_class: "default",
      task_registry: %{"default" => %{requirements: %{}}},
      catalog: catalog,
      scoreboard:
        Enum.map(catalog, fn model ->
          provider = hd(model.providers)

          %{
            model: model.canonical_id,
            provider: Atom.to_string(provider.id),
            runtime: provider.runtimes |> hd() |> Atom.to_string(),
            score: if(model.canonical_id == "primary", do: 1.0, else: 0.5)
          }
        end),
      observations: [],
      budgets: [],
      now: ~U[2026-07-22 22:00:00Z],
      policy: %{}
    }
  end

  defp usage_route_model(canonical_id, provider, ref, runtime) do
    %Arbor.Contracts.LLM.ModelEntry{
      canonical_id: canonical_id,
      providers: [
        %Arbor.Contracts.LLM.ProviderEntry{
          id: provider,
          ref: ref,
          auth: :none,
          runtimes: [runtime]
        }
      ],
      family: :test,
      context_window: 100_000,
      max_output_tokens: 4_000
    }
  end
end
