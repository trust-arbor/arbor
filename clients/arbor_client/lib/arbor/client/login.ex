defmodule Arbor.Client.Login.Pending do
  @moduledoc "Bounded public login instructions plus an in-memory private flow handle."
  @derive {Inspect, except: [:handle]}
  defstruct [:handle, :verification_uri, :user_code, :expires_in, :interval]
end

defmodule Arbor.Client.Login.Session do
  @moduledoc """
  In-memory host-issued conversation credential; never persist or render it.
  The host owns connection lifetime, attachment deadlines and revocation.
  """
  @derive {Inspect, except: [:credential]}
  defstruct [:principal, :target, :credential, :lifetime]
end

defmodule Arbor.Client.Login do
  @moduledoc """
  Bounded device-login client for a trusted Arbor Gateway. The host owns OIDC;
  this client sees only public verification instructions and an opaque,
  target-bound conversation credential. Each HTTP call uses a fresh owner-local
  connection, a total deadline (35 seconds for start, five seconds otherwise), and no redirects or automatic retry.
  Error results contain fixed atoms, never provider bodies or credentials.
  """
  alias Arbor.Client.Endpoint
  alias __MODULE__.{Pending, Session}
  @timeout 5_000
  @max_body 16_384
  @max_headers 16_384
  @max_wire 65_536

  def start(gateway_url, target) do
    if target?(target),
      do: request(gateway_url, :start, %{target: target}, nil),
      else: {:error, :invalid_options}
  end

  def poll(gateway_url, handle) do
    if token?(handle),
      do: request(gateway_url, :poll, %{handle: handle}, nil),
      else: {:error, :invalid_options}
  end

  def cancel(gateway_url, handle) do
    if token?(handle),
      do: request(gateway_url, :cancel, %{handle: handle}, nil),
      else: {:error, :invalid_options}
  end

  def logout(gateway_url, credential) when is_binary(credential) do
    if token?(credential),
      do: request(gateway_url, :logout, %{}, credential),
      else: {:error, :invalid_session}
  end

  def logout(gateway_url, session) do
    with {:ok, session} <- normalize_session(session),
         do: request(gateway_url, :logout, %{}, session.credential)
  end

  @doc """
  Validate the receipt's shape, not current authority. Only the host can decide
  whether its connection lease is attached, reconnectable or revoked.
  """
  def session(session), do: normalize_session(session)

  defp normalize_session(%Session{} = session),
    do: normalize_session(Map.from_struct(session))

  defp normalize_session(
         %{principal: principal, target: target, credential: credential, lifetime: :connection} =
           session
       )
       when map_size(session) == 4 do
    if principal?(principal) and target?(target) and token?(credential) do
      {:ok, struct!(Session, session)}
    else
      {:error, :invalid_session}
    end
  end

  defp normalize_session(_), do: {:error, :invalid_session}

  @doc false
  def target?(value), do: bounded_id?(value, "agent_") or bounded_id?(value, "human_")
  defp principal?(value), do: bounded_id?(value, "human_")

  defp bounded_id?(value, prefix) when is_binary(value) and byte_size(value) in 7..256,
    do:
      String.valid?(value) and String.starts_with?(value, prefix) and
        Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)

  defp bounded_id?(_, _), do: false

  @doc false
  def token?(value) when is_binary(value) and byte_size(value) == 43 do
    String.valid?(value) and Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, value) and
      case Base.url_decode64(value, padding: false) do
        {:ok, bytes} ->
          byte_size(bytes) == 32 and Base.url_encode64(bytes, padding: false) == value

        _ ->
          false
      end
  end

  def token?(_), do: false

  defp request(gateway_url, operation, payload, credential) do
    with {:ok, uri} <- Endpoint.parse(gateway_url) do
      timeout = if operation == :start, do: 35_000, else: @timeout
      deadline = System.monotonic_time(:millisecond) + timeout
      scheme = if uri.scheme == "https", do: :https, else: :http
      transport = [timeout: timeout, send_timeout: 1_000, send_timeout_close: true]

      transport =
        if uri.host == "::1", do: [inet6: true, inet4: false] ++ transport, else: transport

      case Mint.HTTP.connect(scheme, uri.host, uri.port,
             mode: :active,
             protocols: [:http1],
             transport_opts: transport
           ) do
        {:ok, conn} ->
          # Every advanced Mint value still owns this same connected transport.
          # Close it even if decoding or request construction raises.
          try do
            headers = [{"content-type", "application/json"}, {"accept", "application/json"}]

            headers =
              if credential,
                do: [{"authorization", "Conversation " <> credential} | headers],
                else: headers

            if remaining(deadline) > 0 do
              case Mint.HTTP.request(
                     conn,
                     "POST",
                     path(operation),
                     headers,
                     Jason.encode!(payload)
                   ) do
                {:ok, next, ref} ->
                  receive_response(next, ref, operation, deadline, %{
                    status: nil,
                    body: "",
                    headers: [],
                    header_bytes: 0,
                    wire_bytes: 0
                  })

                _ ->
                  {:error, :login_unavailable}
              end
            else
              {:error, :timeout}
            end
          after
            Mint.HTTP.close(conn)
          end

        _ ->
          {:error, :login_unavailable}
      end
    end
  rescue
    _ -> {:error, :login_unavailable}
  catch
    _, _ -> {:error, :login_unavailable}
  end

  defp path(:start), do: "/api/chat/login/start"
  defp path(:poll), do: "/api/chat/login/poll"
  defp path(:cancel), do: "/api/chat/login/cancel"
  defp path(:logout), do: "/api/chat/login/logout"

  defp receive_response(conn, ref, operation, deadline, state) do
    socket = Mint.HTTP.get_socket(conn)
    wait = max(remaining(deadline), 0)

    if wait == 0 do
      {:error, :timeout}
    else
      receive do
        {tag, ^socket, data} = message when tag in [:tcp, :ssl] and is_binary(data) ->
          bytes = state.wire_bytes + byte_size(data)

          if bytes <= @max_wire do
            stream_response(conn, message, ref, operation, deadline, %{state | wire_bytes: bytes})
          else
            {:error, :invalid_response}
          end

        {tag, ^socket} when tag in [:tcp_closed, :ssl_closed] ->
          {:error, :login_unavailable}

        {tag, ^socket, _} when tag in [:tcp_error, :ssl_error] ->
          {:error, :login_unavailable}
      after
        wait -> {:error, :timeout}
      end
    end
  end

  defp stream_response(conn, message, ref, operation, deadline, state) do
    if remaining(deadline) <= 0 do
      {:error, :timeout}
    else
      case Mint.HTTP.stream(conn, message) do
        {:ok, next, responses} ->
          case consume(responses, ref, state) do
            {:more, state} ->
              receive_response(next, ref, operation, deadline, state)

            {:done, state} ->
              result = decode(state, operation)
              if remaining(deadline) > 0, do: result, else: {:error, :timeout}

            error ->
              error
          end

        _ ->
          {:error, :login_unavailable}
      end
    end
  end

  defp consume([], _, state), do: {:more, state}

  defp consume([{:status, ref, status} | rest], ref, %{status: nil} = state),
    do: consume(rest, ref, %{state | status: status})

  defp consume([{:headers, ref, headers} | rest], ref, state) do
    bytes =
      Enum.reduce(headers, state.header_bytes, fn {k, v}, n -> n + byte_size(k) + byte_size(v) end)

    if bytes <= @max_headers do
      consume(rest, ref, %{state | headers: state.headers ++ headers, header_bytes: bytes})
    else
      {:error, :invalid_response}
    end
  end

  defp consume([{:data, ref, bytes} | rest], ref, state) do
    if byte_size(state.body) + byte_size(bytes) <= @max_body,
      do: consume(rest, ref, %{state | body: state.body <> bytes}),
      else: {:error, :invalid_response}
  end

  defp consume([{:done, ref}], ref, state), do: {:done, state}
  defp consume(_, _, _), do: {:error, :invalid_response}

  defp decode(%{status: 200} = state, operation) do
    with true <-
           Enum.all?(state.headers, fn {key, value} ->
             key != "content-encoding" or value == "identity"
           end),
         [content_type] <- for({"content-type", value} <- state.headers, do: value),
         true <-
           String.downcase(content_type) in [
             "application/json",
             "application/json; charset=utf-8"
           ],
         {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(state.body, objects: :ordered_objects),
         true <- length(pairs) == map_size(Map.new(pairs)) do
      response(operation, Map.new(pairs))
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp decode(%{status: status}, _) when status in [401, 403], do: {:error, :unauthorized}
  defp decode(_, _), do: {:error, :login_unavailable}

  defp response(
         :start,
         %{
           "status" => "pending",
           "handle" => handle,
           "verification_uri" => uri,
           "user_code" => code,
           "expires_in" => expires,
           "interval" => interval
         } = value
       )
       when map_size(value) == 6 do
    if token?(handle) and verification_uri?(uri) and safe_code?(code) and
         is_integer(expires) and expires in 1..300 and is_integer(interval) and interval in 1..60 do
      {:ok,
       %Pending{
         handle: handle,
         verification_uri: uri,
         user_code: code,
         expires_in: expires,
         interval: interval
       }}
    else
      {:error, :invalid_response}
    end
  end

  defp response(:poll, %{"status" => "pending"} = value) when map_size(value) == 1,
    do: {:ok, :pending}

  defp response(
         :poll,
         %{
           "status" => "complete",
           "principal" => principal,
           "target" => target,
           "credential" => credential,
           "lifetime" => "connection"
         } = value
       )
       when map_size(value) == 5 do
    case session(%{
           principal: principal,
           target: target,
           credential: credential,
           lifetime: :connection
         }) do
      {:ok, session} -> {:ok, session}
      _ -> {:error, :invalid_response}
    end
  end

  defp response(op, %{"status" => "closed"} = value)
       when op in [:cancel, :logout] and map_size(value) == 1, do: :ok

  defp response(_, _), do: {:error, :invalid_response}

  # Browser instructions may name localhost. Gateway credential transport uses
  # Endpoint's separate TLS/literal-loopback policy, which stays unchanged.
  defp verification_uri?(uri) do
    with true <- safe_text?(uri, 2_048),
         %URI{scheme: scheme, host: host, port: port, userinfo: nil, fragment: nil} <-
           URI.parse(uri) do
      is_binary(host) and host != "" and is_integer(port) and port in 1..65_535 and
        (scheme == "https" or (scheme == "http" and host in ["localhost", "127.0.0.1", "::1"]))
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp safe_code?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: Regex.match?(~r/\A[\x20-\x7e]+\z/, value)

  defp safe_code?(_), do: false

  defp safe_text?(value, max) when is_binary(value) and byte_size(value) > 0,
    do:
      byte_size(value) <= max and String.valid?(value) and
        not Regex.match?(~r/[\x00-\x20\x7f]/, value)

  defp safe_text?(_, _), do: false
  defp remaining(deadline), do: deadline - System.monotonic_time(:millisecond)
end
