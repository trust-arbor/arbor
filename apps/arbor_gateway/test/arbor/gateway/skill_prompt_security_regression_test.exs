defmodule Arbor.Gateway.SkillPromptSecurityRegressionTest do
  use ExUnit.Case, async: false
  alias Arbor.Common.SkillLibrary
  alias Arbor.Gateway.IntentExtractor

  @moduletag :fast
  @moduletag :security_regression
  @moduletag :trusted_skill_bug

  test "intent extraction uses the builtin fallback rather than an unapproved imported prompt" do
    unless Process.whereis(SkillLibrary), do: start_supervised!({SkillLibrary, dirs: []})
    previous = SkillLibrary.get("intent-extraction")

    on_exit(fn ->
      if Process.whereis(SkillLibrary) do
        case previous do
          {:ok, skill} -> SkillLibrary.register(skill)
          _ -> SkillLibrary.reload()
        end
      end
    end)

    :ok =
      SkillLibrary.register(%{
        name: "intent-extraction",
        description: "untrusted",
        body: "FORGED_GATEWAY_SYSTEM_PROMPT",
        taint: :untrusted
      })

    assert Code.ensure_loaded?(Arbor.AI)
    owner = self()

    tracer =
      spawn(fn ->
        receive do
          {:trace, ^owner, :call, {Arbor.AI, :generate_text, [prompt, _opts]}} ->
            send(owner, {:actual_ai_input, prompt})
        end
      end)

    :erlang.trace_pattern({Arbor.AI, :generate_text, 2}, true, [])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    on_exit(fn ->
      :erlang.trace_pattern({Arbor.AI, :generate_text, 2}, false, [])
      if Process.alive?(tracer), do: Process.exit(tracer, :kill)
    end)

    # An unregistered provider refuses locally; the actual public AI boundary
    # still observes the constructed prompt without admitting any provider I/O.
    assert {:error, _} =
             IntentExtractor.extract("Review a synthetic request",
               provider: :skill_test_unregistered,
               model: "synthetic",
               timeout: 100
             )

    :erlang.trace(self(), false, [:call])
    assert_receive {:actual_ai_input, prompt}
    refute prompt =~ "FORGED_GATEWAY_SYSTEM_PROMPT"
    assert prompt =~ "Analyze this user request"
    assert prompt =~ "Review a synthetic request"
  end
end
