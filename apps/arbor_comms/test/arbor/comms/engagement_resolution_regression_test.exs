defmodule Arbor.Comms.EngagementResolutionRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.EngagementStore

  @moduletag :fast
  @claim_event [:arbor, :comms, :engagement, :resolution_claim]

  setup do
    unless Process.whereis(EngagementStore), do: start_supervised!(EngagementStore)
    :ok
  end

  test "resolution publication regression: a visible claim always names a complete record" do
    observer = self()
    agent = unique_agent()
    worker = spawn(fn ->
      receive do
        :resolve ->
          result = EngagementStore.resolve_or_create(agent, "channel", scope: :channel)
          send(observer, {:first_result, self(), result})
      end
    end)

    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, @claim_event, &__MODULE__.hold_claim/4, {observer, worker})

    try do
      send(worker, :resolve)
      assert_receive {:claimed, ^worker, claimed_id}, 2_000

      # The first resolver is paused exactly after publishing its index claim.
      # A second public call must return that complete record, not steal the key.
      assert {:ok, second} = EngagementStore.resolve_or_create(agent, "channel", scope: :channel)
      send(worker, :release)
      assert_receive {:first_result, ^worker, {:ok, first}}, 2_000
      assert first.id == claimed_id
      assert second.id == first.id
      assert {:ok, ^first} = EngagementStore.get(claimed_id)
      assert Enum.map(EngagementStore.list_for_agent(agent), & &1.id) == [first.id]
    after
      send(worker, :release)
      :telemetry.detach(handler)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      cleanup(agent)
    end
  end

  test "deterministic resolution keeps the winning record and attachments under contention" do
    agent = unique_agent()
    try do
      results =
        1..40
        |> Task.async_stream(fn _ ->
          EngagementStore.resolve_or_create(agent, "human", scope: :user, owner_tenant: "human")
        end, max_concurrency: 40)
        |> Enum.map(fn {:ok, {:ok, engagement}} -> engagement end)

      assert [id] = results |> Enum.map(& &1.id) |> Enum.uniq()
      assert {:ok, attached} = EngagementStore.attach_channel(id, "browser")
      assert {:ok, ^attached} = EngagementStore.resolve_or_create(agent, "human", scope: :user)
      assert {:ok, ^attached} = EngagementStore.get(id)
      assert [^attached] = EngagementStore.list_for_agent(agent)
    after
      cleanup(agent)
    end
  end

  @doc false
  def hold_claim(_event, _measurements, metadata, {observer, worker}) do
    if self() == worker do
      send(observer, {:claimed, worker, metadata.engagement_id})
      receive do
        :release -> :ok
      after
        5_000 -> raise "resolution probe was not released"
      end
    end
  end

  defp unique_agent, do: "resolution_#{System.unique_integer([:positive, :monotonic])}"

  defp cleanup(agent) do
    for engagement <- EngagementStore.list_for_agent(agent), do: EngagementStore.delete(engagement.id)
  end
end
