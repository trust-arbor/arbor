defmodule Arbor.Actions.SensitivityPropagationSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  alias Arbor.LLM.{Client, Response}

  defmodule CapturingAdapter do
    def complete(_request, _opts) do
      send(
        Process.whereis(Arbor.Actions.SensitivityPropagationSecurityRegressionTest),
        :model_effect
      )

      {:ok, %Response{text: "Fixture reply", finish_reason: :stop}}
    end
  end

  setup do
    Process.register(self(), __MODULE__)
    previous = :persistent_term.get({Client, :default_client}, nil)
    bridge_key = {Arbor.AI.UnifiedBridge, :client}
    previous_bridge = :persistent_term.get(bridge_key, :missing)
    client = Client.new(adapters: %{"openai" => CapturingAdapter}, default_provider: "openai")
    :persistent_term.put(bridge_key, client)

    Client.set_default_client(
      Client.new(adapters: %{"openai" => CapturingAdapter}, default_provider: "openai")
    )

    on_exit(fn ->
      if previous, do: Client.set_default_client(previous), else: Client.clear_default_client()

      if previous_bridge == :missing,
        do: :persistent_term.erase(bridge_key),
        else: :persistent_term.put(bridge_key, previous_bridge)
    end)

    :ok
  end

  test "security regression: recorded sensitivity survives facade option projection" do
    taint = %Arbor.Contracts.Security.Taint{
      level: :derived,
      sensitivity: :restricted,
      sanitizations: 0,
      confidence: :verified,
      source: nil,
      chain: []
    }

    assert {:error, reason} =
             Arbor.Actions.AI.GenerateText.run(
               %{prompt: "Ordinary project prose", provider: "openai", model: "gpt-4o-mini"},
               %{taint: taint}
             )

    assert inspect(reason) =~ "sensitivity_blocked"
    refute_receive :model_effect
  end

  test "public content reaches the owned test client" do
    assert {:ok, _} =
             Arbor.Actions.AI.GenerateText.run(
               %{prompt: "Ordinary public prose", provider: "openai"},
               %{}
             )

    assert_receive :model_effect
  end
end
