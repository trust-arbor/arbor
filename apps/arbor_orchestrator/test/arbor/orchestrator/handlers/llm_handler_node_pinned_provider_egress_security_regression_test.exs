defmodule Arbor.Orchestrator.Handlers.LlmHandlerNodePinnedProviderEgressSecurityRegressionTest do
  @moduledoc """
  2026-10-11 cross-library review F-018: the legacy LlmHandler egress gate
  classified `session.llm_provider` while the request went to the node's own
  `llm_provider` attribute, so a graph could pin a cloud provider over an
  on-host session default and be authorized as `:on_host`.
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
    # Real trust defaults: on-host egress is allowed, an external provider asks.
    # A fresh agent has no standing, so the tier the gate classifies decides.
    prev_enforce = Application.get_env(:arbor_security, :egress_gate_enforcing)
    Application.put_env(:arbor_security, :egress_gate_enforcing, true)

    on_exit(fn ->
      Application.delete_env(:arbor_orchestrator, :llm_dispatcher)
      RecordingDispatcher.stop()

      case prev_enforce do
        nil -> Application.delete_env(:arbor_security, :egress_gate_enforcing)
        v -> Application.put_env(:arbor_security, :egress_gate_enforcing, v)
      end
    end)

    :ok
  end

  defp build_graph, do: %{attrs: %{"goal" => "g"}}

  defp build_context do
    Arbor.Orchestrator.Engine.Context.new(%{
      "session.agent_id" => "agent_pinned_provider_#{System.unique_integer([:positive])}",
      "session.llm_provider" => "lmstudio",
      "session.llm_model" => "local-model",
      "session.llm_runtime" => :arbor
    })
  end

  test "security regression (F-018): a node that pins a cloud provider is gated as external, not as the on-host session default" do
    node = %{
      id: "pinned",
      attrs: %{
        "simulate" => "false",
        "prompt" => "hi",
        "llm_provider" => "anthropic",
        "llm_model" => "claude-opus-4-6"
      }
    }

    outcome = LlmHandler.execute(node, build_context(), build_graph(), [])

    assert RecordingDispatcher.calls() == [], "the cloud provider must not be reached"
    assert outcome.status == :partial_success
    assert outcome.context_updates["egress_blocked"] == true
  end

  test "the on-host session default still proceeds" do
    node = %{id: "local", attrs: %{"simulate" => "false", "prompt" => "hi"}}

    outcome = LlmHandler.execute(node, build_context(), build_graph(), [])

    assert outcome.status == :success
    assert [{%Arbor.LLM.Request{}, _}] = RecordingDispatcher.calls()
  end
end
