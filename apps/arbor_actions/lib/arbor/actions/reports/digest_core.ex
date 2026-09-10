defmodule Arbor.Actions.Reports.DigestCore do
  @moduledoc false

  @topics ["upstream-deps", "upstream-deps-summary"]
  @file_limit 256 * 1024
  @output_limit 1024 * 1024

  def file_limit, do: @file_limit

  def new(%{reports_directory: "reports", topics: @topics} = params, %Date{} = date)
      when map_size(params) == 2 do
    day = Date.to_iso8601(date)

    {:ok,
     %{
       day: day,
       inputs: Enum.map(@topics, &{&1, "reports/#{&1}/#{day}.md"}),
       output: "reports/morning-digest/#{day}.md"
     }}
  end

  def new(_params, _date), do: {:error, :invalid_digest_parameters}

  def render(%{day: day}, reports) do
    with :ok <- validate_reports(reports) do
      included = for {topic, content} <- reports, is_binary(content), do: topic
      missing = for {topic, :missing} <- reports, do: topic

      sections =
        for {topic, content} <- reports, is_binary(content) do
          ["## ", topic, "\n\n", content, "\n\n---\n\n"]
        end

      body = [
        "# Morning digest — ",
        day,
        "\n\n",
        if(included == [], do: "_No reports are available for this UTC date._\n\n", else: []),
        missing_section(missing),
        sections
      ]

      if IO.iodata_length(body) <= @output_limit do
        {:ok, %{content: IO.iodata_to_binary(body), included: included, missing: missing}}
      else
        {:error, :digest_output_too_large}
      end
    end
  end

  defp validate_reports([{first, a}, {second, b}]) when [first, second] == @topics do
    Enum.reduce_while([a, b], :ok, fn
      :missing, :ok ->
        {:cont, :ok}

      content, :ok when is_binary(content) and byte_size(content) <= @file_limit ->
        if String.valid?(content),
          do: {:cont, :ok},
          else: {:halt, {:error, :invalid_report_encoding}}

      _, :ok ->
        {:halt, {:error, :report_too_large}}
    end)
  end

  defp validate_reports(_), do: {:error, :invalid_digest_inputs}
  defp missing_section([]), do: []
  defp missing_section(topics), do: ["Missing reports: ", Enum.intersperse(topics, ", "), ".\n\n"]
end
