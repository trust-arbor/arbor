defmodule Arbor.Agent.RuntimeAdmission.WaiterCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.RuntimeAdmission.WaiterCore

  @moduletag :fast

  defp record(opts \\ []) do
    waiter_id = Keyword.get(opts, :waiter_id, make_ref())
    intent_id = Keyword.get(opts, :intent_id, "rai_test")
    caller = Keyword.get(opts, :caller_pid, self())
    mon = Keyword.get(opts, :mon, make_ref())
    token = Keyword.get(opts, :deadline_token, make_ref())
    timer = Keyword.get(opts, :timer_ref, make_ref())
    from = Keyword.get(opts, :from, {caller, make_ref()})

    %{
      waiter_id: waiter_id,
      intent_id: intent_id,
      from: from,
      caller_pid: caller,
      mon: mon,
      deadline_token: token,
      timer_ref: timer
    }
  end

  test "ceiling is hard 64; normalize_max never raises it" do
    assert WaiterCore.ceiling() == 64
    assert WaiterCore.normalize_max(64) == 64
    assert WaiterCore.normalize_max(1) == 1
    assert WaiterCore.normalize_max(8) == 8
    assert WaiterCore.normalize_max(100) == 64
    assert WaiterCore.normalize_max(0) == 64
    assert WaiterCore.normalize_max(-1) == 64
    assert WaiterCore.normalize_max(:bogus) == 64
    assert WaiterCore.effective_max(999) == 64
  end

  test "can_accept enforces cap" do
    assert :ok = WaiterCore.can_accept?(0, 64)
    assert :ok = WaiterCore.can_accept?(63, 64)
    assert {:error, :runtime_admission_waiters_full} = WaiterCore.can_accept?(64, 64)
    assert {:error, :runtime_admission_waiters_full} = WaiterCore.can_accept?(2, 2)
    assert {:error, :runtime_admission_waiters_full} = WaiterCore.can_accept?(64, 999)
  end

  test "insert remove_by_mon remove_by_deadline detach_all" do
    rec = record()
    assert {:ok, w, m, d} = WaiterCore.insert(%{}, %{}, %{}, rec, 64)
    assert WaiterCore.intent_count(w, rec.intent_id) == 1

    assert {:ok, ^rec, w2, m2, d2} = WaiterCore.remove_by_mon(w, m, d, rec.mon)
    assert WaiterCore.intent_count(w2, rec.intent_id) == 0
    assert :stale = WaiterCore.remove_by_mon(w2, m2, d2, rec.mon)

    rec2 = record()
    assert {:ok, w, m, d} = WaiterCore.insert(%{}, %{}, %{}, rec2, 64)

    assert {:ok, ^rec2, w3, _m3, _d3} =
             WaiterCore.remove_by_deadline(w, m, d, rec2.deadline_token)

    assert WaiterCore.intent_count(w3, rec2.intent_id) == 0

    rec3 = record()
    rec4 = record(intent_id: rec3.intent_id)
    assert {:ok, w, m, d} = WaiterCore.insert(%{}, %{}, %{}, rec3, 64)
    assert {:ok, w, m, d} = WaiterCore.insert(w, m, d, rec4, 64)
    {detached, w4, m4, d4} = WaiterCore.detach_all(w, m, d, rec3.intent_id)
    assert length(detached) == 2
    assert WaiterCore.intent_count(w4, rec3.intent_id) == 0
    assert m4 == %{}
    assert d4 == %{}
  end

  test "stale forged mon and deadline are inert" do
    rec = record()
    assert {:ok, w, m, d} = WaiterCore.insert(%{}, %{}, %{}, rec, 64)
    assert :stale = WaiterCore.remove_by_mon(w, m, d, make_ref())
    assert :stale = WaiterCore.remove_by_deadline(w, m, d, make_ref())
  end

  test "normalize_correlated drops orphans and mismatched indexes" do
    rec = record()
    assert {:ok, w, m, d} = WaiterCore.insert(%{}, %{}, %{}, rec, 64)

    # Orphan mon index (no matching record) is stripped; live record kept.
    m_bad = Map.put(m, make_ref(), {"rai_other", make_ref()})
    {w2, m2, d2, dropped2} = WaiterCore.normalize_correlated(w, m_bad, d)
    assert WaiterCore.intent_count(w2, rec.intent_id) == 1
    assert map_size(m2) == 1
    assert map_size(d2) == 1
    assert dropped2 == []

    # Break mon index for the live record — record must not survive; returned for cleanup.
    m_broken = Map.delete(m, rec.mon)
    {w3, m3, d3, dropped3} = WaiterCore.normalize_correlated(w, m_broken, d)
    assert w3 == %{}
    assert m3 == %{}
    assert d3 == %{}
    assert length(dropped3) == 1
    assert hd(dropped3).waiter_id == rec.waiter_id

    assert WaiterCore.correlated?(w, m, d)
    refute WaiterCore.correlated?(w, m_bad, d)
    refute WaiterCore.correlated?(w, m_broken, d)
  end

  test "records with extra fields are not exact waiter authority" do
    rec = Map.put(record(), :unexpected, :data)

    assert {:error, :invalid_record} = WaiterCore.insert(%{}, %{}, %{}, rec, 64)
  end

  test "classify_legacy and extract_legacy_drains" do
    from = {self(), make_ref()}
    alias_from = {self(), [:alias | make_ref()]}
    assert WaiterCore.classify_legacy(nil) == :empty
    assert WaiterCore.classify_legacy(%{}) == :modern_map
    assert WaiterCore.classify_legacy([from]) == {:legacy_from_list, [from]}
    assert WaiterCore.classify_legacy([alias_from]) == {:legacy_from_list, [alias_from]}
    assert WaiterCore.classify_legacy([:not_a_from]) == :corrupt

    drains =
      WaiterCore.extract_legacy_drains(%{
        "rai_1" => [from],
        "rai_2" => %{make_ref() => record()}
      })

    assert drains == [{"rai_1", [from]}]
  end

  test "duplicate waiter, monitor, or deadline authority is rejected on insert" do
    waiter_id = make_ref()
    mon = make_ref()
    token = make_ref()
    rec1 = record(waiter_id: waiter_id, mon: mon, deadline_token: token)
    same_waiter = record(waiter_id: waiter_id)
    rec2 = record(mon: mon)
    rec3 = record(deadline_token: token)
    assert {:ok, w, m, d} = WaiterCore.insert(%{}, %{}, %{}, rec1, 64)
    assert {:error, :duplicate_authority} = WaiterCore.insert(w, m, d, same_waiter, 64)
    assert {:error, :duplicate_authority} = WaiterCore.insert(w, m, d, rec2, 64)
    assert {:error, :duplicate_authority} = WaiterCore.insert(w, m, d, rec3, 64)
  end
end
