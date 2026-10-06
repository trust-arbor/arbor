defmodule Arbor.Orchestrator.Handlers.LlmHandlerRequiredPolicySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.LLM.{Client, ContentPart, Response, StreamEvent}
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Handlers.LlmHandler

  defmodule Adapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "sensitivity_local"
    def complete_single_attempt(request, opts), do: complete(request, opts)

    def complete_streaming_single_attempt(request, callback, opts),
      do: complete_streaming(request, callback, opts)

    def complete(request, opts) do
      record(request, opts)

      if Application.get_env(:arbor_orchestrator, :_policy_retry, false) and
           request.provider == "sensitivity_local" and request.model == "safe" do
        {:error, :timeout}
      else
        {:ok, response()}
      end
    end

    def complete_streaming(request, _callback, opts), do: complete(request, opts)

    def stream(request, opts) do
      record(request, opts)

      if Application.get_env(:arbor_orchestrator, :_policy_retry, false) and
           request.provider == "sensitivity_local" and request.model == "safe" do
        {:error, :timeout}
      else
        {:ok,
         [
           %StreamEvent{type: :delta, data: %{"text" => "fixture reply"}},
           %StreamEvent{type: :finish, data: %{"finish_reason" => "stop"}}
         ]}
      end
    end

    defp record(request, opts) do
      send(
        Application.fetch_env!(:arbor_orchestrator, :_policy_observer),
        {:transport_called, request.provider, request.model, opts}
      )
    end

    defp response do
      %Response{
        text: "fixture reply",
        content_parts: [ContentPart.text("fixture reply")],
        finish_reason: :stop
      }
    end
  end

  defmodule FaultPolicy do
    def sensitivity_routing_decision(_, _, _, _) do
      case Application.fetch_env!(:arbor_orchestrator, :_policy_fault) do
        :raise -> raise "private policy failure"
        :exit -> exit(:private_policy_failure)
        :throw -> throw(:private_policy_failure)
        :malformed -> :invalid_decision
      end
    end
  end

  defmodule NativeDispatcher do
    @behaviour Arbor.LLM.Dispatcher
    def dispatch(_request, opts) do
      provider = Application.fetch_env!(:arbor_orchestrator, :_native_provider)
      route = %{provider: provider, destination: provider, model: "safe", runtime: "acp"}

      admission =
        case Keyword.get(opts, :route_authorizer) do
          nil -> :allow
          callback -> callback.(route)
        end

      with :allow <- admission do
        send(
          Application.fetch_env!(:arbor_orchestrator, :_policy_observer),
          {:native_called, route}
        )

        {:ok, %Response{text: "native reply", finish_reason: :stop}}
      end
    end
  end

  setup do
    settings = [
      {:arbor_orchestrator, :_policy_observer, self()},
      {:arbor_orchestrator, :_policy_retry, false},
      {:arbor_orchestrator, :_native_provider, "sensitivity_remote"},
      {:arbor_orchestrator, :sensitivity_routing_module, Arbor.AI},
      {:arbor_orchestrator, :llm_dispatcher, Arbor.AI.Runtime.Dispatch},
      {:arbor_orchestrator, :llm_provider_availability, fn _ -> true end},
      {:arbor_orchestrator, :llm_provider_fallbacks, %{}},
      {:arbor_orchestrator, :llm_fallback_providers, []},
      {:arbor_ai, :sensitivity_routing_overrides, %{"agent_sensitivity_probe" => :block}},
      {:arbor_ai, :backend_capabilities,
       %{
         sensitivity_local: %{
           default: [:public],
           models: %{
             "safe" => [:public, :confidential],
             "safe-fallback" => [:public, :confidential]
           }
         },
         sensitivity_remote: [:public]
       }},
      {:arbor_ai, :backend_trust_levels, %{}},
      {:arbor_security, :egress_gate_enforcing, true}
    ]

    previous =
      Enum.map(settings, fn {app, key, _} -> {app, key, Application.fetch_env(app, key)} end)

    Enum.each(settings, fn {app, key, value} -> Application.put_env(app, key, value) end)

    on_exit(fn ->
      for {app, key, value} <- previous do
        case value do
          {:ok, configured} -> Application.put_env(app, key, configured)
          :error -> Application.delete_env(app, key)
        end
      end

      Application.delete_env(:arbor_orchestrator, :_policy_fault)
    end)

    :ok
  end

  test "security regression: failed actual egress classification refuses before transport" do
    Application.put_env(:arbor_ai, :backend_trust_levels, :malformed_policy)
    assert_refused(execute(:ordinary))
  end

  test "security regression: failed actual sensitivity policy refuses before transport" do
    Application.put_env(:arbor_ai, :backend_capabilities, :malformed_policy)
    assert_refused(execute(:direct))
  end

  for fault <- [:raise, :exit, :throw, :malformed] do
    @fault fault
    test "security regression: required sensitivity policy #{@fault} refuses before transport" do
      Application.put_env(:arbor_orchestrator, :sensitivity_routing_module, FaultPolicy)
      Application.put_env(:arbor_orchestrator, :_policy_fault, @fault)
      assert_refused(execute(:direct))
    end
  end

  test "security regression: missing required sensitivity facade refuses before transport" do
    Application.put_env(
      :arbor_orchestrator,
      :sensitivity_routing_module,
      __MODULE__.MissingPolicy
    )

    assert_refused(execute(:direct))
  end

  test "security regression: unavailable pinned provider cannot fallback around sensitivity" do
    Application.put_env(:arbor_orchestrator, :llm_provider_fallbacks, %{
      "sensitivity_local" => [{"sensitivity_remote", "safe"}]
    })

    Application.put_env(:arbor_orchestrator, :llm_provider_availability, fn provider ->
      provider == "sensitivity_remote"
    end)

    assert_refused(execute(:direct))
  end

  for mode <- [:direct, :stream, :tools], kind <- [:provider, :model] do
    @mode mode
    @kind kind
    test "security regression: #{@mode} #{@kind} retry fallback rechecks final sensitivity" do
      Application.put_env(:arbor_orchestrator, :_policy_retry, true)

      fallback =
        if @kind == :provider,
          do: %{provider: "sensitivity_remote", model: "safe"},
          else: %{model: "unsafe"}

      outcome = execute(@mode, [fallback])
      assert_received {:transport_called, "sensitivity_local", "safe", _}
      refute_received {:transport_called, "sensitivity_remote", _, _}
      refute_received {:transport_called, _, "unsafe", _}
      assert outcome.status in [:fail, :partial_success], inspect(outcome)
    end
  end

  for mode <- [:direct, :stream, :tools] do
    @mode mode
    test "#{@mode} explicitly permitted model fallback reaches actual transport" do
      Application.put_env(:arbor_orchestrator, :_policy_retry, true)
      outcome = execute(@mode, [%{model: "safe-fallback"}])
      assert outcome.status == :success, inspect(outcome)
      assert_received {:transport_called, "sensitivity_local", "safe", _}
      assert_received {:transport_called, "sensitivity_local", "safe-fallback", opts}
      refute Keyword.has_key?(opts, :__orchestrator_sensitivity_scope__)
    end
  end

  for mode <- [:direct, :stream], field <- [:provider, :model] do
    @mode mode
    @field field
    test "security regression: #{@mode} middleware #{@field} rewrite requires exact transport admission" do
      replacement = if @field == :provider, do: "sensitivity_remote", else: "unsafe"
      middleware = fn request, next -> next.(Map.put(request, @field, replacement)) end
      assert_refused(execute(@mode, [], :confidential, middleware))
    end
  end

  test "security regression: native route also requires final sensitivity permission" do
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, NativeDispatcher)
    assert_refused(execute(:direct))
    refute_received {:native_called, _}
  end

  test "permitted native route preserves the existing Session callback" do
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, NativeDispatcher)
    Application.put_env(:arbor_orchestrator, :_native_provider, "sensitivity_local")
    outcome = execute(:direct)
    assert outcome.status == :success, inspect(outcome)
    assert_received {:native_called, %{provider: "sensitivity_local"}}
    assert_received {:session_admitted, %{provider: "sensitivity_local"}}
  end

  test "security regression: malformed existing route callback cannot become permission" do
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, NativeDispatcher)
    Application.put_env(:arbor_security, :egress_gate_enforcing, false)
    outcome = execute(:ordinary, [], :confidential, nil, route_authorizer: :malformed)
    assert_refused(outcome)
  end

  test "public context preserves ordinary provider fallback" do
    Application.put_env(:arbor_orchestrator, :llm_provider_fallbacks, %{
      "sensitivity_local" => [{"sensitivity_remote", "safe"}]
    })

    Application.put_env(:arbor_orchestrator, :llm_provider_availability, fn provider ->
      provider == "sensitivity_remote"
    end)

    outcome = execute(:direct, [], :public)
    assert outcome.status == :success, inspect(outcome)
    assert_received {:transport_called, "sensitivity_remote", "safe", _}
  end

  defp assert_refused(outcome) do
    refute_received {:transport_called, _, _, _}
    assert outcome.status in [:fail, :partial_success], inspect(outcome)
    assert is_binary(outcome.failure_reason) and outcome.failure_reason != ""
    refute outcome.failure_reason =~ "private policy failure"
  end

  defp execute(
         mode,
         fallbacks \\ [],
         sensitivity \\ :confidential,
         middleware \\ nil,
         extra_opts \\ []
       ) do
    client =
      Client.new(
        adapters: %{"sensitivity_local" => Adapter, "sensitivity_remote" => Adapter},
        default_provider: "sensitivity_local",
        model_catalog: %{},
        middleware: if(middleware, do: [middleware], else: []),
        stream_middleware: if(middleware, do: [middleware], else: [])
      )

    context =
      Context.new(%{
        "session.agent_id" => "agent_sensitivity_probe",
        "session.llm_provider" => "sensitivity_local",
        "session.llm_model" => "safe",
        "session.llm_fallback_chain" => fallbacks,
        "__data_sensitivity__" => sensitivity
      })

    attrs = %{
      "simulate" => "false",
      "prompt" => "private fixture prompt",
      "llm_provider" => "sensitivity_local",
      "llm_model" => "safe"
    }

    attrs = if mode == :tools, do: Map.put(attrs, "use_tools", "true"), else: attrs
    parent = self()

    route = %{
      provider: "sensitivity_local",
      destination: "sensitivity_local",
      model: "safe",
      runtime: "arbor"
    }

    opts = [
      llm_client: client,
      frozen_egress_route: route,
      turn_egress_authorizer: fn exact ->
        send(parent, {:session_admitted, exact})
        :allow
      end
    ]

    opts = if mode == :stream, do: Keyword.put(opts, :on_stream, fn _ -> :ok end), else: opts

    opts =
      if mode == :ordinary,
        do: Keyword.drop(opts, [:turn_egress_authorizer, :frozen_egress_route]),
        else: opts

    opts = Keyword.merge(opts, extra_opts)

    LlmHandler.execute(
      %{id: "required-policy", attrs: attrs},
      context,
      %{attrs: %{"goal" => "fixture"}},
      opts
    )
  end
end
