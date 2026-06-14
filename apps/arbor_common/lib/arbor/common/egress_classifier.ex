defmodule Arbor.Common.EgressClassifier do
  @moduledoc """
  Pure network-locality classification for egress decisions.

  Answers one question about a network destination: *how far does the data
  travel?* — independent of any URI naming. This is the reusable primitive that
  host-addressed egressing actions (web fetch, message transports) map onto an
  `Arbor.Contracts.Security.Classification.egress_tier/0`.

  - `:on_host` — loopback / this-machine only (data never leaves the box)
  - `:on_premises` — RFC1918 private, link-local, or IPv6 ULA (leaves the box but
    stays on operator-owned hardware — the homelab/LAN model)
  - `:public` — anything else (a routable public host)

  ## No DNS resolution

  Classification is by the host literal only — it does NOT resolve hostnames.
  The egress gate runs synchronously before the call, where a blocking DNS lookup
  would add latency and its own SSRF/DNS-rebinding surface. A bare public hostname
  classifies as `:public` (conservative). DNS-rebinding defense for the actual
  request is `Arbor.Common.Sanitizers.SSRF`'s job at the data layer, not this
  classifier's.

  Provider-addressed egress (LLM calls keyed by provider atom rather than host)
  does NOT use this module — that mapping lives in `Arbor.AI.BackendTrust`, which
  knows which providers are local vs. cloud.
  """

  @type locality :: :on_host | :on_premises | :public

  @doc """
  Classify the network locality of a host or URL string.

  Accepts a bare host (`"localhost"`, `"10.42.42.6"`, `"api.example.com"`) or a
  full URL (`"https://api.example.com/v1"`) — the host is extracted from a URL.

  ## Examples

      iex> Arbor.Common.EgressClassifier.locality("localhost")
      :on_host

      iex> Arbor.Common.EgressClassifier.locality("http://127.0.0.1:1234/v1")
      :on_host

      iex> Arbor.Common.EgressClassifier.locality("10.42.42.6")
      :on_premises

      iex> Arbor.Common.EgressClassifier.locality("https://api.anthropic.com")
      :public
  """
  @spec locality(String.t() | nil) :: locality()
  def locality(nil), do: :public

  def locality(host_or_url) when is_binary(host_or_url) do
    host_or_url
    |> extract_host()
    |> classify_host()
  end

  def locality(_), do: :public

  # -- Private ---------------------------------------------------------------

  # Pull the host out of a URL; pass a bare host through unchanged.
  defp extract_host(value) do
    case URI.parse(value) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> value
    end
    |> String.trim()
    |> strip_brackets()
    |> String.downcase()
  end

  # IPv6 literals in URLs arrive bracketed ([::1]).
  defp strip_brackets("[" <> rest) do
    String.trim_trailing(rest, "]")
  end

  defp strip_brackets(host), do: host

  defp classify_host(""), do: :public
  defp classify_host("localhost"), do: :on_host

  # Reachable-only-on-this-network hostname conventions.
  defp classify_host(host) do
    cond do
      String.ends_with?(host, ".localhost") -> :on_host
      String.ends_with?(host, ".local") -> :on_premises
      String.ends_with?(host, ".internal") -> :on_premises
      true -> classify_ip(host)
    end
  end

  # Parse as an IP literal and classify by range; non-IPs fall through to :public.
  defp classify_ip(host) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, addr} -> classify_addr(addr)
      {:error, _} -> :public
    end
  end

  # IPv4 loopback / any-address — this machine.
  defp classify_addr({127, _, _, _}), do: :on_host
  defp classify_addr({0, 0, 0, 0}), do: :on_host
  # IPv4 RFC1918 private + link-local — local network (homelab).
  defp classify_addr({10, _, _, _}), do: :on_premises
  defp classify_addr({172, b, _, _}) when b >= 16 and b <= 31, do: :on_premises
  defp classify_addr({192, 168, _, _}), do: :on_premises
  defp classify_addr({169, 254, _, _}), do: :on_premises
  # IPv6 loopback (::1).
  defp classify_addr({0, 0, 0, 0, 0, 0, 0, 1}), do: :on_host
  # IPv6 link-local (fe80::/10) + unique-local (fc00::/7) — local network.
  defp classify_addr({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF,
    do: :on_premises

  defp classify_addr({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF,
    do: :on_premises

  defp classify_addr(_), do: :public
end
