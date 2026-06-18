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
      shape: :s1,
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
         source <- module_source(spec, module_name),
         {:ok, module} <- compile_in_memory(source, module_name),
         :ok <- g1(spec.shape, module, finding) do
      {:ok,
       %{
         spec: spec,
         shape: spec.shape,
         module_source: source,
         module_name: module_name,
         g1: :passed,
         category: spec.category
       }}
    end
  end

  # The template differs by shape: S1 emits a `use Arbor.Eval` per-file check with
  # `run/1`; S3 emits a whole-tree detector with `detect/1`.
  defp module_source(%DetectorSpec{shape: :s3} = spec, module_name),
    do: DetectorTemplate.s3_module_source(spec, module: module_name)

  defp module_source(%DetectorSpec{} = spec, module_name),
    do: DetectorTemplate.s1_module_source(spec, module: module_name)

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

  # An already-built spec (the common programmatic path — e.g. the loop forwarding
  # opts[:spec], or a caller that built the spec itself). MUST precede the generic
  # is_map/1 clause below: a struct IS a map, so without this clause first a
  # %DetectorSpec{} would fall into DetectorSpec.build/1, which does Access
  # (`params[:category]`) on the struct and raises. Re-validate by round-tripping
  # through a plain map so a hand-built struct still gets build/1's checks.
  defp resolve_spec(finding, %DetectorSpec{} = supplied) do
    resolve_spec(finding, Map.from_struct(supplied))
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
        # No deterministic template for this category. If it is a KNOWN shape
        # (S1 or S3) the LLM/test path must supply a spec (S3 categories have no
        # deterministic template — their match_pattern is finding-specific). A
        # genuinely unknown / bespoke-correlation category is rejected as an
        # unsupported shape.
        case DetectorSpec.shape_for_category(category) do
          {:ok, _shape} -> {:error, {:no_deterministic_spec, category}}
          :error -> {:error, {:unsupported_shape, category}}
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
      shape: coerce_shape(get(map, "shape")),
      category: coerce_category(get(map, "category")),
      invariant: get(map, "invariant"),
      name_match: coerce_name_match(get(map, "name_match")),
      target_literals: coerce_literals(get(map, "target_literals")),
      exclusions: coerce_literals(get(map, "exclusions")),
      clause_position: coerce_clause_position(get(map, "clause_position")),
      match_pattern: coerce_match_pattern(get(map, "match_pattern"))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp get(map, key), do: map[key] || map[String.to_atom(key)]

  # shape is a closed, known token set → coerce against the allowlist only.
  defp coerce_shape("s1"), do: :s1
  defp coerce_shape("s3"), do: :s3
  defp coerce_shape(_), do: nil

  defp coerce_category(nil), do: nil

  # Match against BOTH the S1 and S3 known category sets (allowlist only — never
  # String.to_atom on model output).
  defp coerce_category(str) when is_binary(str) do
    Enum.find(
      DetectorSpec.s1_categories() ++ DetectorSpec.s3_categories(),
      &(Atom.to_string(&1) == str)
    )
  end

  defp coerce_category(_), do: nil

  # The S3 match_pattern. `kind` is allowlisted; the call target and literal value
  # are coerced through the SAME hardened coercions as S1 literals/name_match
  # (no String.to_atom on raw model output). A "Mod.fun" call stays a binary.
  defp coerce_match_pattern(%{} = mp) do
    kind = mp["kind"] || mp[:kind]

    case kind do
      "literal" -> %{kind: :literal, literal: coerce_literal(mp["literal"] || mp[:literal])}
      "call" -> %{kind: :call, call: coerce_call_target(mp["call"] || mp[:call])}
      _ -> nil
    end
  end

  defp coerce_match_pattern(_), do: nil

  # A call target: a remote "Mod.fun" stays a binary (matched textually by the
  # generated detector); a bare "fun" / "@fun" / ":fun" becomes an existing atom
  # when known, else falls back to the binary form (never minting new atoms).
  defp coerce_call_target(str) when is_binary(str) do
    if String.contains?(str, "."),
      do: str,
      else: to_known_atom_or(strip_colon(strip_at(str)), str)
  end

  defp coerce_call_target(_), do: nil

  defp strip_at("@" <> rest), do: rest
  defp strip_at(str), do: str

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

  # G1 re-catch dispatches by shape. S1 runs the generated `run/1` against the
  # seed file's AST; S3 runs the generated `detect/1` against the directory
  # containing the seed file and asserts a Finding lands at the seed's
  # file+function.
  defp g1(:s3, module, finding), do: g1_recatch_s3(module, finding)
  defp g1(_s1, module, finding), do: g1_recatch(module, finding)

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

  # S3 G1: run the generated whole-tree detector against the directory containing
  # the seed file, then assert it produced a Finding at the seed's file (and, when
  # known, its function). The detector globs `.ex` under `root`, so we point it at
  # the seed's own directory — a tree containing exactly the bug it was born from.
  defp g1_recatch_s3(module, finding) do
    file = finding.location[:file] || finding.location["file"]
    target_fun = finding.location[:function] || finding.location["function"]

    with {:ok, file} <- require_file(file) do
      findings = module.detect(root: Path.dirname(file))

      cond do
        findings == [] ->
          {:error, {:g1_failed, :no_violation_recaught}}

        not s3_matches_seed?(findings, file, target_fun) ->
          {:error, {:g1_failed, {:wrong_location, file, target_fun}}}

        true ->
          :ok
      end
    end
  end

  # An emitted Finding re-catches the seed iff it lands in the seed file and, when
  # the finding records a target function, in that function. A nil target function
  # matches any site in the seed file (we still re-caught the class in the file).
  defp s3_matches_seed?(findings, file, target_fun) do
    Enum.any?(findings, fn f ->
      loc = f.location || %{}
      same_file?(loc[:file] || loc["file"], file) and s3_function_matches?(loc, target_fun)
    end)
  end

  defp same_file?(nil, _seed), do: false

  defp same_file?(found, seed) do
    Path.expand(to_string(found)) == Path.expand(to_string(seed))
  end

  defp s3_function_matches?(_loc, nil), do: true

  defp s3_function_matches?(loc, target_fun) do
    to_string(loc[:function] || loc["function"] || "") == to_string(target_fun)
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
