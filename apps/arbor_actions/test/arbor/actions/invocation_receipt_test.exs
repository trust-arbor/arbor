defmodule Arbor.Actions.InvocationReceiptTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  defmodule Sink do
    def persist_security_invocation(event) do
      send(Application.fetch_env!(:arbor_security, :receipt_observer), {:event, event})

      if Application.get_env(:arbor_security, :receipt_fail) == event["stage"],
        do: {:error, :unavailable},
        else: {:ok, event["id"]}
    end
  end

  setup do
    keys = [:invocation_audit_mode, :invocation_audit_sink, :receipt_observer, :receipt_fail]
    prior = Map.new(keys, &{&1, Application.fetch_env(:arbor_security, &1)})
    Application.put_env(:arbor_security, :invocation_audit_mode, :required)
    Application.put_env(:arbor_security, :invocation_audit_sink, Sink)
    Application.put_env(:arbor_security, :receipt_observer, self())
    Application.delete_env(:arbor_security, :receipt_fail)

    on_exit(fn ->
      Enum.each(prior, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_security, key, value)
        {key, :error} -> Application.delete_env(:arbor_security, key)
      end)
    end)

    :ok
  end

  test "public receipt identifies actual refusal and preserves ordinary result shape" do
    receipt =
      Arbor.Actions.authorize_and_execute_with_receipt(
        "agent_absent_receipt",
        Arbor.Actions.File.Read,
        %{path: "/synthetic"},
        %{invocation_id: "forged"}
      )

    assert {:error, _} = receipt.result
    assert_receive {:event, %{"stage" => "attempt", "invocation_id" => id}}
    assert receipt.invocation_id == id and id != "forged"

    assert_receive {:event,
                    %{"stage" => "outcome", "invocation_id" => ^id, "outcome" => "refused"}}

    assert {:error, _} =
             Arbor.Actions.authorize_and_execute(
               "agent_absent_receipt",
               Arbor.Actions.File.Read,
               %{path: "/synthetic"}
             )

    assert nil == Arbor.Security.current_invocation_id()
  end

  test "missing initial ACK cannot create a receipt claiming execution" do
    Application.put_env(:arbor_security, :receipt_fail, "attempt")

    assert %{result: {:error, :invocation_audit_unavailable}, invocation_id: nil} =
             Arbor.Actions.authorize_and_execute_with_receipt(
               "agent_absent_receipt",
               Arbor.Actions.File.Read,
               %{path: "/synthetic"}
             )

    refute_receive {:event, %{"stage" => "outcome"}}
  end

  test "terminal audit failure retains exact action refusal but does not invent durable completion" do
    Application.put_env(:arbor_security, :receipt_fail, "outcome")

    assert %{result: {:error, _}, invocation_id: id} =
             Arbor.Actions.authorize_and_execute_with_receipt(
               "agent_absent_receipt",
               Arbor.Actions.File.Read,
               %{path: "/synthetic"}
             )

    assert is_binary(id)
  end
end
