defmodule Arbor.Orchestrator.Handlers.PromptAbTestHandler do
  @moduledoc """
  Handler for prompt.ab_test nodes that run two prompt variants
  against the same input, compare results, and log outcomes for cross-run
  statistical optimization.

  This enables rigorous prompt engineering: instead of guessing which prompt
  is better, run both and let the data decide.

  Node attributes:
    - `variant_a` - first prompt template (supports $goal expansion)
    - `variant_b` - second prompt template (supports $goal expansion)
    - `count` - number of runs per variant per execution (default: 1)
    - `judge_prompt` - custom prompt for the judge LLM to compare outputs
    - `persistence` - JSONL file path for cross-run logging (default: none)
    - `auto_promote` - when true and a variant wins with significance, note it (default: false)
    - `min_samples` - minimum total samples before auto-promotion (default: 20)
    - `significance` - p-value threshold for declaring a winner (default: 0.05)
    - `backend` - backend module override (same as codergen)

  Context updates written:
    - last_response: the winning variant's response for this run
    - last_stage: node ID
    - prompt_ab.{node_id}.winner: "a" or "b" for this run
    - prompt_ab.{node_id}.score_a: judge score for variant A (0.0-1.0)
    - prompt_ab.{node_id}.score_b: judge score for variant B (0.0-1.0)
    - prompt_ab.{node_id}.history_file: path to persistence JSONL (if set)
    - prompt_ab.{node_id}.cumulative_a_wins: total A wins across all runs (if persistence)
    - prompt_ab.{node_id}.cumulative_b_wins: total B wins across all runs (if persistence)
    - prompt_ab.{node_id}.promoted: "a" or "b" if auto-promoted (if applicable)
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.UnifiedLLM.{Client, Message, Request}

  import Arbor.Orchestrator.Handlers.Helpers

  @impl true
  def execute(node, context, graph, opts) do
    backend = resolve_backend(node)
    variant_a = expand_goal(Map.get(node.attrs, "variant_a", ""), graph)
    variant_b = expand_goal(Map.get(node.attrs, "variant_b", ""), graph)
    count = parse_int(Map.get(node.attrs, "count", "1"), 1)
    persistence = Map.get(node.attrs, "persistence")
    auto_promote = Map.get(node.attrs, "auto_promote", "false") == "true"
    min_samples = parse_int(Map.get(node.attrs, "min_samples", "20"), 20)
    significance = parse_float(Map.get(node.attrs, "significance", "0.05"), 0.05)

    stage_dir =
      case Keyword.get(opts, :logs_root) do
        nil -> nil
        root -> Path.join(root, node.id)
      end

    if stage_dir do
      File.mkdir_p!(stage_dir)
    end

    if variant_a == "" or variant_b == "" do
      %Outcome{
        status: :fail,
        failure_reason: "prompt.ab_test requires both variant_a and variant_b attributes"
      }
    else
      # Run both variants `count` times each
      a_responses = run_variant(backend, node, variant_a, context, count, stage_dir, "a")
      b_responses = run_variant(backend, node, variant_b, context, count, stage_dir, "b")

      # Judge: compare responses
      {score_a, score_b, winner, _judgment} =
        judge_variants(
          backend,
          node,
          variant_a,
          variant_b,
          a_responses,
          b_responses,
          context,
          graph
        )

      # Build context updates
      winning_response = if winner == "a", do: hd(a_responses), else: hd(b_responses)

      updates = %{
        "last_stage" => node.id,
        "last_response" => winning_response,
        "prompt_ab.#{node.id}.winner" => winner,
        "prompt_ab.#{node.id}.score_a" => score_a,
        "prompt_ab.#{node.id}.score_b" => score_b
      }

      # Persistence: append to JSONL log, compute cumulative stats
      updates =
        if persistence do
          entry = build_log_entry(node.id, winner, score_a, score_b, variant_a, variant_b)
          append_to_log(persistence, entry)
          {a_wins, b_wins} = compute_cumulative(persistence)
          promoted = check_promotion(auto_promote, a_wins, b_wins, min_samples, significance)

          updates
          |> Map.put("prompt_ab.#{node.id}.history_file", persistence)
          |> Map.put("prompt_ab.#{node.id}.cumulative_a_wins", a_wins)
          |> Map.put("prompt_ab.#{node.id}.cumulative_b_wins", b_wins)
          |> then(fn u ->
            if promoted, do: Map.put(u, "prompt_ab.#{node.id}.promoted", promoted), else: u
          end)
        else
          updates
        end

      notes = "AB Test: variant #{winner} wins (A=#{score_a}, B=#{score_b})"

      notes =
        if updates["prompt_ab.#{node.id}.promoted"] do
          notes <> " | AUTO-PROMOTED: variant #{updates["prompt_ab.#{node.id}.promoted"]}"
        else
          notes
        end

      %Outcome{
        status: :success,
        context_updates: updates,
        notes: notes
      }
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "PromptAbTest handler error: #{Exception.message(e)}"
      }
  end

  @impl true
  def idempotency, do: :side_effecting

  defp resolve_backend(node) do
    case Map.get(node.attrs, "backend") do
      nil ->
        nil

      mod when is_atom(mod) ->
        mod

      mod_string when is_binary(mod_string) ->
        try do
          String.to_existing_atom("Elixir." <> mod_string)
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp expand_goal(prompt, graph) do
    goal = Map.get(graph.attrs, "goal", "")
    String.replace(prompt, "$goal", goal)
  end

  defp run_variant(nil, _node, _prompt, _context, count, stage_dir, label) do
    Enum.map(1..count, fn i ->
      response = "[Simulated AB response for #{label}] variant #{:rand.uniform(1000)}"

      if stage_dir do
        File.write!(Path.join(stage_dir, "variant_#{label}_#{i}.md"), response)
      end

      response
    end)
  end

  defp run_variant(backend, node, prompt, context, count, stage_dir, label) do
    Enum.map(1..count, fn i ->
      case run_backend(backend, node, prompt, context) do
        {:ok, response} ->
          if stage_dir do
            File.write!(Path.join(stage_dir, "variant_#{label}_#{i}.md"), response)
          end

          response

        {:error, _reason} ->
          "[Error response for #{label}]"
      end
    end)
  end

  defp run_backend(nil, _node, _prompt, _context) do
    {:ok, "[Simulated AB response]"}
  end

  defp run_backend(_backend, _node, prompt, _context) do
    client = Client.default_client()

    request = %Request{
      messages: [
        %Message{
          role: "system",
          content: "You are a helpful assistant."
        },
        %Message{
          role: "user",
          content: prompt
        }
      ]
    }

    case Client.complete(client, request) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp judge_variants(backend, node, prompt_a, prompt_b, a_responses, b_responses, context, graph) do
    default_judge =
      "You are comparing two prompt variants for the task: #{Map.get(graph.attrs, "goal", "")}\n\n" <>
        "VARIANT A PROMPT: #{prompt_a}\n" <>
        "VARIANT A RESPONSE: #{hd(a_responses)}\n\n" <>
        "VARIANT B PROMPT: #{prompt_b}\n" <>
        "VARIANT B RESPONSE: #{hd(b_responses)}\n\n" <>
        "Which variant produced the better response? Score each 0.0 to 1.0 and declare a winner.\n" <>
        "Respond in EXACTLY this format:\n" <>
        "SCORE_A: <number>\nSCORE_B: <number>\nWINNER: <A or B>\nREASON: <one sentence>"

    judge_prompt = Map.get(node.attrs, "judge_prompt", default_judge)

    case run_backend(backend, node, judge_prompt, context) do
      {:ok, judge_response} ->
        {score_a, score_b, winner} = parse_judge_response(judge_response)
        {score_a, score_b, winner, judge_response}

      {:error, _reason} ->
        {0.5, 0.5, "a", "[Judge error]"}
    end
  end

  defp parse_judge_response(text) do
    score_a =
      case Regex.run(~r/SCORE_A:\s*([\d.]+)/, text) do
        [_, val] -> parse_float(val, 0.5)
        _ -> 0.5
      end

    score_b =
      case Regex.run(~r/SCORE_B:\s*([\d.]+)/, text) do
        [_, val] -> parse_float(val, 0.5)
        _ -> 0.5
      end

    winner =
      case Regex.run(~r/WINNER:\s*([ABab])/, text) do
        [_, w] -> String.downcase(w)
        _ -> "a"
      end

    {score_a, score_b, winner}
  end

  defp build_log_entry(node_id, winner, score_a, score_b, variant_a, variant_b) do
    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      node_id: node_id,
      winner: winner,
      score_a: score_a,
      score_b: score_b,
      variant_a_hash: :erlang.md5(variant_a) |> Base.encode16(case: :lower),
      variant_b_hash: :erlang.md5(variant_b) |> Base.encode16(case: :lower)
    }
  end

  defp append_to_log(path, entry) do
    File.mkdir_p!(Path.dirname(path))
    line = Jason.encode!(entry) <> "\n"
    File.write!(path, line, [:append])
  end

  defp compute_cumulative(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reduce({0, 0}, fn line, {a_wins, b_wins} ->
          case Jason.decode(line) do
            {:ok, %{"winner" => "a"}} -> {a_wins + 1, b_wins}
            {:ok, %{"winner" => "b"}} -> {a_wins, b_wins + 1}
            _ -> {a_wins, b_wins}
          end
        end)

      {:error, _} ->
        {0, 0}
    end
  end

  defp check_promotion(false, _a_wins, _b_wins, _min_samples, _significance), do: nil

  defp check_promotion(true, a_wins, b_wins, min_samples, significance) do
    total = a_wins + b_wins

    if total < min_samples do
      nil
    else
      p_hat = max(a_wins, b_wins) / total
      z = (p_hat - 0.5) / :math.sqrt(0.25 / total)
      p_value = 1.0 - normal_cdf(z)

      if p_value < significance do
        if a_wins > b_wins, do: "a", else: "b"
      else
        nil
      end
    end
  end

  defp normal_cdf(z) do
    0.5 * (1.0 + :math.erf(z / :math.sqrt(2)))
  end

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> default
    end
  end

  defp parse_float(value, _default) when is_float(value), do: value
  defp parse_float(_value, default), do: default
end
