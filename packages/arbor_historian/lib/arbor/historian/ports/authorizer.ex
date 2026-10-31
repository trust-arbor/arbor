defmodule Arbor.Historian.Ports.Authorizer do
  @moduledoc false
  @behaviour Arbor.Historian.Contracts.Authorizer
  alias Arbor.Historian.Config
  @callbacks [authorize: 4, authorize_self_scoped: 6]

  @impl true
  def authorize(principal, resource, action, opts),
    do: invoke(:authorize, [principal, resource, action, opts])

  @impl true
  def authorize_self_scoped(principal, resource, owner, prefix, action, opts),
    do: invoke(:authorize_self_scoped, [principal, resource, owner, prefix, action, opts])

  defp invoke(function, args) do
    provider = Config.authorizer()

    if is_atom(provider) and provider not in [nil, true, false, __MODULE__] and
         Code.ensure_loaded?(provider) and
         Enum.all?(@callbacks, fn {name, arity} -> function_exported?(provider, name, arity) end) do
      case apply(provider, function, args) do
        {:ok, :authorized} = result -> result
        {:ok, :pending_approval, id} = result when is_binary(id) -> result
        {:error, _} = error -> error
        _ -> {:error, :invalid_authorization_reply}
      end
    else
      {:error, :security_provider_unavailable}
    end
  rescue
    _ -> {:error, :security_provider_unavailable}
  catch
    _, _ -> {:error, :security_provider_unavailable}
  end
end
