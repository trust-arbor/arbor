defmodule Arbor.LLM.OpenCodeZen.PurityTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  @forbidden [
    ~r/DateTime\.utc_now/,
    ~r/System\.(monotonic|os|system)_time/,
    ~r/:rand\./,
    ~r/:erlang\.unique_integer/,
    ~r/\bmake_ref\s*\(/,
    ~r/Application\.get_env/,
    ~r/GenServer\.(call|cast|reply|start_link|start)\b/,
    ~r/\bRepo\./,
    ~r/:ets\./,
    ~r/\bLogger\./,
    ~r/\bFile\.(read|write|open|rm|ls)/
  ]

  test "functional cores contain no impurity" do
    path =
      Path.expand("../../../../lib/arbor/llm/opencode_zen/admission_core.ex", __DIR__)

    assert File.exists?(path)
    src = File.read!(path)

    for re <- @forbidden do
      refute Regex.match?(re, src),
             "impure pattern #{inspect(re.source)} found in #{Path.relative_to_cwd(path)}"
    end
  end
end
