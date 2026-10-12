defmodule Arbor.Orchestrator.Handlers.LlmHandlerAcpPermissionModeSecurityRegressionTest do
  @moduledoc """
  2026-10-11 cross-library review F-002: a DOT attribute
  (`acp_permission_mode="bypass"`) was forwarded unfiltered to the ACP CLI as
  `--permission-mode bypassPermissions`, skipping the ACP permission callback
  and with it every Arbor capability / trust / shell-ceiling decision for every
  tool the CLI ran. Graph text is model-authorable (compose / pipeline.run), so
  attributes may only tighten the CLI's permission posture.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Handlers.LlmHandler

  defmodule RecordingDispatcher do
    @moduledoc false
    @behaviour Arbor.LLM.Dispatcher

    def start do
      case Agent.start(fn -> [] end, name: __MODULE__) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> if Process.alive?(pid), do: Agent.stop(pid), else: :ok
      end
    end

    def calls, do: Agent.get(__MODULE__, & &1) |> Enum.reverse()
    def reset, do: Agent.update(__MODULE__, fn _ -> [] end)

    @impl true
    def dispatch(request, opts) do
      Agent.update(__MODULE__, fn calls -> [{request, opts} | calls] end)

      {:ok,
       %Arbor.LLM.Response{
         text: "from RecordingDispatcher",
         finish_reason: :stop,
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end
  end

  setup do
    {:ok, _} = RecordingDispatcher.start()
    RecordingDispatcher.reset()
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, RecordingDispatcher)

    on_exit(fn ->
      Application.delete_env(:arbor_orchestrator, :llm_dispatcher)
      RecordingDispatcher.stop()
    end)

    :ok
  end

  defp build_node(permission_mode) do
    %{
      id: "acp-perm-node",
      attrs: %{"simulate" => "false", "prompt" => "hi", "acp_permission_mode" => permission_mode}
    }
  end

  defp build_graph, do: %{attrs: %{"goal" => "g"}}

  defp build_context do
    Arbor.Orchestrator.Engine.Context.new(%{
      "session.agent_id" => "agent_acp_perm_#{System.unique_integer([:positive])}",
      "session.llm_provider" => "anthropic",
      "session.llm_model" => "claude-opus-4-6",
      "session.llm_runtime" => :arbor
    })
  end

  for mode <- ["bypass", "bypass_permissions", "auto"] do
    test "security regression (F-002): acp_permission_mode=#{mode} fails the node before dispatch" do
      outcome = LlmHandler.execute(build_node(unquote(mode)), build_context(), build_graph(), [])

      assert RecordingDispatcher.calls() == [],
             "the LLM/ACP runtime must never be reached with a loosened permission mode"

      refute outcome.status == :success
      assert inspect(outcome) =~ "acp_permission_mode_refused"
    end
  end

  test "tightening modes still flow through to the adapter options" do
    outcome = LlmHandler.execute(build_node("default"), build_context(), build_graph(), [])

    assert outcome.status == :success
    assert [{%Arbor.LLM.Request{} = request, _opts}] = RecordingDispatcher.calls()
    assert request.provider_options["acp_adapter_opts"][:permission_mode] == :default
  end

  test "the refused set is exactly the loosening modes" do
    assert Enum.sort(LlmHandler.acp_permission_modes_refused_from_graph()) ==
             Enum.sort([:auto, :bypass, :bypass_permissions])
  end
end
