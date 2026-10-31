defmodule Arbor.LLM.Host.TelemetryCompositionSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.AgentTelemetry.Store
  alias Arbor.Contracts.Agent.Telemetry
  alias Arbor.LLM.{Client, Config, ContentPart, Message, Request, Response, ToolLoop}
  alias Arbor.LLM.Host.Telemetry, as: HostTelemetry
  alias Arbor.LLM.TestSupport.SensitivityFixture
  alias Elixir.Config.Reader, as: ConfigReader

  @moduletag :fast
  @moduletag :security_regression
  @controls_key :telemetry_composition_controls
  @tool "host_fixture_tool"

  defmodule ToolAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "llm_host_telemetry_fixture"

    @impl true
    def complete(request, _opts) do
      %{observer: observer} = SensitivityFixture.get_controls(request.provider_options)

      case Enum.find(request.messages, &(&1.role == :tool)) do
        nil ->
          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             raw: %{},
             content_parts: [
               ContentPart.tool_call("host_fixture_call", "host_fixture_tool", %{"value" => 1})
             ]
           }}

        message ->
          send(observer, {:host_tool_continuation, Message.text(message)})
          {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      end
    end
  end

  defmodule Executor do
    def execute("host_fixture_tool", %{"value" => 1}, _cwd, opts) do
      controls = Application.fetch_env!(:arbor_llm_host, :telemetry_composition_controls)
      %{observer: observer} = SensitivityFixture.get_controls(controls)
      send(observer, {:host_tool_effect, Keyword.fetch!(opts, :agent_id)})
      {:ok, "executed"}
    end
  end

  setup do
    # Capture actual Root selection before installing any test collaborator.
    selected = Application.fetch_env!(:arbor_llm, :telemetry_store)
    assert selected == HostTelemetry
    assert Config.telemetry_store() == selected
    assert Application.get_application(selected) == :arbor_llm_host

    previous =
      Map.new([:telemetry_store, :tool_invocation_auditor, :signal_module], fn key ->
        {key, Application.fetch_env(:arbor_llm, key)}
      end)

    previous_controls = Application.fetch_env(:arbor_llm_host, @controls_key)

    {:ok, cleanup} =
      Agent.start(fn -> %{store: nil, supervisor: nil, owned: false, agents: []} end)

    # This unlinked observer outlives the case and its supervised fixture Agent.
    on_exit(fn ->
      try do
        Enum.each(previous, fn {key, value} -> restore(:arbor_llm, key, value) end)
        restore(:arbor_llm_host, @controls_key, previous_controls)
        cleanup_store!(Agent.get(cleanup, & &1))
      after
        Agent.stop(cleanup)
      end
    end)

    assert Arbor.Common.Config.telemetry_persistence_module() == nil
    supervisor = Process.whereis(Arbor.Common.Supervisor)
    assert is_pid(supervisor)
    assert :application.get_application(supervisor) == {:ok, :arbor_kernel_runtime}

    {store, owned} =
      case Process.whereis(Store) do
        nil ->
          {:ok, pid} = Supervisor.start_child(supervisor, {Store, []})
          {pid, true}

        pid ->
          {pid, false}
      end

    Agent.update(cleanup, &%{&1 | store: store, supervisor: supervisor, owned: owned})
    assert_store_owner!(supervisor, store)

    agent = "llm_host_telemetry_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    assert Store.get(agent) == nil
    Agent.update(cleanup, &%{&1 | agents: [agent]})

    # The fake executor has no protected production effect. Audit is disabled
    # explicitly for this telemetry seam; Root's production binding is checked
    # separately below, and real Core audit remains a Security integration gate.
    Application.put_env(:arbor_llm, :tool_invocation_auditor, :disabled)
    Application.put_env(:arbor_llm, :signal_module, nil)
    SensitivityFixture.setup([ToolAdapter])
    controls = SensitivityFixture.put_controls(%{observer: self()})
    Application.put_env(:arbor_llm_host, @controls_key, controls)
    %{agent: agent, controls: controls, store: store}
  end

  test "security regression: Root-selected telemetry records one actual ToolLoop effect in the KR Store",
       ctx do
    production =
      ConfigReader.read!(Path.expand("../../../../../config/config.exs", __DIR__), env: :prod)

    llm_config = Keyword.fetch!(production, :arbor_llm)
    assert Keyword.fetch!(llm_config, :tool_invocation_auditor) == Arbor.Security
    assert Keyword.fetch!(llm_config, :telemetry_store) == HostTelemetry

    assert Application.spec(:arbor_llm_host, :mod) in [nil, []]
    assert Application.spec(:arbor_llm_host, :registered) in [nil, []]
    applications = Application.spec(:arbor_llm_host, :applications)
    runtime_position = Enum.find_index(applications, &(&1 == :arbor_kernel_runtime))
    llm_position = Enum.find_index(applications, &(&1 == :arbor_llm))
    assert is_integer(runtime_position) and is_integer(llm_position)
    assert runtime_position < llm_position
    assert Application.spec(:arbor_llm, :mod) == {Arbor.LLM.Application, []}
    llm_supervisor = Process.whereis(Arbor.LLM.Supervisor)
    assert is_pid(llm_supervisor)
    assert :application.get_application(llm_supervisor) == {:ok, :arbor_llm}

    assert {:ok, %{content: "done"}} = run(ctx)
    assert_receive {:host_tool_effect, agent}
    assert agent == ctx.agent
    refute_receive {:host_tool_effect, _}
    assert_receive {:host_tool_continuation, content}
    assert content =~ "executed"

    assert %Telemetry{agent_id: ^agent, tool_stats: stats, tool_latencies: [_]} = Store.get(agent)
    assert Map.keys(stats) == [@tool]

    assert %{calls: 1, succeeded: 1, failed: 0, gated: 0, total_duration_ms: duration} =
             stats[@tool]

    assert is_integer(duration) and duration >= 0
    assert Process.whereis(Store) == ctx.store
  end

  test "security regression: an absent optional telemetry port does not fabricate an observation",
       ctx do
    Application.put_env(:arbor_llm, :telemetry_store, nil)
    assert Config.telemetry_store() == nil

    assert {:ok, %{content: "done"}} = run(ctx)
    assert_receive {:host_tool_effect, agent}
    assert agent == ctx.agent
    refute_receive {:host_tool_effect, _}
    assert_receive {:host_tool_continuation, content}
    assert content =~ "executed"
    assert Store.get(ctx.agent) == nil
  end

  test "security regression: a nil required auditor refuses the effect while absent telemetry makes no observation",
       ctx do
    Application.put_env(:arbor_llm, :telemetry_store, nil)
    Application.put_env(:arbor_llm, :tool_invocation_auditor, nil)

    assert {:ok, %{content: "done"}} = run(ctx)
    refute_receive {:host_tool_effect, _}
    assert_receive {:host_tool_continuation, content}
    assert content =~ "invocation_audit_unavailable"
    assert Store.get(ctx.agent) == nil
  end

  defp run(ctx) do
    client =
      Client.new(default_provider: ToolAdapter.provider()) |> Client.register_adapter(ToolAdapter)

    request = %Request{
      provider: ToolAdapter.provider(),
      model: "fixture",
      provider_options: ctx.controls,
      messages: [Message.new(:user, "run the synthetic tool")]
    }

    tools = [
      %{
        "type" => "function",
        "function" => %{
          "name" => @tool,
          "description" => "one synthetic effect",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"value" => %{"type" => "integer"}},
            "required" => ["value"]
          }
        }
      }
    ]

    ToolLoop.run(client, request,
      tool_executor: Executor,
      tools: tools,
      max_turns: 3,
      agent_id: ctx.agent,
      workdir: System.tmp_dir!()
    )
  end

  defp assert_store_owner!(supervisor, store) do
    assert Application.get_application(Store) == :arbor_kernel_runtime

    assert {Store, ^store, :worker, [Store]} =
             List.keyfind(Supervisor.which_children(supervisor), Store, 0)

    assert Process.whereis(Store) == store
    assert :application.get_application(store) == {:ok, :arbor_kernel_runtime}
    assert :ets.info(:arbor_agent_telemetry, :owner) == store
  end

  defp cleanup_store!(%{store: nil}), do: :ok

  defp cleanup_store!(%{store: store, supervisor: supervisor, owned: owned, agents: agents}) do
    # A changed/foreign owner is never stopped or reconfigured for this test.
    assert_store_owner!(supervisor, store)
    for agent <- agents, do: assert(:ok == Store.delete(agent))

    if owned do
      assert :ok == Supervisor.terminate_child(supervisor, Store)
      assert :ok == Supervisor.delete_child(supervisor, Store)
      refute Process.alive?(store)
    end
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)
end
