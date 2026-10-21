defmodule Arbor.Web.LoopbackHost do
  @moduledoc """
  Host-header allowlist for no-auth (dev) Arbor dashboards.

  Binding the listener to `127.0.0.1` does not stop DNS rebinding: a page
  served on a public name can resolve that name to loopback and send
  `Host: evil.example` (and `Origin: http://evil.example`) to the no-auth
  operator UI. Every such request used to become `human_dashboard`.

  This module is the single policy for:

    * rejecting non-loopback Host headers with 403 before Tidewave and
      dashboard plugs run
    * deciding whether `OidcAuth` may mint the local operator session
    * building the loopback `check_origin` allowlist

  Operators who genuinely need LAN access can set `ARBOR_DEV_ALLOW_ANY_HOST=1`
  or add names via `ARBOR_DEV_ALLOWED_HOSTS`. Production (`require_auth: true`)
  is not gated here — it already uses a real identity provider and its own
  `check_origin` list.
  """

  import Plug.Conn

  @behaviour Plug

  @loopback_hosts MapSet.new(["localhost", "127.0.0.1", "::1", "[::1]"])

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    if enforced?(opts) and not allowed_host?(conn, opts) do
      conn
      |> send_resp(403, "Forbidden host")
      |> halt()
    else
      conn
    end
  end

  @doc """
  Whether the no-auth Host allowlist is active for this endpoint.
  """
  @spec enforced?(keyword()) :: boolean()
  def enforced?(opts \\ []) do
    cond do
      allow_any_host?(opts) -> false
      require_auth?(opts) -> false
      restrict_flag(opts) == false -> false
      restrict_flag(opts) == true -> true
      otp_app(opts) == :arbor_dashboard -> true
      true -> false
    end
  end

  @doc """
  True when `conn.host` is loopback or an operator-allowlisted LAN host.
  """
  @spec allowed_host?(Plug.Conn.t() | String.t(), keyword()) :: boolean()
  def allowed_host?(conn_or_host, opts \\ [])

  def allowed_host?(%Plug.Conn{host: host}, opts), do: allowed_host?(host, opts)

  def allowed_host?(host, opts) when is_binary(host) do
    normalized = normalize_host(host)
    MapSet.member?(loopback_hosts(), normalized) or extra_host?(normalized, opts)
  end

  def allowed_host?(_, _opts), do: false

  @doc "Canonical loopback hostnames accepted by the no-auth allowlist."
  @spec loopback_hosts() :: MapSet.t(String.t())
  def loopback_hosts, do: @loopback_hosts

  @doc """
  Origins Phoenix `check_origin` should allow in no-auth mode.
  """
  @spec allowed_origins(pos_integer(), [String.t()]) :: [String.t()]
  def allowed_origins(port, extra_hosts \\ [])
      when is_integer(port) and port > 0 and is_list(extra_hosts) do
    (["localhost", "127.0.0.1", "[::1]"] ++ Enum.map(extra_hosts, &normalize_host/1))
    |> Enum.uniq()
    |> Enum.map(&"http://#{&1}:#{port}")
  end

  @doc "True when the operator opted out of the Host allowlist."
  @spec allow_any_host?(keyword()) :: boolean()
  def allow_any_host?(opts \\ []) do
    case Keyword.fetch(opts, :allow_any_host) do
      {:ok, value} ->
        truthy?(value)

      :error ->
        truthy?(Application.get_env(:arbor_web, :dev_allow_any_host, false))
    end
  end

  defp extra_host?(host, opts) do
    extras =
      case Keyword.fetch(opts, :allowed_hosts) do
        {:ok, hosts} when is_list(hosts) -> hosts
        :error -> Application.get_env(:arbor_web, :dev_allowed_hosts, [])
      end

    extras
    |> List.wrap()
    |> Enum.map(&normalize_host/1)
    |> Enum.member?(host)
  end

  defp require_auth?(opts) do
    case Keyword.fetch(opts, :require_auth) do
      {:ok, value} ->
        truthy?(value)

      :error ->
        truthy?(Application.get_env(otp_app(opts), :require_auth, false))
    end
  end

  defp restrict_flag(opts) do
    case Keyword.fetch(opts, :restrict_dev_hosts) do
      {:ok, value} -> value
      :error -> Application.get_env(otp_app(opts), :restrict_dev_hosts)
    end
  end

  defp otp_app(opts), do: Keyword.get(opts, :otp_app, :arbor_dashboard)

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> strip_host_port()
  end

  defp normalize_host(_), do: ""

  defp strip_host_port("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [ipv6, _port] -> "[" <> ipv6 <> "]"
      [ipv6] -> "[" <> String.trim_trailing(ipv6, "]") <> "]"
    end
  end

  defp strip_host_port(host) do
    case String.split(host, ":", parts: 2) do
      [name, port] ->
        if numeric_port?(port), do: name, else: host

      [name] ->
        name
    end
  end

  defp numeric_port?(port) do
    case Integer.parse(port) do
      {value, ""} when value > 0 and value < 65_536 -> true
      _ -> false
    end
  end

  defp truthy?(true), do: true
  defp truthy?(false), do: false
  defp truthy?(1), do: true
  defp truthy?(0), do: false
  defp truthy?(value) when is_binary(value), do: String.downcase(value) in ~w(1 true yes)
  defp truthy?(_), do: false
end
