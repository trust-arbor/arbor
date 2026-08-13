defmodule Arbor.Memory.ThinkingInventoryTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.{Taint, TaintedValue}
  alias Arbor.Memory.{ThinkingCodec, ThinkingInventory}

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B1C-R1"

  @limit 10
  @max_agents 16

  test "duplicate well-shaped IDs quarantine in every order and leave a unique sibling" do
    dup = "inv_dup_well"
    sibling = "inv_sib_well"
    valid_dup = valid_row(dup, "first")
    malformed_dup = malformed_row(dup)
    valid_dup_again = valid_row(dup, "second")
    sibling_row = valid_row(sibling, "sibling")

    orders = [
      [valid_dup, malformed_dup, sibling_row],
      [malformed_dup, valid_dup, sibling_row],
      [valid_dup, valid_dup_again, sibling_row],
      [sibling_row, valid_dup, malformed_dup],
      [sibling_row, malformed_dup, valid_dup],
      [valid_dup, sibling_row, valid_dup_again]
    ]

    Enum.each(orders, fn rows ->
      assert {:ok, inventory} = ThinkingInventory.classify(rows, @limit, @max_agents)
      assert_only_sibling(inventory, dup, sibling)
    end)
  end

  test "identifiable wrong-shape rows quarantine in both orders and block absence" do
    dup = "inv_dup_shape"
    sibling = "inv_sib_shape"
    taint = sample_taint()
    wrapped = TaintedValue.wrap(%{"version" => 1, "entries" => []}, taint)
    valid_dup = valid_row(dup, "decoded")
    sibling_row = valid_row(sibling, "sibling")

    wrong_shapes = [
      {dup, :not_tainted, :verified},
      {dup, wrapped},
      {dup},
      {dup, wrapped, :verified, :extra}
    ]

    Enum.each(wrong_shapes, fn wrong ->
      Enum.each([[wrong, valid_dup, sibling_row], [valid_dup, sibling_row, wrong]], fn rows ->
        assert {:ok, inventory} = ThinkingInventory.classify(rows, @limit, @max_agents)
        assert_only_sibling(inventory, dup, sibling)

        owned = MapSet.new([dup, sibling, "genuinely_absent"])

        assert ThinkingInventory.absence_ids(owned, inventory.plans, inventory.quarantined) ==
                 MapSet.new(["genuinely_absent"])
      end)
    end)
  end

  test "bare valid identifier quarantines and is not treated as absence" do
    dup = "inv_bare_id"
    sibling = "inv_bare_sib"

    assert {:ok, inventory} =
             ThinkingInventory.classify(
               [dup, valid_row(sibling, "sibling")],
               @limit,
               @max_agents
             )

    assert_only_sibling(inventory, dup, sibling)

    owned = MapSet.new([dup, "missing"])

    assert ThinkingInventory.absence_ids(owned, inventory.plans, inventory.quarantined) ==
             MapSet.new(["missing"])
  end

  test "rows with no identifiable valid ID are ignored while a sibling still plans" do
    sibling = "inv_ignore_sib"
    sibling_row = valid_row(sibling, "sibling")
    oversized = String.duplicate("x", 257)

    ignored = [
      :garbage,
      {<<>>, TaintedValue.wrap(%{}, sample_taint()), :verified},
      {oversized, TaintedValue.wrap(%{}, sample_taint()), :verified},
      %{"agent_id" => sibling}
    ]

    assert {:ok, inventory} =
             ThinkingInventory.classify(ignored ++ [sibling_row], @limit, @max_agents)

    assert planned_ids(inventory) == MapSet.new([sibling])
    assert inventory.quarantined == MapSet.new()
  end

  test "over-limit and improper inventories fail closed" do
    sibling = valid_row("inv_limit_a", "a")
    extra = valid_row("inv_limit_b", "b")

    assert {:error, :invalid_durable_state} =
             ThinkingInventory.classify([sibling, extra], @limit, 1)

    assert {:error, :invalid_durable_state} =
             ThinkingInventory.classify([sibling | :improper], @limit, @max_agents)

    assert {:error, :invalid_durable_state} =
             ThinkingInventory.classify([sibling], 0, @max_agents)
  end

  test "absence_ids keeps quarantined owned IDs and returns genuine absence" do
    plans = [{"kept", []}]
    quarantined = MapSet.new(["malformed_owned", "wrong_shape_owned"])
    owned = MapSet.new(["kept", "malformed_owned", "wrong_shape_owned", "gone"])

    assert ThinkingInventory.absence_ids(owned, plans, quarantined) == MapSet.new(["gone"])
  end

  test "validate_record_input rejects oversized and noncanonical caller data without minting ids" do
    agent_id = "inv_codec_agent"
    oversized = String.duplicate("x", ThinkingCodec.max_text_bytes() + 1)

    assert {:error, :invalid_payload} =
             ThinkingCodec.validate_record_input(agent_id, oversized, [])

    assert {:error, :invalid_payload} =
             ThinkingCodec.validate_record_input(agent_id, "ok", metadata: %{bad: {1, 2}})

    assert {:error, :invalid_payload} =
             ThinkingCodec.validate_record_input(agent_id, "ok", :not_keyword)

    assert :ok = ThinkingCodec.validate_record_input(agent_id, "ok", [])

    ceiling_id = "thk_" <> String.duplicate("a", 13)
    ceiling_time = "9999-12-31T23:59:59.999999Z"

    four_key = %{
      "agent_id" => agent_id,
      "text" => "ok",
      "significant" => false,
      "metadata" => %{}
    }

    six_key = Map.merge(four_key, %{"id" => ceiling_id, "created_at" => ceiling_time})
    assert :erlang.external_size(six_key) > :erlang.external_size(four_key)
    assert :erlang.external_size(six_key) <= ThinkingCodec.max_entry_bytes()
  end

  defp assert_only_sibling(inventory, dup_id, sibling_id) do
    assert MapSet.member?(inventory.quarantined, dup_id)
    refute MapSet.member?(planned_ids(inventory), dup_id)
    assert planned_ids(inventory) == MapSet.new([sibling_id])
  end

  defp planned_ids(%{plans: plans}), do: MapSet.new(plans, &elem(&1, 0))

  defp valid_row(agent_id, text) do
    entry_suffix =
      text
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 13)

    entry = %{
      id: "thk_" <> entry_suffix,
      agent_id: agent_id,
      text: text,
      significant: false,
      created_at: ~U[2026-08-12 00:00:00Z],
      metadata: %{}
    }

    taint = sample_taint()
    {:ok, aggregate, outer} = ThinkingCodec.encode_aggregate([{entry, taint}])
    {agent_id, TaintedValue.wrap(aggregate, outer), :verified}
  end

  defp malformed_row(agent_id) do
    {agent_id, TaintedValue.wrap(%{"version" => 1, "entries" => "not-a-list"}, sample_taint()),
     :verified}
  end

  defp sample_taint do
    %Taint{
      level: :trusted,
      sensitivity: :public,
      source: "thinking_inventory_test"
    }
  end
end
