defmodule Arbor.Shell.ValidationRuntime.Oci do
  @moduledoc false

  @behaviour Arbor.Shell.ValidationRuntime

  alias Arbor.Shell.OciExecutor
  alias Arbor.Shell.OciProber
  alias Arbor.Shell.SpawnCapableTimeout

  @impl true
  @spec execute(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def execute(tool_name, args, opts), do: OciExecutor.execute(tool_name, args, opts)

  @impl true
  @spec probe() :: {:ok, map()} | {:error, term()}
  def probe do
    probe(SpawnCapableTimeout.max_probe_deadline_ms())
  end

  @impl true
  @spec probe(term()) :: {:ok, map()} | {:error, term()}
  def probe(deadline_ms) do
    case OciProber.probe(deadline_ms) do
      {:ok, _admission} -> {:ok, public_status()}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec public_status() :: map()
  def public_status do
    %{"state" => "available", "driver" => "podman"}
  end
end
