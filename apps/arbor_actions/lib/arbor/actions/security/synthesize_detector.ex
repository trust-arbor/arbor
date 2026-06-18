defmodule Arbor.Actions.Security.SynthesizeDetector do
  @moduledoc """
  Synthesize a candidate **S1 (per-file AST)** security detector from a confirmed
  `Arbor.Contracts.Security.Finding` and self-validate it with the **G1 re-catch**
  gate (Security Sentinel E1.1).

  ## The loop this automates

  One confirmed finding → a deterministic L0 detector for its *class* → (later)
  sweep the umbrella → catch every sibling. E1.1 builds the **deterministic core**
  of that loop and stops at a G1-validated candidate: it does NOT write the module
  to the suite, sweep, or auto-register. The output is a candidate the human
  reviews (per the Sentinel's always-propose, never-auto-merge rule).

  ## Pipeline (deterministic-first)

    1. Derive a `DetectorSpec` from the finding — deterministically for the known
       S1 categories (`:fail_open_authz` is the first supported class, keyed by
       category), OR accept a pre-built spec passed by the LLM-synthesis node
       (`synthesize-detector.dot`). A non-S1 category is rejected upstream by
       `DetectorSpec.build/1` with `{:error, {:unsupported_shape, _}}`.
    2. Generate the module source via `DetectorTemplate.s1_module_source/2`.
    3. **G1 re-catch:** compile the generated source in-memory, parse the original
       finding's source file to AST, run the generated detector's `run/1` against
       it, and ASSERT it flags a violation at the finding's function (and line, if
       known). A detector that can't re-catch its own seed is worthless → reject
       with `{:error, {:g1_failed, reason}}`.

  ## Output

    * `{:ok, %{spec, module_source, g1: :passed, ...}}` — a validated candidate
    * `{:error, {:unsupported_shape, category}}` — not an S1 category
    * `{:error, {:g1_failed, reason}}` — generated detector did not re-catch the seed
    * `{:error, {:spec_invalid, reason}}` — the derived/supplied spec was invalid
    * `{:error, {:seed_unreadable, reason}}` — couldn't read/parse the finding's file
  """

  use Jido.Action,
    name: "security_synthesize_detector",
    description:
      "Synthesize a candidate S1 AST detector from a confirmed finding and G1-self-validate it",
    category: "security",
    tags: ["security", "sentinel", "synthesis", "e1"],
    schema: [
      finding: [
        type: {:or, [:map, :struct]},
        required: true,
        doc: "The confirmed Finding (struct or map) the detector is synthesized from"
      ],
      spec: [
        type: {:or, [:map, :struct, :string, nil]},
        default: nil,
        doc:
          "Optional pre-built DetectorSpec — a struct, a map, or a JSON string " <>
            "(the LLM-synthesis node's output). Falls back to the deterministic spec."
      ]
    ]

  alias Arbor.Actions.Security.Detectors.Common
  alias Arbor.Actions.Security.{DetectorSpec, DetectorTemplate}
  alias Arbor.Contracts.Security.Finding

  # Deterministic spec templates keyed by category. `:fail_open_authz` is the
  # first supported class (the proven shape). The name_match / target_literals /
  # exclusions mirror AuthorizationSmells, anchored on the invariant so the
  # predicate generalizes past the one seed instance.
  @deterministic_specs %{
    fail_open_authz: %{
      invariant:
        "Authorization/verification must FAIL CLOSED — an error or unknown case must deny, never allow.",
      name_match:
        ~w(authoriz authentic verif permit acceptable delegation_chain check_approval check_capabilit) ++
          [:can?, :allowed?, :allow?, :grant?],
      target_literals: [:ok, true, :authorized, {:ok, :_}],
      exclusions: [{:ok, :verified}, {:ok, :unverified}],
      clause_position: :rescue_or_catch_all
    }
  }

  @impl true
  def run(%{finding: finding} = params, _context) do
    finding = normalize_finding(finding)

    with {:ok, spec} <- resolve_spec(finding, params[:spec]),
         module_name <- unique_module_name(spec),
         source <- DetectorTemplate.s1_module_source(spec, module: module_name),
         {:ok, module} <- compile_in_memory(source, module_name),
         :ok <- g1_recatch(module, finding) do
      {:ok,
       %{
         spec: spec,
         module_source: source,
         module_name: module_name,
         g1: :passed,
         category: spec.category
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Spec resolution (LLM-supplied OR deterministic)
  # ---------------------------------------------------------------------------

  # A JSON-string spec (the LLM-synthesis node's output). Blank/unparseable →
  # fall back to the deterministic spec (robustness: the deterministic path is
  # the proven one; the LLM only widens past it). A parseable-but-invalid spec
  # surfaces its error so a bad LLM spec is visible, not silently ignored.
  defp resolve_spec(finding, supplied) when is_binary(supplied) do
    case spec_from_json(supplied) do
      {:ok, params} -> resolve_spec(finding, params)
      :empty -> resolve_spec(finding, nil)
    end
  end

  # Prefer an explicitly supplied spec (the LLM-synthesis node's output); else
  # derive deterministically from the finding's category.
  defp resolve_spec(_finding, supplied) when is_map(supplied) and map_size(supplied) > 0 do
    case DetectorSpec.build(supplied) do
      {:ok, spec} -> {:ok, spec}
      {:error, {:unsupported_shape, _} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:spec_invalid, reason}}
    end
  end

  defp resolve_spec(finding, %DetectorSpec{} = supplied) do
    resolve_spec(finding, Map.from_struct(supplied))
  end

  defp resolve_spec(finding, _no_spec) do
    category = finding.category

    case Map.fetch(@deterministic_specs, category) do
      {:ok, template} ->
        params =
          template
          |> Map.put(:category, category)
          |> Map.put(:name, "synthesized_#{category}")
          # Prefer the finding's own invariant text when present (anchors on the
          # specific invariant the confirmed finding violated).
          |> Map.put(:invariant, finding.invariant_violated || template.invariant)

        case DetectorSpec.build(params) do
          {:ok, spec} -> {:ok, spec}
          {:error, reason} -> {:error, {:spec_invalid, reason}}
        end

      :error ->
        # Either non-S1 or S1 without a deterministic template yet → reject with
        # the unsupported-shape signal (the LLM path supplies a spec for these).
        if DetectorSpec.s1_category?(category) do
          {:error, {:no_deterministic_spec, category}}
        else
          {:error, {:unsupported_shape, category}}
        end
    end
  end

  # --- LLM-produced spec decoding (JSON → DetectorSpec params) ---------------

  # Known atom-valued fields are coerced against allowlists — NEVER
  # String.to_atom on model output. Literals are coerced from JSON tokens:
  # a string token to its atom/boolean/nil value, and a 2-element list like
  # ["ok", "_"] to the tuple {:ok, :_} (the `{:ok, _}` wildcard form).
  @known_literal_atoms ~w(ok error true false nil authorized unauthorized verified unverified)
  @known_clause_positions ~w(rescue catch_all rescue_or_catch_all)

  defp spec_from_json(text) do
    trimmed = String.trim(text || "")

    if trimmed == "" do
      :empty
    else
      case decode_json(trimmed) do
        {:ok, %{} = map} -> {:ok, coerce_spec_params(map)}
        _ -> :empty
      end
    end
  end

  defp decode_json(text) do
    text
    |> String.replace(~r/```(?:json)?\s*/i, "")
    |> String.replace("```", "")
    |> String.trim()
    |> Jason.decode()
  end

  defp coerce_spec_params(map) do
    %{
      name: get(map, "name"),
      category: coerce_category(get(map, "category")),
      invariant: get(map, "invariant"),
      name_match: coerce_name_match(get(map, "name_match")),
      target_literals: coerce_literals(get(map, "target_literals")),
      exclusions: coerce_literals(get(map, "exclusions")),
      clause_position: coerce_clause_position(get(map, "clause_position"))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp get(map, key), do: map[key] || map[String.to_atom(key)]

  defp coerce_category(nil), do: nil

  defp coerce_category(str) when is_binary(str) do
    Enum.find(DetectorSpec.s1_categories(), &(Atom.to_string(&1) == str))
  end

  defp coerce_category(_), do: nil

  defp coerce_clause_position(str) when is_binary(str) and str in @known_clause_positions do
    String.to_existing_atom(str)
  end

  defp coerce_clause_position(_), do: nil

  defp coerce_name_match(list) when is_list(list) do
    Enum.flat_map(list, fn
      "@" <> exact -> [to_known_atom_or(exact, exact)]
      bin when is_binary(bin) -> [bin]
      _ -> []
    end)
  end

  defp coerce_name_match(_), do: nil

  defp coerce_literals(list) when is_list(list), do: Enum.map(list, &coerce_literal/1)
  defp coerce_literals(_), do: nil

  # A single JSON literal token → an Elixir literal. A 2-element list → a tuple
  # (recursively), enabling ["ok", "_"] → {:ok, :_}.
  defp coerce_literal([a, b]), do: {coerce_literal(a), coerce_literal(b)}
  defp coerce_literal("_"), do: :_
  defp coerce_literal(true), do: true
  defp coerce_literal(false), do: false
  defp coerce_literal(nil), do: nil

  defp coerce_literal(str) when is_binary(str) do
    cond do
      str == "true" -> true
      str == "false" -> false
      str == "nil" -> nil
      str in @known_literal_atoms -> String.to_existing_atom(strip_colon(str))
      String.starts_with?(str, ":") -> to_known_atom_or(strip_colon(str), str)
      true -> str
    end
  end

  defp coerce_literal(other), do: other

  defp strip_colon(":" <> rest), do: rest
  defp strip_colon(str), do: str

  defp to_known_atom_or(name, fallback) do
    if name in @known_literal_atoms do
      String.to_existing_atom(name)
    else
      try do
        String.to_existing_atom(name)
      rescue
        ArgumentError -> fallback
      end
    end
  end

  # ---------------------------------------------------------------------------
  # G1: in-memory compile + re-catch the seed
  # ---------------------------------------------------------------------------

  defp compile_in_memory(source, module_name) do
    mod = Module.concat([module_name])
    # Purge any prior version so repeated synthesis runs don't redefine-warn.
    purge(mod)

    try do
      [{compiled, _bin} | _] = Code.compile_string(source)
      {:ok, compiled}
    rescue
      e -> {:error, {:g1_failed, {:compile_error, Exception.message(e)}}}
    catch
      kind, reason -> {:error, {:g1_failed, {:compile_throw, kind, reason}}}
    end
  end

  defp g1_recatch(module, finding) do
    file = finding.location[:file] || finding.location["file"]
    target_fun = finding.location[:function] || finding.location["function"]
    target_line = finding.location[:line] || finding.location["line"]

    with {:ok, file} <- require_file(file),
         {:ok, ast} <- parse_seed(file) do
      result = module.run(%{ast: ast})
      violations = result[:violations] || []

      cond do
        violations == [] ->
          {:error, {:g1_failed, :no_violation_recaught}}

        not matches_seed?(violations, target_fun, target_line) ->
          {:error, {:g1_failed, {:wrong_location, target_fun, target_line}}}

        true ->
          :ok
      end
    end
  end

  defp require_file(nil), do: {:error, {:seed_unreadable, :no_file_in_location}}

  defp require_file(file) do
    if File.regular?(file),
      do: {:ok, file},
      else: {:error, {:seed_unreadable, {:not_found, file}}}
  end

  defp parse_seed(file) do
    case Common.parse(file, columns: true) do
      {:ok, ast} -> {:ok, ast}
      {:error, reason} -> {:error, {:seed_unreadable, reason}}
    end
  end

  # The re-catch must land on the finding's function (when known) and, if a line
  # is recorded, at that line. When the finding has no function/line, any
  # violation in the file counts (we still re-caught the class in the seed file).
  defp matches_seed?(violations, nil, _line), do: violations != []

  defp matches_seed?(violations, target_fun, target_line) do
    target_fun = to_string(target_fun)

    Enum.any?(violations, fn v ->
      function_matches?(v, target_fun) and line_matches?(v, target_line)
    end)
  end

  defp function_matches?(v, target_fun), do: to_string(v[:function] || "") == target_fun

  defp line_matches?(_v, nil), do: true
  defp line_matches?(_v, line) when not is_integer(line), do: true
  defp line_matches?(v, line), do: v[:line] == line

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize_finding(%Finding{} = f), do: f

  defp normalize_finding(map) when is_map(map) do
    %Finding{
      id: map[:id] || map["id"] || "candidate",
      category: map[:category] || map["category"],
      title: map[:title] || map["title"] || "",
      location: map[:location] || map["location"] || %{},
      invariant_violated: map[:invariant_violated] || map["invariant_violated"],
      evidence: map[:evidence] || map["evidence"] || %{}
    }
  end

  # A per-run unique module name so the in-memory G1 compile of repeated runs
  # never clashes. Keeps the deterministic base name as a prefix for readability.
  defp unique_module_name(%DetectorSpec{} = spec) do
    DetectorTemplate.default_module_name(spec) <> ".G1_#{System.unique_integer([:positive])}"
  end

  defp purge(mod) do
    :code.purge(mod)
    :code.delete(mod)
    :ok
  end
end
