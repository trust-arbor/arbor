defmodule Arbor.Commands.StartupFootprint do
  @moduledoc """
  Imperative shell for the K3B startup-footprint probe.

  Measures baseline, proposed-gated, and proposed-eager scenarios in
  separate OS-level BEAM instances controlled by OTP `:peer` over
  `standard_io`. Each peer invokes only the fixed Commands-owned probe
  MFA and returns the complete normalized measurement envelope.
  """

  alias Arbor.Commands.StartupFootprint.Core
  alias Arbor.Commands.StartupFootprint.PeerRunner
  alias Arbor.Common.SafePath

  @root_marker ["apps", "arbor_kernel", "mix.exs"]
  @default_policy_rel "apps/arbor_commands/priv/packaging/startup_footprint_policy.v1.json"

  @production_opt_keys [:mode, :json, :root, :policy]

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) when is_list(opts) do
    case Keyword.keys(opts) -- @production_opt_keys do
      [] -> do_run(opts, allow_synthetic: false)
      unexpected -> {:error, {:production_opts_forbid_synthetic, unexpected}}
    end
  end

  def run(_), do: {:error, :invalid_opts}

  @doc false
  @spec run_for_test(keyword()) :: {:ok, map()} | {:error, term()}
  def run_for_test(opts) when is_list(opts) do
    do_run(opts, allow_synthetic: true)
  end

  def run_for_test(_), do: {:error, :invalid_opts}

  @spec scenarios() :: [String.t()]
  def scenarios, do: Core.scenarios()

  defp do_run(opts, allow_synthetic: allow_synthetic) do
    mode = Keyword.get(opts, :mode, "report")
    json? = Keyword.get(opts, :json, false) == true
    output = if json?, do: "json", else: "human"

    with :ok <- admit_mode(mode),
         {:ok, root} <- resolve_root(Keyword.get(opts, :root)),
         {:ok, policy_path} <- resolve_policy_path(root, Keyword.get(opts, :policy)),
         {:ok, policy_raw} <- load_json_map(policy_path),
         {:ok, policy} <- Core.admit_policy(policy_raw),
         {:ok, samples} <- collect_samples(opts, allow_synthetic),
         {:ok, evidence} <-
           Core.admit_evidence(%{
             "schema" => Core.evidence_schema(),
             "version" => 1,
             "policy_version" => Core.policy_version(),
             "samples" => samples
           }),
         {:ok, compare} <- Core.compare(policy, evidence) do
      extras = %{
        "mode" => mode,
        "output" => output,
        "comparison" => compare
      }

      {:ok, Core.show(policy, evidence, extras)}
    end
  end

  defp collect_samples(opts, true = _allow_synthetic) do
    cond do
      is_map(Keyword.get(opts, :samples)) ->
        admit_injected_samples(Keyword.fetch!(opts, :samples))

      is_function(Keyword.get(opts, :run_peer), 1) ->
        run_injected_peers(Keyword.fetch!(opts, :run_peer))

      true ->
        {:error, :missing_synthetic_samples}
    end
  end

  defp collect_samples(_opts, false) do
    measure_production()
  end

  defp admit_injected_samples(samples) when is_map(samples) do
    Enum.reduce_while(Core.scenarios(), {:ok, %{}}, fn scenario, {:ok, acc} ->
      case Core.admit_normalized_sample(Map.get(samples, scenario)) do
        {:ok, sample} -> {:cont, {:ok, Map.put(acc, scenario, sample)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp run_injected_peers(fun) do
    Enum.reduce_while(Core.scenarios(), {:ok, %{}}, fn scenario, {:ok, acc} ->
      case fun.(scenario) do
        {:ok, raw} when is_map(raw) ->
          case normalize_peer_payload(raw) do
            {:ok, sample} -> {:cont, {:ok, Map.put(acc, scenario, sample)}}
            {:error, _} = err -> {:halt, err}
          end

        {:error, _} = err ->
          {:halt, err}

        other ->
          {:halt, {:error, {:invalid_peer_result, other}}}
      end
    end)
  end

  defp measure_production do
    case PeerRunner.measure_all() do
      {:ok, samples} when is_map(samples) ->
        Enum.reduce_while(Core.scenarios(), {:ok, %{}}, fn scenario, {:ok, acc} ->
          case admit_peer_sample(scenario, Map.get(samples, scenario)) do
            {:ok, sample} -> {:cont, {:ok, Map.put(acc, scenario, sample)}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      {:error, _} = err ->
        err
    end
  end

  defp admit_peer_sample(scenario, raw) do
    case normalize_peer_payload(raw) do
      {:ok, sample} ->
        if sample["scenario"] == scenario do
          {:ok, sample}
        else
          {:error, {:scenario_mismatch, scenario, sample["scenario"]}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp normalize_peer_payload(payload) do
    if Map.has_key?(payload, "process_count_delta") do
      Core.admit_normalized_sample(payload)
    else
      Core.normalize_sample(payload)
    end
  end

  defp resolve_root(nil), do: discover_root(File.cwd!())

  defp resolve_root(path) when is_binary(path) do
    case SafePath.validate(path) do
      :ok ->
        expanded = Path.expand(path)
        if packaging_root?(expanded), do: {:ok, expanded}, else: {:error, :invalid_root_marker}

      {:error, reason} ->
        {:error, {:root_path, reason}}
    end
  end

  defp discover_root(start) when is_binary(start), do: find_root(Path.expand(start))
  defp discover_root(_), do: {:error, :invalid_root}

  defp find_root(dir) do
    cond do
      packaging_root?(dir) -> {:ok, dir}
      Path.dirname(dir) == dir -> {:error, :umbrella_root_not_found}
      true -> find_root(Path.dirname(dir))
    end
  end

  defp packaging_root?(dir) when is_binary(dir),
    do: File.regular?(Path.join([dir | @root_marker]))

  defp packaging_root?(_), do: false

  defp resolve_policy_path(root, nil), do: SafePath.safe_join(root, @default_policy_rel)

  defp resolve_policy_path(root, path) when is_binary(path) do
    if String.starts_with?(path, "/") do
      if SafePath.within?(path, root), do: {:ok, Path.expand(path)}, else: {:error, :path_escape}
    else
      SafePath.safe_join(root, path)
    end
  end

  defp load_json_map(path) do
    cond do
      not File.regular?(path) ->
        {:error, {:policy_missing, path}}

      true ->
        case File.read(path) do
          {:ok, bytes} ->
            case Jason.decode(bytes) do
              {:ok, map} when is_map(map) -> {:ok, map}
              _ -> {:error, {:policy_invalid, path}}
            end

          {:error, reason} ->
            {:error, {:policy_read, path, reason}}
        end
    end
  end

  defp admit_mode(mode) when mode in ["report", "check"], do: :ok
  defp admit_mode(_), do: {:error, :invalid_mode}
end
