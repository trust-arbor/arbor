defmodule Arbor.Actions.Security.Detectors.SignedFieldCoverage do
  @moduledoc """
  Whole-tree detector for the C1 crypto invariant: **every field of a signed
  struct must be covered by its `signing_payload/1`.**

  A field present in the struct but absent from the signing payload is not
  covered by the signature, so it can be tampered with without invalidating the
  signature — exactly the C1 bug (metadata / principal_scope / allowed_delegatees
  were unsigned on the capability struct).

  This cannot be a per-file `Arbor.Eval` check in the usual sense because it
  correlates two definitions (the struct and `signing_payload/1`) — but since
  both live in the same module here, it's a focused AST analysis over modules
  that define both.

  ## Heuristic (conservative, low false-positive)

  A struct field is considered *covered* if its name appears ANYWHERE in the
  `signing_payload/1` body — **or in any local helper it transitively calls**
  (e.g. `signing_payload` → `compute_signing_payload`) — as a `struct.field`
  access, a map key, or a bare atom. Only fields completely absent across that
  closure are flagged. Fields whose name contains `signature` are excluded (you
  don't sign the signature itself).

  Modules without both a struct and a `signing_payload/1` are ignored.
  """

  alias Arbor.Contracts.Security.Finding

  @doc """
  Runs the detector over `.ex` files under `root` (default `"apps"`), returning
  a list of `Finding`s — one per unsigned field.
  """
  @spec detect(keyword()) :: [Finding.t()]
  def detect(opts \\ []) do
    root = Keyword.get(opts, :root, "apps")
    git_sha = Keyword.get(opts, :git_sha)

    Path.wildcard(Path.join(root, "**/*.ex"))
    |> Enum.reject(&test_file?/1)
    |> Enum.flat_map(&analyze_file(&1, git_sha))
  end

  # ---------------------------------------------------------------------------

  defp test_file?(file), do: String.contains?(file, "/test/")

  defp analyze_file(file, git_sha) do
    with {:ok, ast} <- parse(file),
         fields = struct_fields(ast),
         true <- fields != [],
         {:ok, signed} <- signing_payload_atoms(ast) do
      excluded = signing_excluded_fields(ast)

      fields
      |> Enum.reject(fn {name, _line} -> signature_field?(name) end)
      |> Enum.reject(fn {name, _line} -> name in excluded end)
      |> Enum.reject(fn {name, _line} -> MapSet.member?(signed, name) end)
      |> Enum.map(fn {name, line} -> finding(file, name, line, git_sha) end)
    else
      _ -> []
    end
  end

  # Fields a module deliberately leaves out of its signing payload, declared as
  #   @signing_excluded [:delegation_chain]
  # Lets a maintainer mark an intentional exclusion so it isn't re-flagged.
  defp signing_excluded_fields(ast) do
    {_, names} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:signing_excluded, _, [list]}]} = node, acc when is_list(list) ->
          {node, Enum.filter(list, &is_atom/1) ++ acc}

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp parse(file) do
    with {:ok, code} <- File.read(file) do
      Code.string_to_quoted(code, columns: true)
    end
  end

  # -- struct fields (typedstruct + defstruct), as {name, line} ---------------

  defp struct_fields(ast) do
    (typedstruct_fields(ast) ++ defstruct_fields(ast)) |> Enum.uniq_by(&elem(&1, 0))
  end

  defp typedstruct_fields(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:typedstruct, _, args} = node, acc ->
          {node, fields_in_typedstruct(args) ++ acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp fields_in_typedstruct(args) do
    block = block_of(args)

    {_, fields} =
      Macro.prewalk(block, [], fn
        {:field, meta, [name | _]} = node, acc when is_atom(name) ->
          {node, [{name, meta[:line]} | acc]}

        node, acc ->
          {node, acc}
      end)

    fields
  end

  defp defstruct_fields(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:defstruct, meta, [list]} = node, acc when is_list(list) ->
          names =
            Enum.map(list, fn
              {k, _v} when is_atom(k) -> {k, meta[:line]}
              k when is_atom(k) -> {k, meta[:line]}
            end)

          {node, names ++ acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp block_of(args) do
    case List.last(args) do
      kw when is_list(kw) -> Keyword.get(kw, :do, kw)
      other -> other
    end
  end

  # -- atoms referenced by signing_payload/1 (following local helpers) --------

  defp signing_payload_atoms(ast) do
    defs = collect_defs(ast)

    case Map.get(defs, :signing_payload) do
      nil -> :error
      bodies -> {:ok, gather(bodies, defs, 3, MapSet.new([:signing_payload]))}
    end
  end

  # %{function_name => [clause_body, ...]} for every def/defp in the module.
  defp collect_defs(ast) do
    {_, defs} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head, [do: body]]} = node, acc when kind in [:def, :defp] ->
          case fname(head) do
            nil -> {node, acc}
            name -> {node, Map.update(acc, name, [body], &[body | &1])}
          end

        node, acc ->
          {node, acc}
      end)

    defs
  end

  defp fname({:when, _, [{n, _, a} | _]}) when is_atom(n) and is_list(a), do: n
  defp fname({n, _, a}) when is_atom(n) and is_list(a), do: n
  defp fname(_), do: nil

  # Union of atoms in `bodies` plus the atoms of every local function they call,
  # transitively (depth-limited, cycle-guarded).
  defp gather(bodies, defs, depth, visited) do
    own =
      bodies
      |> Enum.map(&collect_atoms/1)
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    if depth == 0 do
      own
    else
      bodies
      |> Enum.flat_map(&local_calls/1)
      |> Enum.uniq()
      |> Enum.filter(&Map.has_key?(defs, &1))
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.reduce(own, fn name, acc ->
        MapSet.union(acc, gather(Map.get(defs, name), defs, depth - 1, MapSet.put(visited, name)))
      end)
    end
  end

  defp collect_atoms(body) do
    {_, atoms} =
      Macro.prewalk(body, [], fn
        node, acc when is_atom(node) -> {node, [node | acc]}
        node, acc -> {node, acc}
      end)

    MapSet.new(atoms)
  end

  defp local_calls(body) do
    {_, calls} =
      Macro.prewalk(body, [], fn
        {name, _, args} = node, acc when is_atom(name) and is_list(args) -> {node, [name | acc]}
        node, acc -> {node, acc}
      end)

    Enum.uniq(calls)
  end

  defp signature_field?(name), do: String.contains?(Atom.to_string(name), "signature")

  # -- finding ----------------------------------------------------------------

  defp finding(file, field, line, git_sha) do
    Finding.new(
      category: :crypto_weakness,
      title: "Signed-struct field `#{field}` is not covered by signing_payload/1",
      git_sha: git_sha,
      detector: %{layer: "L0b", name: "signed_field_coverage", version: "1"},
      severity: %{level: :high},
      confidence: %{score: 0.7, rationale: "field absent from signing_payload/1 body"},
      location: %{
        library: library_of(file),
        file: file,
        line: line,
        function: "signing_payload/1"
      },
      invariant_violated:
        "Every field of a signed struct must be covered by signing_payload/1, or it can be tampered with without invalidating the signature (C1).",
      evidence: %{smell_match: :unsigned_field, field: field},
      recommendation: %{
        approach:
          "Add `#{field}` to signing_payload/1 (and bump @signing_version), or confirm it is intentionally excluded and document why."
      },
      actionability: %{auto_fixable: false, risk_class: :high},
      verification: %{must_fail_on_revert: true}
    )
  end

  defp library_of(file) do
    case Regex.run(~r{apps/([^/]+)/}, file) do
      [_, lib] -> lib
      _ -> nil
    end
  end
end
