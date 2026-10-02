defmodule Arbor.Gateway.Chat.TerminalLogin do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn

  @anonymous_paths ~w(/api/chat/login/start /api/chat/login/poll /api/chat/login/cancel)
  @max_body_bytes 2_048

  @impl true
  def init(opts), do: opts

  # This runs after the existing IP limiter and before generic authentication
  # or parsing. Only these exact methods/paths may create anonymous login work.
  @impl true
  def call(%{method: "POST", request_path: path} = conn, _opts)
      when path in @anonymous_paths do
    with true <- safe_transport?(conn) and conn.query_string == "",
         true <- get_req_header(conn, "authorization") == [],
         true <- get_req_header(conn, "x-api-key") == [],
         {:ok, body, conn} <- read_object(conn) do
      login(conn, path, body)
    else
      _ -> error(conn, 401, "unauthorized")
    end
  end

  def call(%{method: "POST", request_path: "/api/chat/login/logout"} = conn, _opts) do
    with {:ok, credential} <- credential(conn),
         {:ok, body, conn} when map_size(body) == 0 <- read_object(conn),
         :ok <- security(:revoke_terminal_session, [credential]) do
      json(conn, 200, %{status: "closed"})
    else
      _ -> error(conn, 401, "unauthorized")
    end
  end

  def call(conn, _opts) do
    if conversation_header?(conn) do
      # A Conversation credential never becomes generic Gateway authentication.
      case {conn.method, conn.request_path, credential(conn)} do
        {"GET", "/api/chat/socket", {:ok, _}} ->
          put_private(conn, :terminal_conversation, true)

        _ ->
          error(conn, 401, "unauthorized")
      end
    else
      conn
    end
  end

  defp login(conn, "/api/chat/login/start", %{"target" => target} = body)
       when map_size(body) == 1 and is_binary(target) do
    case security(:begin_terminal_login, [target]) do
      {:ok,
       %{
         handle: handle,
         verification_uri: uri,
         user_code: code,
         expires_in: ttl,
         interval: interval
       }}
      when is_binary(handle) and is_binary(uri) and is_binary(code) and is_integer(ttl) and
             ttl > 0 and is_integer(interval) and interval > 0 ->
        json(conn, 200, %{
          status: "pending",
          handle: handle,
          verification_uri: uri,
          user_code: code,
          expires_in: ttl,
          interval: interval
        })

      {:error, :unauthorized} ->
        error(conn, 401, "unauthorized")

      _ ->
        error(conn, 503, "login_unavailable")
    end
  end

  defp login(conn, "/api/chat/login/poll", %{"handle" => handle} = body)
       when map_size(body) == 1 do
    if opaque?(handle) do
      case security(:terminal_login_status, [handle]) do
        {:ok, :pending} ->
          json(conn, 200, %{status: "pending"})

        {:ok,
         %{principal: principal, target: target, credential: credential, lifetime: :connection}}
        when is_binary(principal) and is_binary(target) and is_binary(credential) ->
          json(conn, 200, %{
            status: "complete",
            principal: principal,
            target: target,
            credential: credential,
            lifetime: "connection"
          })

        {:error, :unauthorized} ->
          error(conn, 401, "unauthorized")

        _ ->
          error(conn, 503, "login_unavailable")
      end
    else
      error(conn, 401, "unauthorized")
    end
  end

  defp login(conn, "/api/chat/login/cancel", %{"handle" => handle} = body)
       when map_size(body) == 1 do
    if opaque?(handle) and security(:cancel_terminal_login, [handle]) == :ok,
      do: json(conn, 200, %{status: "closed"}),
      else: error(conn, 401, "unauthorized")
  end

  defp login(conn, _path, _body), do: error(conn, 400, "login_unavailable")

  @doc false
  def socket_state(conn) do
    with {:ok, credential} <- credential(conn),
         {:ok, binding} <- preflight(credential) do
      {:ok,
       binding
       |> Map.delete(:session_token)
       |> Map.put(:credential, credential)
       |> Map.put(:auth_mode, :conversation_session)}
    end
  end

  @doc false
  def preflight(credential) do
    if opaque?(credential) do
      case security(:preflight_terminal_session, [credential]) do
        {:ok, binding} -> binding_metadata(binding)
        {:error, :session_in_use} -> {:error, :session_in_use}
        _ -> {:error, :unauthorized}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc false
  def claim(credential), do: metadata(:claim_terminal_session, credential)

  @doc false
  def verify(credential) do
    with true <- opaque?(credential),
         {:ok, %{session_token: proof} = binding} <-
           security(:verify_terminal_session, [credential]),
         {:ok, metadata} <- binding_metadata(binding),
         true <- is_binary(proof) and byte_size(proof) in 1..4096 do
      {:ok, Map.put(metadata, :session_token, proof)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp metadata(operation, credential) do
    with true <- opaque?(credential),
         {:ok, binding} <- security(operation, [credential]),
         {:ok, metadata} <- binding_metadata(binding) do
      {:ok, metadata}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp binding_metadata(%{
         principal: principal,
         target: target,
         owner: owner,
         lifetime: :connection
       })
       when is_binary(principal) and is_binary(target) and is_binary(owner),
       do: {:ok, %{principal: principal, target: target, owner: owner, lifetime: :connection}}

  defp binding_metadata(_), do: {:error, :unauthorized}

  defp credential(conn) do
    with true <- safe_transport?(conn) and conn.query_string == "",
         true <- get_req_header(conn, "x-api-key") == [],
         ["Conversation " <> value] <- get_req_header(conn, "authorization"),
         true <- opaque?(value) do
      {:ok, value}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp conversation_header?(conn),
    do:
      Enum.any?(get_req_header(conn, "authorization"), fn value ->
        value |> String.trim_leading() |> String.downcase() |> String.starts_with?("conversation")
      end)

  defp opaque?(value) when is_binary(value) and byte_size(value) == 43,
    do: Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, value)

  defp opaque?(_), do: false

  # Trust the transport itself, never Forwarded/X-Forwarded-* claims. Plain HTTP
  # requires both a literal loopback URL and a loopback peer.
  defp safe_transport?(%{scheme: :https}), do: true

  defp safe_transport?(%{scheme: :http, host: host, remote_ip: peer})
       when host in ["127.0.0.1", "::1", "[::1]"] do
    match?({127, _, _, _}, peer) or peer == {0, 0, 0, 0, 0, 0, 0, 1}
  end

  defp safe_transport?(_), do: false

  defp read_object(conn) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <- content_type in ["application/json", "application/json; charset=utf-8"],
         [] <- get_req_header(conn, "content-encoding"),
         {:ok, bytes, conn} <-
           read_body(conn,
             length: @max_body_bytes,
             read_length: @max_body_bytes + 1,
             read_timeout: 5_000
           ),
         true <- byte_size(bytes) <= @max_body_bytes,
         {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(bytes, objects: :ordered_objects),
         true <- length(Enum.uniq_by(pairs, &elem(&1, 0))) == length(pairs) do
      {:ok, Map.new(pairs), conn}
    else
      _ -> {:error, :invalid_body}
    end
  rescue
    _ -> {:error, :invalid_body}
  end

  defp security(function, args) do
    apply(
      Application.get_env(:arbor_gateway, :terminal_login_security, Arbor.Security),
      function,
      args
    )
  rescue
    _ -> {:error, :login_unavailable}
  catch
    _, _ -> {:error, :login_unavailable}
  end

  defp error(conn, status, error), do: json(conn, status, %{error: error})

  defp json(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
