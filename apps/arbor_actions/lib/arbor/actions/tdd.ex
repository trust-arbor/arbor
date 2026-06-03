defmodule Arbor.Actions.TDD do
  @moduledoc """
  TDD-loop primitives — small Actions that glue the multi-iteration
  test-driven generation pipeline in
  `apps/arbor_orchestrator/specs/pipelines/examples/tdd-cycle.dot`.

  These actions exist because DOT-attr context-key flow has a friction
  point: `context_keys=` passes context values into action args
  verbatim, then atomization filters them against the action's schema
  atoms. So pulling dotted keys (`exec.foo.bar`) into a generic action
  fails — the dotted name isn't a schema atom. The actions here
  accept structured shapes that the DOT can populate via flat
  context keys, keeping the DOT itself declarative.

  Actions:

    * `BuildImplPrompt` — assemble the LLM prompt for the
      implementation-generation stage. Handles both initial generation
      (no feedback) and feedback iterations (last attempt + failure
      from the previous run).
    * `RecordAttempt` — bump the iteration counter, snapshot the last
      attempt's code and failure output, compute the exhaustion flag.
      Lets the next iteration's `BuildImplPrompt` see what came before.
  """

  defmodule BuildImplPrompt do
    @moduledoc """
    Build the user prompt for the implementation-generation LLM call.

    On `iteration == 0` produces the initial prompt — spec + the
    model's own tests + an instruction to implement.

    On `iteration > 0` produces a feedback prompt — same spec + tests,
    plus the previous attempt and the test runner's failure output,
    plus an instruction to fix.

    ## Returns

      `%{prompt: <string>}`
    """

    use Jido.Action,
      name: "tdd_build_impl_prompt",
      description: "Build the LLM prompt for the TDD implementation-generation stage",
      category: "tdd",
      tags: ["tdd", "prompt"],
      schema: [
        module_name: [type: :string, required: true, doc: "Target module name"],
        signature: [type: :string, required: true, doc: "Function signature spec"],
        description: [type: :string, required: true, doc: "Prose spec description"],
        test_code: [type: :string, required: true, doc: "The test the impl must satisfy"],
        iteration: [type: :non_neg_integer, default: 0, doc: "Current iteration counter"],
        last_impl: [type: :string, default: "", doc: "Previous attempt's code (iter > 0)"],
        last_failure: [type: :string, default: "", doc: "Previous attempt's failure (iter > 0)"]
      ]

    def taint_roles do
      %{
        module_name: {:control, requires: [:command_injection]},
        signature: :control,
        description: :data,
        test_code: :data,
        iteration: :control,
        last_impl: :data,
        last_failure: :data
      }
    end

    @impl true
    def run(%{iteration: 0} = params, _context) do
      prompt = """
      Implement the Elixir module #{params.module_name}.

      Signature:

          #{params.signature}

      Description:

      #{params.description}

      Your implementation must make this test pass:

      ```elixir
      #{params.test_code}
      ```

      Output ONLY the module source code, starting with `defmodule`. No
      markdown fences. No prose. No explanation.
      """

      {:ok, %{prompt: prompt}}
    end

    @impl true
    def run(params, _context) do
      prompt = """
      Implement the Elixir module #{params.module_name}.

      Signature:

          #{params.signature}

      Description:

      #{params.description}

      Your implementation must make this test pass:

      ```elixir
      #{params.test_code}
      ```

      Your previous attempt (iteration #{params.iteration}) was:

      ```elixir
      #{params.last_impl}
      ```

      Running the tests produced:

      ```
      #{params.last_failure}
      ```

      Fix the implementation. Output ONLY the corrected module source
      code, starting with `defmodule`. No markdown fences. No prose.
      """

      {:ok, %{prompt: prompt}}
    end
  end

  defmodule RecordAttempt do
    @moduledoc """
    Record the just-completed attempt for the next iteration's feedback.

    Reads the current implementation (from the previous `gen_impl`
    compute node's `last_response`), the test runner's output, and the
    current iteration counter. Returns the updated state.

    ## Returns

      ```
      %{
        iteration: next_iter,
        exhausted: next_iter >= max_iterations,
        last_impl: current_impl,
        last_failure: test_output
      }
      ```
    """

    use Jido.Action,
      name: "tdd_record_attempt",
      description: "Record the failed attempt + bump iteration counter",
      category: "tdd",
      tags: ["tdd", "loop"],
      schema: [
        iteration: [type: :non_neg_integer, required: true, doc: "Current iteration"],
        max_iterations: [type: :pos_integer, required: true, doc: "Hard cap"],
        current_impl: [type: :string, required: true, doc: "What just got tried"],
        test_output: [type: :string, required: true, doc: "What the test runner said"]
      ]

    def taint_roles do
      %{
        iteration: :control,
        max_iterations: :control,
        current_impl: :data,
        test_output: :data
      }
    end

    @impl true
    def run(params, _context) do
      next_iter = params.iteration + 1

      {:ok,
       %{
         iteration: next_iter,
         exhausted: next_iter >= params.max_iterations,
         last_impl: params.current_impl,
         last_failure: params.test_output
       }}
    end
  end
end
