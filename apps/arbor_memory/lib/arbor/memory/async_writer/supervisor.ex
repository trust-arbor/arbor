defmodule Arbor.Memory.AsyncWriter.Supervisor do
  @moduledoc false

  alias Arbor.Memory.Config

  @name __MODULE__

  @doc false
  def child_spec(opts) do
    name = Keyword.get(opts, :name, @name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)

    case Config.async_writer_max_children() do
      {:ok, max_children} ->
        DynamicSupervisor.start_link(
          name: name,
          strategy: :one_for_one,
          max_children: max_children,
          max_restarts: 100,
          max_seconds: 1
        )

      {:error, :invalid_config} ->
        {:error, :invalid_config}
    end
  end

  @doc false
  def name, do: @name
end
