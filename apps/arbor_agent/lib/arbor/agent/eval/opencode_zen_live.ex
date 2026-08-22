defmodule Arbor.Agent.Eval.OpenCodeZenLive do
  @moduledoc """
  Live two-tier probe that refreshes the OpenCode Zen admission catalog.

  Tier 1 is a mechanical well-formed tool-call check per candidate. Tier 2
  is `Arbor.Agent.Eval.TaskEval` and runs only for tier-1 passers. Outcomes
  convert through `OpenCodeZenAdmission` and replace the recorded catalog.
  """

  alias Arbor.Agent.Eval.{OpenCodeZenAdmission, TaskEval}
  alias Arbor.LLM.OpenCodeZen

  @default_max_heartbeats 3

  @doc """
  Probe `opts[:ids]` and persist an updated catalog.

  Options:

    * `:ids` — candidate model ids (required)
    * `:max_heartbeats` — TaskEval budget (default 3)
    * `:complete` — `(id -> response)` tier-1 function
    * `:eval_task` — `(id, max_heartbeats -> trial_map)` tier-2 function
    * `:persist` — `(payload -> :ok | {:error, term()})`
    * `:existing` — current catalog state
    * `:now` — recorded_at stamp
    * `:log` — `(binary -> any())` progress callback
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) when is_list(opts) do
    ids = Keyword.fetch!(opts, :ids)
    max_heartbeats = Keyword.get(opts, :max_heartbeats) || @default_max_heartbeats
    complete = Keyword.get(opts, :complete, &default_complete/1)
    eval_task = Keyword.get(opts, :eval_task, &default_eval_task/2)
    persist = Keyword.get(opts, :persist, &OpenCodeZen.persist_admission/1)
    existing = Keyword.get(opts, :existing, OpenCodeZen.catalog())
    now = Keyword.get(opts, :now, Date.utc_today() |> Date.to_iso8601())
    log = Keyword.get(opts, :log, fn _line -> :ok end)

    models =
      Enum.reduce(ids, existing.models, fn id, acc ->
        record = probe_one(id, max_heartbeats, complete, eval_task, log)
        upsert_model(acc, record)
      end)

    payload = %{
      "version" => existing.version || 1,
      "provider" => "opencode_zen",
      "recorded_at" => now,
      "eval" => %{
        "tier1" => "mechanical_tool_call",
        "tier2" =>
          "mix arbor.eval.task --max-heartbeats #{max_heartbeats} --bug glob_wildcard --variants bare"
      },
      "models" => models
    }

    case persist.(payload) do
      :ok -> {:ok, payload}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec tier1_request(String.t()) :: Arbor.LLM.Request.t()
  def tier1_request(id) when is_binary(id) do
    %Arbor.LLM.Request{
      provider: "opencode_zen",
      model: id,
      messages: [
        %Arbor.LLM.Message{
          role: :user,
          content: "Call the ping tool exactly once with ok=true. Do not reply with text."
        }
      ],
      tools: [
        %{
          "type" => "function",
          "function" => %{
            "name" => "ping",
            "description" => "Mechanical admission probe",
            "parameters" => %{
              "type" => "object",
              "properties" => %{"ok" => %{"type" => "boolean"}},
              "required" => ["ok"]
            }
          }
        }
      ],
      # ReqLLM drops OpenAI-spec "required"; pin ping so the wire request
      # actually enforces a tool call.
      tool_choice: %{type: "tool", name: "ping"}
    }
  end

  defp probe_one(id, max_heartbeats, complete, eval_task, log) do
    log.("  tier 1 #{id}")
    response = complete.(id)
    tier1 = OpenCodeZenAdmission.tier1_from_response(unwrap_response(response))

    if tier1.passed do
      log.("  tier 2 #{id} (max-heartbeats #{max_heartbeats})")
      trial = eval_task.(id, max_heartbeats)
      OpenCodeZenAdmission.record(id, tier1, OpenCodeZenAdmission.tier2_from_trial(trial))
    else
      log.("  rejected at tier 1: #{tier1.reason}")

      OpenCodeZenAdmission.record(id, tier1, %{
        passed: false,
        skipped: true,
        reason: "tier1_failed"
      })
    end
  end

  defp unwrap_response({:ok, response}), do: response
  defp unwrap_response(other), do: other

  defp upsert_model(models, record) do
    id = record["id"]

    case Enum.find_index(models, &(Map.get(&1, "id") == id)) do
      nil -> models ++ [record]
      index -> List.replace_at(models, index, record)
    end
  end

  defp default_complete(id) do
    Arbor.LLM.Adapter.ReqLLM.complete(tier1_request(id))
  end

  defp default_eval_task(id, max_heartbeats) do
    case TaskEval.run(
           variants: [:bare],
           max_heartbeats: max_heartbeats,
           reps: 1,
           model: id,
           provider: :opencode_zen,
           bug: :glob_wildcard
         ) do
      {:ok, summary} ->
        stats = get_in(summary, [:variants, :bare]) || %{}
        submitted? = Map.get(stats, :proposals_submitted, 0) > 0

        %{
          proposal_submitted: submitted?,
          heartbeats_to_proposal: if(submitted?, do: Map.get(stats, :avg_heartbeats), else: nil)
        }

      {:error, reason} ->
        %{proposal_submitted: false, error: inspect(reason)}
    end
  end
end
