defmodule Arbor.AI.CommsResponderSensitivitySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.AI.{CommsResponder, UnifiedBridge}
  alias Arbor.Contracts.Comms.{Message, ResponseEnvelope}
  alias Arbor.LLM.{Client, Response}

  defmodule CapturingAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "anthropic"

    def complete(request, opts) do
      observer = Process.whereis(Arbor.AI.CommsResponderSensitivitySecurityRegressionTest)
      send(observer, {:comms_llm_effect, request, opts})
      {:ok, %Response{text: "[CHANNEL:signal] Fixture reply"}}
    end
  end

  setup do
    Process.register(self(), __MODULE__)
    client_key = {UnifiedBridge, :client}
    previous_client = :persistent_term.get(client_key, :missing)

    previous = [
      {:arbor_ai, :default_provider, Application.fetch_env(:arbor_ai, :default_provider)},
      {:arbor_ai, :default_model, Application.fetch_env(:arbor_ai, :default_model)},
      {:arbor_llm, :sensitivity_guarded_adapters,
       Application.fetch_env(:arbor_llm, :sensitivity_guarded_adapters)}
    ]

    Application.put_env(:arbor_ai, :default_provider, :anthropic)
    Application.put_env(:arbor_ai, :default_model, "claude-sonnet-4-5-20250514")
    Application.put_env(:arbor_llm, :sensitivity_guarded_adapters, [CapturingAdapter])
    :persistent_term.put(client_key, Client.new(adapters: %{"anthropic" => CapturingAdapter}))

    on_exit(fn ->
      if previous_client == :missing,
        do: :persistent_term.erase(client_key),
        else: :persistent_term.put(client_key, previous_client)

      Enum.each(previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end)

    :ok
  end

  test "security regression: comms message labels survive prompt formatting" do
    message = message(%{sensitivity: :restricted})

    assert {:error, {:sensitivity_blocked, _}} =
             CommsResponder.generate_response(message, %{})

    refute_receive {:comms_llm_effect, _, _}
  end

  test "security regression: comms context labels survive response generation" do
    assert {:error, {:sensitivity_blocked, _}} =
             CommsResponder.generate_response(message(), %{sensitivity: :restricted})

    refute_receive {:comms_llm_effect, _, _}
  end

  test "security regression: ordinary comms response still reaches its configured adapter" do
    assert {:ok, %ResponseEnvelope{body: "Fixture reply", channel: :signal}} =
             CommsResponder.generate_response(message(), %{})

    assert_receive {:comms_llm_effect, request, _opts}
    assert Enum.any?(request.messages, &(&1.content == "[via signal] Ordinary planning notes"))
  end

  defp message(metadata \\ %{}) do
    Message.new(
      channel: :signal,
      from: "fixture_sender",
      content: "Ordinary planning notes",
      metadata: metadata
    )
  end
end
