defmodule Arbor.Commands.CodingGrantCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.CodingGrantCore, as: Core

  @moduletag :fast

  @uri_a "arbor://fs/read/tmp"
  @uri_b "arbor://action/coding/dispatch"
  @uri_c "arbor://agent/dispatch"

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
  end

  test "grant mode grants named URIs then rechecks readiness" do
    {:ok, state} = Core.new(max_rounds: 3)
    {state, {:grant, @uri_a}} = Core.step(state, {:readiness, missing_report([@uri_a, @uri_b])})
    {state, {:grant, @uri_b}} = Core.step(state, {:grant_result, @uri_a, :ok})
    {state, :readiness} = Core.step(state, {:grant_result, @uri_b, :ok})
    {_state, {:halt, result}} = Core.step(state, {:readiness, missing_report([])})
    assert result.status == :converged
    assert result.rounds == 2
    assert result.granted == [@uri_a, @uri_b]
  end

  test "stable missing report invokes readiness exactly N times and stays unconverged" do
    report = missing_report([@uri_a, @uri_b])
    {:ok, state} = Core.new(max_rounds: 2)
    effects = drive_until_halt(state, fn :readiness -> report end)

    readiness_count = Enum.count(effects, &(&1 == :readiness))
    grants = for {:grant, uri} <- effects, do: uri

    assert readiness_count == 2
    assert grants == [@uri_a, @uri_b]
    assert {:halt, result} = List.last(effects)
    assert result.status == :unconverged
    assert result.rounds == 2
    assert result.rounds <= 2
    assert result.remaining == [@uri_a, @uri_b]
    assert result.granted == [@uri_a, @uri_b]
    assert Core.show(result) =~ @uri_a
    assert Core.show(result) =~ @uri_b
  end

  test "partial progress: first grant succeeds, second fails" do
    {:ok, state} = Core.new(max_rounds: 5)

    {state, {:grant, @uri_a}} =
      Core.step(state, {:readiness, missing_report([@uri_a, @uri_b, @uri_c])})

    {state, {:grant, @uri_b}} = Core.step(state, {:grant_result, @uri_a, :ok})
    {_state, {:halt, result}} = Core.step(state, {:grant_result, @uri_b, {:error, :denied}})

    assert result.status == :grant_failed
    assert result.granted == [@uri_a]
    assert result.failed == [{@uri_b, :denied}]
    assert result.remaining == [@uri_b, @uri_c]
    assert result.rounds == 1
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
    assert result.remaining == [@uri_a, @uri_a, @uri_b]
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
  test "security regression: role-less, execution_principal, and unrelated-plane findings never grant" do
    report =
      readiness_report([
        %{"classification" => "missing", "resource_uris" => [@uri_a]},
        %{
          "principal_role" => "execution_principal",
          "classification" => "missing",
          "resource_uris" => [@uri_b]
        }
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
          "classification" => "missing",
          "resource_uris" => ["arbor://fs/read/noise-#{n}"]
        }
      end) ++ [caller_missing_finding([@uri_a])]

    {:ok, state} = Core.new([])
    {_, effect} = Core.step(state, {:readiness, readiness_report(findings)})
    assert {:grant, @uri_a} = effect

    uris = Enum.map(1..1024, fn n -> "arbor://fs/read/item-#{n}" end)
    {:ok, state} = Core.new([])
    {_, effect} = Core.step(state, {:readiness, missing_report(uris)})
    assert {:grant, "arbor://fs/read/item-1"} = effect
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
    {state, {:grant, @uri_a}} = Core.step(state, {:readiness, missing_report([@uri_a])})
    {state, :readiness} = Core.step(state, {:grant_result, @uri_a, :ok})
    {_state, {:halt, result}} = Core.step(state, {:readiness, :unavailable})

    assert result.status == :malformed_report
    assert result.granted == [@uri_a]
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
          "classification" => "missing",
          "resource_uris" => ["arbor://fs/read/noise-#{n}"]
        }
      end) ++ [caller_missing_finding([@uri_a])]

    {:ok, state} = Core.new([])
    {_, effect} = Core.step(state, {:readiness, readiness_report(findings)})

    case effect do
      {:grant, @uri_a} ->
        assert true

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

  defp drive(state, {:grant, uri}, readiness_fun, effects) do
    {state, effect} = Core.step(state, {:grant_result, uri, :ok})
    drive(state, effect, readiness_fun, [{:grant, uri} | effects])
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

  defp readiness_report(findings) do
    %{
      "planes" => %{
        "executor" => %{
          "details" => %{
            "projection" => %{
              "authority_horizon" => %{
                "findings" => findings,
                "required_resources" => %{
                  "total_count" => 0,
                  "resource_uris" => [],
                  "resource_uris_digest" => "sha256:" <> String.duplicate("00", 32)
                }
              }
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
