defmodule Arbor.Agent.Eval.SecurityReview.Prompt do
  @moduledoc """
  The L2 deep-review prompt for the eval runner.

  Adapted from L1's diff-review prompt (`l1-diff-review.dot`) but for *whole-code*
  review rather than a diff: the reviewer is shown full file(s) and asked to find
  any security issue present, not only newly-introduced ones. The JSON output
  contract is identical to L1's so the existing `Arbor.Actions.Security.DiffFindings`
  parser (closed category vocabulary, fence-tolerant) can decode the response.
  """

  @system """
  You are a security code reviewer. Review the Elixir source below for security \
  issues PRESENT in the code (not only newly-introduced ones); ignore style/quality. \
  Look for: authorization that fails open (a rescue/catch or a catch-all clause that \
  returns an allow value such as :ok/true/{:ok, _}); missing or bypassed capability \
  checks; capability URI over-matching (prefix matching without a path boundary, so \
  "arbor://fs/" matches "arbor://fs-other/"); crypto misuse (wrong hash mode for \
  Ed25519, fields left out of a signing payload, MAC-after-decrypt, weak randomness); \
  serialization that drops or diverges from the signed field set; taint/provenance \
  lost across a boundary (e.g. dropped on checkpoint/resume so tainted data is later \
  treated as clean); secret/credential/token exposure; command/SQL injection and \
  unsafe interpolation; path traversal; unsafe deserialization (binary_to_term on \
  untrusted input); String.to_atom on untrusted input; TOCTOU. When several files are \
  shown together, also look for issues that span them (a value defined in one file \
  and mis-used in another). Be precise and conservative — only report a real risk.

  Output ONLY a JSON array (no prose, no markdown fences). Each element: \
  {"category": one of [fail_open_authz, crypto_weakness, capability_overmatch, \
  serialization_drop, unsafe_atom, config_fail_open, path_traversal, secret_exposure, \
  injection, dependency_risk, other], "title": a short specific title, "file": the \
  file path shown, "line": an integer line number or null, "severity": one of \
  [critical, high, medium, low], "rationale": why this is a risk, "recommendation": \
  the concrete fix}. If the code has no security issue, output exactly [].\
  """

  @doc "The system prompt for an L2 review call."
  @spec system() :: String.t()
  def system, do: @system

  @doc """
  The user prompt wrapping one review unit's code. `label` identifies the unit
  (a single file path, or "N files" for a whole-subsystem unit).
  """
  @spec user(String.t(), String.t()) :: String.t()
  def user(code, label) do
    "Review the following code (#{label}) for security issues.\n\n" <> code
  end

  # --- agentic (tool-using) variant ----------------------------------------

  @agent_system @system <>
                  "\n\nYou are reviewing a subsystem you cannot see up front. Use the " <>
                  "provided read-only tools to navigate it: call `list_files` to see " <>
                  "what's there, `read_file` to read a file, and `search` to find a " <>
                  "pattern across files. Read what you need to understand the code, " <>
                  "including how values flow BETWEEN files. When you are done " <>
                  "investigating, stop calling tools and output the final JSON array " <>
                  "of findings (and nothing else)."

  @doc "System prompt for the agentic (tool-using) strategy."
  @spec agent_system() :: String.t()
  def agent_system, do: @agent_system

  @doc "User kickoff prompt for the agentic strategy (the code is reached via tools)."
  @spec agent_user() :: String.t()
  def agent_user do
    "Review this subsystem for security issues. Start with `list_files`, then read " <>
      "and search as needed. Output ONLY the final JSON array of findings when done."
  end
end
