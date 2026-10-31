defmodule Arbor.Historian.Ports.Observation do
  @moduledoc false
  alias Arbor.Historian.Config

  def emit(category, type, data) do
    case Config.event_provider() do
      provider when is_atom(provider) and provider not in [nil, true, false, __MODULE__] ->
        provider.emit(category, type, data)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
