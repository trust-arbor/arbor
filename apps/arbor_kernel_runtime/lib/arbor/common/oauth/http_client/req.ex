defmodule Arbor.Common.OAuth.HttpClient.Req do
  @moduledoc """
  `Req`-backed adapter for `Arbor.Common.OAuth.HttpClient`.

  The important property of this adapter is that the response **body** byte
  budget is a transport bound, not a post-hoc check. A `Req` `:into` collector
  halts the request the moment a body chunk would push retained bytes past
  `max_response_bytes`, so an endless or hostile body never accumulates in
  memory and the socket is torn down early.

  Response headers are bounded independently. The adapter uses the dedicated
  `Arbor.Common.OAuth.HttpClient.Pool`, which pins HTTP/1 and configures Mint
  1.9.3's parser-level response/trailer limit to 32 KiB. The facade then admits
  only a closed 64-header shape with per-field and aggregate limits.

  Pinned request options and why:

    * `redirect: false` / `max_redirects: 0` — a 302 must not silently move a
      credential POST off an origin the caller already validated.
    * `compressed: false` — do not advertise compression; a byte bound applied
      to compressed bytes is not a bound on memory.
    * `decode_body: false` — the raw binary is returned; structural decoding
      budgets stay with the caller.
    * `retry: false` — authorization codes are single-use; a transparent retry
      both multiplies the byte budget and re-POSTs a spent code.
    * dedicated Finch pool — keep HTTP/1 explicit and apply Mint's 32 KiB
      parser-level response-header limit before Req constructs a response.
    * pool and receive timeouts are capped by `timeout_ms`; a monotonic deadline
      bounds the whole request, including connection setup, even when chunks
      keep arriving.
  """

  @behaviour Arbor.Common.OAuth.HttpClient

  alias Arbor.Common.OAuth.HttpClient.{Pool, Request, Response}

  @bytes_key :arbor_oauth_response_bytes
  @chunks_key :arbor_oauth_response_chunks
  @overflow_key :arbor_oauth_response_overflow
  @maximum_key :arbor_oauth_response_maximum
  @deadline_key :arbor_oauth_response_deadline
  @timeout_key :arbor_oauth_response_timeout

  @impl true
  def request(%Request{} = request) do
    req = build(request)
    deadline = Map.fetch!(req.private, @deadline_key)

    req
    |> request_before_deadline(deadline, request.timeout_ms)
    |> normalize(request)
  end

  @doc """
  Build the bounded `Req.Request` for an OAuth request.

  Exposed for focused tests that assert the pinned options without performing IO.
  """
  @spec build(Request.t()) :: Req.Request.t()
  def build(%Request{} = request) do
    deadline = System.monotonic_time(:millisecond) + request.timeout_ms

    [
      url: request.url,
      method: request.method,
      headers: request.headers,
      redirect: false,
      max_redirects: 0,
      compressed: false,
      decode_body: false,
      retry: false,
      pool_timeout: request.timeout_ms,
      receive_timeout: request.timeout_ms,
      finch: Pool.name()
    ]
    |> maybe_put_form(request.form)
    |> Req.new()
    |> Req.Request.put_private(@maximum_key, request.max_response_bytes)
    |> Req.Request.put_private(@deadline_key, deadline)
    |> Req.Request.put_private(@timeout_key, request.timeout_ms)
    |> then(
      &%{
        &1
        | into:
            bounded_into(
              request.max_response_bytes,
              deadline,
              request.timeout_ms
            )
      }
    )
    |> Req.Request.prepend_response_steps(arbor_oauth_bounded_body: &assemble_bounded_body/1)
  end

  @doc """
  A `Req` `:into` collector that never retains more than `maximum` bytes.

  On the chunk that would exceed the budget the **whole chunk is discarded** —
  retaining a truncated prefix would leave a torn body that a decoder could
  mistake for a complete one. The overflow is recorded and the request halts.
  """
  @spec bounded_into(pos_integer()) :: (term(), {Req.Request.t(), Req.Response.t()} ->
                                          {:cont | :halt, {Req.Request.t(), Req.Response.t()}})
  def bounded_into(maximum) when is_integer(maximum) and maximum > 0 do
    bounded_into(maximum, :infinity, nil)
  end

  defp bounded_into(maximum, deadline, timeout_ms) do
    fn {:data, data}, {req, resp} when is_binary(data) ->
      if deadline_expired?(deadline) do
        {:halt, mark_timeout(req, resp, timeout_ms)}
      else
        retained = Map.get(resp.private, @bytes_key, 0)

        if retained + byte_size(data) > maximum do
          private =
            resp.private
            |> Map.put(@overflow_key, maximum)
            |> Map.put(@chunks_key, [])

          {:halt, {%{req | halted: true}, %{resp | body: "", private: private}}}
        else
          private =
            resp.private
            |> Map.put(@bytes_key, retained + byte_size(data))
            |> Map.update(@chunks_key, [data], &[data | &1])

          {:cont, {req, %{resp | body: "", private: private}}}
        end
      end
    end
  end

  # --- Private ---

  defp maybe_put_form(opts, nil), do: opts
  defp maybe_put_form(opts, form) when is_map(form), do: Keyword.put(opts, :form, form)

  defp request_before_deadline(req, deadline, timeout_ms) do
    owner = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(owner, {result_ref, Req.request(req)})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        {:arbor_oauth_request_process_exit, :other}
    after
      remaining_ms(deadline) ->
        stop_timed_out_request(pid, monitor_ref, result_ref)
        {:arbor_oauth_deadline_exceeded, timeout_ms}
    end
  end

  defp stop_timed_out_request(pid, monitor_ref, result_ref) do
    Process.exit(pid, :kill)
    await_request_down(pid, monitor_ref, result_ref)
  end

  defp await_request_down(pid, monitor_ref, result_ref) do
    receive do
      {^result_ref, _late_result} ->
        await_request_down(pid, monitor_ref, result_ref)

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        flush_late_result(result_ref)
    end
  end

  defp flush_late_result(result_ref) do
    receive do
      {^result_ref, _late_result} -> :ok
    after
      0 -> :ok
    end
  end

  defp assemble_bounded_body({req, %Req.Response{private: %{@timeout_key => _}} = resp}) do
    {req, resp}
  end

  defp assemble_bounded_body({req, %Req.Response{private: %{@overflow_key => _}} = resp}) do
    {req, resp}
  end

  defp assemble_bounded_body({req, %Req.Response{} = resp}) do
    if deadline_expired?(Map.get(req.private, @deadline_key, :infinity)) do
      mark_timeout(req, resp, Map.get(req.private, @timeout_key))
    else
      case identity_content_encoding(resp) do
        :ok ->
          body =
            resp.private
            |> Map.get(@chunks_key, [])
            |> Enum.reverse()
            |> IO.iodata_to_binary()

          {req, %{resp | body: body}}

        {:error, reason} ->
          {%{req | halted: true},
           %{resp | body: "", private: Map.put(resp.private, :arbor_oauth_response_error, reason)}}
      end
    end
  end

  defp identity_content_encoding(resp) do
    case Req.Response.get_header(resp, "content-encoding") do
      [] ->
        :ok

      values ->
        if Enum.all?(values, &(String.downcase(String.trim(&1)) in ["", "identity"])),
          do: :ok,
          else: {:error, {:invalid_response, :non_identity_content_encoding}}
    end
  end

  defp normalize({:ok, %Req.Response{private: %{@timeout_key => timeout_ms}}}, _request) do
    {:error, {:timeout, timeout_ms}}
  end

  defp normalize({:arbor_oauth_deadline_exceeded, timeout_ms}, _request) do
    {:error, {:timeout, timeout_ms}}
  end

  defp normalize({:arbor_oauth_request_process_exit, :other}, _request) do
    {:error, {:transport_error, :other}}
  end

  defp normalize({:ok, %Req.Response{private: %{@overflow_key => maximum}}}, _request) do
    {:error, {:response_bytes_exceeded, maximum}}
  end

  defp normalize({:ok, %Req.Response{private: %{arbor_oauth_response_error: reason}}}, _request) do
    {:error, reason}
  end

  defp normalize({:ok, %Req.Response{} = resp}, %Request{max_response_bytes: maximum}) do
    body = if is_binary(resp.body), do: resp.body, else: ""

    if byte_size(body) > maximum do
      # Defence in depth: the collector should have halted first.
      {:error, {:response_bytes_exceeded, maximum}}
    else
      {:ok, %Response{status: resp.status, headers: normalize_headers(resp.headers), body: body}}
    end
  end

  defp normalize({:error, exception}, %Request{timeout_ms: timeout_ms}) do
    case transport_reason(exception) do
      :timeout ->
        {:error, {:timeout, timeout_ms}}

      reason when reason in [:econnrefused, :nxdomain, :closed] ->
        {:error, {:transport_error, reason}}

      _other ->
        {:error, {:transport_error, :other}}
    end
  end

  defp transport_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp transport_reason(_exception), do: :other

  defp normalize_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {name, values} ->
      Enum.map(List.wrap(values), &{to_string(name), to_string(&1)})
    end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp normalize_headers(_headers), do: []

  defp mark_timeout(req, resp, timeout_ms) do
    private =
      resp.private
      |> Map.put(@timeout_key, timeout_ms)
      |> Map.put(@chunks_key, [])

    {%{req | halted: true}, %{resp | body: "", private: private}}
  end

  defp deadline_expired?(:infinity), do: false

  defp deadline_expired?(deadline) when is_integer(deadline),
    do: System.monotonic_time(:millisecond) >= deadline

  defp remaining_ms(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
