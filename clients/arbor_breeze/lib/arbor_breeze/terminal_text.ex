defmodule ArborBreeze.TerminalText do
  @moduledoc "Literal terminal display for untrusted host text; never an ANSI control channel."

  def literal(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.to_charlist()
    |> Enum.map(fn
      ?\n ->
        "\n"

      ?\t ->
        "    "

      codepoint when codepoint < 32 or codepoint in 127..159 ->
        "\\u" <> String.pad_leading(Integer.to_string(codepoint, 16), 4, "0")

      codepoint ->
        <<codepoint::utf8>>
    end)
    |> IO.iodata_to_binary()
  end

  def literal(_), do: ""
end
