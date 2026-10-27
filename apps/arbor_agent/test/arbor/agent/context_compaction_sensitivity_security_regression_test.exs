defmodule Arbor.Agent.ContextCompactionSensitivitySecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.ContextCompactor

  @moduletag :fast

  test "security regression: recorded restricted prose remains restricted across successive narrative summaries" do
    observer = self()

    compactor =
      ContextCompactor.new(
        effective_window: 3_000,
        enable_llm_compaction: true,
        summarizer: fn _prompt, config ->
          send(observer, {:summary_input_sensitivity, Map.get(config, :sensitivity)})
          {:ok, "The earlier conversation discussed the project plan."}
        end
      )
      |> ContextCompactor.append(%{role: :system, content: "Keep a concise conversation record."})
      |> ContextCompactor.append(%{role: :user, content: "Let us discuss the project plan."})
      |> ContextCompactor.append(%{
        role: :assistant,
        content: "The launch plan contains these ordinary planning notes. " <> filler(),
        sensitivity: :restricted
      })

    first = advance_until_summary(compactor, 1, 1)

    assert ContextCompactor.stats(first).narrative_count >= 1
    assert_receive {:summary_input_sensitivity, :restricted}
    assert summary(first).sensitivity == :restricted

    # The next incoming records and generated summary are all plain prose.
    # Their bytes cannot reconstruct the original record's restricted label.
    second = advance_until_summary(first, ContextCompactor.stats(first).narrative_count + 1, 101)

    assert ContextCompactor.stats(second).narrative_count >
             ContextCompactor.stats(first).narrative_count

    assert_receive {:summary_input_sensitivity, :restricted}
    assert summary(second).sensitivity == :restricted
  end

  defp advance_until_summary(compactor, target_count, first_turn) do
    Enum.reduce_while(first_turn..(first_turn + 80), compactor, fn turn, current ->
      current =
        current
        |> ContextCompactor.append(%{
          role: :user,
          content: "Public discussion turn #{turn}. " <> filler()
        })
        |> ContextCompactor.append(%{
          role: :assistant,
          content: "These are ordinary public follow-up notes. " <> filler()
        })
        |> ContextCompactor.maybe_compact()

      if ContextCompactor.stats(current).narrative_count >= target_count,
        do: {:halt, current},
        else: {:cont, current}
    end)
  end

  defp summary(compactor) do
    compactor
    |> ContextCompactor.llm_messages()
    |> Enum.find(&(Map.get(&1, :compactor_kind) == :summary))
  end

  defp filler, do: String.duplicate("ordinary planning discussion material ", 60)
end
