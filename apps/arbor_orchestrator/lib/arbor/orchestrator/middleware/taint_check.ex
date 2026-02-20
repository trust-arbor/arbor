defmodule Arbor.Orchestrator.Middleware.TaintCheck do
  @moduledoc """
  Mandatory middleware that propagates taint classification through pipeline execution.

  Bridges to `Arbor.Signals.Taint` when available. Classifies node inputs
  before execution and propagates taint labels to outputs after execution.

  When a compiled node has a `taint_profile` (from the IR Compiler), enforces:

  **before_node:**
  - Required sanitizations — halts if input taint lacks required bitmask bits
  - Minimum confidence — halts if input taint confidence is too low
  - Provider constraint — halts if LLM provider can't handle the data sensitivity

  **after_node:**
  - Wipe sanitizations — zeroes output sanitization bits (for LLM nodes, council decision #6)
  - Output sanitizations — ORs sanitization bits into output (for sanitizer nodes)
  - Sensitivity floor — upgrades output sensitivity to at least the node's floor

  Supports both legacy atom-based taint labels and the 4-dimensional Taint struct
  from `Arbor.Contracts.Security.Taint`.

  No-op when Arbor.Signals.Taint is not loaded.

  ## Token Assigns

    - `:taint_labels` — accumulated taint labels from prior nodes (atom or struct)
    - `:skip_taint_check` — set to true to bypass this middleware
  """

  use Arbor.Orchestrator.Middleware

  import Bitwise

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.IR.TaintProfile

  @sensitivity_rank %{public: 0, internal: 1, confidential: 2, restricted: 3}

  @impl true
  def before_node(token) do
    if Map.get(token.assigns, :skip_taint_check, false) do
      token
    else
      token
      |> maybe_classify_inputs()
      |> enforce_taint_profile_before()
    end
  end

  @impl true
  def after_node(token) do
    if Map.get(token.assigns, :skip_taint_check, false) do
      token
    else
      token
      |> maybe_propagate_taint()
      |> enforce_taint_profile_after()
    end
  end

  # Classification and propagation need Arbor.Signals.Taint for struct-aware
  # logic. Taint profile enforcement is self-contained (uses IR.TaintProfile
  # and the Contracts.Security.Taint struct directly).
  defp maybe_classify_inputs(token) do
    if taint_available?(), do: classify_inputs(token), else: token
  end

  defp maybe_propagate_taint(token) do
    if taint_available?(), do: propagate_taint(token), else: token
  end

  # ── Before-node enforcement (compiled taint_profile) ─────────────────

  defp enforce_taint_profile_before(%{halted: true} = token), do: token

  defp enforce_taint_profile_before(token) do
    case token.node.taint_profile do
      nil ->
        token

      %TaintProfile{} = profile ->
        token
        |> check_required_sanitizations(profile)
        |> check_min_confidence(profile)
        |> check_provider_constraint(profile)
    end
  end

  defp check_required_sanitizations(%{halted: true} = token, _profile), do: token

  defp check_required_sanitizations(token, %TaintProfile{required_sanitizations: 0}), do: token

  defp check_required_sanitizations(token, %TaintProfile{required_sanitizations: required}) do
    labels = Map.get(token.assigns, :taint_labels, %{})

    failed =
      Enum.find(labels, fn {_key, label} ->
        case extract_sanitizations(label) do
          nil -> false
          provided -> not TaintProfile.satisfies?(provided, required)
        end
      end)

    case failed do
      nil ->
        token

      {key, label} ->
        provided = extract_sanitizations(label) || 0
        missing = TaintProfile.missing_sanitizations(provided, required)

        Token.halt(
          token,
          "node #{token.node.id}: input '#{key}' missing sanitizations: #{inspect(missing)}",
          %Outcome{
            status: :fail,
            failure_reason:
              "Taint check failed: input '#{key}' missing sanitizations #{inspect(missing)}"
          }
        )
    end
  end

  defp check_min_confidence(%{halted: true} = token, _profile), do: token

  defp check_min_confidence(token, %TaintProfile{min_confidence: :unverified}), do: token

  defp check_min_confidence(token, %TaintProfile{min_confidence: min_confidence}) do
    labels = Map.get(token.assigns, :taint_labels, %{})
    min_rank = TaintProfile.confidence_rank(min_confidence)

    failed =
      Enum.find(labels, fn {_key, label} ->
        case extract_confidence(label) do
          nil -> false
          confidence -> TaintProfile.confidence_rank(confidence) < min_rank
        end
      end)

    case failed do
      nil ->
        token

      {key, label} ->
        actual = extract_confidence(label)

        Token.halt(
          token,
          "node #{token.node.id}: input '#{key}' confidence #{actual} below required #{min_confidence}",
          %Outcome{
            status: :fail,
            failure_reason:
              "Taint check failed: input '#{key}' confidence #{actual} < #{min_confidence}"
          }
        )
    end
  end

  defp check_provider_constraint(%{halted: true} = token, _profile), do: token

  defp check_provider_constraint(token, %TaintProfile{provider_constraint: nil}), do: token

  defp check_provider_constraint(token, %TaintProfile{provider_constraint: constraint}) do
    labels = Map.get(token.assigns, :taint_labels, %{})

    if backend_trust_available?() do
      failed =
        Enum.find(labels, fn {_key, label} ->
          case extract_sensitivity(label) do
            nil -> false
            sensitivity -> not apply(Arbor.AI.BackendTrust, :can_see?, [constraint, sensitivity])
          end
        end)

      case failed do
        nil ->
          token

        {key, label} ->
          sensitivity = extract_sensitivity(label)

          Token.halt(
            token,
            "node #{token.node.id}: provider #{constraint} cannot handle #{sensitivity} data in '#{key}'",
            %Outcome{
              status: :fail,
              failure_reason:
                "Taint check failed: provider #{constraint} cannot see #{sensitivity} data"
            }
          )
      end
    else
      token
    end
  rescue
    _ -> token
  catch
    :exit, _ -> token
  end

  # ── After-node enforcement (compiled taint_profile) ──────────────────

  defp enforce_taint_profile_after(%{halted: true} = token), do: token

  defp enforce_taint_profile_after(token) do
    case token.node.taint_profile do
      nil ->
        token

      %TaintProfile{} = profile ->
        token
        |> apply_wipe_sanitizations(profile)
        |> apply_output_sanitizations(profile)
        |> enforce_sensitivity_floor(profile)
    end
  end

  defp apply_wipe_sanitizations(token, %TaintProfile{wipes_sanitizations: false}), do: token

  defp apply_wipe_sanitizations(token, %TaintProfile{wipes_sanitizations: true}) do
    labels = Map.get(token.assigns, :taint_labels, %{})

    wiped =
      Map.new(labels, fn {key, label} ->
        {key, wipe_sanitization_bits(label)}
      end)

    Token.assign(token, :taint_labels, wiped)
  end

  defp apply_output_sanitizations(token, %TaintProfile{output_sanitizations: 0}), do: token

  defp apply_output_sanitizations(token, %TaintProfile{output_sanitizations: bits}) do
    labels = Map.get(token.assigns, :taint_labels, %{})

    updated =
      Map.new(labels, fn {key, label} ->
        {key, or_sanitization_bits(label, bits)}
      end)

    Token.assign(token, :taint_labels, updated)
  end

  defp enforce_sensitivity_floor(token, %TaintProfile{sensitivity: :public}), do: token

  defp enforce_sensitivity_floor(token, %TaintProfile{sensitivity: floor_sensitivity}) do
    labels = Map.get(token.assigns, :taint_labels, %{})
    floor_rank = Map.get(@sensitivity_rank, floor_sensitivity, 0)

    upgraded =
      Map.new(labels, fn {key, label} ->
        {key, maybe_upgrade_sensitivity(label, floor_sensitivity, floor_rank)}
      end)

    Token.assign(token, :taint_labels, upgraded)
  end

  # ── Existing classification and propagation ──────────────────────────

  defp classify_inputs(token) do
    input_keys = extract_input_keys(token.node)
    existing_labels = Map.get(token.assigns, :taint_labels, %{})

    new_labels =
      Enum.reduce(input_keys, existing_labels, fn key, acc ->
        value = Context.get(token.context, key)

        if is_binary(value) do
          label = classify_value(value, token.node)
          Map.put(acc, key, label)
        else
          acc
        end
      end)

    Token.assign(token, :taint_labels, new_labels)
  end

  defp propagate_taint(token) do
    if token.outcome && token.outcome.context_updates do
      labels = Map.get(token.assigns, :taint_labels, %{})

      tainted_inputs =
        Enum.any?(labels, fn {_k, v} ->
          extract_level(v) != :trusted
        end)

      if tainted_inputs do
        output_labels =
          token.outcome.context_updates
          |> Map.keys()
          |> Enum.reduce(labels, fn key, acc ->
            worst = worst_taint(Map.values(labels))
            Map.put(acc, key, worst)
          end)

        Token.assign(token, :taint_labels, output_labels)
      else
        token
      end
    else
      token
    end
  end

  defp extract_input_keys(node) do
    attrs = node.attrs

    keys =
      for key <- ["source_key", "input_key", "graph_source_key"],
          val = Map.get(attrs, key),
          val != nil,
          do: val

    ["last_response" | keys] |> Enum.uniq()
  end

  defp classify_value(value, node) do
    case auto_classify_by_path(node) do
      nil -> classify_by_content(value)
      taint -> taint
    end
  end

  defp auto_classify_by_path(node) do
    path = Map.get(node.attrs, "path") || Map.get(node.attrs, "file_path")

    if is_binary(path) do
      cond do
        String.contains?(path, [".env", "credentials", "secret", "private_key"]) ->
          make_taint_struct(:untrusted, :restricted)

        String.contains?(path, ["/tmp/", "/var/", "/proc/"]) ->
          make_taint_struct(:untrusted, :internal)

        true ->
          nil
      end
    else
      nil
    end
  end

  defp classify_by_content(_value) do
    if struct_propagation_available?() do
      make_taint_struct(:trusted, :internal)
    else
      :trusted
    end
  end

  defp make_taint_struct(level, sensitivity) do
    taint_struct = Arbor.Contracts.Security.Taint

    if Code.ensure_loaded?(taint_struct) do
      struct(taint_struct, level: level, sensitivity: sensitivity)
    else
      level
    end
  end

  # ── Extractors for atom/struct dual handling ─────────────────────────

  defp extract_level(label) when is_atom(label), do: label
  defp extract_level(%{level: level}), do: level
  defp extract_level(_), do: :unknown

  defp extract_sanitizations(%{sanitizations: s}) when is_integer(s), do: s
  defp extract_sanitizations(_), do: nil

  defp extract_confidence(%{confidence: c}) when is_atom(c), do: c
  defp extract_confidence(_), do: nil

  defp extract_sensitivity(%{sensitivity: s}) when is_atom(s), do: s
  defp extract_sensitivity(_), do: nil

  # ── Sanitization bit manipulation ───────────────────────────────────

  defp wipe_sanitization_bits(%{__struct__: mod} = taint) do
    struct(mod, Map.from_struct(taint) |> Map.put(:sanitizations, 0))
  end

  defp wipe_sanitization_bits(label), do: label

  defp or_sanitization_bits(%{__struct__: mod, sanitizations: existing} = taint, bits) do
    struct(mod, Map.from_struct(taint) |> Map.put(:sanitizations, bor(existing, bits)))
  end

  defp or_sanitization_bits(label, _bits), do: label

  defp maybe_upgrade_sensitivity(
         %{__struct__: mod, sensitivity: current} = taint,
         floor,
         floor_rank
       ) do
    current_rank = Map.get(@sensitivity_rank, current, 0)

    if current_rank < floor_rank do
      struct(mod, Map.from_struct(taint) |> Map.put(:sensitivity, floor))
    else
      taint
    end
  end

  defp maybe_upgrade_sensitivity(label, _floor, _floor_rank), do: label

  # ── Worst taint propagation ─────────────────────────────────────────

  defp worst_taint([]), do: :unknown

  defp worst_taint(labels) do
    if struct_propagation_available?() do
      structs =
        Enum.filter(labels, fn
          %{__struct__: _} -> true
          _ -> false
        end)

      if structs != [] do
        apply(Arbor.Signals.Taint, :propagate_taint, [structs])
      else
        worst_taint_atoms(labels)
      end
    else
      worst_taint_atoms(labels)
    end
  end

  defp worst_taint_atoms(labels) do
    severity = %{hostile: 4, untrusted: 3, derived: 2, unknown: 1, trusted: 0}

    labels
    |> Enum.map(&extract_level/1)
    |> Enum.max_by(fn label -> Map.get(severity, label, 0) end)
  end

  # ── Availability checks ─────────────────────────────────────────────

  defp taint_available? do
    Code.ensure_loaded?(Arbor.Signals.Taint)
  end

  defp struct_propagation_available? do
    Code.ensure_loaded?(Arbor.Signals.Taint) and
      function_exported?(Arbor.Signals.Taint, :propagate_taint, 1)
  end

  defp backend_trust_available? do
    Code.ensure_loaded?(Arbor.AI.BackendTrust) and
      function_exported?(Arbor.AI.BackendTrust, :can_see?, 2)
  end
end
