defmodule Arbor.Actions.Coding.DesignCouncilCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.DesignCouncilCore
  alias Arbor.Contracts.Coding.DesignArtifactDescriptor

  @moduletag :fast

  @perspectives [
    :brainstorming,
    :user_experience,
    :security,
    :privacy,
    :stability,
    :capability,
    :emergence,
    :vision,
    :performance,
    :generalization,
    :resource_usage,
    :consistency,
    :adversarial
  ]

  test "unanimous approve yields approve, empty note, and full dispersion" do
    assert {:ok, decided} = decide(unanimous(:approve))
    assert decided["checkpoint_outcome"] == "approve"
    assert decided["note"] == ""

    assert decided["dispersion"] == %{
             "approve" => 13,
             "reject" => 0,
             "abstain" => 0,
             "error" => 0,
             "responded" => 13
           }
  end

  test "one security reject forces rework even when others approve" do
    evaluations =
      unanimous(:approve)
      |> put_vote(:security, :reject, ["Missing capability check"])

    assert {:ok, decided} = decide(evaluations)
    assert decided["checkpoint_outcome"] == "rework"
    assert decided["note"] == "Missing capability check"
    assert decided["dispersion"]["reject"] == 1
    assert decided["dispersion"]["approve"] == 12
    assert decided["dispersion"]["responded"] == 13
  end

  test "three generic rejects force rework" do
    evaluations =
      unanimous(:approve)
      |> put_vote(:privacy, :reject, ["Name the privacy bound"])
      |> put_vote(:capability, :reject, ["Name the missing grant"])
      |> put_vote(:vision, :reject, ["Name the missing success criterion"])

    assert {:ok, decided} = decide(evaluations)
    assert decided["checkpoint_outcome"] == "rework"
    assert decided["dispersion"]["reject"] == 3

    assert decided["note"] ==
             "Name the missing grant\nName the missing success criterion\nName the privacy bound"
  end

  test "six responders is below the default min and yields rework" do
    evaluations =
      @perspectives
      |> Enum.take(6)
      |> Enum.map(fn perspective ->
        {perspective, %{vote: :approve, concerns: [], perspective: perspective}}
      end)
      |> Kernel.++(
        @perspectives
        |> Enum.drop(6)
        |> Enum.map(fn perspective ->
          {perspective, %{vote: :abstain, concerns: [], perspective: perspective}}
        end)
      )

    assert {:ok, decided} = decide(evaluations)
    assert decided["checkpoint_outcome"] == "rework"
    assert decided["dispersion"]["responded"] == 6
    assert decided["dispersion"]["abstain"] == 7
  end

  test "all-abstain never counts as approval" do
    assert {:ok, decided} = decide(unanimous(:abstain))
    assert decided["checkpoint_outcome"] == "rework"
    assert decided["dispersion"]["responded"] == 0
    assert decided["dispersion"]["abstain"] == 13
    assert decided["dispersion"]["approve"] == 0
  end

  test "note is bounded, unique, and deterministically ordered" do
    evaluations = [
      {:adversarial, %{vote: :approve, concerns: []}},
      {:security, %{vote: :approve, concerns: []}},
      {:stability, %{vote: :approve, concerns: []}},
      {:privacy, %{vote: :reject, concerns: ["zeta concern", "alpha concern"]}},
      {:capability, %{vote: :reject, concerns: ["alpha concern", String.duplicate("x", 500)]}}
    ]

    assert {:ok, decided} = decide(evaluations)
    lines = String.split(decided["note"], "\n")
    assert lines == Enum.sort(lines)
    assert length(lines) == 3
    assert hd(lines) == "alpha concern"
    assert Enum.all?(lines, &(byte_size(&1) <= 400))
  end

  test "malformed concern terms on non-veto seats are errors, never raised or inspected" do
    evaluations = [
      {:adversarial, %{vote: :approve, concerns: []}},
      {:security, %{vote: :approve, concerns: []}},
      {:stability, %{vote: :approve, concerns: []}},
      {:brainstorming, %{vote: :approve, concerns: [%{nested: :map}]}},
      {:user_experience, %{vote: :approve, concerns: [{:tuple, :term}]}},
      {:privacy, %{vote: :approve, concerns: [<<0xFF, 0xFE>>]}},
      {:capability, %{vote: :approve, concerns: ["valid concern"]}}
    ]

    assert {:ok, state} = DesignCouncilCore.new(%{"evaluations" => evaluations})
    assert {:ok, decided} = DesignCouncilCore.decide(state)
    assert decided["dispersion"]["error"] == 3
    assert decided["dispersion"]["approve"] == 4
    assert decided["checkpoint_outcome"] == "rework"
  end

  test "malformed concern terms on a veto seat fail closed as veto unavailable" do
    evaluations =
      unanimous(:approve)
      |> put_vote(:security, :approve, [%{nested: :map}])

    assert {:error, :design_council_veto_unavailable} = decide(evaluations)
  end

  test "each default veto provider error fails closed instead of approving" do
    for perspective <- [:adversarial, :security, :stability] do
      evaluations = put_error(unanimous(:approve), perspective, :api_error)
      assert {:error, :design_council_veto_unavailable} = decide(evaluations)
    end
  end

  test "a non-veto provider error still approves when responder quorum holds" do
    evaluations = put_error(unanimous(:approve), :brainstorming, :api_error)
    assert {:ok, decided} = decide(evaluations)
    assert decided["checkpoint_outcome"] == "approve"
    assert decided["dispersion"]["error"] == 1
    assert decided["dispersion"]["approve"] == 12
    assert decided["dispersion"]["responded"] == 12
  end

  test "a veto-seat error wins over a reject-threshold rework" do
    evaluations =
      unanimous(:approve)
      |> put_error(:security, :api_error)
      |> put_vote(:privacy, :reject, ["Name the privacy bound"])
      |> put_vote(:capability, :reject, ["Name the missing grant"])
      |> put_vote(:vision, :reject, ["Name the missing success criterion"])

    assert {:error, :design_council_veto_unavailable} = decide(evaluations)
  end

  test "custom veto_perspectives treat only the configured seat error as unavailable" do
    privacy_error = put_error(unanimous(:approve), :privacy, :api_error)
    security_error = put_error(unanimous(:approve), :security, :api_error)

    assert {:error, :design_council_veto_unavailable} =
             decide(privacy_error, %{"veto_perspectives" => ["privacy"]})

    assert {:ok, decided} = decide(security_error, %{"veto_perspectives" => ["privacy"]})
    assert decided["checkpoint_outcome"] == "approve"
    assert decided["dispersion"]["error"] == 1
    assert decided["dispersion"]["reject"] == 0
  end

  test "a security rework vote still yields rework, not veto unavailability" do
    evaluations = put_vote(unanimous(:approve), :security, :rework, ["Missing capability check"])
    assert {:ok, decided} = decide(evaluations)
    assert decided["checkpoint_outcome"] == "rework"
    assert decided["note"] == "Missing capability check"
    assert decided["dispersion"]["reject"] == 1
  end

  test "an omitted default veto seat fails closed as veto unavailable" do
    evaluations =
      unanimous(:approve)
      |> Enum.reject(fn {perspective, _eval} -> perspective == :security end)

    assert {:error, :design_council_veto_unavailable} = decide(evaluations)
  end

  test "a duplicate veto seat identity fails closed as veto unavailable" do
    evaluations =
      unanimous(:approve) ++
        [{:security, %{vote: :approve, concerns: [], perspective: :security}}]

    assert {:error, :design_council_veto_unavailable} = decide(evaluations)
  end

  test "near-limit valid packet keeps the design and every section label" do
    design = String.duplicate("d", DesignArtifactDescriptor.max_bytes())
    task = String.duplicate("t", 4_096)
    item = String.duplicate("i", 4_094)

    packet = %{
      "success_criteria" => [item],
      "constraints" => [item],
      "non_goals" => [item],
      "architecture_refs" => [item]
    }

    plan_review_context =
      ~s({"budgets":{"wall_clock_ms":28800000},"plan_fingerprint":"#{String.duplicate("a", 64)}"})

    assert {:ok, question} =
             DesignCouncilCore.build_question(packet, task, plan_review_context, design)

    assert question =~
             "Judge only the frozen task, compiler-owned plan review context, success criteria"

    assert question =~ "new platform features outside this packet are nonblocking"
    assert question =~ "manager-observed verification"
    assert question =~ "cannot deny or expand the task"
    assert question =~ "Task:"
    assert question =~ "Plan review context (canonical JSON):"
    assert question =~ ~s("wall_clock_ms":28800000)
    assert question =~ "Success criteria:"
    assert question =~ "Constraints:"
    assert question =~ "Non-goals:"
    assert question =~ "Architecture refs:"
    assert question =~ "Design:"
    assert question =~ design
    assert question =~ task
    refute byte_size(question) > 65_536
  end

  test "show/1 returns the decided map or an error on invalid state" do
    assert {:ok, decided} = decide(unanimous(:approve))
    assert {:ok, ^decided} = DesignCouncilCore.show(decided)
    assert {:error, :invalid_design_council_state} = DesignCouncilCore.show(%{})
    assert {:error, :invalid_design_council_state} = DesignCouncilCore.show(:not_a_result)
  end

  test "question overflow fails closed instead of tail-clipping" do
    design = String.duplicate("d", DesignArtifactDescriptor.max_bytes() + 1)

    assert {:error, {:design_council_section_overflow, "design"}} =
             DesignCouncilCore.build_question(
               %{"success_criteria" => ["one"]},
               "task",
               ~s({"budgets":{"wall_clock_ms":10000}}),
               design
             )
  end

  test "functional core contains no impurity" do
    source =
      File.read!(
        Path.expand(
          "../../../../lib/arbor/actions/coding/design_council_core.ex",
          __DIR__
        )
      )

    for forbidden <- [
          "File.",
          "System.",
          "Application.",
          "Registry.",
          "GenServer.",
          "Process.",
          ":ets.",
          "DateTime.utc_now",
          "make_ref",
          "strong_rand_bytes",
          "String.to_atom",
          "IO."
        ] do
      refute source =~ forbidden, "design council core must not call #{forbidden}"
    end
  end

  defp decide(evaluations, extra \\ %{}) do
    params = Map.merge(%{"evaluations" => evaluations}, extra)

    with {:ok, state} <- DesignCouncilCore.new(params) do
      DesignCouncilCore.decide(state)
    end
  end

  defp unanimous(vote) do
    Enum.map(@perspectives, fn perspective ->
      {perspective, %{vote: vote, concerns: [], perspective: perspective}}
    end)
  end

  defp put_vote(evaluations, perspective, vote, concerns) do
    Enum.map(evaluations, fn
      {^perspective, eval} -> {perspective, Map.merge(eval, %{vote: vote, concerns: concerns})}
      other -> other
    end)
  end

  defp put_error(evaluations, perspective, reason) do
    Enum.map(evaluations, fn
      {^perspective, _eval} -> {perspective, {:error, reason}}
      other -> other
    end)
  end
end
