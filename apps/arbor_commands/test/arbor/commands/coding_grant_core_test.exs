defmodule Arbor.Commands.CodingGrantCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.CodingGrantCore, as: Core

  @moduletag :fast

  @caller "agent_operator_grant"
  @uri_a "arbor://fs/read/tmp"
  @uri_b "arbor://action/coding/dispatch"
  @uri_c "arbor://agent/dispatch"
  @recorded_caller "agent_operator_recorded"
  @recorded_coordinator "agent_coordinator_recorded"
  @recorded_uri "arbor://action/coding/design_council_review"

  test "exposes new/1, step/2, and show/1 only" do
    assert Enum.sort(Core.__info__(:functions)) == [new: 1, show: 1, step: 2]
  end

  test "module source has no callback invocations on state fields" do
    src = core_source()
    refute src =~ ~r/\.\(/
  end

  test "functional cores contain no impurity" do
    src = core_source()

    forbidden = [
      ~r/DateTime\.utc_now/,
      ~r/System\.(monotonic|os|system)_time/,
      ~r/:rand\./,
      ~r/:erlang\.unique_integer/,
      ~r/\bmake_ref\s*\(/,
      ~r/Application\.get_env/,
      ~r/GenServer\./,
      ~r/\bRepo\./,
      ~r/:ets\./,
      ~r/\bLogger\./
    ]

    Enum.each(forbidden, fn re ->
      refute Regex.match?(re, src), "impure pattern #{inspect(re.source)} in CodingGrantCore"
    end)
  end

  test "new/1 defaults max_rounds to 5 and rejects unknown options" do
    assert {:ok, state} = Core.new([])
    assert state.max_rounds == 5
    assert state.dry_run == false
    assert {:error, :invalid_options} = Core.new(plan: "x")
    assert {:error, :invalid_options} = Core.new("nope")
    assert {:error, :invalid_options} = Core.new(dry_run: :yes)
  end

  test "max_rounds 0, negative, and 21 are invalid_max_rounds even as preconstructed state" do
    report = missing_report([@uri_a])

    Enum.each([0, -1, 21], fn max_rounds ->
      assert {:error, :invalid_max_rounds} = Core.new(max_rounds: max_rounds)

      {:ok, state} = Core.new(max_rounds: 5)
      {_, effect} = Core.step(%{state | max_rounds: max_rounds}, {:readiness, report})
      assert {:halt, result} = effect
      assert result.status == :invalid_max_rounds
      refute match?({:grant, _}, effect)
    end)
  end

  test "empty caller-missing list converges" do
    {:ok, state} = Core.new([])
    {_, {:halt, result}} = Core.step(state, {:readiness, missing_report([])})
    assert result.status == :converged
    assert result.rounds == 1
    assert result.granted == []
    assert result.failed == []
    assert result.remaining == []

    assert Core.show(result) ==
             """
             coding grant: converged
             rounds: 1
             granted: (none)
             failed: (none)
             remaining: (none)
             """
             |> String.trim_trailing()
  end

  test "grant mode grants named URIs then rechecks readiness" do
    {:ok, state} = Core.new(max_rounds: 3)
    target_a = caller_target(@uri_a)
    target_b = caller_target(@uri_b)

    {state, {:grant, ^target_a}} =
      Core.step(state, {:readiness, missing_report([@uri_a, @uri_b])})

    {state, {:grant, ^target_b}} = Core.step(state, {:grant_result, target_a, :ok})
    {state, :readiness} = Core.step(state, {:grant_result, target_b, :ok})
    {_state, {:halt, result}} = Core.step(state, {:readiness, missing_report([])})
    assert result.status == :converged
    assert result.rounds == 2
    assert result.granted == [target_a, target_b]

    assert Core.show(result) ==
             """
             coding grant: converged
             rounds: 2
             granted: arbor://fs/read/tmp
             arbor://action/coding/dispatch
             failed: (none)
             remaining: (none)
             """
             |> String.trim_trailing()
  end

  test "stable missing report invokes readiness exactly N times and stays unconverged" do
    report = missing_report([@uri_a, @uri_b])
    {:ok, state} = Core.new(max_rounds: 2)
    effects = drive_until_halt(state, fn :readiness -> report end)

    readiness_count = Enum.count(effects, &(&1 == :readiness))
    grants = for {:grant, target} <- effects, do: target

    assert readiness_count == 2
    assert grants == [caller_target(@uri_a), caller_target(@uri_b)]
    assert {:halt, result} = List.last(effects)
    assert result.status == :unconverged
    assert result.rounds == 2
    assert result.rounds <= 2
    assert result.remaining == [caller_target(@uri_a), caller_target(@uri_b)]
    assert result.granted == [caller_target(@uri_a), caller_target(@uri_b)]
    assert Core.show(result) =~ @uri_a
    assert Core.show(result) =~ @uri_b
    refute Core.show(result) =~ "execution_principal"
  end

  test "partial progress: first grant succeeds, second fails" do
    {:ok, state} = Core.new(max_rounds: 5)
    target_a = caller_target(@uri_a)
    target_b = caller_target(@uri_b)
    target_c = caller_target(@uri_c)

    {state, {:grant, ^target_a}} =
      Core.step(state, {:readiness, missing_report([@uri_a, @uri_b, @uri_c])})

    {state, {:grant, ^target_b}} = Core.step(state, {:grant_result, target_a, :ok})
    {_state, {:halt, result}} = Core.step(state, {:grant_result, target_b, {:error, :denied}})

    assert result.status == :grant_failed
    assert result.granted == [target_a]
    assert result.failed == [{target_b, :denied}]
    assert result.remaining == [target_b, target_c]
    assert result.rounds == 1

    assert Core.show(result) ==
             """
             coding grant: grant_failed
             rounds: 1
             granted: arbor://fs/read/tmp
             failed: arbor://action/coding/dispatch (:denied)
             remaining: arbor://action/coding/dispatch
             arbor://agent/dispatch
             """
             |> String.trim_trailing()
  end

  test "dry-run invokes readiness every round, emits named URIs without dedupe, and never grants" do
    report = missing_report([@uri_a, @uri_a, @uri_b])
    {:ok, state} = Core.new(max_rounds: 3, dry_run: true)
    effects = drive_until_halt(state, fn :readiness -> report end)

    assert Enum.all?(effects, fn effect -> not match?({:grant, _}, effect) end)
    assert Enum.count(effects, &(&1 == :readiness)) == 3

    emits = for {:emit, text} <- effects, do: text
    assert length(emits) == 3

    Enum.each(emits, fn text ->
      assert text == Enum.join([@uri_a, @uri_a, @uri_b], "\n")
    end)

    assert {:halt, result} = List.last(effects)
    assert result.status == :unconverged
    assert result.rounds == 3
    assert result.granted == []

    assert result.remaining == [
             caller_target(@uri_a),
             caller_target(@uri_a),
             caller_target(@uri_b)
           ]
  end

  test "dry-run converges only when a report names nothing" do
    {:ok, state} = Core.new(dry_run: true, max_rounds: 4)

    {state, {:emit, _text}} = Core.step(state, {:readiness, missing_report([@uri_a])})
    {state, :readiness} = Core.step(state, {:grant_result, :emit_ack, :ok})
    {_state, {:halt, result}} = Core.step(state, {:readiness, missing_report([])})

    assert result.status == :converged
    assert result.rounds == 2
    assert result.granted == []
  end

  @tag :security_regression
  test "security regression: non-map findings entry fails closed with no grants" do
    assert_malformed_no_grant(poisoned_findings(["not-a-map"]))
  end

  @tag :security_regression
  test "security regression: caller/missing resource_uris absent, string, or map fail closed" do
    Enum.each([:absent, "arbor://fs/read/tmp", %{"uri" => @uri_a}], fn bad ->
      finding = caller_missing_finding(bad)
      assert_malformed_no_grant(poisoned_findings([finding]))
    end)
  end

  @tag :security_regression
  test "security regression: nil, non-URI, or root wildcard in resource_uris fail closed" do
    Enum.each([nil, "not-a-uri", "arbor://**"], fn bad ->
      finding = caller_missing_finding([@uri_b, bad])
      assert_malformed_no_grant(poisoned_findings([finding]))
    end)
  end

  @tag :security_regression
  test "security regression: traversal URI in a caller/missing finding fails closed with no sibling grants" do
    finding = caller_missing_finding([@uri_a, "arbor://fs/read/../secret"])
    assert_malformed_no_grant(readiness_report([finding]))

    assert_malformed_no_grant(
      readiness_report([
        caller_missing_finding(["arbor://fs/read/../secret"]),
        caller_missing_finding([@uri_a])
      ])
    )
  end

  @tag :security_regression
  test "security regression: valid caller finding then malformed sibling fails closed with no grants" do
    report = readiness_report([caller_missing_finding([@uri_a]), "not-a-map"])
    assert_malformed_no_grant(report)
  end

  @tag :security_regression
  test "security regression: role-less and unrelated-plane findings never grant" do
    report =
      readiness_report([
        %{"classification" => "missing", "resource_uris" => [@uri_a]}
      ])

    report =
      put_in(report, ["planes", "other"], %{
        "details" => %{
          "projection" => %{
            "authority_horizon" => %{
              "findings" => [caller_missing_finding([@uri_c])],
              "required_resources" => [@uri_c]
            }
          }
        }
      })

    {:ok, state} = Core.new([])
    {_, effect} = Core.step(state, {:readiness, report})
    assert {:halt, result} = effect
    assert result.status == :converged
    refute match?({:grant, _}, effect)
  end

  test "exactly 64 findings and exactly 1024 caller URIs are admitted" do
    findings =
      Enum.map(1..63, fn n ->
        %{
          "principal_role" => "execution_principal",
          "classification" => "ready",
          "resource_uris" => ["arbor://fs/read/noise-#{n}"]
        }
      end) ++ [caller_missing_finding([@uri_a])]

    {:ok, state} = Core.new([])
    {_, effect} = Core.step(state, {:readiness, readiness_report(findings)})
    assert {:grant, target} = effect
    assert target == caller_target(@uri_a)

    uris = Enum.map(1..1024, fn n -> "arbor://fs/read/item-#{n}" end)
    {:ok, state} = Core.new([])
    {_, effect} = Core.step(state, {:readiness, missing_report(uris)})
    assert {:grant, first} = effect
    assert first == caller_target("arbor://fs/read/item-1")
  end

  test "scalar or list at each intermediate horizon path is malformed" do
    {:ok, state} = Core.new([])
    good = readiness_report([])

    Enum.each(["planes", "executor", "details", "projection"], fn key ->
      Enum.each([1, ["not-a-map"]], fn bad ->
        {_, effect} = Core.step(state, {:readiness, replace_path_component(good, key, bad)})
        assert {:halt, result} = effect
        assert result.status == :malformed_report, "expected malformed for #{key}=#{inspect(bad)}"
        refute match?({:grant, _}, effect)
      end)
    end)
  end

  test "later malformed readiness preserves granted progress" do
    {:ok, state} = Core.new([])
    target_a = caller_target(@uri_a)
    {state, {:grant, ^target_a}} = Core.step(state, {:readiness, missing_report([@uri_a])})
    {state, :readiness} = Core.step(state, {:grant_result, target_a, :ok})
    {_state, {:halt, result}} = Core.step(state, {:readiness, :unavailable})

    assert result.status == :malformed_report
    assert result.granted == [target_a]
    assert result.failed == []
    assert result.rounds == 2
  end

  test "wide reports are truncated and never converge" do
    too_many_findings =
      readiness_report(
        Enum.map(1..65, fn n ->
          %{
            "principal_role" => "execution_principal",
            "classification" => "ready",
            "resource_uris" => ["arbor://fs/read/extra-#{n}"]
          }
        end)
      )

    {:ok, state} = Core.new([])
    {_, {:halt, result}} = Core.step(state, {:readiness, too_many_findings})
    assert result.status == :report_truncated
    refute result.status == :converged

    too_many_uris =
      missing_report(Enum.map(1..1025, fn n -> "arbor://fs/read/item-#{n}" end))

    {:ok, state} = Core.new([])
    {_, {:halt, result}} = Core.step(state, {:readiness, too_many_uris})
    assert result.status == :report_truncated
    refute result.status == :converged
  end

  test "32 irrelevant findings then a caller finding grants or truncates, never converges" do
    findings =
      Enum.map(1..32, fn n ->
        %{
          "principal_role" => "execution_principal",
          "classification" => "ready",
          "resource_uris" => ["arbor://fs/read/noise-#{n}"]
        }
      end) ++ [caller_missing_finding([@uri_a])]

    {:ok, state} = Core.new([])
    {_, effect} = Core.step(state, {:readiness, readiness_report(findings)})

    case effect do
      {:grant, target} ->
        assert target == caller_target(@uri_a)

      {:halt, result} ->
        assert result.status == :report_truncated
        refute result.status == :converged

      other ->
        flunk("expected grant or truncation, got #{inspect(other)}")
    end
  end

  test "absent or wrong-shaped horizon is malformed" do
    {:ok, state} = Core.new([])
    {_, {:halt, result}} = Core.step(state, {:readiness, %{}})
    assert result.status == :malformed_report

    report = readiness_report([])

    report =
      put_in(report, ["planes", "executor", "details", "projection", "authority_horizon"], 1)

    {_, {:halt, result}} = Core.step(state, {:readiness, report})
    assert result.status == :malformed_report
  end

  test "security regression: converged despite execution-principal missing findings on recorded 2026-08-31 shape" do
    report = recorded_exec_missing_report()
    target = exec_target(@recorded_uri, @recorded_coordinator)

    {:ok, state} = Core.new(max_rounds: 3)
    {state, effect} = Core.step(state, {:readiness, report})
    assert {:grant, ^target} = effect
    refute match?({:halt, %{status: :converged}}, effect)

    {state, :readiness} = Core.step(state, {:grant_result, target, :ok})
    {_state, {:halt, result}} = Core.step(state, {:readiness, recorded_empty_report()})
    assert result.status == :converged
    assert result.granted == [target]

    {:ok, limited} = Core.new(max_rounds: 1)
    {_state, {:halt, unconverged}} = Core.step(limited, {:readiness, report})
    assert unconverged.status == :unconverged
    assert unconverged.remaining == [target]
    refute unconverged.status == :converged
  end

  test "a URI is never granted to a principal the readiness report did not name" do
    named = "agent_named"
    caller = "agent_caller"
    uri = @uri_b

    report =
      readiness_report(
        [
          %{
            "principal_role" => "execution_principal",
            "classification" => "missing",
            "resource_uris" => [uri]
          }
        ],
        caller_id: caller,
        principals: [
          %{"role" => "execution_principal", "principal_id" => named},
          %{"role" => "authenticated_caller", "principal_id" => caller}
        ]
      )

    {:ok, state} = Core.new([])
    {_, effect} = Core.step(state, {:readiness, report})
    assert {:grant, target} = effect
    assert target == exec_target(uri, named)
    refute target.principal_id == caller
    refute target.principal_id == "agent_other"
  end

  test "unresolvable execution-principal missing finding is malformed with no grants" do
    report =
      readiness_report(
        [
          %{
            "principal_role" => "execution_principal",
            "classification" => "missing",
            "resource_uris" => [@uri_b]
          }
        ],
        caller_id: nil,
        principals: []
      )
      |> Map.delete("caller_id")

    assert_malformed_no_grant(report)
  end

  test "finding principal_id that disagrees with the named role id is malformed with no grants" do
    report =
      readiness_report(
        [
          %{
            "principal_role" => "execution_principal",
            "principal_id" => "agent_other",
            "classification" => "missing",
            "resource_uris" => [@uri_b]
          }
        ],
        principals: [
          %{"role" => "execution_principal", "principal_id" => @recorded_coordinator},
          %{"role" => "authenticated_caller", "principal_id" => @caller}
        ]
      )

    assert_malformed_no_grant(report)
  end

  test "plan-validation error with field is surfaced verbatim" do
    report =
      projection_error_report(%{
        "code" => "invalid_object",
        "field" => "workspace_policy"
      })

    {:ok, state} = Core.new([])
    {_, effect} = Core.step(state, {:readiness, report})
    assert {:halt, result} = effect
    assert result.status == {:invalid_object, "workspace_policy"}
    refute match?({:grant, _}, effect)
    assert result.granted == []
    shown = Core.show(result)
    assert shown =~ ~s({:invalid_object, "workspace_policy"})
    refute shown =~ "malformed_report"
  end

  test "live executor plan-validation encoding is not malformed_report" do
    report =
      projection_error_report(%{
        "code" => "invalid_object",
        "message" => "dispatch readiness blocked: invalid_object"
      })

    {:ok, state} = Core.new([])
    {_, effect} = Core.step(state, {:readiness, report})
    assert {:halt, result} = effect
    assert result.status == :invalid_object
    refute result.status == :malformed_report
    refute match?({:grant, _}, effect)
    assert result.granted == []
  end

  test "horizon nil without a plan-validation error stays malformed_report" do
    {:ok, state} = Core.new([])
    {_, {:halt, result}} = Core.step(state, {:readiness, :unavailable})
    assert result.status == :malformed_report

    {_, {:halt, empty}} = Core.step(state, {:readiness, %{}})
    assert empty.status == :malformed_report
  end

  test "binary grant ack is not accepted as a grant" do
    {:ok, state} = Core.new([])
    target = caller_target(@uri_a)
    {state, {:grant, ^target}} = Core.step(state, {:readiness, missing_report([@uri_a])})
    {_state, {:halt, result}} = Core.step(state, {:grant_result, @uri_a, :ok})
    assert result.status == :grant_failed
    assert result.granted == []
  end

  defp assert_malformed_no_grant(report) do
    {:ok, state} = Core.new([])
    {_, effect} = Core.step(state, {:readiness, report})
    assert {:halt, result} = effect
    assert result.status == :malformed_report
    refute match?({:grant, _}, effect)
    assert result.granted == []
  end

  defp drive_until_halt(state, readiness_fun, effects \\ []) do
    drive(state, :readiness, readiness_fun, effects)
  end

  defp drive(_state, {:halt, result}, _readiness_fun, effects) do
    Enum.reverse([{:halt, result} | effects])
  end

  defp drive(state, :readiness, readiness_fun, effects) do
    report = readiness_fun.(:readiness)
    {state, effect} = Core.step(state, {:readiness, report})
    drive(state, effect, readiness_fun, [:readiness | effects])
  end

  defp drive(state, {:grant, target}, readiness_fun, effects) do
    {state, effect} = Core.step(state, {:grant_result, target, :ok})
    drive(state, effect, readiness_fun, [{:grant, target} | effects])
  end

  defp drive(state, {:emit, text}, readiness_fun, effects) do
    {state, effect} = Core.step(state, {:grant_result, :emit_ack, :ok})
    drive(state, effect, readiness_fun, [{:emit, text} | effects])
  end

  defp poisoned_findings([bad | _ignore]) do
    readiness_report([bad, caller_missing_finding([@uri_a])])
  end

  defp missing_report(uris) do
    readiness_report([caller_missing_finding(uris)])
  end

  defp caller_missing_finding(:absent) do
    %{"principal_role" => "authenticated_caller", "classification" => "missing"}
  end

  defp caller_missing_finding(uris) do
    %{
      "principal_role" => "authenticated_caller",
      "classification" => "missing",
      "resource_uris" => uris
    }
  end

  defp caller_target(uri, principal_id \\ @caller) do
    %{principal_role: "authenticated_caller", principal_id: principal_id, uri: uri}
  end

  defp exec_target(uri, principal_id) do
    %{principal_role: "execution_principal", principal_id: principal_id, uri: uri}
  end

  defp recorded_exec_missing_report do
    readiness_report(
      [
        %{
          "principal_role" => "execution_principal",
          "classification" => "missing",
          "total_count" => 1,
          "resource_uris" => [@recorded_uri],
          "resource_uris_digest" => "sha256:" <> String.duplicate("ab", 32)
        }
      ],
      caller_id: @recorded_caller,
      agent_id: @recorded_coordinator,
      principals: [
        %{"role" => "execution_principal", "principal_id" => @recorded_coordinator},
        %{"role" => "authenticated_caller", "principal_id" => @recorded_caller}
      ],
      required_resources: %{
        "total_count" => 1,
        "resource_uris" => [@recorded_uri],
        "resource_uris_digest" => "sha256:" <> String.duplicate("ab", 32)
      }
    )
  end

  defp recorded_empty_report do
    readiness_report([],
      caller_id: @recorded_caller,
      agent_id: @recorded_coordinator,
      principals: [
        %{"role" => "execution_principal", "principal_id" => @recorded_coordinator},
        %{"role" => "authenticated_caller", "principal_id" => @recorded_caller}
      ]
    )
  end

  defp readiness_report(findings, opts \\ []) do
    caller_id = Keyword.get(opts, :caller_id, @caller)
    agent_id = Keyword.get(opts, :agent_id)
    principals = Keyword.get(opts, :principals, default_principals(caller_id, agent_id))

    required =
      Keyword.get(opts, :required_resources, %{
        "total_count" => 0,
        "resource_uris" => [],
        "resource_uris_digest" => "sha256:" <> String.duplicate("00", 32)
      })

    horizon =
      %{
        "findings" => findings,
        "required_resources" => required
      }
      |> maybe_put("principals", principals)

    projection = %{"authority_horizon" => horizon}

    %{
      "planes" => %{
        "executor" => %{
          "details" => %{
            "projection" => projection
          }
        }
      }
    }
    |> maybe_put("caller_id", caller_id)
    |> maybe_put("agent_id", agent_id)
  end

  defp default_principals(caller_id, agent_id) do
    []
    |> maybe_principal("authenticated_caller", caller_id)
    |> maybe_principal("execution_principal", agent_id)
  end

  defp maybe_principal(list, _role, id) when not is_binary(id) or id == "", do: list
  defp maybe_principal(list, role, id), do: list ++ [%{"role" => role, "principal_id" => id}]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp projection_error_report(error) do
    %{
      "planes" => %{
        "executor" => %{
          "details" => %{
            "projection" => %{
              "kind" => "coding_dispatch_readiness",
              "authority_horizon" => nil,
              "error" => error
            }
          }
        }
      }
    }
  end

  defp replace_path_component(report, key, value) do
    parent = Enum.take_while(["planes", "executor", "details", "projection"], &(&1 != key))
    put_in(report, parent ++ [key], value)
  end

  defp core_source do
    Path.expand("../../../lib/arbor/commands/coding_grant_core.ex", __DIR__)
    |> File.read!()
  end
end
