defmodule Arbor.Eval.SecurityReview20261006RegressionTest do
  use ExUnit.Case, async: true
  @moduletag spec: "KSEC-001"

  @moduletag :fast

  alias Arbor.Eval

  setup do
    Process.register(self(), :arbor_eval_security_probe)
    :ok
  end

  @tag spec: "KSEC-001"
  test "security regression: compile check never executes or unloads model code" do
    marker = :compile_check_executed_untrusted_code

    code = """
    send(Process.whereis(:arbor_eval_security_probe), #{inspect(marker)})
    # defmodule Arbor.Signals.Bus do end
    :ok
    """

    bus_pid = Process.whereis(Arbor.Signals.Bus)
    assert is_pid(bus_pid)
    assert :code.is_loaded(Arbor.Signals.Bus) != false

    assert [
             %{
               "actual" => ^code,
               "scores" => [%{passed: true, detail: detail}],
               "passed" => true
             }
           ] =
             Eval.run_eval(
               [sample("compile-check-public-boundary", code, nil)],
               "passthrough",
               ["compile_check"]
             )

    refute_receive ^marker
    assert detail =~ "execution not performed"
    assert :code.is_loaded(Arbor.Signals.Bus) != false
    assert Process.whereis(Arbor.Signals.Bus) == bus_pid
    assert Process.alive?(bus_pid)
  end

  test "security regression: functional grader fails closed without evaluating dataset text" do
    marker = :functional_test_executed_untrusted_code

    expected = %{
      "module" => "Anything",
      "tests" => [
        %{
          "setup" => "send(Process.whereis(:arbor_eval_security_probe), #{inspect(marker)})",
          "call" => "send(Process.whereis(:arbor_eval_security_probe), #{inspect(marker)})",
          "expect" => ":ok"
        }
      ]
    }

    actual = "send(Process.whereis(:arbor_eval_security_probe), #{inspect(marker)})"

    assert [
             %{
               "actual" => ^actual,
               "scores" => [%{score: score, passed: false, detail: detail}],
               "passed" => false
             }
           ] =
             Eval.run_eval(
               [sample("functional-public-boundary", actual, expected)],
               "passthrough",
               ["functional_test"]
             )

    assert score == 0.0
    assert detail =~ "isolated evaluator required"
    refute_receive ^marker
  end

  defp sample(id, input, expected) do
    %{
      "id" => id,
      "input" => input,
      "expected" => expected,
      "metadata" => %{}
    }
  end
end
