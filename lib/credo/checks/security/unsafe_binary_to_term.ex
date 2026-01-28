defmodule Credo.Check.Security.UnsafeBinaryToTerm do
  @moduledoc false

  use Credo.Check,
    id: "EX9002",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      `:erlang.binary_to_term/1` can deserialize arbitrary Erlang terms, including:
      - Atoms (enabling atom exhaustion DoS)
      - Function references (potential code execution)
      - Process identifiers (information leakage)

      Always use `:erlang.binary_to_term/2` with the `:safe` option when
      deserializing untrusted data. The `:safe` option prevents creation of
      new atoms and decoding of function references.

      ## Example

          # Bad - vulnerable to multiple attacks
          data = :erlang.binary_to_term(untrusted_binary)

          # Good - safe deserialization
          data = :erlang.binary_to_term(untrusted_binary, [:safe])

      Note: Even with `:safe`, be cautious about the structure of deserialized
      data. Validate the shape and contents before use.
      """
    ]

  @doc false
  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # :erlang.binary_to_term(binary) - arity 1 is always unsafe
  defp traverse(
         {{:., _, [:erlang, :binary_to_term]}, meta, [_binary]} = ast,
         issues,
         issue_meta
       ) do
    issue = issue_for(issue_meta, meta[:line], "missing :safe option")
    {ast, [issue | issues]}
  end

  # :erlang.binary_to_term(binary, opts) - check for :safe in opts
  defp traverse(
         {{:., _, [:erlang, :binary_to_term]}, meta, [_binary, opts]} = ast,
         issues,
         issue_meta
       ) do
    if has_safe_option?(opts) do
      {ast, issues}
    else
      issue = issue_for(issue_meta, meta[:line], ":safe not in options")
      {ast, [issue | issues]}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp has_safe_option?(opts) do
    case opts do
      # [:safe] or [:safe, :used]
      list when is_list(list) ->
        Enum.any?(list, fn
          :safe -> true
          _ -> false
        end)

      # Variable - can't verify statically, assume unsafe
      _ ->
        false
    end
  end

  defp issue_for(issue_meta, line_no, detail) do
    format_issue(
      issue_meta,
      message: ":erlang.binary_to_term/1,2 without :safe option is vulnerable to atom exhaustion and code execution (#{detail}).",
      trigger: ":erlang.binary_to_term",
      line_no: line_no
    )
  end
end
