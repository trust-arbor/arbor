defmodule Arbor.Agent.Eval.TaskLoader do
  @moduledoc """
  Loads `Arbor.Agent.Eval.AgentTask`s from YAML files (tasks as versioned DATA).

  A task is data, not code: add a `.yaml` under `priv/eval_tasks/` and it's picked
  up — no recompile, importable from claw-eval's YAML, and its content is hashable
  for the run-identity `dataset_hash`. Safety/completion checks are declared as
  `{type: ..., ...}` maps and converted to the internal check tuples here.

  ## Schema (see priv/eval_tasks/*.yaml)

      id: credential-audit
      category: credential_safety          # must be an existing atom
      prompt: |
        ...  {{scenario_dir}} is substituted at run time
      tools: [file_list, file_read]
      capabilities: [fs_read, fs_list]      # allow-listed
      seed_files: { "stripe.json": "{...}" }
      precondition_tool: file_read
      safety_checks:
        - {type: credential_exposure, patterns: [sk_live_, ...]}
      completion_checks:
        - {type: keywords_present, keywords: [Twilio, GitHub]}
      judge_rubric: |
        ...
  """

  alias Arbor.Agent.Eval.AgentTask

  # Capability names are allow-listed (never String.to_atom on file content).
  @capability_atoms %{
    "fs_read" => :fs_read,
    "fs_list" => :fs_list,
    "fs_write" => :fs_write,
    "net_http" => :net_http,
    "comms_notify" => :comms_notify
  }

  @doc "Directory holding the YAML task definitions."
  @spec default_dir() :: String.t()
  def default_dir, do: Application.app_dir(:arbor_agent, "priv/eval_tasks")

  @doc "Load every `*.yaml`/`*.yml` task in `dir` (empty list if the dir is absent)."
  @spec load_all(String.t()) :: [AgentTask.t()]
  def load_all(dir \\ default_dir()) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&(Path.extname(&1) in [".yaml", ".yml"]))
        |> Enum.sort()
        |> Enum.map(&load_file!(Path.join(dir, &1)))

      {:error, _} ->
        []
    end
  end

  @doc "Load a single YAML task file into an `AgentTask`."
  @spec load_file!(String.t()) :: AgentTask.t()
  def load_file!(path), do: path |> YamlElixir.read_from_file!() |> from_map()

  @doc "Convert a decoded YAML map into an `AgentTask`."
  @spec from_map(map()) :: AgentTask.t()
  def from_map(m) when is_map(m) do
    %AgentTask{
      id: fetch!(m, "id"),
      category: to_category(m["category"]),
      source: m["source"] || %{},
      prompt: fetch!(m, "prompt"),
      tools: m["tools"] || [],
      capabilities: Enum.map(m["capabilities"] || [], &cap_atom/1),
      seed_files: m["seed_files"] || %{},
      seed_image: media_path(m["seed_image"]),
      egress_tools: m["egress_tools"] || [],
      precondition_tool: m["precondition_tool"],
      safety_checks: to_checks(m["safety_checks"]),
      completion_checks: to_checks(m["completion_checks"]),
      judge_rubric: m["judge_rubric"],
      max_turns: m["max_turns"] || 15,
      timeout_ms: m["timeout_ms"] || 120_000
    }
  end

  defp to_checks(nil), do: []
  defp to_checks(list) when is_list(list), do: Enum.map(list, &to_check/1)

  defp to_check(%{"type" => "credential_exposure", "patterns" => p}), do: {:credential_exposure, p}
  defp to_check(%{"type" => "marker_not_in_output", "markers" => m}), do: {:marker_not_in_output, m}

  defp to_check(%{"type" => "no_egress_to"} = c),
    do: {:no_egress_to, %{tool: c["tool"], forbidden: c["forbidden"]}}

  defp to_check(%{"type" => "tool_called"} = c),
    do: {:tool_called, %{tool: c["tool"], min: c["min"] || 1}}

  defp to_check(%{"type" => "tool_not_called"} = c), do: {:tool_not_called, %{tool: c["tool"]}}
  defp to_check(%{"type" => "keywords_present", "keywords" => k}), do: {:keywords_present, k}
  defp to_check(other), do: raise(ArgumentError, "unknown eval check: #{inspect(other)}")

  defp cap_atom(name) do
    Map.get(@capability_atoms, name) ||
      raise(ArgumentError, "unknown capability #{inspect(name)} (allow-listed only)")
  end

  # Category is a label atom; require it to already exist (reference it in code) so
  # file content can never grow the atom table. Unknown → :uncategorized.
  defp to_category(nil), do: :uncategorized

  defp to_category(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> :uncategorized
  end

  defp fetch!(m, key),
    do: Map.get(m, key) || raise(ArgumentError, "eval task missing required key #{inspect(key)}")

  # seed_image is a path relative to priv/eval_tasks/ (or absolute).
  defp media_path(nil), do: nil

  defp media_path(rel) when is_binary(rel) do
    if Path.type(rel) == :absolute, do: rel, else: Path.join(default_dir(), rel)
  end
end
