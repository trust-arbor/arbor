defmodule Arbor.Memory.Config do
  @moduledoc false

  @app :arbor_memory
  @target_keys MapSet.new([:name, :backend, :opts, "name", "backend", "opts"])
  @default_maintenance_archive_target %{
    name: :memory_events,
    backend: Arbor.Persistence.EventLog.ETS,
    opts: []
  }

  @type event_log_target :: %{name: atom(), backend: module(), opts: keyword()}

  @spec maintenance_archive_target() ::
          {:ok, event_log_target()} | {:error, :invalid_event_log_target}
  def maintenance_archive_target do
    @app
    |> Application.get_env(:maintenance_archive_target, @default_maintenance_archive_target)
    |> normalize_event_log_target()
  end

  @spec normalize_event_log_target(term()) ::
          {:ok, event_log_target()} | {:error, :invalid_event_log_target}
  def normalize_event_log_target(target) when is_list(target) do
    if closed_keyword?(target) do
      target
      |> Map.new()
      |> normalize_event_log_target()
    else
      {:error, :invalid_event_log_target}
    end
  end

  def normalize_event_log_target(target) when is_map(target) and not is_struct(target) do
    with :ok <- ensure_closed_keys(target),
         {:ok, name} <- fetch_field(target, :name),
         {:ok, backend} <- fetch_field(target, :backend),
         {:ok, opts} <- fetch_opts(target),
         true <- is_atom(name) and not is_nil(name),
         true <- is_atom(backend) and not is_nil(backend),
         true <- closed_keyword?(opts) do
      {:ok, %{name: name, backend: backend, opts: opts}}
    else
      _ -> {:error, :invalid_event_log_target}
    end
  end

  def normalize_event_log_target(_target), do: {:error, :invalid_event_log_target}

  defp ensure_closed_keys(target) do
    if Enum.all?(Map.keys(target), &MapSet.member?(@target_keys, &1)), do: :ok, else: :error
  end

  defp fetch_field(target, atom_key) do
    string_key = Atom.to_string(atom_key)

    case {Map.fetch(target, atom_key), Map.fetch(target, string_key)} do
      {{:ok, _atom_value}, {:ok, _string_value}} -> :error
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> :error
    end
  end

  defp fetch_opts(target) do
    case fetch_field(target, :opts) do
      {:ok, opts} -> {:ok, opts}
      :error -> {:ok, []}
    end
  end

  defp closed_keyword?(list) when is_list(list) do
    with true <- length(list) <= 64,
         true <- Enum.all?(list, &match?({key, _value} when is_atom(key), &1)) do
      keys = Enum.map(list, &elem(&1, 0))
      length(keys) == MapSet.size(MapSet.new(keys))
    else
      _ -> false
    end
  end

  defp closed_keyword?(_list), do: false
end
