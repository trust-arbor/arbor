defmodule Arbor.Orchestrator.Handlers.SanitizeHandler do
  @moduledoc """
  Core handler for sanitization (taint-tracking-rebuild Phase 4).

  Canonical type: `sanitize`

  Runs one or more **vetted, registered** sanitizers (`Arbor.Common.Sanitizers`)
  over an input value and records the resulting sanitization bits on the output's
  provenance taint. This is the mechanism that lets data legitimately satisfy a
  `requires:` control parameter (e.g. a shell `command` requires `command_injection`
  sanitization): the bit is set by THIS handler actually running the sanitizer, not
  by a node author asserting it — so the `requires:` gate can't be forged from a DOT
  graph.

  Note on levels: sanitization sets bits but does NOT reduce the provenance LEVEL.
  `:untrusted` data sanitized for command_injection is still `:untrusted` and still
  blocked at the level gate; sanitization only unblocks `:derived`/`:trusted` data
  on a `requires:` param. Lowering the level is a separate, earned reduction
  (quarantined extraction / human review).

  ## Node Attributes

    - `sanitize` — comma-separated sanitizer types to apply, e.g.
      "command_injection" or "xss,log_injection". Only the registered types are
      accepted (see `Arbor.Common.Sanitizers.types/0`); unknown types fail closed.
    - `source_key` — context key to read the value from (default: "last_response")
    - `output_key` — context key to write the sanitized value to
      (default: "sanitize.{node_id}")
    - `allowed_root` — optional; passed to sanitizers that need it (path_traversal)
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  require Logger

  alias Arbor.Common.Sanitizers
  alias Arbor.Contracts.Security.Taint
  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @impl true
  def execute(node, context, _graph, _opts) do
    source_key = Map.get(node.attrs, "source_key", "last_response")
    output_key = Map.get(node.attrs, "output_key", "sanitize.#{node.id}")
    value = Context.get(context, source_key)

    with {:ok, types} <- parse_types(Map.get(node.attrs, "sanitize")),
         input_taint <- input_taint(context, source_key),
         opts <- sanitizer_opts(node.attrs),
         {:ok, sanitized, updated_taint} <-
           Sanitizers.sanitize_all(types, value, input_taint, opts) do
      Logger.debug(
        "[SanitizeHandler] #{node.id}: applied #{inspect(types)}; " <>
          "sanitizations #{input_taint.sanitizations} -> #{updated_taint.sanitizations}"
      )

      %Outcome{
        status: :success,
        notes: "Sanitized #{source_key} via #{inspect(types)}",
        context_updates: %{output_key => sanitized},
        # The output carries the input's provenance level PLUS the new
        # sanitization bits — recorded as authoritative for this node's outputs.
        output_taint: updated_taint
      }
    else
      {:error, reason} ->
        # Fail closed: if sanitization fails (or an unknown sanitizer was named)
        # we do NOT emit a partially-cleaned value or a forged bit.
        %Outcome{
          status: :fail,
          failure_reason: "sanitize failed for #{source_key}: #{inspect(reason)}"
        }
    end
  rescue
    e ->
      %Outcome{status: :fail, failure_reason: "sanitize handler error: #{Exception.message(e)}"}
  end

  @impl true
  def idempotency, do: :idempotent

  # --- Helpers ---

  # Parse the `sanitize` attr into a list of known sanitizer-type atoms.
  # Unknown / empty fails closed (we won't run an unrecognized "sanitizer").
  defp parse_types(nil), do: {:error, :missing_sanitize_attr}
  defp parse_types(""), do: {:error, :missing_sanitize_attr}

  defp parse_types(csv) when is_binary(csv) do
    known = MapSet.new(Sanitizers.types())

    names =
      csv
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    parsed =
      Enum.map(names, fn name ->
        atom = safe_existing_atom(name)
        if atom && MapSet.member?(known, atom), do: atom, else: {:unknown, name}
      end)

    case Enum.find(parsed, &match?({:unknown, _}, &1)) do
      {:unknown, bad} -> {:error, {:unknown_sanitizer, bad}}
      nil when parsed == [] -> {:error, :missing_sanitize_attr}
      nil -> {:ok, parsed}
    end
  end

  defp safe_existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  # The provenance of the input being sanitized. Unlabeled input is treated as
  # :untrusted (you sanitize because the data is suspect) — conservative.
  defp input_taint(context, source_key) do
    case Context.taint_label(context, source_key) do
      %Taint{} = t -> t
      _ -> %Taint{level: :untrusted}
    end
  end

  defp sanitizer_opts(attrs) do
    case Map.get(attrs, "allowed_root") do
      root when is_binary(root) and root != "" -> [allowed_root: root]
      _ -> []
    end
  end
end
