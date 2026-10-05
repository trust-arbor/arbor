import Config

# Explicit sizing avoids starting OS disk/CPU monitors in a terminal client.
config :back_breeze, render_cache_max_memory_bytes: 256 * 1_024 * 1_024
