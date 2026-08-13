defmodule Arbor.Memory.MutationAdmissionOwnerRootsTest do
  @moduledoc """
  Owner-root helper over public MutationAdmission (VP-05D2C3I1B1A).
  """

  use ExUnit.Case, async: false

  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.MutationAdmission.Lease
  alias Arbor.Memory.MutationAdmission.OwnerRoots

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B1A"

  setup do
    assert {:ok, %{durability: :node_restart}} = MutationAdmission.readiness()
    agent_id = "owner_roots_#{System.unique_integer([:positive])}"
    %{agent_id: agent_id, roots: OwnerRoots.new()}
  end

  test "admit_new does not insert until defer", %{agent_id: agent_id, roots: roots} do
    assert OwnerRoots.held_count(roots, agent_id) == 0
    assert {:ok, %Lease{} = lease} = OwnerRoots.admit_new(roots, agent_id)
    assert OwnerRoots.held_count(roots, agent_id) == 0
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)

    assert {:ok, deferred} = OwnerRoots.defer(roots, agent_id, lease)
    assert OwnerRoots.held?(deferred, agent_id)
    assert OwnerRoots.held_count(deferred, agent_id) == 1

    {cleared, :ok} = OwnerRoots.ack(deferred, lease)
    assert OwnerRoots.held_count(cleared, agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  test "admit_new after drain fails and changes no helper state", %{
    agent_id: agent_id,
    roots: roots
  } do
    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert {:error, _reason} = OwnerRoots.admit_new(roots, agent_id)
    assert roots == OwnerRoots.new()
    assert OwnerRoots.held_count(roots, agent_id) == 0
    assert {:ok, %{gate: :draining, active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  test "independent admit_new calls are distinct roots", %{agent_id: agent_id, roots: roots} do
    assert {:ok, first} = OwnerRoots.admit_new(roots, agent_id)
    assert {:ok, second} = OwnerRoots.admit_new(roots, agent_id)
    refute first == second

    assert {:ok, held} = OwnerRoots.defer(roots, agent_id, first)
    assert {:ok, held} = OwnerRoots.defer(held, agent_id, second)
    assert OwnerRoots.held_count(held, agent_id) == 2
    assert {:ok, %{active_roots: 2}} = MutationAdmission.status(agent_id)

    {after_one, :ok} = OwnerRoots.ack(held, first)
    assert OwnerRoots.held_count(after_one, agent_id) == 1
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)

    {cleared, :ok} = OwnerRoots.settle_agent(after_one, agent_id, nil)
    assert OwnerRoots.held_count(cleared, agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  test "ack and settle drop handles after an extra public release", %{
    agent_id: agent_id,
    roots: roots
  } do
    assert {:ok, lease} = OwnerRoots.admit_new(roots, agent_id)
    assert {:ok, held} = OwnerRoots.defer(roots, agent_id, lease)
    assert :ok = MutationAdmission.release(lease)

    {after_ack, _result} = OwnerRoots.ack(held, lease)
    assert OwnerRoots.held_count(after_ack, agent_id) == 0

    assert {:ok, other} = OwnerRoots.admit_new(roots, agent_id)
    assert {:ok, held_other} = OwnerRoots.defer(roots, agent_id, other)
    assert :ok = MutationAdmission.release(other)

    {settled, :ok} = OwnerRoots.settle_agent(held_other, agent_id, other)
    assert OwnerRoots.held_count(settled, agent_id) == 0
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "forget removes stale local evidence without releasing backend authority", %{
    agent_id: agent_id,
    roots: roots
  } do
    assert {:ok, lease} = OwnerRoots.admit_new(roots, agent_id)
    assert {:ok, held} = OwnerRoots.defer(roots, agent_id, lease)

    forgotten = OwnerRoots.forget(held, lease)
    refute OwnerRoots.held?(forgotten, agent_id)
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)

    assert :ok = MutationAdmission.release(lease)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  test "ensure_deferred_root acquires once and does not reenter", %{
    agent_id: agent_id,
    roots: roots
  } do
    assert {:ok, held} = OwnerRoots.ensure_deferred_root(roots, agent_id)
    assert OwnerRoots.held_count(held, agent_id) == 1
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)

    assert {:ok, ^held} = OwnerRoots.ensure_deferred_root(held, agent_id)
    assert OwnerRoots.held_count(held, agent_id) == 1
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)

    {cleared, :ok} = OwnerRoots.settle_agent(held, agent_id, nil)
    assert OwnerRoots.held_count(cleared, agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  test "inspect never includes the raw token", %{agent_id: agent_id, roots: roots} do
    assert {:ok, lease} = OwnerRoots.admit_new(roots, agent_id)
    assert {:ok, held} = OwnerRoots.defer(roots, agent_id, lease)

    rendered = inspect(held)
    assert rendered =~ "#MutationAdmission.OwnerRoots<"
    refute rendered =~ "token="
    refute rendered =~ "#MutationAdmission.Lease"

    {cleared, :ok} = OwnerRoots.ack(held, lease)
    assert OwnerRoots.held_count(cleared, agent_id) == 0
  end

  test "immediate ack of an undeferred lease leaves zero active roots", %{
    agent_id: agent_id,
    roots: roots
  } do
    assert {:ok, lease} = OwnerRoots.admit_new(roots, agent_id)
    {cleared, :ok} = OwnerRoots.ack(roots, lease)
    assert OwnerRoots.held_count(cleared, agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end
end
