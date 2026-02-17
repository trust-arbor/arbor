defmodule Arbor.Orchestrator.Conformance.ProviderDocVerificationTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Conformance.{Matrix, ProviderDocVerification}

  test "each implemented unified_llm row has provider-doc verification metadata" do
    implemented_ids =
      Matrix.items().unified_llm
      |> Enum.filter(&(&1.status == :implemented))
      |> Enum.map(& &1.id)

    verifications = ProviderDocVerification.all()

    Enum.each(implemented_ids, fn id ->
      assert %{checked_on: %Date{}, sources: sources, notes: notes} = Map.get(verifications, id),
             "Missing provider-doc verification entry for unified_llm matrix row #{id}"

      assert is_list(sources) and sources != []
      assert Enum.any?(sources, &String.contains?(&1, "openai.com"))
      assert Enum.any?(sources, &String.contains?(&1, "claude.com"))
      assert Enum.any?(sources, &String.contains?(&1, "google.dev"))
      assert Enum.any?(sources, &String.contains?(&1, "openai_responses_from_openai_node_sdk"))
      assert Enum.any?(sources, &String.contains?(&1, "anthropic_messages_from_typescript_sdk"))

      assert Enum.any?(
               sources,
               &String.contains?(&1, "google_generate_content_from_js_genai_sdk")
             )

      assert is_binary(notes) and notes != ""
    end)
  end
end
