defmodule Arbor.Orchestrator.Session.RefusalDiagnostic do
  @moduledoc """
  Bounded, content-free description of why a Session refused a turn.

  The caller still only sees `:turn_preparation_refused`; this text is for the
  operator log, so a refusal is never silent. Every turn-preparation failure
  used to collapse into that one atom, which hid a missing disclosure grant on
  every fresh install (found 2026-11-13).

  Nothing a turn carries may reach the log, so this module never renders a
  string, map value or list element:

    * exceptions are named by module; the message is kept only for exception
      types whose message is built from code (module and function names), not
      from the data being matched;
    * other reasons are reduced to their shape: atoms, numbers and tuple
      structure survive, binaries, maps and lists become sizes;
    * stack frames become `Module.fun/arity (file:line)`, never arguments.

  Pure: no logging, no process state.
  """

  @max_frames 3
  @max_depth 3
  @max_tuple_elements 4
  @max_message_chars 160
  @max_chars 600

  # Messages built from code, not from the value being matched or inspected.
  @code_built_messages [
    UndefinedFunctionError,
    FunctionClauseError,
    ArithmeticError,
    SystemLimitError
  ]

  @doc """
  Describe a rescued or caught failure: `kind` and `reason` as given to
  `rescue`/`catch`, plus `__STACKTRACE__`.
  """
  @spec describe(atom(), term(), Exception.stacktrace() | term()) :: String.t()
  def describe(kind, reason, stacktrace \\ []) do
    head =
      case {kind, reason} do
        {:error, %{__exception__: true} = exception} -> describe_exception(exception)
        {kind, reason} -> "#{kind} #{shape(reason)}"
      end

    case frames(stacktrace) do
      "" -> bound(head)
      at -> bound(head <> " at " <> at)
    end
  end

  @doc "Describe a returned error reason (no exception, no stack)."
  @spec describe_reason(term()) :: String.t()
  def describe_reason(reason), do: bound(shape(reason))

  @doc """
  The shape of a term: atoms, numbers, pids and tuple structure are kept;
  binaries, lists and maps are replaced by their size.
  """
  @spec shape(term()) :: String.t()
  def shape(term), do: shape(term, @max_depth)

  defp shape(term, _depth) when is_atom(term), do: inspect(term)
  defp shape(term, _depth) when is_integer(term) or is_float(term), do: inspect(term)
  defp shape(term, _depth) when is_binary(term), do: "<binary #{byte_size(term)} bytes>"
  defp shape(term, _depth) when is_bitstring(term), do: "<bitstring>"
  defp shape(term, _depth) when is_list(term), do: "<list #{safe_length(term)} items>"
  defp shape(%module{}, _depth) when is_atom(module), do: "%#{inspect(module)}{}"
  defp shape(term, _depth) when is_map(term), do: "<map #{map_size(term)} keys>"
  defp shape(term, _depth) when is_pid(term), do: "#PID"
  defp shape(term, _depth) when is_reference(term), do: "#Reference"
  defp shape(term, _depth) when is_port(term), do: "#Port"
  defp shape(term, _depth) when is_function(term), do: "#Function"
  defp shape(term, 0) when is_tuple(term), do: "{...#{tuple_size(term)}}"

  defp shape(term, depth) when is_tuple(term) do
    elements = Tuple.to_list(term)
    shown = elements |> Enum.take(@max_tuple_elements) |> Enum.map(&shape(&1, depth - 1))
    more = if length(elements) > @max_tuple_elements, do: [", ..."], else: []
    "{" <> Enum.join(shown, ", ") <> Enum.join(more) <> "}"
  end

  defp shape(_term, _depth), do: "<term>"

  defp describe_exception(%module{} = exception) do
    name = inspect(module)

    case exception do
      %{__struct__: mod} when mod in @code_built_messages ->
        name <> ": " <> truncate(safe_message(exception), @max_message_chars)

      %KeyError{key: key} ->
        name <> " key=" <> shape(key)

      %{__struct__: mod, term: term} when mod in [MatchError, CaseClauseError, WithClauseError] ->
        name <> " " <> shape(term)

      %ErlangError{original: original} ->
        name <> " " <> shape(original)

      _ ->
        name
    end
  end

  defp safe_message(exception) do
    Exception.message(exception)
  rescue
    _ -> "<message unavailable>"
  end

  defp frames(stacktrace) when is_list(stacktrace) do
    stacktrace
    |> Enum.take(@max_frames)
    |> Enum.flat_map(&frame/1)
    |> Enum.join(" <- ")
  end

  defp frames(_stacktrace), do: ""

  defp frame({module, function, args, location}) when is_list(args),
    do: frame({module, function, length(args), location})

  defp frame({module, function, arity, location} = entry)
       when is_atom(module) and is_atom(function) and is_integer(arity) and is_list(location) do
    [Exception.format_stacktrace_entry(entry)]
  rescue
    _ -> []
  end

  defp frame(_entry), do: []

  defp safe_length(list) do
    length(list)
  rescue
    _ -> "?"
  end

  defp bound(text), do: truncate(text, @max_chars)

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end
end
