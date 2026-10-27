defmodule Arbor.Consensus.SensitivityPropagationSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  alias Arbor.LLM.{Client, Response}

  defmodule CapturingAdapter do
    def complete(_request, _opts) do
      send(
        Process.whereis(Arbor.Consensus.SensitivityPropagationSecurityRegressionTest),
        :model_effect
      )

      {:ok, %Response{text: "Fixture reply", finish_reason: :stop}}
    end
  end

  setup do
    Process.register(self(), __MODULE__)
    previous = :persistent_term.get({Client, :default_client}, nil)

    Client.set_default_client(
      Client.new(adapters: %{"openai" => CapturingAdapter}, default_provider: "openai")
    )

    on_exit(fn ->
      if previous, do: Client.set_default_client(previous), else: Client.clear_default_client()
    end)

    :ok
  end

  test "security regression: recorded sensitivity survives facade option projection" do
    assert {:error, {:sensitivity_blocked, _}} =
             Arbor.Consensus.LLMBridge.complete("Public system", "Ordinary project prose",
               provider: "openai",
               model: "gpt-4o-mini",
               sensitivity: :restricted
             )

    refute_receive :model_effect
  end
end
