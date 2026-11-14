defmodule Arbor.Gateway.CommittedDevKey do
  @moduledoc """
  Refuse the committed `arbor-dev-key` literal outside local loopback `:dev`.

  `config/dev.exs` ships this well-known key for local MCP. It must not
  survive into a non-dev Mix env or a non-loopback bind (Exposure Check
  group X / Symantec Skynet, 2026-10-23).
  """

  @committed_dev_key "arbor-dev-key"

  @doc "The exact literal shipped in `config/dev.exs`."
  @spec committed_dev_key() :: String.t()
  def committed_dev_key, do: @committed_dev_key

  @doc "True when `key` is the committed development literal."
  @spec committed_dev_key?(term()) :: boolean()
  def committed_dev_key?(key) when is_binary(key), do: String.trim(key) == @committed_dev_key
  def committed_dev_key?(_key), do: false

  @doc """
  Admit a configured gateway API key.

  Options (atom keys only):

    * `:api_key` — key to check (default: env then application env)
    * `:env` — Mix env (default: runtime Mix env, or `:prod` without Mix)
    * `:bind_ip` — listener address (default: `:arbor_gateway` `:bind_ip`)
  """
  @spec admit(keyword()) :: :ok | {:error, String.t()}
  def admit(opts \\ []) when is_list(opts) do
    key = fetch_key(opts)
    env = Keyword.get(opts, :env, runtime_env())
    bind_ip = Keyword.get(opts, :bind_ip, configured_bind_ip())

    cond do
      not committed_dev_key?(key) ->
        :ok

      env != :dev ->
        {:error, not_dev_message(env)}

      not loopback_bind?(bind_ip) ->
        {:error, non_loopback_message(bind_ip)}

      true ->
        :ok
    end
  end

  @doc """
  Boot-time check. Returns `{:error, {:committed_dev_key_refused, message}}`
  when the committed development key is not admissible.
  """
  @spec boot_check(keyword()) :: :ok | {:error, {:committed_dev_key_refused, String.t()}}
  def boot_check(opts \\ []) when is_list(opts) do
    case admit(opts) do
      :ok -> :ok
      {:error, message} -> {:error, {:committed_dev_key_refused, message}}
    end
  end

  @doc "True when `bind_ip` is a loopback address."
  @spec loopback_bind?(term()) :: boolean()
  def loopback_bind?({127, a, b, c})
      when a in 0..255 and b in 0..255 and c in 0..255,
      do: true

  def loopback_bind?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback_bind?(:loopback), do: true

  def loopback_bind?(addr) when is_binary(addr) do
    normalized = addr |> String.trim() |> String.downcase() |> strip_brackets()

    case :inet.parse_address(String.to_charlist(normalized)) do
      {:ok, ip} -> loopback_bind?(ip)
      {:error, _reason} -> normalized == "localhost"
    end
  end

  def loopback_bind?(_bind_ip), do: false

  @doc """
  Configured gateway API key. Environment wins over application env so the
  committed `config/dev.exs` literal cannot shadow `ARBOR_GATEWAY_API_KEY`.
  """
  @spec configured_key() :: String.t() | nil
  def configured_key do
    case System.get_env("ARBOR_GATEWAY_API_KEY") do
      key when is_binary(key) and key != "" -> key
      _ -> Application.get_env(:arbor_gateway, :api_key)
    end
  end

  defp fetch_key(opts) do
    case Keyword.fetch(opts, :api_key) do
      {:ok, key} -> key
      :error -> configured_key()
    end
  end

  defp configured_bind_ip do
    Application.get_env(:arbor_gateway, :bind_ip, {127, 0, 0, 1})
  end

  # Releases do not load Mix. Missing Mix is treated as not-dev (fail closed).
  defp runtime_env do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      Mix.env()
    else
      :prod
    end
  end

  defp strip_brackets("[" <> rest), do: String.trim_trailing(rest, "]")
  defp strip_brackets(host), do: host

  defp not_dev_message(env) do
    "Committed development API key 'arbor-dev-key' is not allowed when MIX_ENV is " <>
      "#{inspect(env)} (only :dev on a loopback bind). Set a unique ARBOR_GATEWAY_API_KEY."
  end

  defp non_loopback_message(bind_ip) do
    "Committed development API key 'arbor-dev-key' is not allowed when the gateway " <>
      "binds a non-loopback address (#{inspect(bind_ip)}). Bind 127.0.0.1 or set a " <>
      "unique ARBOR_GATEWAY_API_KEY."
  end
end
