defmodule Arbor.Orchestrator.Human.ConsoleInterviewer do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Human.Interviewer

  alias Arbor.Orchestrator.Human.{Answer, Question}

  @impl true
  def ask(%Question{} = question, opts \\ []) do
    io = Keyword.get(opts, :io, default_io())

    print_question(io, question)
    response = io.gets.("Select: ")
    normalize_response(response, question)
  end

  defp print_question(io, %Question{text: text, options: options}) do
    io.puts.("[?] " <> to_string(text))

    Enum.each(options, fn option ->
      io.puts.("  [#{option.key}] #{option.label}")
    end)
  end

  defp normalize_response(nil, _question), do: %Answer{value: :timeout}

  defp normalize_response(response, %Question{options: options}) when is_binary(response) do
    value = response |> String.trim()

    selected =
      Enum.find(options, fn option ->
        String.downcase(option.key) == String.downcase(value) or
          String.downcase(option.label) == String.downcase(value) or
          String.downcase(option.to) == String.downcase(value)
      end)

    if selected do
      %Answer{value: selected.key, selected_option: selected}
    else
      %Answer{value: value}
    end
  end

  defp normalize_response(_response, _question), do: %Answer{value: :skipped}

  defp default_io do
    %{
      puts: fn line -> IO.puts(line) end,
      gets: fn prompt -> IO.gets(prompt) end
    }
  end
end
