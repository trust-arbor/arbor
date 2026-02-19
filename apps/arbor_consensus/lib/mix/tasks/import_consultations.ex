defmodule Mix.Tasks.Arbor.ImportConsultations do
  @moduledoc """
  Import historical council consultations from `.arbor/council/` into the eval database.

  Parses `perspectives.md` files (YAML frontmatter + JSON code fences) and
  individual per-perspective `.md` files, creating EvalRun + EvalResult records.

  ## Usage

      mix arbor.import_consultations           # import all, skip existing
      mix arbor.import_consultations --dry-run  # preview without inserting
      mix arbor.import_consultations --force    # re-import even if exists
  """
  use Mix.Task

  @shortdoc "Import historical council consultations into eval database"

  @council_dir ".arbor/council"
  @domain "advisory_consultation"

  # Perspectives with individual per-file markdown (not perspectives.md)
  @individual_file_perspectives ~w[
    brainstorming capability consistency emergence generalization
    performance privacy resource_usage security stability
    user_experience vision
  ]

  @impl Mix.Task
  def run(args) do
    dry_run? = "--dry-run" in args
    force? = "--force" in args

    Mix.Task.run("app.start")

    council_root = find_council_root()

    unless council_root do
      Mix.shell().error("Could not find #{@council_dir} directory")
      System.halt(1)
    end

    existing_datasets = if force?, do: MapSet.new(), else: load_existing_datasets()

    dirs =
      council_root
      |> File.ls!()
      |> Enum.sort()
      |> Enum.map(&Path.join(council_root, &1))
      |> Enum.filter(&File.dir?/1)

    Mix.shell().info("Found #{length(dirs)} council directories")
    Mix.shell().info("Existing consultations in DB: #{MapSet.size(existing_datasets)}")

    results =
      Enum.reduce(dirs, %{imported: 0, skipped: 0, failed: 0}, fn dir, acc ->
        dir_name = Path.basename(dir)

        cond do
          MapSet.member?(existing_datasets, dir_name) ->
            Mix.shell().info("  SKIP #{dir_name} (already imported)")
            %{acc | skipped: acc.skipped + 1}

          true ->
            try_import(dir, dir_name, dry_run?, acc)
        end
      end)

    Mix.shell().info("")
    prefix = if dry_run?, do: "[DRY RUN] ", else: ""

    Mix.shell().info(
      "#{prefix}Done: #{results.imported} imported, #{results.skipped} skipped, #{results.failed} failed"
    )
  end

  # ── Import logic ───────────────────────────────────────────────────

  defp import_consultation(dir, dry_run?) do
    perspectives_path = Path.join(dir, "perspectives.md")
    question_path = Path.join(dir, "question.md")

    cond do
      File.exists?(perspectives_path) ->
        import_perspectives_md(dir, perspectives_path, dry_run?)

      has_individual_perspective_files?(dir) ->
        import_individual_files(dir, question_path, dry_run?)

      true ->
        {:skip, "no perspectives found"}
    end
  end

  defp try_import(dir, dir_name, dry_run?, acc) do
    case import_consultation(dir, dry_run?) do
      {:ok, count} ->
        label = if dry_run?, do: "WOULD IMPORT", else: "IMPORTED"
        Mix.shell().info("  #{label} #{dir_name} (#{count} perspectives)")
        %{acc | imported: acc.imported + 1}

      {:skip, reason} ->
        Mix.shell().info("  SKIP #{dir_name} (#{reason})")
        %{acc | skipped: acc.skipped + 1}

      {:error, reason} ->
        Mix.shell().error("  FAIL #{dir_name}: #{inspect(reason)}")
        %{acc | failed: acc.failed + 1}
    end
  end

  # ── Format 1: perspectives.md ──────────────────────────────────────

  defp import_perspectives_md(dir, path, dry_run?) do
    content = File.read!(path)

    case parse_perspectives_md(content) do
      {:ok, frontmatter, perspectives} when perspectives != [] ->
        question = Map.get(frontmatter, "question", Path.basename(dir))
        date = Map.get(frontmatter, "date", extract_date_from_dirname(dir))

        if dry_run? do
          {:ok, length(perspectives)}
        else
          insert_consultation(dir, question, date, perspectives)
        end

      {:ok, _frontmatter, []} ->
        {:skip, "no perspective data parsed"}
    end
  end

  defp parse_perspectives_md(content) do
    case String.split(content, "---", parts: 3) do
      [_, yaml_str, body] ->
        frontmatter = parse_yaml_frontmatter(yaml_str)
        perspectives = parse_perspective_sections(body)
        {:ok, frontmatter, perspectives}

      _ ->
        # No frontmatter, try parsing body directly
        perspectives = parse_perspective_sections(content)
        {:ok, %{}, perspectives}
    end
  end

  defp parse_yaml_frontmatter(yaml_str) do
    yaml_str
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          key = String.trim(key)
          value = value |> String.trim() |> String.trim("\"")

          if key != "" and value != "" do
            Map.put(acc, key, value)
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  defp parse_perspective_sections(body) do
    # First try: JSON code fences
    # Match sections like: ## perspective_name (provider:model)
    # Followed by ```json ... ```
    json_regex = ~r/##\s+(\w+)\s+\(([^)]+)\)\s*\n+```json\n(.*?)```/s
    json_matches = Regex.scan(json_regex, body)

    if json_matches != [] do
      Enum.map(json_matches, fn [_full, name, provider_model, json_str] ->
        {provider, model} = parse_provider_model(provider_model)

        parsed =
          case Jason.decode(json_str) do
            {:ok, data} -> data
            {:error, _} -> %{"analysis" => json_str}
          end

        %{name: name, provider: provider, model: model, data: parsed}
      end)
    else
      # Fallback: prose format
      # Match: ## perspective_name (provider) followed by prose text until next ## or end
      prose_regex = ~r/##\s+(\w+)\s+\(([^)]+)\)\s*\n(.*?)(?=\n##\s|\z)/s

      Regex.scan(prose_regex, body)
      |> Enum.map(fn [_full, name, provider_model, prose] ->
        {provider, model} = parse_provider_model(provider_model)
        data = parse_prose_perspective(prose)
        %{name: name, provider: provider, model: model, data: data}
      end)
    end
  end

  defp parse_prose_perspective(prose) do
    # Extract structured sections from prose format
    considerations = extract_prose_list(prose, "Considerations")
    alternatives = extract_prose_list(prose, "Alternatives")
    recommendation = extract_prose_section(prose, "Recommendation")

    # Everything before the first ** section is the analysis
    analysis =
      case String.split(prose, ~r/\n\*\*/, parts: 2) do
        [before, _] -> String.trim(before)
        [all] -> String.trim(all)
      end

    %{
      "analysis" => analysis,
      "considerations" => considerations,
      "alternatives" => alternatives,
      "recommendation" => recommendation || ""
    }
  end

  defp extract_prose_list(text, heading) do
    regex = ~r/\*\*#{heading}:\*\*\s*\n(.*?)(?=\n\*\*|\z)/s

    case Regex.run(regex, text) do
      [_, content] ->
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "- "))
        |> Enum.map(&String.trim_leading(&1, "- "))

      nil ->
        []
    end
  end

  defp extract_prose_section(text, heading) do
    regex = ~r/\*\*#{heading}:\*\*\s*\n(.*?)(?=\n\*\*|\z)/s

    case Regex.run(regex, text) do
      [_, content] -> String.trim(content)
      nil -> nil
    end
  end

  defp parse_provider_model(str) do
    str = String.trim(str)

    cond do
      # "openrouter:google/gemini-3-flash-preview"
      String.contains?(str, ":") ->
        [provider | rest] = String.split(str, ":", parts: 2)
        {provider, Enum.join(rest, ":")}

      # "codex_cli via orchestrator"
      String.contains?(str, " via ") ->
        [provider | _] = String.split(str, " via ")
        {provider, str}

      true ->
        {"unknown", str}
    end
  end

  # ── Format 2: individual perspective files ─────────────────────────

  defp has_individual_perspective_files?(dir) do
    Enum.any?(@individual_file_perspectives, fn name ->
      File.exists?(Path.join(dir, "#{name}.md"))
    end)
  end

  defp import_individual_files(dir, question_path, dry_run?) do
    question =
      if File.exists?(question_path) do
        extract_question_from_md(question_path)
      else
        Path.basename(dir)
      end

    date = extract_date_from_dirname(dir)

    perspectives =
      @individual_file_perspectives
      |> Enum.filter(fn name -> File.exists?(Path.join(dir, "#{name}.md")) end)
      |> Enum.map(fn name ->
        path = Path.join(dir, "#{name}.md")
        content = File.read!(path)
        frontmatter = extract_frontmatter(content)
        body = extract_body(content)

        {provider, model} =
          case Map.get(frontmatter, "provider") do
            nil -> {"unknown", "unknown"}
            p -> parse_provider_model(p)
          end

        # Try to extract JSON from code fence, otherwise use prose
        data =
          case Regex.run(~r/```json\n(.*?)```/s, body) do
            [_, json_str] ->
              case Jason.decode(json_str) do
                {:ok, parsed} -> parsed
                {:error, _} -> %{"analysis" => String.slice(body, 0, 5000)}
              end

            nil ->
              %{"analysis" => String.slice(body, 0, 5000)}
          end

        %{
          name: name,
          provider: provider,
          model: model,
          data: data
        }
      end)

    # Also check for hand-perspectives directory
    hand_dir = Path.join(dir, "hand-perspectives")

    hand_perspectives =
      if File.dir?(hand_dir) do
        hand_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(fn filename ->
          name = String.trim_trailing(filename, ".md")
          path = Path.join(hand_dir, filename)
          content = File.read!(path)
          body = extract_body(content)

          %{
            name: name,
            provider: "hand",
            model: "claude-opus",
            data: %{"analysis" => String.slice(body, 0, 5000)}
          }
        end)
      else
        []
      end

    # Also check for hand-*.md files at top level
    hand_files =
      dir
      |> File.ls!()
      |> Enum.filter(fn f -> String.starts_with?(f, "hand-") and String.ends_with?(f, ".md") end)
      |> Enum.map(fn filename ->
        name = filename |> String.trim_leading("hand-") |> String.trim_trailing(".md")
        path = Path.join(dir, filename)
        content = File.read!(path)
        body = extract_body(content)

        %{
          name: name,
          provider: "hand",
          model: "claude-opus",
          data: %{"analysis" => String.slice(body, 0, 5000)}
        }
      end)

    all_perspectives = perspectives ++ hand_perspectives ++ hand_files

    if all_perspectives == [] do
      {:skip, "no perspective content parsed"}
    else
      if dry_run? do
        {:ok, length(all_perspectives)}
      else
        insert_consultation(dir, question, date, all_perspectives)
      end
    end
  end

  defp extract_question_from_md(path) do
    content = File.read!(path)
    fm = extract_frontmatter(content)

    # Check frontmatter for question field
    case Map.get(fm, "question") do
      q when is_binary(q) and q != "" ->
        String.trim(q)

      _ ->
        # Fall back to body text after frontmatter
        body = extract_body(content)
        # Take the first heading or first paragraph
        body
        |> String.split("\n")
        |> Enum.find(&(String.trim(&1) != ""))
        |> case do
          nil -> Path.basename(Path.dirname(path))
          line -> line |> String.trim_leading("# ") |> String.trim()
        end
    end
  end

  defp extract_frontmatter(content) do
    case String.split(content, "---", parts: 3) do
      [_, yaml_str, _] -> parse_yaml_frontmatter(yaml_str)
      _ -> %{}
    end
  end

  defp extract_body(content) do
    case String.split(content, "---", parts: 3) do
      [_, _, body] -> String.trim(body)
      _ -> String.trim(content)
    end
  end

  # ── Database insertion ─────────────────────────────────────────────

  defp insert_consultation(dir, question, date, perspectives) do
    run_id = generate_id()
    dir_name = Path.basename(dir)

    perspective_names = Enum.map(perspectives, & &1.name)

    run_attrs = %{
      id: run_id,
      domain: @domain,
      model: "multi",
      provider: "multi",
      dataset: dir_name,
      sample_count: length(perspectives),
      status: "completed",
      config: %{
        "question" => question,
        "source" => "filesystem_import",
        "directory" => dir_name
      },
      metadata: %{
        "source" => "import_consultations",
        "perspective_count" => length(perspectives),
        "perspectives" => perspective_names,
        "original_date" => date
      }
    }

    case Arbor.Persistence.insert_eval_run(run_attrs) do
      {:ok, _} ->
        result_attrs =
          Enum.map(perspectives, fn p ->
            data = p.data

            # Extract vote/confidence from data if present
            vote = extract_field(data, "recommendation", "approve")
            confidence = extract_confidence(data)
            concerns = Map.get(data, "considerations", Map.get(data, "concerns", []))
            recommendations = extract_recommendations(data)

            %{
              id: generate_id(),
              run_id: run_id,
              sample_id: p.name,
              input: question,
              actual: format_response(data),
              passed: true,
              scores: %{
                "vote" => vote,
                "confidence" => confidence
              },
              duration_ms: 0,
              metadata: %{
                "provider" => p.provider,
                "model" => p.model,
                "perspective" => p.name,
                "concerns" => ensure_list(concerns),
                "recommendations" => ensure_list(recommendations)
              }
            }
          end)

        Arbor.Persistence.insert_eval_results_batch(result_attrs)
        {:ok, length(perspectives)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp find_council_root do
    candidates = [
      Path.join(File.cwd!(), @council_dir),
      Path.join(Path.join(File.cwd!(), ".."), @council_dir),
      Path.expand("~/code/trust-arbor/arbor/#{@council_dir}")
    ]

    Enum.find(candidates, &File.dir?/1)
  end

  defp load_existing_datasets do
    case Arbor.Persistence.list_eval_runs(domain: @domain, limit: 1000) do
      {:ok, runs} ->
        runs |> Enum.map(& &1.dataset) |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp extract_date_from_dirname(dir) do
    basename = Path.basename(dir)

    case Regex.run(~r/^(\d{4}-\d{2}-\d{2})/, basename) do
      [_, date] -> date
      _ -> Date.to_iso8601(Date.utc_today())
    end
  end

  defp extract_field(data, key, default) when is_map(data) do
    Map.get(data, key, default)
  end

  defp extract_field(_, _, default), do: default

  defp extract_confidence(data) when is_map(data) do
    case Map.get(data, "confidence") do
      val when is_number(val) -> val
      _ -> 0.7
    end
  end

  defp extract_confidence(_), do: 0.7

  defp extract_recommendations(data) when is_map(data) do
    cond do
      is_list(Map.get(data, "recommendations")) -> Map.get(data, "recommendations")
      is_binary(Map.get(data, "recommendation")) -> [Map.get(data, "recommendation")]
      is_list(Map.get(data, "alternatives")) -> Map.get(data, "alternatives")
      true -> []
    end
  end

  defp extract_recommendations(_), do: []

  defp ensure_list(val) when is_list(val), do: val
  defp ensure_list(val) when is_binary(val), do: [val]
  defp ensure_list(_), do: []

  defp format_response(data) when is_map(data) do
    parts =
      [
        format_section("Analysis", Map.get(data, "analysis")),
        format_section("Recommendation", Map.get(data, "recommendation")),
        format_list("Considerations", Map.get(data, "considerations")),
        format_list("Concerns", Map.get(data, "concerns")),
        format_list("Alternatives", Map.get(data, "alternatives")),
        format_list("Recommendations", Map.get(data, "recommendations"))
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "\n\n")
  end

  defp format_response(text) when is_binary(text), do: text
  defp format_response(_), do: ""

  defp format_section(_title, nil), do: nil
  defp format_section(_title, ""), do: nil
  defp format_section(title, text), do: "## #{title}\n\n#{text}"

  defp format_list(_title, nil), do: nil
  defp format_list(_title, []), do: nil

  defp format_list(title, items) when is_list(items) do
    bullets = Enum.map_join(items, "\n", &"- #{&1}")
    "## #{title}\n\n#{bullets}"
  end

  defp format_list(_, _), do: nil

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
