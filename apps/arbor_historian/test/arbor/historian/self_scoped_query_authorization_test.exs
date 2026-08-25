defmodule Arbor.Historian.SelfScopedQueryAuthorizationTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Historian
  alias Arbor.Historian.StreamIds

  # Trust mints the canonical `arbor://historian/query`; the facade gates the
  # scoped stream. Since 2026-08-25 the minted parent covers the agent's OWN
  # stream only. Found live: an agent discovered historian_query_events, was
  # minted the parent, and was refused on its own history.

  setup do
    for mod <- [
          Arbor.Security.Identity.Registry,
          Arbor.Security.SystemAuthority,
          Arbor.Security.CapabilityStore,
          Arbor.Security.Reflex.Registry,
          Arbor.Security.Constraint.RateLimiter
        ] do
      unless Process.whereis(mod), do: start_supervised!(mod)
    end

    agent = "agent_hist_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      # Supervised Security processes are already down here when this test
      # started them; only clean up when a longer-lived store is present.
      if Process.whereis(Arbor.Security.CapabilityStore) do
        case Arbor.Security.list_capabilities(agent) do
          {:ok, caps} -> Enum.each(caps, &Arbor.Security.revoke(&1.id))
          _ -> :ok
        end
      end
    end)

    {:ok, _} = Arbor.Security.grant(principal: agent, resource: "arbor://historian/query")
    {:ok, agent: agent}
  end

  test "the minted parent authorizes the agent's own stream", %{agent: agent} do
    refute match?(
             {:error, {:unauthorized, _}},
             Historian.authorize_query(agent, stream: StreamIds.for_agent(agent), limit: 5)
           )
  end

  test "security regression: the parent does not open another agent's stream", %{agent: agent} do
    assert {:error, {:unauthorized, _}} =
             Historian.authorize_query(agent, stream: StreamIds.for_agent("agent_someone_else"))
  end

  test "security regression: the parent does not open the global stream", %{agent: agent} do
    assert {:error, {:unauthorized, _}} = Historian.authorize_query(agent, stream: "general")
  end

  test "security regression: the parent does not open a category (security)", %{agent: agent} do
    assert {:error, {:unauthorized, _}} = Historian.authorize_query(agent, category: :security)
  end
end
