defmodule Arbor.Commands.CodingBenchmark.Git do
  @moduledoc false

  alias Arbor.Commands.ImmutableGitSource.Git

  @fixture_max_object_requests 10_002

  defdelegate deadline(timeout_ms), to: Git
  defdelegate run(workdir, args, timeout), to: Git
  defdelegate run(workdir, args, timeout, opts), to: Git
  defdelegate max_cat_file_batch_objects(), to: Git
  defdelegate parse_batch_check_output(output, requests), to: Git
  defdelegate bounded_diagnostic_output(output), to: Git
  defdelegate parse_batch_objects_output(output, specs), to: Git
  defdelegate partition_objects_for_batch(specs, max_output_bytes), to: Git
  defdelegate partition_requests_for_check(requests, shell_ceiling), to: Git
  defdelegate batch_object_wire_bytes(spec), to: Git

  @doc false
  @spec max_object_requests() :: pos_integer()
  def max_object_requests, do: @fixture_max_object_requests

  @doc false
  @spec normalize_object_requests(term()) :: {:ok, list()} | {:error, String.t()}
  def normalize_object_requests(requests) do
    cond do
      not is_list(requests) ->
        Git.normalize_object_requests(requests)

      over_fixture_request_limit?(requests) ->
        {:error, "git_object_request_limit"}

      true ->
        Git.normalize_object_requests(requests)
    end
  end

  @spec read_objects(String.t(), list(), term(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def read_objects(workdir, requests, timeout, opts \\ [])

  def read_objects(workdir, requests, timeout, opts) when is_list(requests) and is_list(opts) do
    if over_fixture_request_limit?(requests) do
      {:error, "git_object_request_limit"}
    else
      map_budget_error(
        Git.read_objects(workdir, requests, timeout, Keyword.put(opts, :compat_telemetry, true))
      )
    end
  end

  def read_objects(workdir, requests, timeout, opts),
    do: map_budget_error(Git.read_objects(workdir, requests, timeout, opts))

  defp map_budget_error({:error, "object_attestation_failed"}),
    do: {:error, "fixture_object_attestation_failed"}

  defp map_budget_error(other), do: other

  defp over_fixture_request_limit?(requests) when is_list(requests) do
    over_fixture_request_limit?(requests, 0)
  end

  defp over_fixture_request_limit?(_requests), do: false

  defp over_fixture_request_limit?([], _count), do: false

  defp over_fixture_request_limit?(_list, count) when count >= @fixture_max_object_requests,
    do: true

  defp over_fixture_request_limit?([_head | tail], count),
    do: over_fixture_request_limit?(tail, count + 1)
end
