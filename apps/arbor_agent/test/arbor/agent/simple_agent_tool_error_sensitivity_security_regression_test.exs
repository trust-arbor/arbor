defmodule Arbor.Agent.SimpleAgentToolErrorSensitivitySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Agent.SimpleAgent
  alias Arbor.LLM.{Client, ContentPart, Response}

  defmodule Probe do
    use Jido.Action,
      name: "simple_agent_source_probe",
      description: "Read a fixture source",
      schema: [source: [type: :string, required: true]]

    def run(_params, _context), do: raise("only the configured executor owns this tool")
  end

  defmodule LabeledExecutor do
    def execute_action("simple_agent_source_probe", %{"source" => source}, _workdir, _opts) do
      observer =
        Process.whereis(Arbor.Agent.SimpleAgentToolErrorSensitivitySecurityRegressionTest)

      send(observer, {:simple_source_executed, source})
      sensitivity = if source == "Read the first source", do: :restricted, else: :public
      {:error, %{message: "Ordinary project planning notes", sensitivity: sensitivity}}
    end
  end

  defmodule CapturingAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "openai"

    def complete(request, _opts) do
      round = Enum.count(request.messages, &(&1.role == :tool))

      observer =
        Process.whereis(Arbor.Agent.SimpleAgentToolErrorSensitivitySecurityRegressionTest)

      send(observer, {:simple_model_effect, round})

      if round == 0 do
        source = Enum.find(request.messages, &(&1.role == :user)).content

        {:ok,
         %Response{
           text: "",
           finish_reason: :tool_calls,
           content_parts: [
             ContentPart.tool_call("source_call", "simple_agent_source_probe", %{
               "source" => source
             })
           ]
         }}
      else
        {:ok,
         %Response{
           text: "Fixture reply",
           finish_reason: :stop,
           content_parts: [ContentPart.text("Fixture reply")]
         }}
      end
    end
  end

  setup do
    Process.register(self(), __MODULE__)
    previous_client = Client.default_client()
    previous_executor = Application.fetch_env(:arbor_agent, :simple_agent_executor)
    previous_adapters = Application.fetch_env(:arbor_llm, :sensitivity_guarded_adapters)

    Client.set_default_client(Client.new(adapters: %{"openai" => CapturingAdapter}))
    Application.put_env(:arbor_agent, :simple_agent_executor, LabeledExecutor)
    Application.put_env(:arbor_llm, :sensitivity_guarded_adapters, [CapturingAdapter])

    on_exit(fn ->
      Client.set_default_client(previous_client)

      for {app, key, previous} <- [
            {:arbor_agent, :simple_agent_executor, previous_executor},
            {:arbor_llm, :sensitivity_guarded_adapters, previous_adapters}
          ] do
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    :ok
  end

  test "security regression: SimpleAgent retains labels on an error tool result" do
    assert {:error, {:sensitivity_blocked, _}} = run("Read the first source")
    assert_receive {:simple_model_effect, 0}
    assert_receive {:simple_source_executed, "Read the first source"}
    refute_receive {:simple_model_effect, 1}
  end

  test "security regression: SimpleAgent public tool errors preserve normal continuation" do
    assert {:ok, result} = run("Read the second source")
    assert result.status == :completed
    assert result.text == "Fixture reply"
    assert_receive {:simple_model_effect, 0}
    assert_receive {:simple_source_executed, "Read the second source"}
    assert_receive {:simple_model_effect, 1}
  end

  defp run(source) do
    SimpleAgent.run(source,
      provider: :openai,
      model: "gpt-4o-mini",
      tools: [Probe],
      system_prompt: "Use the declared fixture tool.",
      context_management: :none,
      max_turns: 3
    )
  end
end
