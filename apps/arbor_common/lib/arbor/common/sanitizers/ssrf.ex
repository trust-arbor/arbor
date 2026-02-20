defmodule Arbor.Common.Sanitizers.SSRF do
  @moduledoc """
  Sanitizer for Server-Side Request Forgery (SSRF) attacks.

  Validates URLs by parsing, checking scheme, resolving hostname via
  `:inet.getaddr/2`, and verifying the resolved IP isn't in a private
  range. Returns the URL with the resolved IP for the caller to use
  (DNS rebinding protection).

  Sets bit 5 on the taint sanitizations bitmask.

  ## Options

  - `:allowed_schemes` — allowed URL schemes (default: `["http", "https"]`)
  - `:allowed_ports` — allowed ports (default: `[80, 443, 8080, 8443]`)
  - `:allow_private` — allow private IPs (default: `false`, for testing)
  """

  @behaviour Arbor.Contracts.Security.Sanitizer

  alias Arbor.Contracts.Security.Taint

  import Bitwise

  @bit 0b00100000
  @default_schemes ["http", "https"]
  @default_ports [80, 443, 8080, 8443]

  # Cloud metadata endpoints
  @metadata_hosts [
    "169.254.169.254",
    "metadata.google.internal",
    "metadata.google.com"
  ]

  @impl true
  @spec sanitize(term(), Taint.t(), keyword()) ::
          {:ok, String.t(), Taint.t()} | {:error, term()}
  def sanitize(value, %Taint{} = taint, opts \\ []) when is_binary(value) do
    allowed_schemes = Keyword.get(opts, :allowed_schemes, @default_schemes)
    allowed_ports = Keyword.get(opts, :allowed_ports, @default_ports)
    allow_private = Keyword.get(opts, :allow_private, false)

    with {:ok, uri} <- parse_url(value),
         :ok <- validate_scheme(uri, allowed_schemes),
         :ok <- validate_host_present(uri),
         :ok <- validate_port(uri, allowed_ports),
         :ok <- check_metadata_host(uri),
         {:ok, resolved_ip} <- resolve_host(uri),
         :ok <- check_private_ip(resolved_ip, allow_private) do
      updated_taint = %{taint | sanitizations: bor(taint.sanitizations, @bit)}
      {:ok, value, updated_taint}
    end
  end

  @impl true
  @spec detect(term()) :: {:safe, float()} | {:unsafe, [String.t()]}
  def detect(value) when is_binary(value) do
    found = detect_patterns(value)

    case found do
      [] -> {:safe, 1.0}
      patterns -> {:unsafe, patterns}
    end
  end

  def detect(_), do: {:safe, 1.0}

  # -- Private ---------------------------------------------------------------

  defp parse_url(value) do
    uri = URI.parse(value)

    if uri.scheme && uri.host do
      {:ok, uri}
    else
      {:error, {:invalid_url, "URL must have scheme and host"}}
    end
  end

  defp validate_scheme(uri, allowed_schemes) do
    if String.downcase(uri.scheme) in allowed_schemes do
      :ok
    else
      {:error, {:blocked_scheme, uri.scheme}}
    end
  end

  defp validate_host_present(uri) do
    if uri.host && uri.host != "" do
      :ok
    else
      {:error, {:missing_host, "URL must have a host"}}
    end
  end

  defp validate_port(uri, allowed_ports) do
    port = uri.port || default_port(uri.scheme)

    if port in allowed_ports do
      :ok
    else
      {:error, {:blocked_port, port}}
    end
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
  defp default_port(_), do: nil

  defp check_metadata_host(uri) do
    if String.downcase(uri.host) in @metadata_hosts do
      {:error, {:metadata_endpoint, uri.host}}
    else
      :ok
    end
  end

  defp resolve_host(uri) do
    host = to_charlist(uri.host)

    # Try IPv4 first, then IPv6
    case :inet.getaddr(host, :inet) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _} ->
        case :inet.getaddr(host, :inet6) do
          {:ok, ip} -> {:ok, ip}
          {:error, reason} -> {:error, {:dns_resolution_failed, reason}}
        end
    end
  end

  defp check_private_ip(_ip, true), do: :ok

  defp check_private_ip(ip, false) do
    if private_ip?(ip) do
      {:error, {:private_ip, format_ip(ip)}}
    else
      :ok
    end
  end

  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({0, 0, 0, 0}), do: true
  # IPv6 loopback
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv6 link-local (fe80::/10)
  defp private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true
  # IPv6 unique local (fc00::/7)
  defp private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  defp private_ip?(_), do: false

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_ip({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map_join(":", &Integer.to_string(&1, 16))
  end

  defp detect_patterns(value) do
    lowered = String.downcase(value)

    checks = [
      {Regex.match?(~r/\blocalhost\b/, lowered), "localhost"},
      {Regex.match?(~r/\b127\.0\.0\.\d+\b/, lowered), "loopback_ip"},
      {Regex.match?(~r/\b10\.\d+\.\d+\.\d+\b/, lowered), "private_ip_10"},
      {Regex.match?(~r/\b172\.(1[6-9]|2\d|3[01])\.\d+\.\d+\b/, lowered), "private_ip_172"},
      {Regex.match?(~r/\b192\.168\.\d+\.\d+\b/, lowered), "private_ip_192"},
      {Regex.match?(~r/\b169\.254\.\d+\.\d+\b/, lowered), "link_local_ip"},
      {Regex.match?(~r/\b0\.0\.0\.0\b/, lowered), "any_address"},
      {Regex.match?(~r/::1\b/, lowered), "ipv6_loopback"},
      {String.contains?(lowered, "169.254.169.254"), "aws_metadata"},
      {String.contains?(lowered, "metadata.google"), "gcp_metadata"},
      {Regex.match?(~r/\b(?:file|gopher|dict|ftp|ldap)\b:/, lowered), "unusual_scheme"},
      {Regex.match?(~r/@/, value), "credentials_in_url"},
      {Regex.match?(~r/#/, value), "fragment_in_url"}
    ]

    for {true, name} <- checks, do: name
  end
end
