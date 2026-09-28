defmodule Arbor.LLM.ToolLoopCallOutcomeSecurityRegressionTest do
  @moduledoc """
  Security regression (D5, imp-dspy-port review 2026-09-27): when a model
  repeats a call whose earlier attempt may have taken effect with no answer,
  ToolLoop re-ran it after backoff without looking at the outcome or the
  tool's replay class, so a timed-out side-effecting call could be duplicated.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Tool.CallFailure
  alias Arbor.LLM.Client
  alias Arbor.LLM.ContentPart
  alias Arbor.LLM.Message
  alias Arbor.LLM.Request
  alias Arbor.LLM.Response
  alias Arbor.LLM.ToolLoop

  @moduletag :fast
  @moduletag :security_regression
  @probe :tool_loop_call_outcome_probe
  @script_key {__MODULE__, :script}

  # Scripted tools. Each execution is reported to the test process, so a call
  # the loop refuses to re-run is visible as a missing execution.
  defmodule ScriptedTools do
    @probe :tool_loop_call_outcome_probe

    def execute(name, args, _workdir, _opts) do
      send(@probe, {:executed, name, args})
      failure(name)
    end

    defp failure("send_payment"), do: unknown("send_payment", :side_effecting)
    defp failure("read_balance"), do: unknown("read_balance", :read_only)

    defp failure("gated_write") do
      {:error,
       CallFailure.new!(
         outcome: :refused,
         message: "Action gated_write unauthorized.",
         tool: "gated_write",
         idempotency: :side_effecting
       )}
    end

    defp unknown(name, class) do
      {:error,
       CallFailure.new!(
         outcome: :unknown,
         message: "Action #{name} was interrupted while running: timeout",
         tool: name,
         idempotency: class
       )}
    end
  end

  # Replays one scripted tool call per round, then echoes every tool result the
  # model saw so the test can read exactly what the model was told.
  defmodule ScriptedAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    @script_key {Arbor.LLM.ToolLoopCallOutcomeSecurityRegressionTest, :script}

    def provider, do: "call_outcome_test"

    def complete(%Request{messages: messages}, _opts) do
      tool_results = Enum.filter(messages, &(&1.role == :tool))
      script = :persistent_term.get(@script_key)

      case Enum.at(script, length(tool_results)) do
        {name, args} ->
          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             content_parts: [ContentPart.tool_call("call_#{length(tool_results)}", name, args)],
             usage: %{},
             raw: %{}
           }}

        nil ->
          seen = Enum.map_join(tool_results, "\n---\n", &to_string(&1.content))

          {:ok,
           %Response{
             text: seen,
             finish_reason: :stop,
             content_parts: [ContentPart.text(seen)],
             usage: %{},
             raw: %{}
           }}
      end
    end
  end

  setup do
    Process.register(self(), @probe)
    Application.put_env(:arbor_llm, :tool_loop_backoff_base_ms, 1)

    on_exit(fn ->
      Application.delete_env(:arbor_llm, :tool_loop_backoff_base_ms)
      :persistent_term.erase(@script_key)
    end)

    :ok
  end

  test "security regression: an identical side-effecting call with an unknown outcome is not re-run" do
    first = %{"to" => "acct_1", "amount" => 100}
    different = %{"to" => "acct_2", "amount" => 100}

    {:ok, result} =
      run_script([{"send_payment", first}, {"send_payment", first}, {"send_payment", different}])

    assert executions("send_payment", first) == 1
    assert executions("send_payment", different) == 1

    # The model is told the first call may have taken effect, then why the
    # repeat did not run.
    assert result.content =~ "may have taken effect"
    assert result.content =~ "will not be retried automatically"
    assert result.content =~ "was not re-run"
  end

  test "an unknown outcome on a tool declared safe to repeat is re-run" do
    args = %{"account" => "acct_1"}

    {:ok, result} = run_script([{"read_balance", args}, {"read_balance", args}])

    assert executions("read_balance", args) == 2
    assert result.content =~ "declared safe to repeat"
    refute result.content =~ "was not re-run"
  end

  test "a refused call ran nothing, so a repeat is executed" do
    args = %{"path" => "notes.txt"}

    {:ok, result} = run_script([{"gated_write", args}, {"gated_write", args}])

    assert executions("gated_write", args) == 2
    assert result.content =~ "The call was not carried out."
  end

  defp run_script(script) do
    :persistent_term.put(@script_key, script)

    client =
      Client.new(default_provider: ScriptedAdapter.provider())
      |> Client.register_adapter(ScriptedAdapter)

    request = %Request{
      provider: ScriptedAdapter.provider(),
      model: "test",
      messages: [Message.new(:user, "pay the invoice")]
    }

    ToolLoop.run(client, request, tool_executor: ScriptedTools, tools: [], max_turns: 10)
  end

  defp executions(name, args, count \\ 0) do
    receive do
      {:executed, ^name, ^args} -> executions(name, args, count + 1)
    after
      0 -> count
    end
  end
end
