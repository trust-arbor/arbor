defmodule Arbor.Consensus.Evaluator.DeterministicBackend do
  @moduledoc """
  Authorization boundary for deterministic consensus evidence.

  Implementations resolve a closed request to evidence produced by an
  authorized validation workflow. They must not derive execution authority
  from proposal metadata or launch proposal-selected commands. The callback
  must stop owned work when its caller exits; the evaluator enforces the
  request timeout by terminating and settling the callback process.

  Successful evidence uses a closed status/code matrix:

  - `:passed` with `"checks_passed"`
  - `:failed` with `"checks_failed"` or `"tests_failed"`
  - `:blocked` with `"validation_blocked"` or `"validation_timed_out"`

  Authorization, execution, timeout, and lookup failures should use the closed
  error reasons below instead of inventing evidence codes.
  """

  alias Arbor.Consensus.Evaluator.DeterministicRequest

  @failure_reasons [
    :deterministic_backend_unauthorized,
    :deterministic_backend_execution_failed,
    :deterministic_backend_timed_out,
    :deterministic_evidence_not_found,
    :invalid_deterministic_evidence
  ]

  @status_code_matrix %{
    passed: ["checks_passed"],
    failed: ["checks_failed", "tests_failed"],
    blocked: ["validation_blocked", "validation_timed_out"]
  }

  @type status :: :passed | :failed | :blocked

  @type result :: %{
          required(:status) => status(),
          required(:code) => String.t(),
          required(:duration_ms) => non_neg_integer()
        }

  @callback evaluate(DeterministicRequest.t()) ::
              {:ok, result()} | {:error, atom()}

  @doc false
  @spec failure_reasons() :: [atom()]
  def failure_reasons, do: @failure_reasons

  @doc false
  @spec valid_status_code?(term(), term()) :: boolean()
  def valid_status_code?(status, code) do
    case Map.fetch(@status_code_matrix, status) do
      {:ok, allowed_codes} -> code in allowed_codes
      :error -> false
    end
  end
end
