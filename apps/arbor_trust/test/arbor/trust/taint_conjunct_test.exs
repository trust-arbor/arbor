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
end
