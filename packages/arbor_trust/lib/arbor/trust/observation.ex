defmodule Arbor.Trust.Observation do
  @moduledoc "Optional trusted observation adapter, with no implicit product provider."
  def emit(category, type, data, opts \\ []) do
    case Application.get_env(:arbor_trust, :observation) do
      nil ->
        :ok

      provider when is_atom(provider) and provider not in [true, false] ->
        if Code.ensure_loaded?(provider) and function_exported?(provider, :emit, 4),
          do: provider.emit(category, type, data, opts),
          else: :ok

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
