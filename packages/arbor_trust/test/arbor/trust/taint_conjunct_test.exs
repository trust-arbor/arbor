defmodule Arbor.Trust.TaintConjunctTest do
  use ExUnit.Case, async: true

  alias Arbor.Trust.TaintConjunct

  @moduletag :fast

  describe "mode/2" do
    test "TRUST-15 degrades high-risk effects with untrusted or hostile taint" do
      for effect_class <- [:network_egress, :process_spawn, :financial, :identity_mutating],
          taint <- [:untrusted, :hostile] do
        assert TaintConjunct.mode("arbor://test/op",
                 effect_class: effect_class,
                 operation_taint: taint
               ) == :ask
      end
    end

    test "does not degrade reads, local writes, derived data, or trusted data" do
      assert TaintConjunct.mode("arbor://test/read",
               effect_class: :read,
               operation_taint: :hostile
             ) == :auto

      assert TaintConjunct.mode("arbor://test/write",
               effect_class: :local_write,
               operation_taint: :untrusted
             ) == :auto

      assert TaintConjunct.mode("arbor://test/process",
               effect_class: :process_spawn,
               operation_taint: :derived
             ) == :auto

      assert TaintConjunct.mode("arbor://test/process",
               effect_class: :process_spawn,
               operation_taint: :trusted
             ) == :auto
    end

    test "falls back to capability profile effect class by URI" do
      assert TaintConjunct.mode("arbor://agent/create",
               operation_taint: :hostile
             ) == :ask
    end

    test "uses the worst level from a taint map" do
      taint = %{
        "safe" => %{level: :trusted},
        "unsafe" => %{level: :hostile}
      }

      assert TaintConjunct.mode("arbor://test/process",
               effect_class: :process_spawn,
               operation_taint: taint
             ) == :ask
    end
  end

  describe "security regression: present-but-unreadable taint fails closed (Imp D3 follow-up)" do
    # Pre-fix, an unknown atom/string, `true`, an unlabeled map, or an unknown
    # `:level` normalized to nil and imposed nothing, while EgressGate decided
    # the same value as :untrusted.
    @unreadable [
      :clean,
      true,
      "safe",
      "UNTRUSTED",
      0,
      %{},
      %{level: :bogus},
      %{"level" => "nope"},
      %{"prompt" => "garbage"},
      %{"safe" => %{level: :trusted}, "odd" => :bogus}
    ]

    test "unreadable operation taint degrades high-risk effects to :ask" do
      for taint <- @unreadable, key <- [:operation_taint, :egress_taint, :taint] do
        assert TaintConjunct.mode("arbor://test/process", [
                 {:effect_class, :process_spawn},
                 {key, taint}
               ]) ==
                 :ask,
               "expected #{inspect(key)}: #{inspect(taint)} to degrade"

        assert TaintConjunct.operation_taint([{key, taint}]) == :untrusted
      end
    end

    test "through ProfileResolver, an :auto rule becomes :ask for unreadable taint" do
      profile = %{rules: %{"arbor://test/egress" => :auto}, baseline: :ask}

      for taint <- @unreadable do
        assert Arbor.Trust.ProfileResolver.effective_mode(profile, "arbor://test/egress",
                 security_ceilings: %{},
                 effect_class: :network_egress,
                 operation_taint: taint
               ) == :ask
      end
    end

    test "absent taint stays no-signal: callers that do not track taint are unchanged" do
      for opts <- [[], [operation_taint: nil], [operation_taint: nil, egress_taint: nil]] do
        assert TaintConjunct.operation_taint(opts) == nil

        assert TaintConjunct.mode("arbor://test/process", [effect_class: :process_spawn] ++ opts) ==
                 :auto
      end

      # The action path's explicit clean label for an unlabeled context.
      assert TaintConjunct.mode("arbor://test/process",
               effect_class: :process_spawn,
               operation_taint: nil,
               egress_taint: :trusted
             ) == :auto
    end
  end
end
