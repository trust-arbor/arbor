defmodule Arbor.Memory.ContextWindowSensitivitySecurityRegressionTest do
  @moduledoc """
  Security regression: context ownership retains sensitivity when rich messages
  are demoted to plain summaries or discarded and the window is restored.

  Exercises the public immutable ContextWindow API. Summarization stays local;
  the provider admission regressions independently prove the egress gate.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.ContextWindow

  @moduletag :fast

  test "security regression: restricted summary floor survives discarded messages and restoration" do
    window =
      ContextWindow.new("context_sensitivity",
        multi_layer: true,
        max_tokens: 100,
        summarization_enabled: false
      )
      |> ContextWindow.add_message(%{
        role: :user,
        content: String.duplicate("The unreleased milestone is ready for internal review. ", 20),
        metadata: %{taint: restricted_taint()}
      })

    assert window.full_detail == []
    assert (window.recent_summary || "") <> (window.distant_summary || "") != ""

    serialized = ContextWindow.serialize(window)
    assert serialized["sensitivity"] == "restricted"

    restored = ContextWindow.deserialize(serialized)
    assert Map.get(restored, :sensitivity) == :restricted

    public_update =
      ContextWindow.add_message(restored, %{
        role: :user,
        content: "A public status update.",
        metadata: %{sensitivity: :public}
      })

    assert Map.get(public_update, :sensitivity) == :restricted
    assert Map.get(ContextWindow.clear(public_update), :sensitivity) == :restricted
  end

  test "security regression: legacy nonempty summary without a label restores as restricted" do
    restored =
      ContextWindow.deserialize(%{
        "agent_id" => "legacy_context_sensitivity",
        "multi_layer" => true,
        "recent_summary" => "An ordinary-looking summary of private decisions.",
        "distant_summary" => "",
        "full_detail" => []
      })

    assert Map.get(restored, :sensitivity) == :restricted
  end

  test "security regression: malformed message classification retains a restricted local floor" do
    window =
      ContextWindow.new("malformed_context_sensitivity", multi_layer: true)
      |> ContextWindow.add_message(%{
        role: :user,
        content: "Locally retained content.",
        metadata: %{sensitivity: :invalid_classification}
      })

    assert Map.get(window, :sensitivity) == :restricted
    assert [%{content: "Locally retained content."}] = window.full_detail
  end

  defp restricted_taint do
    %Taint{
      level: :derived,
      sensitivity: :restricted,
      confidence: :verified,
      sanitizations: 0,
      source: "private-conversation",
      chain: ["conversation:private", "memory:summary"]
    }
  end
end
