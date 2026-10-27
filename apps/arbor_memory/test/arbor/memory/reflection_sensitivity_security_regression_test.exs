defmodule Arbor.Memory.ReflectionSensitivitySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Memory.{ReflectionProcessor, WorkingMemory}
  alias Arbor.Memory.Test.DurableGraphAuthority

  defmodule CapturingLLM do
    def reflect(prompt, context) do
      observer = Process.whereis(Arbor.Memory.ReflectionSensitivitySecurityRegressionTest)
      send(observer, {:legacy_reflection_llm, prompt, context})
      {:error, :captured_reflection}
    end

    def generate_text(prompt, opts) do
      observer = Process.whereis(Arbor.Memory.ReflectionSensitivitySecurityRegressionTest)
      send(observer, {:deep_reflection_llm, prompt, opts})
      {:error, :captured_reflection}
    end
  end

  setup do
    Process.register(self(), __MODULE__)
    DurableGraphAuthority.start!()
    previous = Application.fetch_env(:arbor_memory, :reflection_llm_module)
    Application.put_env(:arbor_memory, :reflection_llm_module, CapturingLLM)
    agent_id = "reflection_sensitivity_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_memory, :reflection_llm_module, value)
        :error -> Application.delete_env(:arbor_memory, :reflection_llm_module)
      end

      Arbor.Memory.delete_working_memory(agent_id)
      Arbor.Memory.cleanup_for_agent(agent_id)
    end)

    %{agent_id: agent_id}
  end

  test "security regression: legacy reflection retains a floor for freshly fetched private context",
       %{
         agent_id: agent_id
       } do
    assert {:error, :captured_reflection} =
             ReflectionProcessor.reflect(agent_id, "Review recent progress", sensitivity: :public)

    assert_receive {:legacy_reflection_llm, "Review recent progress", context}
    assert Map.get(context, :sensitivity) == :restricted
  end

  test "security regression: deep reflection retains a floor after private memory formatting", %{
    agent_id: agent_id
  } do
    memory =
      agent_id
      |> WorkingMemory.new()
      |> WorkingMemory.add_thought("Ordinary private planning notes")

    Arbor.Memory.save_working_memory(agent_id, memory)

    assert {:error, :captured_reflection} =
             ReflectionProcessor.deep_reflect(agent_id, sensitivity: :public)

    assert_receive {:deep_reflection_llm, prompt, opts}
    assert prompt =~ "Ordinary private planning notes"
    assert Keyword.get(opts, :sensitivity) == :restricted
    assert Keyword.get(opts, :agent_id) == agent_id
  end
end
