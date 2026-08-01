defmodule Arbor.Persistence.EventLog.DurabilityTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Persistence
  alias Arbor.Persistence.EventLog
  alias Arbor.Persistence.EventLog.Agent
  alias Arbor.Persistence.EventLog.Ecto
  alias Arbor.Persistence.EventLog.ETS

  defmodule HintedBackend do
    @moduledoc false
    def durability_class(opts), do: Keyword.get(opts, :durability_class, :process_lifetime)
  end

  test "EventLog behaviour declares optional durability_class callback" do
    optional_callbacks = EventLog.behaviour_info(:optional_callbacks)
    assert {:durability_class, 1} in optional_callbacks
  end

  test "public durability classes remain code-owned through Arbor.Persistence facade" do
    # These values are backend-owned and should not be changed by caller config.
    assert {:ok, :node_restart} =
             Persistence.durability_class(
               :durability_ecto,
               Ecto,
               durability_class: :process_lifetime
             )

    assert {:ok, :process_lifetime} =
             Persistence.durability_class(:durability_ets, ETS, durability_class: :node_restart)

    assert {:ok, :process_lifetime} =
             Persistence.durability_class(:durability_agent, Agent,
               durability_class: :node_restart
             )

    assert {:ok, :node_restart} =
             Persistence.report_backend_durability_class(:durability_ecto, Ecto, [])

    assert {:ok, :process_lifetime} =
             Persistence.report_backend_durability_class(:durability_ets, ETS, [])

    assert {:ok, :process_lifetime} =
             Persistence.report_backend_durability_class(:durability_agent, Agent, [])
  end

  test "security regression: caller hints cannot elevate Ecto durability via facade" do
    assert {:ok, :node_restart} =
             Persistence.durability_class(
               :durability_ecto_elevate,
               Ecto,
               durability_class: :volatile,
               attempt: :node_restart,
               app_restart: true
             )
  end

  test "security regression: caller hints cannot elevate ETS or Agent durability via facade" do
    assert {:ok, :process_lifetime} =
             Persistence.durability_class(
               :durability_ets_elevate,
               ETS,
               durability_class: :node_restart,
               app_restart: true
             )

    assert {:ok, :process_lifetime} =
             Persistence.durability_class(
               :durability_agent_elevate,
               Agent,
               durability_class: :node_restart,
               app_restart: true
             )
  end

  test "security regression: direct durability_class callbacks are fixed by code" do
    assert ETS.durability_class(process_lifetime: true, durability_class: :node_restart) ==
             :process_lifetime

    assert ETS.durability_class(durability_class: :node_restart) == :process_lifetime
    assert Agent.durability_class(foo: :bar, durability_class: :node_restart) == :process_lifetime
    assert Ecto.durability_class(foo: :bar, durability_class: :volatile) == :node_restart
  end

  test "security regression: facade strips caller durability hints before callback" do
    assert {:ok, :process_lifetime} =
             Persistence.durability_class(
               :durability_hinted,
               HintedBackend,
               durability_class: :node_restart
             )
  end
end
