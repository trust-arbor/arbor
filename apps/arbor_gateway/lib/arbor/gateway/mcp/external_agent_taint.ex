defmodule Arbor.Gateway.MCP.ExternalAgentTaint do
  @moduledoc """
  Provenance label for action inputs that arrive from another agent over MCP
  (the gateway's `arbor_run` and BEAM-local `AgentEndpoint` calls).

  Those arguments are produced by an LLM agent, exactly like an in-process
  compute node's tool calls, which `LlmHandler` labels at least `:derived`.
  Until 2026-09-27 they reached `Arbor.Actions.authorize_and_execute/4` with no
  `:taint` at all and were decided as clean (decision: label external-agent
  inputs `:derived`, following Imp review D3). The label feeds the action
  layer's taint policy: `:audit_only` (dev) records control-param use,
  `:strict` (prod) blocks non-trusted control params, as it already does for
  in-process agents. It does not change egress: `:derived` is not
  exfiltration-blocked.
  """

  alias Arbor.Contracts.Security.Taint

  @spec label(String.t()) :: Taint.t()
  def label(source) when is_binary(source), do: %Taint{level: :derived, source: source}
end
