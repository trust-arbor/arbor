defmodule Arbor.Persistence.AuthorizationProviderTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.{Core, Event, EventLog, Store}

  defmodule Provider do
    def authorize(principal, resource, operation, opts) do
      send(self(), {:authorization_request, principal, resource, operation, opts})

      case Process.get({__MODULE__, :response}) do
        :raise -> raise "provider fault"
        :throw -> throw(:provider_fault)
        :exit -> exit(:provider_fault)
        response -> response
      end
    end
  end

  setup do
    previous = Application.fetch_env(:arbor_persistence, :authorization_provider)
    Application.delete_env(:arbor_persistence, :authorization_provider)
    store = unique_name(:authorization_store)
    log = unique_name(:authorization_log)
    start_supervised!({Store.ETS, name: store})
    start_supervised!({EventLog.ETS, name: log})

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_persistence, :authorization_provider, value)
        :error -> Application.delete_env(:arbor_persistence, :authorization_provider)
      end
    end)

    %{store: store, log: log}
  end

  test "missing and malformed providers deny without a write", %{store: store} do
    for provider <- [nil, false, true, :missing_persistence_authorizer, %{}] do
      Application.put_env(:arbor_persistence, :authorization_provider, provider)

      assert {:error, {:unauthorized, :authorization_unavailable}} =
               Core.authorize_write("principal", store, Store.ETS, "key", "secret")

      assert {:error, :not_found} = Core.get(store, Store.ETS, "key")
    end
  end

  test "provider failure or malformed responses cannot perform effects", %{store: store, log: log} do
    Application.put_env(:arbor_persistence, :authorization_provider, Provider)

    for response <- [:raise, :throw, :exit, nil, :ok, {:ok, true}, {:ok, :pending_approval, nil}] do
      Process.put({Provider, :response}, response)

      assert {:error, {:unauthorized, _}} =
               Core.authorize_write("principal", store, Store.ETS, "key", "secret")

      assert {:error, {:unauthorized, _}} =
               Core.authorize_append(
                 "principal",
                 log,
                 EventLog.ETS,
                 "stream",
                 Event.new("stream", "event", %{})
               )

      assert {:error, :not_found} = Core.get(store, Store.ETS, "key")
      refute Core.stream_exists?(log, EventLog.ETS, "stream")
    end
  end

  test "pending approval is preserved without an effect", %{store: store} do
    Application.put_env(:arbor_persistence, :authorization_provider, Provider)
    Process.put({Provider, :response}, {:ok, :pending_approval, "proposal"})

    assert {:ok, :pending_approval, "proposal"} =
             Core.authorize_write("principal", store, Store.ETS, "key", "secret")

    assert {:error, :not_found} = Core.get(store, Store.ETS, "key")
  end

  test "allowed request keeps resource, operation and trace binding", %{store: store} do
    Application.put_env(:arbor_persistence, :authorization_provider, Provider)
    Process.put({Provider, :response}, {:ok, :authorized})

    assert :ok =
             Core.authorize_write("principal", store, Store.ETS, "key", "value",
               trace_id: "trace"
             )

    assert_receive {:authorization_request, "principal", resource, :write, [trace_id: "trace"]}
    assert resource == "arbor://persistence/write/#{store}"
    assert {:ok, "value"} = Core.authorize_read("principal", store, Store.ETS, "key")
  end

  defp unique_name(prefix) do
    # A bounded number of test-owned names, never an external identifier.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
