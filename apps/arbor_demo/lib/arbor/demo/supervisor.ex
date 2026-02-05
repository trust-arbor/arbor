defmodule Arbor.Demo.Supervisor do
  @moduledoc false
  use DynamicSupervisor

  def start_link(opts) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    DynamicSupervisor.start_link(__MODULE__, [], gen_opts)
  end

  def start_child(supervisor \\ __MODULE__, child_spec) do
    DynamicSupervisor.start_child(supervisor, child_spec)
  end

  def terminate_child(supervisor \\ __MODULE__, pid) do
    DynamicSupervisor.terminate_child(supervisor, pid)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
