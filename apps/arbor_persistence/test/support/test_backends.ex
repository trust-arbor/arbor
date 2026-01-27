defmodule Arbor.Persistence.TestBackends do
  @moduledoc """
  Test backends that simulate failures for error-path testing.
  """

  defmodule FailingStore do
    @behaviour Arbor.Persistence.Store

    @impl true
    def put(_key, _value, _opts), do: {:error, :write_failed}

    @impl true
    def get(_key, _opts), do: {:error, :read_failed}

    @impl true
    def delete(_key, _opts), do: {:error, :delete_failed}

    @impl true
    def list(_opts), do: {:error, :list_failed}

    @impl true
    def exists?(_key, _opts), do: false
  end

  defmodule FailingEventLog do
    @behaviour Arbor.Persistence.EventLog

    @impl true
    def append(_stream_id, _events, _opts), do: {:error, :append_failed}

    @impl true
    def read_stream(_stream_id, _opts), do: {:error, :read_failed}

    @impl true
    def read_all(_opts), do: {:error, :read_failed}

    @impl true
    def stream_exists?(_stream_id, _opts), do: false

    @impl true
    def stream_version(_stream_id, _opts), do: {:error, :version_failed}
  end
end
