defmodule Arbor.Client.Management do
  @moduledoc """
  Bounded, signed HTTP discovery and operator commands. Conversation leases are
  deliberately not accepted. Each call signs its exact method, path and body
  with a fresh nonce, owns one connection, and never retries or follows redirects.
  A mutation whose reply cannot be confirmed returns `:management_unconfirmed`;
  inspect authoritative state before deciding whether to issue another command.
  """
  alias Arbor.Client.{Endpoint, Signer}
  @max_body 131_072
  @max_headers 16_384
  @max_wire 262_144

  def list_agents(identity, url, opts \\ []),
    do: request(identity, url, :agents, "GET", "/api/chat/agents", "", opts)

  def resolve_agent(identity, url, token, opts \\ []),
    do:
      token_request(identity, url, :resolve, "GET", "/api/chat/agents/resolve/", token, "", opts)

  def list_aliases(identity, url, opts \\ []),
    do: request(identity, url, :aliases, "GET", "/api/chat/aliases", "", opts)

  def set_alias(identity, url, name, target, opts \\ []) do
    if alias_name?(name) and input_text?(target, 256),
      do:
        request(
          identity,
          url,
          :alias,
          "POST",
          "/api/chat/aliases",
          %{name: name, target: target},
          opts
        ),
      else: {:error, :invalid_options}
  end

  def remove_alias(identity, url, name, opts \\ []) do
    if alias_name?(name),
      do: token_request(identity, url, :unalias, "DELETE", "/api/chat/aliases/", name, "", opts),
      else: {:error, :invalid_options}
  end

  def create_agent(identity, url, params, opts \\ []) do
    if create_params?(params),
      do: request(identity, url, :create, "POST", "/api/chat/agents", params, opts),
      else: {:error, :invalid_options}
  end

  def start_agent(identity, url, target, opts \\ []),
    do: lifecycle_request(identity, url, :start, target, opts)

  def stop_agent(identity, url, target, opts \\ []),
    do: lifecycle_request(identity, url, :stop, target, opts)

  defp lifecycle_request(identity, url, op, target, opts) do
    if input_text?(target, 256),
      do:
        request(
          identity,
          url,
          op,
          "POST",
          "/api/chat/agents/" <> segment(target) <> "/" <> Atom.to_string(op),
          %{},
          opts
        ),
      else: {:error, :invalid_options}
  end

  defp token_request(identity, url, op, method, prefix, token, body, opts) do
    if input_text?(token, 256),
      do: request(identity, url, op, method, prefix <> segment(token), body, opts),
      else: {:error, :invalid_options}
  end

  # Encode an entire path segment, including slash, percent and Unicode bytes.
  defp segment(text), do: URI.encode(text, &URI.char_unreserved?/1)

  defp request(identity, url, op, method, path, payload, opts) do
    with :ok <- identity(identity),
         {:ok, timeout, limit} <- options(opts),
         {:ok, uri} <- Endpoint.parse(url, :signed) do
      body = if is_binary(payload), do: payload, else: Jason.encode!(payload)
      header = Signer.authorization_header(identity, method, path, body)
      deadline = System.monotonic_time(:millisecond) + timeout
      transport = [timeout: timeout, send_timeout: min(timeout, 1_000), send_timeout_close: true]

      transport =
        if uri.host == "::1", do: [inet6: true, inet4: false] ++ transport, else: transport

      scheme = if uri.scheme == "https", do: :https, else: :http

      case Mint.HTTP.connect(scheme, uri.host, uri.port,
             mode: :active,
             protocols: [:http1],
             transport_opts: transport
           ) do
        {:ok, conn} ->
          try do
            headers = [
              {"authorization", header},
              {"content-type", "application/json"},
              {"accept", "application/json"}
            ]

            if remaining(deadline) > 0 do
              case Mint.HTTP.request(conn, method, path, headers, body) do
                {:ok, next, ref} ->
                  receive_response(next, ref, op, deadline, limit, %{
                    status: nil,
                    body: "",
                    headers: [],
                    header_bytes: 0,
                    wire_bytes: 0
                  })
                  |> bind_result(op, path, payload)

                _ ->
                  uncertain(op, :gateway_unavailable)
              end
            else
              {:error, :timeout}
            end
          rescue
            _ -> uncertain(op, :gateway_unavailable)
          catch
            _, _ -> uncertain(op, :gateway_unavailable)
          after
            Mint.HTTP.close(conn)
          end

        _ ->
          {:error, :gateway_unavailable}
      end
    end
  rescue
    _ -> {:error, :gateway_unavailable}
  catch
    _, _ -> {:error, :gateway_unavailable}
  end

  # A confirmed receipt must retain any exact selector already known locally.
  # Shorthands are resolved authoritatively by the host, never guessed here.
  defp bind_result({:ok, result} = success, op, path, payload) do
    bound =
      case op do
        op when op in [:start, :stop] ->
          [_, "api", "chat", "agents", token, _] = String.split(path, "/")
          target = URI.decode(token)
          not agent_id?(target) or result.agent_id == target

        :alias ->
          result.name == payload.name

        :unalias ->
          result.name == URI.decode(String.replace_prefix(path, "/api/chat/aliases/", ""))

        :create ->
          not Map.has_key?(payload, :name) or result.display_name == payload.name

        _ ->
          true
      end

    if bound, do: success, else: {:error, :management_unconfirmed}
  end

  defp bind_result(error, _, _, _), do: error

  defp identity(%{agent_id: _, private_key: _} = value) when map_size(value) == 2 do
    if Signer.valid_identity?(value), do: :ok, else: {:error, :invalid_identity}
  end

  defp identity(_), do: {:error, :invalid_identity}

  defp options(opts) when is_list(opts) and length(opts) <= 2 do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:timeout_ms, :max_entries])) and
         length(Enum.uniq(Keyword.keys(opts))) == length(opts) do
      timeout = Keyword.get(opts, :timeout_ms, 10_000)
      limit = Keyword.get(opts, :max_entries, 50)

      if is_integer(timeout) and timeout in 1..30_000 and is_integer(limit) and limit in 1..100,
        do: {:ok, timeout, limit},
        else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp options(_), do: {:error, :invalid_options}

  defp input_text?(text, max)
       when is_binary(text) and byte_size(text) > 0 and byte_size(text) <= max,
       do:
         String.valid?(text) and String.trim(text) != "" and
           not Regex.match?(~r/[\x00-\x1f\x7f-\x9f]/u, text)

  defp input_text?(_, _), do: false

  defp alias_name?(text),
    do:
      input_text?(text, 128) and not String.starts_with?(text, "agent_") and
        not Regex.match?(~r/\s/u, text)

  defp create_params?(%{template: template} = params) when map_size(params) in 1..3 do
    Enum.all?(Map.keys(params), &(&1 in [:template, :name, :model])) and
      input_text?(template, 128) and
      Enum.all?(Map.take(params, [:name, :model]), fn {_, value} -> input_text?(value, 256) end)
  end

  defp create_params?(_), do: false

  defp receive_response(conn, ref, op, deadline, limit, state) do
    socket = Mint.HTTP.get_socket(conn)
    wait = max(remaining(deadline), 0)

    if wait == 0 do
      uncertain(op, :timeout)
    else
      receive do
        {tag, ^socket, data} = message when tag in [:tcp, :ssl] and is_binary(data) ->
          bytes = state.wire_bytes + byte_size(data)

          if bytes <= @max_wire do
            stream_response(conn, message, ref, op, deadline, limit, %{state | wire_bytes: bytes})
          else
            uncertain(op, :response_too_large)
          end

        {tag, ^socket} when tag in [:tcp_closed, :ssl_closed] ->
          uncertain(op, :gateway_unavailable)

        {tag, ^socket, _} when tag in [:tcp_error, :ssl_error] ->
          uncertain(op, :gateway_unavailable)
      after
        wait -> uncertain(op, :timeout)
      end
    end
  end

  defp stream_response(conn, message, ref, op, deadline, limit, state) do
    if remaining(deadline) <= 0 do
      uncertain(op, :timeout)
    else
      case Mint.HTTP.stream(conn, message) do
        {:ok, next, responses} ->
          case consume(responses, ref, state) do
            {:more, state} ->
              receive_response(next, ref, op, deadline, limit, state)

            {:done, state} ->
              result = decode(state, op, limit)
              if remaining(deadline) > 0, do: result, else: uncertain(op, :timeout)

            {:error, error} ->
              uncertain(op, error)
          end

        _ ->
          uncertain(op, :gateway_unavailable)
      end
    end
  end

  defp consume([], _, state), do: {:more, state}

  defp consume([{:status, ref, status} | rest], ref, %{status: nil} = state),
    do: consume(rest, ref, %{state | status: status})

  defp consume([{:headers, ref, headers} | rest], ref, state) do
    bytes =
      Enum.reduce(headers, state.header_bytes, fn {k, v}, n -> n + byte_size(k) + byte_size(v) end)

    if bytes <= @max_headers,
      do: consume(rest, ref, %{state | headers: state.headers ++ headers, header_bytes: bytes}),
      else: {:error, :response_too_large}
  end

  defp consume([{:data, ref, bytes} | rest], ref, state) do
    if byte_size(state.body) + byte_size(bytes) <= @max_body,
      do: consume(rest, ref, %{state | body: state.body <> bytes}),
      else: {:error, :response_too_large}
  end

  defp consume([{:done, ref}], ref, state), do: {:done, state}
  defp consume(_, _, _), do: {:error, :invalid_response}

  defp decode(%{status: status} = state, op, limit) do
    with true <-
           Enum.all?(state.headers, fn {k, v} -> k != "content-encoding" or v == "identity" end),
         [type] <- for({"content-type", value} <- state.headers, do: value),
         true <- String.downcase(type) in ["application/json", "application/json; charset=utf-8"],
         {:ok, value} <- Jason.decode(state.body, objects: :ordered_objects),
         {:ok, map} when is_map(map) <- unique_objects(value) do
      if status == 200, do: response(op, map, limit), else: error_response(status, map, op)
    else
      _ -> uncertain(op, :invalid_response)
    end
  end

  defp unique_objects(%Jason.OrderedObject{values: pairs}) do
    if length(pairs) == map_size(Map.new(pairs)) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case unique_objects(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :duplicate_key}
    end
  end

  defp unique_objects(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case unique_objects(value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp unique_objects(value), do: {:ok, value}

  defp error_response(403, %{"error" => text}, _) when is_binary(text) do
    if String.starts_with?(text, "approval required"),
      do: {:error, :approval_required},
      else: {:error, :unauthorized}
  end

  defp error_response(401, _, _), do: {:error, :unauthorized}
  defp error_response(404, _, _), do: {:error, :not_found}
  defp error_response(409, _, op) when op == :resolve, do: {:error, :ambiguous}

  defp error_response(422, %{"error" => text}, _) when is_binary(text) do
    if String.contains?(text, "ambiguous"),
      do: {:error, :ambiguous},
      else: {:error, :invalid_options}
  end

  defp error_response(_, _, op), do: uncertain(op, :gateway_unavailable)

  defp response(:agents, %{"agents" => rows} = map, limit)
       when map_size(map) == 1 and is_list(rows) do
    if Enum.all?(rows, &agent_row?/1) and unique_ids?(rows) do
      {:ok,
       %{agents: Enum.map(Enum.take(rows, limit), &atom_agent/1), truncated: length(rows) > limit}}
    else
      {:error, :invalid_response}
    end
  end

  defp response(:resolve, %{"agent_id" => id} = map, _) when map_size(map) == 1 do
    if agent_id?(id), do: {:ok, id}, else: {:error, :invalid_response}
  end

  defp response(:aliases, %{"aliases" => aliases} = map, limit)
       when map_size(map) == 1 and is_map(aliases) do
    if Enum.all?(aliases, fn {name, id} -> output_text?(name, 128) and agent_id?(id) end) do
      rows =
        aliases
        |> Enum.sort()
        |> Enum.take(limit)
        |> Enum.map(fn {name, id} -> %{name: name, agent_id: id} end)

      {:ok, %{aliases: rows, truncated: map_size(aliases) > limit}}
    else
      {:error, :invalid_response}
    end
  end

  defp response(:alias, %{"name" => name, "agent_id" => id} = map, _) when map_size(map) == 2 do
    if output_text?(name, 128) and agent_id?(id),
      do: {:ok, %{name: name, agent_id: id}},
      else: {:error, :management_unconfirmed}
  end

  defp response(:unalias, %{"name" => name, "removed" => true} = map, _)
       when map_size(map) == 2 do
    if output_text?(name, 128),
      do: {:ok, %{name: name, removed: true}},
      else: {:error, :management_unconfirmed}
  end

  defp response(:create, %{"agent_id" => id, "display_name" => name, "running" => true} = map, _)
       when map_size(map) == 3 do
    if agent_id?(id) and output_text?(name, 256),
      do: {:ok, %{agent_id: id, display_name: name, running: true}},
      else: {:error, :management_unconfirmed}
  end

  defp response(op, %{"agent_id" => id, "running" => running} = map, _)
       when op in [:start, :stop] and map_size(map) == 2 do
    if agent_id?(id) and running == (op == :start),
      do: {:ok, %{agent_id: id, running: running}},
      else: {:error, :management_unconfirmed}
  end

  defp response(op, _, _), do: uncertain(op, :invalid_response)

  defp agent_row?(
         %{
           "agent_id" => id,
           "display_name" => name,
           "template" => template,
           "model" => model,
           "running" => running
         } = row
       )
       when map_size(row) == 5,
       do:
         agent_id?(id) and Enum.all?([name, template, model], &output_text?(&1, 256)) and
           is_boolean(running)

  defp agent_row?(_), do: false

  defp atom_agent(row),
    do: %{
      agent_id: row["agent_id"],
      display_name: row["display_name"],
      template: row["template"],
      model: row["model"],
      running: row["running"]
    }

  defp unique_ids?(rows), do: length(Enum.uniq_by(rows, & &1["agent_id"])) == length(rows)

  defp agent_id?(id) when is_binary(id) and byte_size(id) in 7..256,
    do: String.valid?(id) and Regex.match?(~r/\Aagent_[A-Za-z0-9_-]+\z/, id)

  defp agent_id?(_), do: false

  defp output_text?(text, max)
       when is_binary(text) and byte_size(text) > 0 and byte_size(text) <= max,
       do: String.valid?(text)

  defp output_text?(_, _), do: false

  defp uncertain(op, _) when op in [:alias, :unalias, :create, :start, :stop],
    do: {:error, :management_unconfirmed}

  defp uncertain(_, error), do: {:error, error}
  defp remaining(deadline), do: deadline - System.monotonic_time(:millisecond)
end
