defmodule Arbor.Trust.BaselineConstraintTest do
  @moduledoc """
  A4 / P1 (capability-policy-model-review): a trust profile's BASELINE may be
  `:block` or `:ask` only. An `:auto` baseline (or unflagged `:allow`) inverts
  deny-by-default into a denylist — the polarity inversion. Enforced at
  `Authority.effective_mode` (the guaranteed point every profile passes through,
  regardless of how the baseline was set). Per-URI `:auto`/`:allow` RULES are
  untouched — earned autonomy on a specific power stays.
  """
  use ExUnit.Case, async: false

  alias Arbor.Trust.Authority

  # A plain resource: not infrastructure-auto, not in the default ceilings.
  @uri "arbor://code/read"

  defp profile_with_baseline(baseline, rules \\ %{}) do
    %{Authority.new_profile("agent_a4") | baseline: baseline, rules: rules}
  end

  test "an :auto baseline never resolves as the effective default (P1)" do
    assert Authority.effective_mode(profile_with_baseline(:auto), @uri) == :block
  end

  test "an :allow baseline coerces to :block without the opt-in flag" do
    assert Authority.effective_mode(profile_with_baseline(:allow), @uri) == :block
  end

  test "an :allow baseline stays :allow WITH config :arbor_trust, :allow_permissive_baseline" do
    prev = Application.get_env(:arbor_trust, :allow_permissive_baseline)
    Application.put_env(:arbor_trust, :allow_permissive_baseline, true)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:arbor_trust, :allow_permissive_baseline)
        v -> Application.put_env(:arbor_trust, :allow_permissive_baseline, v)
      end
    end)

    assert Authority.effective_mode(profile_with_baseline(:allow), @uri) == :allow
  end

  test ":block and :ask baselines pass through unchanged" do
    assert Authority.effective_mode(profile_with_baseline(:block), @uri) == :block
    assert Authority.effective_mode(profile_with_baseline(:ask), @uri) == :ask
  end

  test "a per-URI :auto RULE under a :block baseline still resolves :auto (only the baseline is constrained)" do
    profile = profile_with_baseline(:block, %{@uri => :auto})
    assert Authority.effective_mode(profile, @uri) == :auto
  end
end
