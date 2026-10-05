import Config

case System.get_env("ARBOR_BREEZE_RENDER_CACHE_BYTES") do
  nil ->
    :ok

  value ->
    case Integer.parse(value) do
      {bytes, ""} when bytes > 0 ->
        config :back_breeze, render_cache_max_memory_bytes: bytes

      _ ->
        raise ArgumentError, "ARBOR_BREEZE_RENDER_CACHE_BYTES must be a positive integer"
    end
end
