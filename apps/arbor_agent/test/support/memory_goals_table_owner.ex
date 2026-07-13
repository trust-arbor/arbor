defmodule Arbor.Agent.Test.MemoryGoalsTableOwner do
  @moduledoc false

  # Test-only ETS owner for `:arbor_memory_goals` when arbor_memory is not
  # started (isolated agent test env). Supervised under AppSupervisor so
  # application shutdown reaps the owner and its named table instead of
  # leaving an unsupervised forever-sleeping process.

  use GenServer

  @table :arbor_memory_goals

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case :ets.whereis(@table) do
      :undefined ->
        _ =
          :ets.new(@table, [
            :named_table,
            :public,
            :set
          ])

        {:ok, %{table: @table, created: true}}

      _tid ->
        # Another owner (e.g. live GoalStore) already holds the table.
        {:ok, %{table: @table, created: false}}
    end
  rescue
    ArgumentError ->
      # Race: table appeared between whereis and new — treat as present.
      {:ok, %{table: @table, created: false}}
  end
end
