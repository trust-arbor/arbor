defmodule Arbor.Orchestrator.Handlers.ExtractHandler do
  @moduledoc """
  Core handler for quarantined extraction via schema validation
  (taint-tracking-rebuild Phase 4, variant "b").

  Canonical type: `extract`

  Validates an input value against a strict, mechanically-checkable schema. If it
  conforms, the value is **structurally constrained** and its provenance level is
  reduced `:untrusted`/`:hostile` -> `:derived` (a `:verified_pipeline` reduction):
  the output can no longer be arbitrary attacker text, so it earns `:derived`
  (allowed-but-audited at control), not raw `:untrusted` (blocked at control).

  The reduction is EARNED by passing validation — a value that fails the schema is
  NOT emitted and NOT reduced (fail closed). This is the no-LLM core; the LLM
  dual-pattern (read untrusted text -> structured fields, then validate) layers on
  later (see `.arbor/roadmap/1-brainstorming/quarantined-extraction-llm.md`).

  Sanitization bits and confidence carry through unchanged; only the level drops.
  `:trusted`/`:derived` inputs validate but are not raised.

  ## Node Attributes

    - `source_key` — context key to read (default: "last_response")
    - `output_key` — context key to write the validated value (default: "extract.{id}")
    - At least one structural validator (else fail — a reduction must be earned):
      - `enum` — comma-separated allowed values; the value must be exactly one
      - `int` — "true": value must parse as an integer (optional `min` / `max`)
      - `match` — a regex the value must FULLY match
    - `max_length` — optional upper bound on string length (modifier, not sufficient alone)
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  require Logger

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Signals.Taint, as: TaintOps

  @impl true
  def execute(node, context, _graph, _opts) do
    source_key = Map.get(node.attrs, "source_key", "last_response")
    output_key = Map.get(node.attrs, "output_key", "extract.#{node.id}")
    value = Context.get(context, source_key)

    case validate(value, node.attrs) do
      {:ok, validated} ->
        input_taint = input_taint(context, source_key)
        {reduced, emitted?} = maybe_reduce(input_taint)

        if emitted? do
          emit_reduced(input_taint.level, reduced.level, context)
        end

        %Outcome{
          status: :success,
          notes:
            "Extracted/validated #{source_key}; level #{input_taint.level} -> #{reduced.level}",
          context_updates: %{output_key => validated},
          output_taint: reduced
        }

      {:error, reason} ->
        # Fail closed: an unvalidated value is NOT emitted and NOT reduced.
        %Outcome{
          status: :fail,
          failure_reason: "extract validation failed for #{source_key}: #{reason}"
        }
    end
  rescue
    e ->
      %Outcome{status: :fail, failure_reason: "extract handler error: #{Exception.message(e)}"}
  end

  @impl true
  def idempotency, do: :idempotent

  # --- Validation ---

  defp validate(value, attrs) do
    # A reduction must be EARNED by a structural constraint (enum/int/match);
    # max_length alone is a modifier, not sufficient.
    structural = Enum.filter(["enum", "int", "match"], &Map.has_key?(attrs, &1))

    if structural == [] do
      {:error, "no structural validator (enum/int/match) — a reduction must be earned"}
    else
      to_run = structural ++ if Map.has_key?(attrs, "max_length"), do: ["max_length"], else: []

      Enum.reduce_while(to_run, {:ok, value}, fn validator, {:ok, val} ->
        case run_validator(validator, val, attrs) do
          {:ok, coerced} -> {:cont, {:ok, coerced}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp run_validator("enum", value, attrs) do
    allowed =
      attrs["enum"] |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    str = to_string(value)
    if str in allowed, do: {:ok, str}, else: {:error, "value not in enum #{inspect(allowed)}"}
  end

  defp run_validator("int", value, attrs) do
    with {n, ""} <- Integer.parse(to_string(value)),
         :ok <- check_bound(n, attrs["min"], &>=/2, "below min"),
         :ok <- check_bound(n, attrs["max"], &<=/2, "above max") do
      {:ok, n}
    else
      :error -> {:error, "not an integer"}
      {n, _rest} when is_integer(n) -> {:error, "not a clean integer"}
      {:error, _} = err -> err
    end
  end

  defp run_validator("match", value, attrs) do
    case Regex.compile(attrs["match"]) do
      {:ok, re} ->
        str = to_string(value)
        # Full match: the whole string must be the pattern, not just contain it.
        if Regex.match?(anchored(re, attrs["match"]), str),
          do: {:ok, str},
          else: {:error, "value does not match #{inspect(attrs["match"])}"}

      {:error, _} ->
        {:error, "invalid regex #{inspect(attrs["match"])}"}
    end
  end

  defp run_validator("max_length", value, attrs) do
    max = String.to_integer(to_string(attrs["max_length"]))
    str = to_string(value)
    if String.length(str) <= max, do: {:ok, str}, else: {:error, "exceeds max_length #{max}"}
  end

  defp check_bound(_n, nil, _cmp, _msg), do: :ok

  defp check_bound(n, bound_str, cmp, msg) do
    case Integer.parse(to_string(bound_str)) do
      {bound, ""} -> if cmp.(n, bound), do: :ok, else: {:error, "#{msg} (#{bound})"}
      _ -> :ok
    end
  end

  # Anchor a regex so `match` means full-string match, not "contains".
  defp anchored(_re, pattern) do
    {:ok, re} = Regex.compile("\\A(?:#{pattern})\\z")
    re
  end

  # --- Taint reduction ---

  defp input_taint(context, source_key) do
    case Context.taint_label(context, source_key) do
      %Taint{} = t -> t
      _ -> %Taint{level: :untrusted}
    end
  end

  # Reduce untrusted/hostile -> derived via verified_pipeline; trusted/derived
  # inputs are left as-is (never raised). Returns {taint, reduced?}.
  defp maybe_reduce(%Taint{level: level} = taint) when level in [:untrusted, :hostile] do
    case TaintOps.reduce(level, :derived, :verified_pipeline) do
      {:ok, new_level} -> {%{taint | level: new_level}, true}
      {:error, _} -> {taint, false}
    end
  end

  defp maybe_reduce(taint), do: {taint, false}

  defp emit_reduced(from_level, to_level, context) do
    data = %{
      from_level: from_level,
      to_level: to_level,
      reason: :verified_pipeline,
      agent_id: Context.get(context, "session.agent_id")
    }

    cond do
      not Code.ensure_loaded?(Arbor.Signals) ->
        :ok

      function_exported?(Arbor.Signals, :durable_emit, 4) ->
        Arbor.Signals.durable_emit(:security, :taint_reduced, data, stream_id: "security:events")

      function_exported?(Arbor.Signals, :emit, 3) ->
        Arbor.Signals.emit(:security, :taint_reduced, data)

      true ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
