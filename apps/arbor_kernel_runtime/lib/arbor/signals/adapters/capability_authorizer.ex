defmodule Arbor.Signals.Adapters.CapabilityAuthorizer do
  @moduledoc """
  Capability-based subscription authorizer.

  Checks whether a principal has a capability granting access to
  `arbor://signals/subscribe/<topic>` by forwarding a bounded request to
  the configured authorization provider (`:security_module`).

  The provider is selected via `Arbor.Signals.Config.security_module/0`.
  Standalone and test default is `nil` (fail closed). Non-test runtime
  injects the production implementation.

  This authorizer does not verify session tokens. When `:session_token`
  is present it is forwarded raw so the provider retains identity,
  binding, redaction, capability, approval, and audit enforcement.

  Missing, invalid, or failing providers deny with `{:error, :no_capability}`.
  """

  @behaviour Arbor.Signals.Behaviours.SubscriptionAuthorizer
  @behaviour Arbor.Signals.Behaviours.ChannelPrincipalAuthorizer

  require Logger

  alias Arbor.Contracts.Security.AuthContext
  alias Arbor.Signals.Config
  alias Arbor.Signals.Provider

  @impl true
  def authorize_subscription(principal_id, topic, opts \\ []) do
    resource_uri = "arbor://signals/subscribe/#{topic}"
    auth_opts = bounded_session_opts(opts)

    case Provider.resolve(Config.security_module(), :authorize, 4) do
      {:ok, provider} ->
        map_authorize_result(
          Provider.invoke(provider, :authorize, [
            principal_id,
            resource_uri,
            :subscribe,
            auth_opts
          ])
        )

      {:error, _reason} ->
        Logger.warning(
          "CapabilityAuthorizer: security module #{inspect(Config.security_module())} not loaded, " <>
            "denying subscription for #{inspect(principal_id)} to #{inspect(resource_uri)}"
        )

        {:error, :no_capability}
    end
  rescue
    error ->
      Logger.error(
        "CapabilityAuthorizer: error checking capability for #{inspect(principal_id)} " <>
          "on topic #{inspect(topic)}: #{inspect(error)}"
      )

      {:error, :no_capability}
  catch
    :throw, _ -> {:error, :no_capability}
    :exit, _ -> {:error, :no_capability}
  end

  @impl Arbor.Signals.Behaviours.ChannelPrincipalAuthorizer
  def authorize_channel_principal(%AuthContext{} = auth_context, operation, channel_id)
      when is_atom(operation) and (is_binary(channel_id) or is_nil(channel_id)) do
    with {:ok, principal_id, auth_opts} <- channel_auth_opts(auth_context),
         {:ok, provider} <- Provider.resolve(Config.security_module(), :authorize, 4),
         resource_uri = channel_resource_uri(operation, channel_id),
         {:ok, {:ok, :authorized}} <-
           Provider.invoke(provider, :authorize, [
             principal_id,
             resource_uri,
             operation,
             auth_opts
           ]) do
      {:ok, principal_id}
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  def authorize_channel_principal(_auth_context, _operation, _channel_id),
    do: {:error, :unauthorized}

  defp map_authorize_result({:ok, {:ok, :authorized}}), do: {:ok, :authorized}

  defp map_authorize_result({:ok, {:ok, :pending_approval, _id}}),
    do: {:error, :pending_approval}

  defp map_authorize_result({:ok, {:error, _reason}}), do: {:error, :no_capability}
  defp map_authorize_result({:ok, _malformed}), do: {:error, :no_capability}
  defp map_authorize_result({:error, :provider_raised, _mod}), do: {:error, :no_capability}
  defp map_authorize_result({:error, :provider_threw}), do: {:error, :no_capability}
  defp map_authorize_result({:error, :provider_exited}), do: {:error, :no_capability}

  defp bounded_session_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      Enum.map(Keyword.get_values(opts, :session_token), &{:session_token, &1})
    else
      []
    end
  rescue
    _ -> []
  end

  defp bounded_session_opts(_opts), do: []

  defp channel_auth_opts(%AuthContext{
         principal_id: principal_id,
         signed_request: signed_request
       })
       when is_binary(principal_id) and principal_id != "" and not is_nil(signed_request) do
    {:ok, principal_id, [signed_request: signed_request, verify_identity: true]}
  end

  defp channel_auth_opts(_auth_context), do: {:error, :identity_proof_required}

  defp channel_resource_uri(operation, nil),
    do: "arbor://signals/channel/#{operation}"

  defp channel_resource_uri(operation, channel_id) do
    digest = :crypto.hash(:sha256, channel_id) |> Base.encode16(case: :lower)
    "arbor://signals/channel/#{operation}/#{digest}"
  end

  @doc false
  def security_module, do: Config.security_module()
end
