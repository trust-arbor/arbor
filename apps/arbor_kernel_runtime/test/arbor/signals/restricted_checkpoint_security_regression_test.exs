defmodule Arbor.Signals.RestrictedCheckpointSecurityRegressionTest do
  use Arbor.Signals.TestCase
  @moduletag spec: "KSEC-020"

  @moduletag :fast

  alias Arbor.Signals.Config.Testing
  alias Arbor.Signals.{Signal, Store}

  setup do
    Testing.isolate_namespace()
    Testing.put(:restricted_topics, [:security, :identity])
    Store.clear()
    :ok
  end

  @tag :security_regression
  @tag spec: "KSEC-020"
  test "security regression: checkpoint snapshots and restore exclude restricted signals" do
    restricted = Signal.new(:security, :checkpoint_secret, %{__encrypted__: true, payload: "x"})
    public = Signal.new(:activity, :checkpoint_public, %{value: 1})

    assert :ok = Store.put_sync(restricted)
    assert :ok = Store.put_sync(public)

    assert {:ok, snapshot} = Store.snapshot()
    refute Map.has_key?(snapshot.signals, restricted.id)
    assert snapshot.signals[public.id] == public
    assert snapshot.order == [public.id]

    assert :ok =
             Store.restore(%{
               signals: %{restricted.id => restricted, public.id => public},
               order: [restricted.id, public.id],
               stats: snapshot.stats
             })

    assert {:error, :not_found} = Store.get(restricted.id)
    assert {:ok, ^public} = Store.get(public.id)
  end
end
