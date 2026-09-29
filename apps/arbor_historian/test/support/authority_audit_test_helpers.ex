defmodule Arbor.Historian.AuthorityAuditTestHelpers do
  @moduledoc false

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
    previous = Application.fetch_env(:arbor_security, :event_log_adapter)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_security, :event_log_adapter, value)
        :error -> Application.delete_env(:arbor_security, :event_log_adapter)
      end
    end)

    # This collaborator handles the older observability stream only. The
    # authority mutation journal, SQL target, and content ACK remain real.
    # Set it explicitly instead of inheriting Security's test_helper config.
    Application.put_env(:arbor_security, :event_log_adapter, LegacyEventLog)
  end

  def start_manual_puller! do
    pid = start_supervised!({AuthorityAuditPuller, poll_interval_ms: 60_000})
    %{timer: timer} = :sys.get_state(pid)

    # These protocol lanes own all delivery through public explicit flushes.
    # Cancel the initial timer before any workload; flush never rearms it.
    # A slow CI run must not race an unrelated background delivery count.
    assert is_integer(Process.cancel_timer(timer))
    pid
  end
end
