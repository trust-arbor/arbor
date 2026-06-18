# credo:disable-for-this-file
defmodule Arbor.Actions.Security.PrecisionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.Precision

  defp sib(id), do: %{id: id}

  describe "assess/3 — admit vs reject" do
    test "admits when precision >= floor (default 0.5)" do
      siblings = [sib("a"), sib("b"), sib("c"), sib("d")]
      verdicts = %{"a" => :confirmed, "b" => :confirmed, "c" => :confirmed, "d" => :refuted}

      assessment = Precision.assess(siblings, verdicts)

      assert assessment.confirmed == 3
      assert assessment.refuted == 1
      assert assessment.precision == 0.75
      assert assessment.admit? == true
      assert assessment.reason == :meets_precision_floor
    end

    test "rejects {:below_precision_floor, ...} when below the floor" do
      siblings = [sib("a"), sib("b"), sib("c"), sib("d")]
      verdicts = %{"a" => :confirmed, "b" => :refuted, "c" => :refuted, "d" => :refuted}

      assessment = Precision.assess(siblings, verdicts)

      assert assessment.confirmed == 1
      assert assessment.refuted == 3
      assert assessment.precision == 0.25
      assert assessment.admit? == false
      assert assessment.reason == {:below_precision_floor, 0.25, 0.5}
    end

    test "boundary: precision exactly == floor admits" do
      siblings = [sib("a"), sib("b")]
      verdicts = %{"a" => :confirmed, "b" => :refuted}

      assessment = Precision.assess(siblings, verdicts, threshold: 0.5)

      assert assessment.precision == 0.5
      assert assessment.admit? == true
      assert assessment.reason == :meets_precision_floor
    end

    test "boundary: precision just below an explicit threshold rejects" do
      siblings = [sib("a"), sib("b"), sib("c")]
      verdicts = %{"a" => :confirmed, "b" => :confirmed, "c" => :refuted}

      # precision = 2/3 ≈ 0.6667; threshold 0.7 → reject
      assessment = Precision.assess(siblings, verdicts, threshold: 0.7)

      assert assessment.precision == 0.6667
      assert assessment.admit? == false
      assert {:below_precision_floor, 0.6667, 0.7} = assessment.reason
    end

    test "all confirmed → precision 1.0, admitted" do
      siblings = [sib("a"), sib("b")]
      verdicts = %{"a" => :confirmed, "b" => :confirmed}

      assessment = Precision.assess(siblings, verdicts)

      assert assessment.precision == 1.0
      assert assessment.admit? == true
    end

    test "all refuted → precision 0.0, rejected below floor" do
      siblings = [sib("a"), sib("b")]
      verdicts = %{"a" => :refuted, "b" => :refuted}

      assessment = Precision.assess(siblings, verdicts)

      assert assessment.precision == 0.0
      assert assessment.admit? == false
      assert {:below_precision_floor, +0.0, _} = assessment.reason
    end
  end

  describe "assess/3 — edge cases" do
    test "no triaged siblings → not admitted, reason :no_triaged_siblings (fail closed)" do
      assessment = Precision.assess([sib("a")], %{})

      assert assessment.confirmed == 0
      assert assessment.refuted == 0
      assert assessment.precision == 0.0
      assert assessment.admit? == false
      assert assessment.reason == :no_triaged_siblings
    end

    test "verdicts for non-sibling ids are ignored" do
      siblings = [sib("a"), sib("b")]
      # "ghost" is not in siblings → ignored; only a/b count.
      verdicts = %{"a" => :confirmed, "b" => :confirmed, "ghost" => :refuted}

      assessment = Precision.assess(siblings, verdicts)

      assert assessment.confirmed == 2
      assert assessment.refuted == 0
      assert assessment.precision == 1.0
      assert assessment.admit? == true
    end

    test "accepts string-keyed sibling maps" do
      siblings = [%{"id" => "a"}, %{"id" => "b"}]
      verdicts = %{"a" => :confirmed, "b" => :refuted}

      assessment = Precision.assess(siblings, verdicts)

      assert assessment.confirmed == 1
      assert assessment.refuted == 1
      assert assessment.precision == 0.5
      assert assessment.admit? == true
    end
  end

  describe "resolve_threshold/1" do
    test "opts threshold wins" do
      assert Precision.resolve_threshold(threshold: 0.9) == 0.9
    end

    test "falls back to app env, then default 0.5" do
      # No app env set in test → default.
      assert Precision.resolve_threshold([]) == 0.5
    end
  end
end
