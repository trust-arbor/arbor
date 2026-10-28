defmodule Arbor.Persistence.SessionStoreProvenanceSecurityRegressionTest do
  use Arbor.Persistence.DatabaseCase, async: false

  @moduletag :database

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Persistence.SessionStore

  test "security regression: invalid labeled batch inserts no rows" do
    session_id = "security-regression-#{System.unique_integer([:positive])}"
    assert {:ok, session} = SessionStore.create_session("agent-security", session_id: session_id)

    valid_content = [%{"type" => "text", "text" => "valid"}]
    forged_content = [%{"type" => "text", "text" => "forged"}]

    assert {:ok, envelope} =
             TaintEnvelope.new(valid_content, %Taint{level: :derived, source: "test"})

    assert {:ok, valid_taint} = TaintEnvelope.to_map(envelope)

    assert {:error, {:invalid_entry, 1, {:invalid_durable_provenance, _}}} =
             SessionStore.append_entries(session.id, [
               entry(valid_content, %{"taint" => valid_taint}),
               entry(
                 forged_content,
                 %{"taint" => Map.put(valid_taint, "payload_sha256", String.duplicate("0", 64))}
               )
             ])

    assert SessionStore.entry_count(session.id) == 0
  end

  defp entry(content, metadata) do
    %{
      entry_type: "user",
      role: "user",
      content: content,
      timestamp: DateTime.utc_now(),
      metadata: metadata
    }
  end
end
