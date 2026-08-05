defmodule Arbor.Memory.IntentStoreAuthorityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Memory.IntentStore
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @store_name :arbor_memory_durable

  setup do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})
    %{agent_id: "intent_authority_#{System.unique_integer([:positive])}"}
  end

  test "security regression: compatibility reads reject a forged ETS projection", %{
    agent_id: agent_id
  } do
    original = Intent.think("durable original")
    forged = %{original | reasoning: "forged caller projection"}

    try do
      assert {:ok, ^original} = IntentStore.record_intent(agent_id, original)
      assert wait_until(fn -> durable_record_exists?(agent_id) end)

      assert [{^agent_id, projection}] = :ets.lookup(:arbor_memory_intents, agent_id)
      true = :ets.insert(:arbor_memory_intents, {agent_id, %{projection | intents: [forged]}})

      assert [^original] = IntentStore.recent_intents(agent_id)
    after
      IntentStore.clear(agent_id)
    end
  end

  defp durable_record_exists?(agent_id) do
    match?(
      {:ok, _record},
      BufferedStore.get("intents:#{agent_id}", name: @store_name)
    )
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(fun, _attempts) when not is_function(fun, 0), do: false
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
