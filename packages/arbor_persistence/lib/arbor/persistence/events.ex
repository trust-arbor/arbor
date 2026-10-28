defmodule Arbor.Persistence.Events do
  @moduledoc false

  @spec available?() :: boolean()
  def available?, do: not is_nil(provider())

  @spec emit(atom(), atom(), map(), keyword()) :: :ok
  def emit(category, type, data, opts \\ []) do
    if provider = provider(), do: apply(provider, :emit, [category, type, data, opts])
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @spec subscribe(String.t(), function()) :: term()
  def subscribe(topic, callback) do
    if provider = provider(),
      do: apply(provider, :subscribe, [topic, callback]),
      else: {:error, :unavailable}
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp provider do
    provider = Application.get_env(:arbor_persistence, :event_bus)

    if is_atom(provider) and provider not in [nil, true, false] and
         Code.ensure_loaded?(provider) and function_exported?(provider, :emit, 4) and
         function_exported?(provider, :subscribe, 2),
       do: provider,
       else: nil
  end
end
