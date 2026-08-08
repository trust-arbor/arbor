defmodule Arbor.Persistence.EventStreamAbsenceSecurityRegressionTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence

  defmodule MalformedBackend do
    def stream_absent(_stream_id, _opts), do: nil
  end

  defmodule RaisingBackend do
    def stream_absent(_stream_id, _opts), do: raise("simulated absence backend failure")
  end

  defmodule BlockingBackend do
    def stream_absent(_stream_id, _opts), do: Process.sleep(:infinity)
  end

  defmodule UnsupportedBackend do
  end

  test "security regression: public stream absence fails closed on backend uncertainty" do
    stream_id = "event-stream-absence-security-regression"
    store_name = :event_stream_absence_security_regression

    for backend <- [MalformedBackend, RaisingBackend] do
      assert {:error, {:absence_indeterminate, ^stream_id}} =
               apply(Persistence, :event_stream_absent?, [store_name, backend, stream_id, []])
    end

    assert {:error, {:absence_indeterminate, ^stream_id}} =
             apply(Persistence, :event_stream_absent?, [
               store_name,
               BlockingBackend,
               stream_id,
               [absence_timeout_ms: 100]
             ])

    assert {:error, :absence_not_supported} =
             apply(Persistence, :event_stream_absent?, [
               store_name,
               UnsupportedBackend,
               stream_id,
               []
             ])
  end
end
