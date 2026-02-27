defmodule Arbor.AI.AcpPool.Supervisor do
  @moduledoc """
  DynamicSupervisor for AcpSession processes managed by the AcpPool.

  Sessions are started on-demand via `DynamicSupervisor.start_child/2`
  when the pool needs to create a new session for a provider.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
