defmodule Arbor.Consensus.Evaluators.AdvisoryLLMHostFallbackTest do
  # Not async: swaps app env seams.
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Consensus.Evaluators.AdvisoryLLM

  defmodule Routes do
    def route("openai_oauth"), do: :unavailable
    def route("xai_oauth"), do: :available
    def route("openrouter"), do: :available
    def route("ollama"), do: :unavailable
    def route(_), do: :unknown
  end

  setup do
    keys = [:provider_route_mfa, :perspective_models, :advisory_fallback_providers]
    previous = Map.new(keys, &{&1, Application.get_env(:arbor_consensus, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {k, nil} -> Application.delete_env(:arbor_consensus, k)
        {k, v} -> Application.put_env(:arbor_consensus, k, v)
      end)
    end)

    Application.put_env(:arbor_consensus, :provider_route_mfa, {Routes, :route})

    Application.put_env(:arbor_consensus, :advisory_fallback_providers, [
      {"xai_oauth", "grok-4.6"}
    ])

    :ok
  end

  test "a seat pinned to a known-but-unavailable route falls back to the first available candidate" do
    Application.put_env(:arbor_consensus, :perspective_models, %{
      security: "openai_oauth:gpt-5.6-sol"
    })

    assert {"xai_oauth", "grok-4.6"} = AdvisoryLLM.resolve_provider_model(:security)
  end

  test "an available preferred route is kept" do
    Application.put_env(:arbor_consensus, :perspective_models, %{
      adversarial: "openrouter:google/gemini-3.7-flash"
    })

    assert {"openrouter", "google/gemini-3.7-flash"} =
             AdvisoryLLM.resolve_provider_model(:adversarial)
  end

  test "an unknown route (custom adapter) and a per-call override are left alone" do
    Application.put_env(:arbor_consensus, :perspective_models, %{vision: "my_adapter:m1"})
    assert {"my_adapter", "m1"} = AdvisoryLLM.resolve_provider_model(:vision)

    assert {"openai_oauth", "gpt-5.6-sol"} =
             AdvisoryLLM.resolve_provider_model(:vision,
               provider_model: "openai_oauth:gpt-5.6-sol"
             )
  end

  test "without the route seam no fallback happens" do
    Application.delete_env(:arbor_consensus, :provider_route_mfa)

    Application.put_env(:arbor_consensus, :perspective_models, %{
      security: "openai_oauth:gpt-5.6-sol"
    })

    assert {"openai_oauth", "gpt-5.6-sol"} = AdvisoryLLM.resolve_provider_model(:security)
  end
end
