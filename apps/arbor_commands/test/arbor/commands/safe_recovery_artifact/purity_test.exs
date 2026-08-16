defmodule Arbor.Commands.SafeRecoveryArtifact.PurityTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  @forbidden [
    ~r/DateTime\.utc_now/,
    ~r/System\.(monotonic|os|system)_time/,
    ~r/:rand\./,
    ~r/:erlang\.unique_integer/,
    ~r/\bmake_ref\s*\(/,
    ~r/Application\.(get_env|fetch_env|put_env)/,
    ~r/GenServer\.(call|cast|reply|start_link|start)\b/,
    ~r/:ets\./,
    ~r/\bLogger\./,
    ~r/:crypto\.strong_rand_bytes/,
    ~r/\bProcess\.(send|send_after|monitor|spawn)/,
    ~r/\bFile\.(read|write|open|rm|ls)/,
    ~r/:file\./,
    ~r/String\.to_atom/,
    ~r/List\.to_atom/,
    ~r/binary_to_atom/,
    ~r/list_to_atom/,
    ~r/binary_to_existing_atom/,
    ~r/binary_to_term/,
    ~r/:erl_scan/,
    ~r/:erl_parse/,
    ~r/:file\.consult/,
    ~r/Code\.eval/,
    ~r/Code\.compile/
  ]

  test "production modules contain no impurity or atom-interning" do
    root = Path.expand("../../../../lib/arbor/commands/safe_recovery_artifact", __DIR__)
    paths = Path.wildcard(Path.join(root, "*.ex"))
    assert length(paths) == 5

    Enum.each(paths, fn path ->
      src = File.read!(path)

      Enum.each(@forbidden, fn re ->
        refute Regex.match?(re, src),
               "impure pattern #{inspect(re.source)} found in #{Path.basename(path)}"
      end)
    end)
  end
end
