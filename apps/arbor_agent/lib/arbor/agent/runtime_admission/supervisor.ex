defmodule Arbor.Agent.RuntimeAdmission.Supervisor do
  @moduledoc """
  DynamicSupervisor for runtime-admission intent owners (Phase 4C C3C1a0).

  Owns target-unique IntentOwner children. TaskStore restart inventory uses
  `which_children/0` as the authoritative presence source.

  Production always starts the fixed `IntentOwner` module — no caller-selected
  owner module. Test-only `start_owner_test/3` may inject a double under
  `Mix.env() == :test`.
  """

  use DynamicSupervisor

  @name __MODULE__
  @fixed_owner Arbor.Agent.RuntimeAdmission.IntentOwner

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: 256)
  end

  @doc "Start a temporary fixed IntentOwner child under this supervisor."
  @spec start_owner(keyword(), GenServer.server()) :: DynamicSupervisor.on_start_child()
  def start_owner(start_opts, supervisor \\ @name) when is_list(start_opts) do
    start_owner_child(@fixed_owner, start_opts, supervisor)
  end

  if Mix.env() == :test do
    @doc false
    @spec start_owner_test(module(), keyword(), GenServer.server()) ::
            DynamicSupervisor.on_start_child()
    def start_owner_test(owner_module, start_opts, supervisor \\ @name)
        when is_atom(owner_module) and is_list(start_opts) do
      start_owner_child(owner_module, start_opts, supervisor)
    end
  end

  defp start_owner_child(owner_module, start_opts, supervisor)
       when is_atom(owner_module) and is_list(start_opts) do
    child = %{
      id: {:runtime_admission_owner, Keyword.fetch!(start_opts, :intent_id)},
      start: {owner_module, :start_link, [start_opts]},
      restart: :temporary,
      type: :worker,
      shutdown: 5_000
    }

    DynamicSupervisor.start_child(supervisor, child)
  end

  @doc "Bounded inventory of live owner children."
  @spec which_children(GenServer.server()) ::
          {:ok, [tuple()]} | {:error, :supervisor_unavailable}
  def which_children(supervisor \\ @name) do
    {:ok, DynamicSupervisor.which_children(supervisor)}
  rescue
    _ -> {:error, :supervisor_unavailable}
  catch
    :exit, _ -> {:error, :supervisor_unavailable}
  end
end