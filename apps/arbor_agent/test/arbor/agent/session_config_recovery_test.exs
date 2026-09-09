defmodule Arbor.Agent.SessionConfigRecoveryTest do
  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Agent.SessionConfig

  @moduletag :database

  test "startup never turns mixed engagement entries into an aggregate checkpoint" do
    agent_id = "agent_config_recovery_#{System.unique_integer([:positive])}"
    session_id = "agent-session-#{agent_id}"
    assert {:ok, session} = Arbor.Persistence.ensure_session(session_id, agent_id)

    entries =
      for {engagement, content} <- [{"eng_alpha", "alpha secret"}, {"eng_beta", "beta secret"}] do
        %{
          entry_type: "user",
          role: "user",
          content: [%{"type" => "text", "text" => content}],
          timestamp: DateTime.utc_now(),
          metadata: %{"engagement_id" => engagement}
        }
      end

    assert {:ok, 2} = Arbor.Persistence.append_session_entries(session.id, entries)
    assert length(Arbor.Persistence.load_recent_session_messages(session_id)) == 2

    opts = SessionConfig.build(agent_id, context_management: :none)

    refute Keyword.has_key?(opts, :checkpoint)
    assert opts[:config]["recover_session"] == true
  end
end
