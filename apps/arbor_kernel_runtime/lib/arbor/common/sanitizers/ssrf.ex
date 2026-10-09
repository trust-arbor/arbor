defmodule Arbor.Common.Sanitizers.SSRF do
  @moduledoc """
  Sanitizer for Server-Side Request Forgery (SSRF) attacks.

  Validates URLs by parsing, checking scheme, resolving every IPv4 and IPv6
  address for the hostname, and rejecting the URL if any address is not
  globally routable.

  `sanitize/3` accepts only IP literals because its string result cannot carry
  DNS authority through to a network client. Req callers use `req_options/3`:
  it repeats resolution immediately before each connection, replaces Finch's
  destination with the validated IP tuple, and retains the original hostname
  for the Host header, TLS SNI, and certificate verification. That supports
  ordinary HTTPS names without a second DNS lookup or a rebinding window.

  Sets bit 5 on the taint sanitizations bitmask.

  ## Options

  - `:allowed_schemes` — allowed URL schemes (default: `["http", "https"]`)
  - `:allowed_ports` — allowed ports (default: `[80, 443, 8080, 8443]`)
  - `:allow_private` — allow private IPs (default: `false`; callers must derive
    this from trusted host policy, never URL input)
  - `:resolver` — module implementing `resolve_all/1` (test seam)
  """

  @behaviour Arbor.Contracts.Security.Sanitizer

  alias Arbor.Common.Sanitizers.SSRF.FinchPool
  alias Arbor.Contracts.Security.Taint

  import Bitwise

  @bit 0b00100000
  @default_schemes ["http", "https"]
  @default_ports [80, 443, 8080, 8443]
  @max_response_bytes 1_048_576
  @default_request_timeout_ms 15_000
  @max_request_timeout_ms 120_000
  @test_options_enabled Application.compile_env(
                          :arbor_kernel_runtime,
                          :expose_test_fixtures,
                          false
                        )

  defmodule Resolver do
    @moduledoc false

    def resolve_all(host) when is_list(host) do
      ipv4 = addresses(host, :inet)
      ipv6 = addresses(host, :inet6)

      case Enum.uniq(ipv4 ++ ipv6) do
        [] -> {:error, :nxdomain}
        addresses -> {:ok, addresses}
      end
    end

    defp addresses(host, family) do
      case :inet.getaddrs(host, family) do
        {:ok, addresses} -> addresses
        {:error, _reason} -> []
      end
    end
  end

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
    security = security_options(opts)

    with {:ok, uri, _resolved_ips} <- validate_target(value, security),
         :ok <- require_pinned_target(uri) do
      updated_taint = %{taint | sanitizations: bor(taint.sanitizations, @bit)}
      {:ok, value, updated_taint}
    end
  end

  @doc """
  Adds a connect-time DNS pin to a Req request.

  The returned options force Req's Finch adapter, disable automatic redirects,
  retries, and compression, preserve the original hostname for TLS/HTTP
  authority, and replace the socket destination with an already-validated IP
  tuple immediately before Finch connects. The pinned Finch callback streams
  the response and tears down the socket before retaining more than 1 MiB.
  Callers that follow redirects must validate each `Location` as a new request.

  `security_opts` is reserved for sanitizer policy. The resolver and Finch
  transport seams are available only in test builds.
  """
  @spec req_options(String.t(), keyword(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def req_options(value, request_opts \\ [], security_opts \\ [])

  def req_options(value, request_opts, security_opts)
      when is_binary(value) and is_list(request_opts) and is_list(security_opts) do
    with {:ok, deadline} <- request_deadline(request_opts) do
      req_options(value, request_opts, security_opts, deadline)
    end
  end

  def req_options(_value, _request_opts, _security_opts), do: {:error, :invalid_request_options}

  @doc """
  Adds a DNS pin while consuming an existing monotonic request deadline.

  Reuse the deadline returned by `request_deadline/1` for every redirect in one
  logical operation. A supplied deadline can shorten the configured timeout but
  can never extend it.
  """
  @spec req_options(String.t(), keyword(), keyword(), integer()) ::
          {:ok, keyword()} | {:error, term()}
  def req_options(value, request_opts, security_opts, inherited_deadline)
      when is_binary(value) and is_list(request_opts) and is_list(security_opts) and
             is_integer(inherited_deadline) do
    security = security_options(security_opts)

    with :ok <- reject_unsafe_req_options(request_opts),
         {:ok, timeout_ms} <- request_timeout_ms(request_opts),
         {:ok, pool_timeout_ms} <- pool_timeout_ms(request_opts, timeout_ms),
         deadline <- bounded_deadline(inherited_deadline, timeout_ms),
         {:ok, uri, _resolved_ips} <-
           validate_target_before_deadline(value, security, deadline, timeout_ms),
         {:ok, remaining_ms} <- remaining_budget(deadline, timeout_ms) do
      callback = pinned_finch_request(uri, security, deadline)

      safe_options =
        request_opts
        |> Keyword.put(:redirect, false)
        |> Keyword.put(:max_redirects, 0)
        |> Keyword.put(:retry, false)
        |> Keyword.put(:compressed, false)
        |> Keyword.put(:decode_body, false)
        |> Keyword.put(:raw, true)
        |> Keyword.put(:pool_timeout, min(pool_timeout_ms, remaining_ms))
        |> Keyword.put(:receive_timeout, remaining_ms)
        |> Keyword.put(:plug, nil)
        # Req 0.7 replaced the `Req.Steps.run_finch/1` step with the `Req.Finch`
        # adapter module. A function capture of the removed step raises
        # UndefinedFunctionError before any request runs.
        |> Keyword.put(:adapter, Req.Finch)
        |> Keyword.put(:finch, FinchPool.req_name())
        |> Keyword.put(:finch_request, callback)

      {:ok, safe_options}
    end
  end

  def req_options(_value, _request_opts, _security_opts, _deadline),
    do: {:error, :invalid_request_options}

  @doc """
  Starts the monotonic deadline for one SSRF-protected HTTP operation.

  The returned integer is opaque. Pass it back to `req_options/4` for the
  initial request and every manually followed redirect.
  """
  @spec request_deadline(keyword()) :: {:ok, integer()} | {:error, term()}
  def request_deadline(request_opts \\ [])

  def request_deadline(request_opts) when is_list(request_opts) do
    with :ok <- reject_unsafe_req_options(request_opts),
         {:ok, timeout_ms} <- request_timeout_ms(request_opts) do
      {:ok, System.monotonic_time(:millisecond) + timeout_ms}
    end
  end

  def request_deadline(_request_opts), do: {:error, :invalid_request_options}

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

  defp security_options(opts) do
    %{
      allowed_schemes: Keyword.get(opts, :allowed_schemes, @default_schemes),
      allowed_ports: Keyword.get(opts, :allowed_ports, @default_ports),
      allow_private: Keyword.get(opts, :allow_private, false) == true,
      resolver:
        if(@test_options_enabled,
          do: Keyword.get(opts, :resolver, Resolver),
          else: Resolver
        ),
      finch_request: if(@test_options_enabled, do: Keyword.get(opts, :finch_request), else: nil)
    }
  end

  defp validate_target(value, security) do
    with {:ok, uri} <- parse_url(value),
         :ok <- validate_scheme(uri, security.allowed_schemes),
         :ok <- validate_host_present(uri),
         :ok <- validate_port(uri, security.allowed_ports),
         :ok <- check_metadata_host(uri),
         {:ok, resolved_ips} <- resolve_host(uri, security.resolver),
         :ok <- check_private_ips(resolved_ips, security.allow_private) do
      {:ok, uri, resolved_ips}
    end
  end

  defp parse_url(value) do
    uri = URI.parse(value)

    cond do
      not is_binary(uri.scheme) or uri.scheme == "" ->
        {:error, {:invalid_url, "URL must have a scheme"}}

      uri.userinfo ->
        {:error, {:invalid_url, "URL credentials are not allowed"}}

      true ->
        {:ok, uri}
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
    if canonical_hostname(uri.host) in @metadata_hosts do
      {:error, {:metadata_endpoint, uri.host}}
    else
      :ok
    end
  end

  defp resolve_host(uri, resolver) do
    host = canonical_hostname(uri.host)

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _reason} ->
        resolve_dns(host, resolver)
    end
  end

  defp resolve_dns(host, resolver) do
    with true <-
           is_atom(resolver) and Code.ensure_loaded?(resolver) and
             function_exported?(resolver, :resolve_all, 1),
         {:ok, addresses} when is_list(addresses) and addresses != [] <-
           resolver.resolve_all(to_charlist(host)),
         true <- Enum.all?(addresses, &valid_ip_tuple?/1) do
      {:ok, Enum.uniq(addresses)}
    else
      {:error, reason} -> {:error, {:dns_resolution_failed, reason}}
      _ -> {:error, {:dns_resolution_failed, :invalid_resolver_result}}
    end
  rescue
    _ -> {:error, {:dns_resolution_failed, :resolver_failure}}
  catch
    _, _ -> {:error, {:dns_resolution_failed, :resolver_failure}}
  end

  defp check_private_ips(_ips, true), do: :ok

  defp check_private_ips(ips, false) do
    case Enum.find(ips, &private_ip?/1) do
      nil -> :ok
      ip -> {:error, {:private_ip, format_ip(ip)}}
    end
  end

  # Returning the original hostname after DNS validation lets the eventual
  # client resolve it again and defeats the check (classic DNS rebinding).
  # IP literals are already pinned. A hostname can be used only through
  # `req_options/3`, even when trusted policy allows a private destination;
  # the string returned by `sanitize/3` cannot carry a DNS pin.
  defp require_pinned_target(uri) do
    case :inet.parse_address(String.to_charlist(canonical_hostname(uri.host))) do
      {:ok, _address} -> :ok
      {:error, _reason} -> {:error, :dns_pinning_required}
    end
  end

  defp reject_unsafe_req_options(request_opts) do
    unsafe = [
      :adapter,
      :base_url,
      :connect_options,
      :finch,
      :finch_request,
      :into,
      :plug,
      :unix_socket,
      :url
    ]

    cond do
      not Keyword.keyword?(request_opts) ->
        {:error, :invalid_request_options}

      key = Enum.find(unsafe, &Keyword.has_key?(request_opts, &1)) ->
        {:error, {:unsafe_req_option, key}}

      true ->
        :ok
    end
  end

  defp request_timeout_ms(request_opts) do
    case Keyword.get(request_opts, :receive_timeout, @default_request_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        {:ok, min(timeout_ms, @max_request_timeout_ms)}

      :infinity ->
        {:ok, @max_request_timeout_ms}

      _other ->
        {:error, {:invalid_req_option, :receive_timeout}}
    end
  end

  defp pool_timeout_ms(request_opts, request_timeout_ms) do
    case Keyword.get(request_opts, :pool_timeout, request_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        {:ok, min(timeout_ms, request_timeout_ms)}

      :infinity ->
        {:ok, request_timeout_ms}

      _other ->
        {:error, {:invalid_req_option, :pool_timeout}}
    end
  end

  defp bounded_deadline(inherited_deadline, timeout_ms) do
    min(inherited_deadline, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp validate_target_before_deadline(value, security, deadline, timeout_ms) do
    case run_before_deadline(deadline, fn -> validate_target(value, security) end) do
      {:ok, result} -> result
      {:error, :timeout} -> {:error, {:request_timeout, timeout_ms}}
      {:error, :operation_process_exit} -> {:error, :request_process_exit}
    end
  end

  defp remaining_budget(deadline, timeout_ms) do
    case remaining_ms(deadline) do
      0 -> {:error, {:request_timeout, timeout_ms}}
      remaining -> {:ok, remaining}
    end
  end

  defp pinned_finch_request(uri, security, deadline) do
    fn request, finch_request, _finch_name, finch_options ->
      initial = {Req.Response.new(), 0, []}

      collector = fn
        {:status, status}, {response, retained, chunks} ->
          {:cont, {%{response | status: status}, retained, chunks}}

        {:headers, fields}, {response, retained, chunks} ->
          headers = Req.Response.new(headers: fields).headers
          response = %{response | headers: headers}

          case validate_content_encoding(response) do
            :ok -> {:cont, {response, retained, chunks}}
            {:error, reason} -> {:halt, {:invalid_response, reason, response}}
          end

        {:data, data}, {response, retained, chunks} when is_binary(data) ->
          if retained + byte_size(data) > @max_response_bytes do
            {:halt, {:response_bytes_exceeded, response}}
          else
            {:cont, {response, retained + byte_size(data), [data | chunks]}}
          end

        {:trailers, fields}, {response, retained, chunks} ->
          trailers = Req.Response.new(trailers: fields).trailers
          {:cont, {%{response | trailers: trailers}, retained, chunks}}
      end

      # Finch's receive timeout is per chunk, so a peer can otherwise keep a
      # request alive forever by sending one byte before each timeout. Run the
      # complete connect-time validation and stream in a monitored process and
      # kill it at a monotonic deadline, matching the OAuth transport boundary.
      stream = fn ->
        with :ok <- validate_finch_destination(finch_request, uri),
             {:ok, _uri, [address | _]} <- validate_target(URI.to_string(uri), security) do
          pinned_request = pin_finch_destination(finch_request, address, uri)

          case security.finch_request do
            nil ->
              hostname = canonical_hostname(uri.host)

              FinchPool.with_pool(address, hostname, deadline, fn slot_name ->
                remaining = remaining_ms(deadline)

                Finch.stream_while(
                  pinned_request,
                  slot_name,
                  initial,
                  collector,
                  finch_options
                  |> clamp_finch_timeout(:receive_timeout, remaining)
                  |> clamp_finch_timeout(:pool_timeout, remaining)
                  |> Keyword.put(:request_timeout, remaining)
                )
              end)

            transport ->
              run_fixture_transport(
                transport,
                pinned_request,
                FinchPool.req_name(),
                finch_options,
                @max_response_bytes
              )
          end
        else
          {:error, reason} -> {:ssrf_blocked, reason}
        end
      end

      response =
        deadline
        |> run_before_deadline(stream)
        |> normalize_stream_result(@max_response_bytes)

      {request, response}
    end
  end

  defp validate_finch_destination(finch_request, uri) when is_map(finch_request) do
    expected_scheme = scheme_atom(uri.scheme)
    expected_host = canonical_hostname(uri.host)
    expected_port = uri.port || default_port(uri.scheme)

    if Map.get(finch_request, :scheme) == expected_scheme and
         canonical_hostname(Map.get(finch_request, :host)) == expected_host and
         Map.get(finch_request, :port) == expected_port do
      :ok
    else
      {:error, :request_destination_changed}
    end
  end

  defp validate_finch_destination(_finch_request, _uri),
    do: {:error, :invalid_finch_request}

  defp pin_finch_destination(finch_request, address, uri) do
    headers =
      finch_request
      |> Map.get(:headers, [])
      |> Enum.reject(fn
        {name, _value} when is_binary(name) -> String.downcase(name) == "host"
        _other -> false
      end)

    %{finch_request | host: address, headers: [{"host", authority(uri)} | headers]}
  end

  # Test-only seam retained for deterministic pin/rebind tests. Production
  # always takes the streaming clause above; this fallback still rejects an
  # oversized synthetic response so fixtures cannot silently bypass policy.
  defp run_fixture_transport(transport, request, finch_name, finch_options, maximum) do
    case transport.(request, finch_name, finch_options) do
      {:ok, response} when is_map(response) ->
        response = Req.Response.new(response)

        if is_binary(response.body) and byte_size(response.body) <= maximum do
          case validate_content_encoding(response) do
            :ok -> {:fixture_response, response}
            {:error, reason} -> {:fixture_invalid_response, reason}
          end
        else
          {:fixture_overflow, maximum}
        end

      {:error, reason} ->
        {:fixture_error, reason}

      _other ->
        {:fixture_error, :invalid_finch_transport_result}
    end
  end

  defp clamp_finch_timeout(options, key, remaining) do
    timeout =
      case Keyword.get(options, key, remaining) do
        value when is_integer(value) and value > 0 -> min(value, remaining)
        _other -> remaining
      end

    Keyword.put(options, key, timeout)
  end

  defp run_before_deadline(deadline, operation) do
    owner = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(owner, {result_ref, operation.()})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, result}

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        {:error, :operation_process_exit}
    after
      remaining_ms(deadline) ->
        stop_timed_out_stream(pid, monitor_ref, result_ref)
        {:error, :timeout}
    end
  end

  defp stop_timed_out_stream(pid, monitor_ref, result_ref) do
    Process.exit(pid, :kill)
    await_stream_down(pid, monitor_ref, result_ref)
  end

  defp await_stream_down(pid, monitor_ref, result_ref) do
    receive do
      {^result_ref, _late_result} ->
        await_stream_down(pid, monitor_ref, result_ref)

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        flush_late_stream_result(result_ref)
    end
  end

  defp flush_late_stream_result(result_ref) do
    receive do
      {^result_ref, _late_result} -> :ok
    after
      0 -> :ok
    end
  end

  defp remaining_ms(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp normalize_stream_result({:error, :timeout}, _maximum),
    do: Req.TransportError.exception(reason: :timeout)

  defp normalize_stream_result({:error, :operation_process_exit}, _maximum),
    do: Req.TransportError.exception(reason: :stream_process_exit)

  defp normalize_stream_result({:ok, {:ssrf_blocked, reason}}, _maximum),
    do: blocked_transport_error(reason)

  defp normalize_stream_result({:ok, {:fixture_response, response}}, _maximum), do: response

  defp normalize_stream_result({:ok, {:fixture_overflow, maximum}}, _configured_maximum),
    do: Req.TransportError.exception(reason: {:response_bytes_exceeded, maximum})

  defp normalize_stream_result({:ok, {:fixture_invalid_response, reason}}, _maximum),
    do: Req.TransportError.exception(reason: {:invalid_response, reason})

  defp normalize_stream_result({:ok, {:fixture_error, reason}}, _maximum),
    do: normalize_finch_error(reason)

  defp normalize_stream_result(
         {:ok, {:ok, {:response_bytes_exceeded, _response}}},
         maximum
       ),
       do: Req.TransportError.exception(reason: {:response_bytes_exceeded, maximum})

  defp normalize_stream_result({:ok, {:ok, {:invalid_response, reason, _response}}}, _maximum),
    do: Req.TransportError.exception(reason: {:invalid_response, reason})

  defp normalize_stream_result({:ok, {:ok, {response, _retained, chunks}}}, _maximum) do
    %{response | body: chunks |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp normalize_stream_result({:ok, {:error, reason, _state}}, _maximum),
    do: normalize_finch_error(reason)

  defp normalize_stream_result({:ok, {:error, reason}}, _maximum),
    do: normalize_finch_error(reason)

  defp normalize_stream_result(_other, _maximum),
    do: Req.TransportError.exception(reason: :invalid_finch_transport_result)

  defp normalize_finch_error(%{__exception__: true} = exception), do: exception
  defp normalize_finch_error(reason), do: Req.TransportError.exception(reason: reason)

  defp blocked_transport_error(reason),
    do: Req.TransportError.exception(reason: {:ssrf_blocked, reason})

  defp validate_content_encoding(response) do
    encodings =
      response
      |> Req.Response.get_header("content-encoding")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    if Enum.all?(encodings, &(&1 in ["", "identity"])),
      do: :ok,
      else: {:error, :non_identity_content_encoding}
  end

  defp authority(uri) do
    hostname = canonical_hostname(uri.host)
    hostname = if String.contains?(hostname, ":"), do: "[#{hostname}]", else: hostname
    port = uri.port || default_port(uri.scheme)

    if port == default_port(uri.scheme), do: hostname, else: "#{hostname}:#{port}"
  end

  defp canonical_hostname(host) when is_binary(host) do
    host
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp canonical_hostname(_host), do: ""

  defp scheme_atom("http"), do: :http
  defp scheme_atom("https"), do: :https
  defp scheme_atom(_scheme), do: :invalid

  defp private_ip?({a, _, _, _}) when a == 0, do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({192, 0, 0, _}), do: true
  defp private_ip?({192, 0, 2, _}), do: true
  defp private_ip?({192, 88, 99, _}), do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({198, b, _, _}) when b in 18..19, do: true
  defp private_ip?({198, 51, 100, _}), do: true
  defp private_ip?({203, 0, 113, _}), do: true
  # IPv4 multicast (224/4) and reserved/future-use space (240/4).
  defp private_ip?({a, _, _, _}) when a >= 224, do: true
  # IPv6 unspecified
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # IPv6 loopback
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv4-compatible ::/96 is special-use even when its low 32 bits look public.
  defp private_ip?({0, 0, 0, 0, 0, 0, _g, _h}), do: true
  # IPv4-mapped IPv6 addresses inherit the embedded IPv4 classification.
  defp private_ip?({0, 0, 0, 0, 0, 0xFFFF, g, h}) do
    private_ip?({g >>> 8, g &&& 0xFF, h >>> 8, h &&& 0xFF})
  end

  # IPv6 global unicast is currently allocated from 2000::/3. Conservatively
  # reject every other family so multicast, link/site local, unique-local,
  # discard-only, translation, and unallocated ranges never reach a client.
  defp private_ip?({a, _, _, _, _, _, _, _}) when a < 0x2000 or a > 0x3FFF, do: true
  # IETF protocol assignments, benchmarking/ORCHID space, and documentation.
  defp private_ip?({0x2001, b, _, _, _, _, _, _}) when b <= 0x01FF, do: true
  defp private_ip?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: true
  # Deprecated 6to4 relays can encode a non-global IPv4 destination.
  defp private_ip?({0x2002, _, _, _, _, _, _, _}), do: true
  # Documentation prefix 3fff::/20.
  defp private_ip?({0x3FFF, b, _, _, _, _, _, _}) when b <= 0x0FFF, do: true
  defp private_ip?({_a, _b, _c, _d}), do: false
  defp private_ip?({_a, _b, _c, _d, _e, _f, _g, _h}), do: false
  defp private_ip?(_), do: true

  defp valid_ip_tuple?({a, b, c, d}),
    do: Enum.all?([a, b, c, d], &(is_integer(&1) and &1 in 0..255))

  defp valid_ip_tuple?({a, b, c, d, e, f, g, h}),
    do: Enum.all?([a, b, c, d, e, f, g, h], &(is_integer(&1) and &1 in 0..65_535))

  defp valid_ip_tuple?(_), do: false

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
      {Regex.match?(~r/\b0\.\d+\.\d+\.\d+\b/, lowered), "reserved_ip_0"},
      {Regex.match?(~r/\b10\.\d+\.\d+\.\d+\b/, lowered), "private_ip_10"},
      {Regex.match?(~r/\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+\b/, lowered),
       "shared_address_space"},
      {Regex.match?(~r/\b172\.(1[6-9]|2\d|3[01])\.\d+\.\d+\b/, lowered), "private_ip_172"},
      {Regex.match?(~r/\b192\.168\.\d+\.\d+\b/, lowered), "private_ip_192"},
      {Regex.match?(~r/\b169\.254\.\d+\.\d+\b/, lowered), "link_local_ip"},
      {Regex.match?(~r/\b0\.0\.0\.0\b/, lowered), "any_address"},
      {Regex.match?(~r/::1\b/, lowered), "ipv6_loopback"},
      {String.contains?(lowered, "::ffff:127."), "ipv4_mapped_loopback"},
      {String.contains?(lowered, "169.254.169.254"), "aws_metadata"},
      {String.contains?(lowered, "metadata.google"), "gcp_metadata"},
      {Regex.match?(~r/\b(?:file|gopher|dict|ftp|ldap)\b:/, lowered), "unusual_scheme"},
      {Regex.match?(~r/@/, value), "credentials_in_url"},
      {Regex.match?(~r/#/, value), "fragment_in_url"}
    ]

    for {true, name} <- checks, do: name
  end
end
