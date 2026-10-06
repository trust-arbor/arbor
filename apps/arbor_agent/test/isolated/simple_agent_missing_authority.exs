ExUnit.start(autorun: false, seed: 61006)

defmodule Arbor.Agent.SimpleAgentMissingAuthorityProbeTest do
  use ExUnit.Case, async: false
  alias Arbor.Agent.SimpleAgent
  alias Arbor.LLM.{Client, ContentPart, Response}

  defmodule Probe do
    use Jido.Action,
      name: "missing_authority_probe",
      description: "Private recording action",
      schema: []

    def run(_args, _context) do
      send(Arbor.Agent.SimpleAgentMissingAuthorityProbeTest, :unauthorized_effect)
      {:ok, "recorded"}
    end
  end

  defmodule Adapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "authority_probe_model"

    def complete(request, _opts) do
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        {:ok, %Response{text: "finished", content_parts: [ContentPart.text("finished")]}}
      else
        {:ok,
         %Response{
           text: "",
           finish_reason: :tool_calls,
           content_parts: [ContentPart.tool_call("probe_1", "missing_authority_probe", %{})]
         }}
      end
    end
  end

  test "security regression: public SimpleAgent.run refuses a tool without capability authority" do
    assert Process.whereis(Arbor.Security.CapabilityStore) == nil
    Process.register(self(), __MODULE__)
    {:ok, registry} = Arbor.Common.ActionRegistry.start_link()
    :ok = Arbor.Common.ActionRegistry.register("missing_authority_probe", Probe)
    assert {:ok, Probe} = Arbor.Actions.name_to_module("missing_authority_probe")

    Client.set_default_client(
      Client.new(
        adapters: %{"authority_probe_model" => Adapter},
        default_provider: "authority_probe_model",
        model_catalog: %{}
      )
    )

    try do
      assert {:ok, result} =
               SimpleAgent.run("Propose the probe",
                 provider: "authority_probe_model",
                 model: "probe",
                 tools: [Probe],
                 context_management: :none,
                 system_prompt: "Private model fixture",
                 working_dir: System.tmp_dir!(),
                 agent_id: "agent_missing_authority"
               )

      refute_receive :unauthorized_effect
      assert [%{result: tool_result}] = result.tool_calls
      assert tool_result =~ "ERROR:"
      assert Process.whereis(Arbor.Security.CapabilityStore) == nil
    after
      GenServer.stop(registry)
    end
  end
end

result = ExUnit.run()
if result.total != 1 or result.failures != 0, do: System.halt(1)
IO.puts("SIMPLE_AGENT_MISSING_AUTHORITY_REFUSED")
