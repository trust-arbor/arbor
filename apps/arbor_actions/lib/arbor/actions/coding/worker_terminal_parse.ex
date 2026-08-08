defmodule Arbor.Actions.Coding.WorkerTerminalParse do
  @moduledoc """
  Pipeline-internal parse of the advisory coding worker terminal JSON envelope.

  Exact whole-message validation only. Outcome authority remains workspace
  inspection — this action never decides no_changes, validation, review, commit,
  or disposal.

  Pure validation lives in `WorkerTerminalEnvelopeCore`; this module is the thin
  impure Jido shell only.
  """

  use Jido.Action,
    name: "coding_worker_terminal_parse",
    description: "Parse advisory exact whole-message coding worker terminal JSON",
    category: "coding",
    tags: ["coding", "protocol", "parser", "pipeline_internal"],
    schema: [
      text: [type: :string, required: true, doc: "Raw bounded ACP worker terminal text"]
    ]

  alias Arbor.Actions.Coding.WorkerTerminalEnvelopeCore

  def taint_roles, do: %{text: :data}
  def effect_class, do: :read
  def execution_idempotency, do: :read_only

  @impl true
  def run(params, _context) when is_map(params) do
    text = Map.get(params, :text) || Map.get(params, "text")

    # Always return a JSON-clean evidence envelope so the graph can retain
    # protocol_error fields and still proceed to workspace inspection. Validity
    # is advisory only — never task-outcome authority.
    case WorkerTerminalEnvelopeCore.parse(text) do
      {:ok, fields} ->
        {:ok, fields}

      {:error, _code, evidence} ->
        {:ok, evidence}
    end
  end

  def run(_params, _context) do
    {:ok,
     %{
       "valid" => false,
       "status" => nil,
       "summary" => nil,
       "protocol_error" => "text_required",
       "text_byte_size" => 0,
       "text_sha256" => nil
     }}
  end
end
