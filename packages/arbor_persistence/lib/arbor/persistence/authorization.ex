defmodule Arbor.Persistence.Authorization do
  @moduledoc false

  @spec authorize(term(), String.t(), atom(), keyword()) :: term()
  def authorize(principal, resource, action, opts) do
    provider = Application.get_env(:arbor_persistence, :authorization_provider)

    if is_atom(provider) and provider not in [nil, true, false] and
         Code.ensure_loaded?(provider) and function_exported?(provider, :authorize, 4) do
      case apply(provider, :authorize, [principal, resource, action, opts]) do
        {:ok, :authorized} = result -> result
        {:ok, :pending_approval, id} = result when is_binary(id) -> result
        {:error, _} = result -> result
        _ -> {:error, :invalid_authorization_response}
      end
    else
      {:error, :authorization_unavailable}
    end
  rescue
    _ -> {:error, :authorization_unavailable}
  catch
    _, _ -> {:error, :authorization_unavailable}
  end
end
