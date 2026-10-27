defmodule Arbor.Signals.AuthorizationContext do
  @moduledoc false

  alias Arbor.Signals.{Config, Provider}

  @spec valid?(term()) :: boolean()
  def valid?(context), do: match?({:ok, _principal_id}, principal_id(context))

  @spec principal_id(term()) :: {:ok, String.t()} | {:error, :authenticated_principal_required}
  def principal_id(context) do
    with {:ok, provider} <- Provider.resolve(Config.auth_context_module(), :principal_id, 1),
         {:ok, {:ok, principal_id}} <- Provider.invoke(provider, :principal_id, [context]),
         true <- is_binary(principal_id) and principal_id != "" do
      {:ok, principal_id}
    else
      _invalid -> {:error, :authenticated_principal_required}
    end
  rescue
    _ -> {:error, :authenticated_principal_required}
  catch
    _, _ -> {:error, :authenticated_principal_required}
  end

  @spec signed_request(term()) :: {:ok, term()} | {:error, :identity_proof_required}
  def signed_request(context) do
    with {:ok, _principal_id} <- principal_id(context),
         {:ok, provider} <- Provider.resolve(Config.auth_context_module(), :signed_request, 1),
         {:ok, {:ok, signed_request}} <- Provider.invoke(provider, :signed_request, [context]),
         false <- is_nil(signed_request) do
      {:ok, signed_request}
    else
      _invalid -> {:error, :identity_proof_required}
    end
  rescue
    _ -> {:error, :identity_proof_required}
  catch
    _, _ -> {:error, :identity_proof_required}
  end
end
