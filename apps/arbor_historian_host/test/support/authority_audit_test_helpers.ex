defmodule Arbor.Historian.AuthorityAuditTestHelpers do
  @moduledoc false

  use Boundary, top_level?: true, deps: [Arbor.Historian, Arbor.Security, ExUnit], exports: :all

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Arbor.Historian.AuthorityAuditPuller

  defmodule LegacyEventLog do
    @moduledoc false
    @behaviour Arbor.Security.Contracts.EventLogAdapter

    @impl true
    def persist_security_event(_type, _data), do: :ok

    @impl true
    def read_security_events(_opts), do: {:ok, []}
  end

  def isolate_legacy_events! do
    previous = Application.fetch_env(:arbor_capabilities, :event_log_adapter)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_capabilities, :event_log_adapter, value)
        :error -> Application.delete_env(:arbor_capabilities, :event_log_adapter)
      end
    end)

    # This collaborator handles the older observability stream only. The
    # authority mutation journal, SQL target, and content ACK remain real.
    # Set it explicitly instead of inheriting Security's test_helper config.
    Application.put_env(:arbor_capabilities, :event_log_adapter, LegacyEventLog)
  end

  def prepare_manual_puller! do
    if Process.get({__MODULE__, :manual_consumer_bound}) do
      :ok
    else
      bind_manual_consumer()
    end
  end

  defp bind_manual_consumer do
    keys = [:authority_audit_consumer_name, :authority_audit_consumer_application]
    previous = Map.new(keys, &{&1, Application.fetch_env(:arbor_capabilities, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_capabilities, key, value)
        {key, :error} -> Application.delete_env(:arbor_capabilities, key)
      end)
    end)

    # Core's test bootstrap may bind its own synthetic consumer. This fixture
    # explicitly owns the real named puller and restores both prior bindings.
    Application.put_env(:arbor_capabilities, :authority_audit_consumer_name, AuthorityAuditPuller)
    Application.put_env(:arbor_capabilities, :authority_audit_consumer_application, :test)
    Process.put({__MODULE__, :manual_consumer_bound}, true)
    :ok
  end

  def start_manual_puller! do
    :ok = prepare_manual_puller!()
    pid = start_supervised!({AuthorityAuditPuller, poll_interval_ms: 60_000})
    %{timer: timer} = :sys.get_state(pid)

    # These protocol lanes own all delivery through public explicit flushes.
    # Cancel the initial timer before any workload; flush never rearms it.
    # A slow CI run must not race an unrelated background delivery count.
    assert is_integer(Process.cancel_timer(timer))
    pid
  end
end
