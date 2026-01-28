is_watch = System.get_env("MIX_TEST_WATCH") == "true"
is_ci = System.get_env("CI") == "true"

exclude =
  cond do
    is_watch -> [:integration, :distributed, :chaos, :slow]
    is_ci -> [:distributed, :chaos]
    true -> [:integration, :distributed, :chaos]
  end

ExUnit.start(exclude: exclude, async: !is_ci)
