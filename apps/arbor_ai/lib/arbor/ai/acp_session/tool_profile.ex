defmodule Arbor.AI.AcpSession.ToolProfile do
  @moduledoc """
  Imperative shell for `Arbor.AI.AcpSession.ToolProfileCore`: reads the
  agent's capabilities and trust policy through the same injectable seams the
  permission handler uses (`:security_module`, `:trust_policy_module`) and
  returns the derived profile, or `nil` when it cannot be derived.

  Never raises and never blocks a session start: any failure yields `nil`,
  which means "no launch-time restriction; per-call authorization applies".
  """

  alias Arbor.AI.AcpSession.ToolProfileCore

  require Logger

  @spec resolve(String.t() | nil) :: ToolProfileCore.profile() | nil
  def resolve(agent_id) when is_binary(agent_id) and agent_id != "" do
    with {:ok, uris} <- capability_uris(agent_id),
         {:ok, mode_fun} <- mode_fun(agent_id) do
      ToolProfileCore.derive(uris, mode_fun)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  def resolve(_agent_id), do: nil

  @doc "Adapter/handler keyword options for a resolved profile (`[]` when nil)."
  @spec opts(ToolProfileCore.profile() | nil) :: keyword()
  def opts(nil), do: []
  def opts(profile) when is_map(profile), do: ToolProfileCore.adapter_opts(profile)

  defp capability_uris(agent_id) do
    module = Application.get_env(:arbor_ai, :security_module, Arbor.Security)

    if Code.ensure_loaded?(module) and function_exported?(module, :list_capabilities, 2) do
      case module.list_capabilities(agent_id, []) do
        {:ok, capabilities} when is_list(capabilities) ->
          {:ok,
           capabilities
           |> Enum.map(&capability_uri/1)
           |> Enum.filter(&is_binary/1)}

        _other ->
          :error
      end
    else
      :error
    end
  end

  defp capability_uri(%{resource_uri: uri}), do: uri
  defp capability_uri(%{"resource_uri" => uri}), do: uri
  defp capability_uri(_), do: nil

  defp mode_fun(agent_id) do
    module = Application.get_env(:arbor_ai, :trust_policy_module, Arbor.Trust.Policy)

    if Code.ensure_loaded?(module) and function_exported?(module, :confirmation_mode, 2) do
      {:ok, fn uri -> module.confirmation_mode(agent_id, uri) end}
    else
      # No trust policy available: treat every held tool as auto, matching
      # the handler's `:unavailable -> :authorized` behaviour.
      {:ok, fn _uri -> :auto end}
    end
  end
end
