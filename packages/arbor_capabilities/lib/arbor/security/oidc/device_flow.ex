defmodule Arbor.Security.OIDC.DeviceFlow do
  @moduledoc """
  Compatibility facade for the optional device-authorization protocol adapter.
  """

  alias Arbor.Security.OIDC.Adapter

  @spec start(map()) :: {:ok, map()} | {:error, term()}
  def start(config), do: Adapter.call(:start_device_flow, [config])

  @spec poll(map(), map()) :: {:ok, map()} | {:error, term()}
  def poll(config, device_response),
    do: Adapter.call(:poll_device_flow, [config, device_response])

  @spec refresh(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def refresh(config, refresh_token),
    do: Adapter.call(:refresh_device_flow, [config, refresh_token])
end
