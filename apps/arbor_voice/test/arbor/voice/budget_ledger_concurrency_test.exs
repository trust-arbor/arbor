defmodule Arbor.Voice.BudgetLedgerConcurrencyTest do
  @moduledoc """
  Concurrent reserve admission proof for VOICE-24 (partial — Session does not
  yet close the backend or emit the notice/signal; see VP-04).
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Voice.BudgetLedger
  alias Arbor.Voice.BudgetLedger.Reservation
  alias Arbor.Voice.Test.BudgetLedgerFakeBackend, as: Fake

  defp vres(seed) do
    suffix =
      seed
      |> :erlang.phash2()
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(32, "0")
      |> String.slice(-32, 32)

    "vres_" <> suffix
  end

  @tag spec: "VOICE-24"
  test "many simultaneous reservations for one user/day admit no more than the limit and preserve one fenced record" do
    name = :"budget_ledger_concurrency_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Fake.start_link(agent_name: name)
    on_exit(fn -> Fake.stop(name) end)

    opts = [backend: Fake, backend_opts: [agent_name: name]]
    daily_limit = 500
    per_reserve = 100
    attempts = 12

    results =
      1..attempts
      |> Task.async_stream(
        fn i ->
          BudgetLedger.reserve(
            "user-1",
            "2026-08-02",
            per_reserve,
            daily_limit,
            opts ++ [reservation_id: vres(Integer.to_string(i))]
          )
        end,
        max_concurrency: attempts,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, fn
             {:ok, %Reservation{}} -> true
             {:error, :budget_exhausted} -> true
             {:error, :contention} -> true
             _other -> false
           end)

    admitted = Enum.count(results, &match?({:ok, _}, &1))
    assert admitted >= 1
    assert admitted * per_reserve <= daily_limit

    assert {:ok, remaining} = BudgetLedger.remaining("user-1", "2026-08-02", daily_limit, opts)
    assert remaining == daily_limit - admitted * per_reserve

    key =
      Enum.find_value(results, fn
        {:ok, %Reservation{key: key}} -> key
        _other -> nil
      end)

    record = Fake.peek(name, key)
    assert record.generation == 1
    assert record.revision == admitted
  end
end
