defmodule Arbor.Gateway.RateLimiter do
  @moduledoc """
  Simple ETS-based rate limiter plug for the Gateway API.

  Tracks request counts per client IP using sliding time windows.
  Returns 429 Too Many Requests when the limit is exceeded.

  ## Configuration

      config :arbor_gateway, :rate_limit,
        max_requests: 100,        # requests per window
        window_seconds: 60,       # window size
        cleanup_interval: 60_000  # stale bucket cleanup (ms)

  ## Environment Variables

  - `GATEWAY_RATE_LIMIT` — max requests per window (overrides config)
  """

  import Plug.Conn

  @behaviour Plug

  @default_max_requests 100
  @default_window_seconds 60
  @table __MODULE__

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    ensure_table()

    ip = format_ip(conn.remote_ip)
    now = System.system_time(:second)
    {max_requests, window} = get_limits()
    window_key = div(now, window)
    bucket = {ip, window_key}

    count = :ets.update_counter(@table, bucket, {2, 1}, {bucket, 0})

    if count > max_requests do
      conn
      |> put_resp_header("retry-after", to_string(window))
      |> put_resp_content_type("application/json")
      |> send_resp(429, Jason.encode!(%{error: "rate_limit_exceeded", retry_after: window}))
      |> halt()
    else
      conn
      |> put_resp_header("x-ratelimit-limit", to_string(max_requests))
      |> put_resp_header("x-ratelimit-remaining", to_string(max(0, max_requests - count)))
    end
  end

  @doc """
  Clean up expired rate limit buckets. Call periodically.
  """
  @spec cleanup :: :ok
  def cleanup do
    if :ets.whereis(@table) != :undefined do
      now = System.system_time(:second)
      {_max, window} = get_limits()
      current_window = div(now, window)

      # Delete buckets from 2+ windows ago
      :ets.select_delete(@table, [
        {{{:_, :"$1"}, :_}, [{:<, :"$1", current_window - 1}], [true]}
      ])
    end

    :ok
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:public, :set, :named_table, write_concurrency: true])
    end
  rescue
    ArgumentError ->
      # Table already created by another process (race condition)
      :ok
  end

  defp get_limits do
    env_limit =
      case System.get_env("GATEWAY_RATE_LIMIT") do
        nil -> nil
        val -> String.to_integer(val)
      end

    config = Application.get_env(:arbor_gateway, :rate_limit, [])

    max_requests = env_limit || Keyword.get(config, :max_requests, @default_max_requests)
    window = Keyword.get(config, :window_seconds, @default_window_seconds)

    {max_requests, window}
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(other), do: inspect(other)
end
