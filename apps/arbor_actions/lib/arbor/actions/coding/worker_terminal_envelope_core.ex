defmodule Arbor.Actions.Coding.WorkerTerminalEnvelopeCore do
  @moduledoc """
  Pure exact whole-message advisory terminal JSON validation for coding workers.

  Accepts only one JSON object that is the entire message (outer whitespace
  trimmed). Never scans for nested envelopes. Worker status is advisory only —
  callers must not use it as task-outcome authority.
  """

  @max_text_bytes 65_536
  @max_summary_bytes 4_096
  @allowed_statuses MapSet.new(["implemented", "declined"])
  @required_keys MapSet.new(["status"])
  @optional_keys MapSet.new(["summary"])
  @allowed_keys MapSet.union(@required_keys, @optional_keys)

  @protocol_errors ~w(
    text_required
    oversized
    invalid_json
    not_object
    not_whole_message
    unknown_status
    unknown_fields
    summary_not_string
    summary_oversized
    blank_status
  )

  @type protocol_error :: String.t()
  @type parse_ok :: %{
          required(String.t()) => boolean() | String.t() | nil
        }
  @type parse_error :: {:error, protocol_error(), map()}

  @doc "Closed protocol error codes."
  @spec protocol_errors() :: [String.t()]
  def protocol_errors, do: @protocol_errors

  @doc "Maximum accepted terminal text size in bytes."
  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: @max_text_bytes

  @doc "Maximum optional summary size in bytes."
  @spec max_summary_bytes() :: pos_integer()
  def max_summary_bytes, do: @max_summary_bytes

  @doc """
  Parse exact whole-message advisory terminal JSON.

  Returns `{:ok, fields}` or `{:error, protocol_error, evidence}` where evidence
  is JSON-clean and bounded (never includes full raw text).
  """
  @spec parse(term()) :: {:ok, parse_ok()} | parse_error()
  def parse(text) when is_binary(text) do
    # Byte-size first so oversized invalid UTF-8 never raises in trim/decode.
    cond do
      byte_size(text) > @max_text_bytes ->
        error("oversized", text)

      true ->
        trimmed = trim_ascii_ws(text)

        if trimmed == "" do
          error("text_required", text)
        else
          parse_trimmed(trimmed, text)
        end
    end
  end

  def parse(_text), do: error("text_required", "")

  defp parse_trimmed(trimmed, original) do
    # Never call String.* on untrusted input: invalid UTF-8 must return
    # bounded invalid evidence, not raise ArgumentError.
    case safe_json_decode(trimmed) do
      {:ok, object} when is_map(object) and not is_struct(object) ->
        # Exact whole-message: Jason.decode/1 already requires the full string
        # to be one JSON value (no residual non-JSON after the value).
        validate_object(object, original)

      {:ok, _other} ->
        error("not_object", original)

      :invalid_json ->
        # Distinguish residual garbage after a valid object from pure invalid JSON
        # by attempting a leading-object scan only for diagnostics — never accept.
        case leading_object_residue(trimmed) do
          :has_residue -> error("not_whole_message", original)
          :none -> error("invalid_json", original)
        end
    end
  end

  defp safe_json_decode(text) when is_binary(text) do
    try do
      case Jason.decode(text) do
        {:ok, value} -> {:ok, value}
        {:error, _reason} -> :invalid_json
      end
    rescue
      # Invalid UTF-8 or other binary faults must never raise to the graph.
      _ -> :invalid_json
    end
  end

  # ASCII whitespace trim that never raises on invalid UTF-8.
  defp trim_ascii_ws(text) when is_binary(text) do
    text
    |> trim_leading_ascii_ws()
    |> trim_trailing_ascii_ws()
  end

  defp trim_leading_ascii_ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r],
    do: trim_leading_ascii_ws(rest)

  defp trim_leading_ascii_ws(rest), do: rest

  defp trim_trailing_ascii_ws(text) do
    size = byte_size(text)

    if size == 0 do
      text
    else
      case :binary.at(text, size - 1) do
        c when c in [?\s, ?\t, ?\n, ?\r] ->
          trim_trailing_ascii_ws(binary_part(text, 0, size - 1))

        _ ->
          text
      end
    end
  end

  defp validate_object(object, original) do
    keys = Map.keys(object) |> MapSet.new()

    cond do
      not MapSet.subset?(keys, @allowed_keys) ->
        error("unknown_fields", original)

      not MapSet.subset?(@required_keys, keys) ->
        error("unknown_status", original)

      true ->
        validate_fields(object, original)
    end
  end

  defp validate_fields(object, original) do
    status = Map.get(object, "status")
    summary = Map.get(object, "summary")

    cond do
      not is_binary(status) ->
        error("unknown_status", original)

      blank_binary?(status) ->
        error("blank_status", original)

      not MapSet.member?(@allowed_statuses, status) ->
        error("unknown_status", original)

      not is_nil(summary) and not is_binary(summary) ->
        error("summary_not_string", original)

      is_binary(summary) and byte_size(summary) > @max_summary_bytes ->
        error("summary_oversized", original)

      true ->
        {:ok,
         %{
           "valid" => true,
           "status" => status,
           "summary" => summary,
           "protocol_error" => nil,
           "text_byte_size" => byte_size(original),
           "text_sha256" => sha256_hex(original)
         }}
    end
  end

  defp blank_binary?(value) when is_binary(value), do: trim_ascii_ws(value) == ""
  defp blank_binary?(_value), do: true

  # If the string starts with a balanced object and then non-whitespace remains,
  # classify as not_whole_message (e.g. `{}{}` or `{} prose`).
  defp leading_object_residue(<<"{", _::binary>> = text) do
    case take_balanced_object(text) do
      {:ok, _object, rest} ->
        if trim_ascii_ws(rest) == "", do: :none, else: :has_residue

      :error ->
        :none
    end
  end

  defp leading_object_residue(_text), do: :none

  defp take_balanced_object(<<"{", rest::binary>>) do
    take_balanced_object(rest, ["{"], ["{"])
  end

  defp take_balanced_object(_text), do: :error

  defp take_balanced_object(<<>>, _stack, _acc), do: :error

  defp take_balanced_object(<<"\"", rest::binary>>, stack, acc) do
    case take_string(rest, ["\"" | acc]) do
      {:ok, rest2, acc2} -> take_balanced_object(rest2, stack, acc2)
      :error -> :error
    end
  end

  defp take_balanced_object(<<"{", rest::binary>>, stack, acc) do
    take_balanced_object(rest, ["{" | stack], ["{" | acc])
  end

  defp take_balanced_object(<<"}", rest::binary>>, ["{" | stack], acc) do
    acc = ["}" | acc]

    case stack do
      [] ->
        object =
          acc
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        {:ok, object, rest}

      _more ->
        take_balanced_object(rest, stack, acc)
    end
  end

  defp take_balanced_object(<<byte, rest::binary>>, stack, acc) when stack != [] do
    take_balanced_object(rest, stack, [byte | acc])
  end

  defp take_balanced_object(_rest, _stack, _acc), do: :error

  defp take_string(<<"\\\"", rest::binary>>, acc), do: take_string(rest, ["\\\"" | acc])
  defp take_string(<<"\"", rest::binary>>, acc), do: {:ok, rest, ["\"" | acc]}
  defp take_string(<<>>, _acc), do: :error
  defp take_string(<<byte, rest::binary>>, acc), do: take_string(rest, [byte | acc])

  defp error(code, original) when code in @protocol_errors do
    {:error, code,
     %{
       "valid" => false,
       "status" => nil,
       "summary" => nil,
       "protocol_error" => code,
       "text_byte_size" => if(is_binary(original), do: byte_size(original), else: 0),
       "text_sha256" =>
         if(is_binary(original) and original != "", do: sha256_hex(original), else: nil)
     }}
  end

  defp sha256_hex(text) when is_binary(text) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, text), case: :lower)
  end
end
