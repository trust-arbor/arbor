defmodule Arbor.Actions.Coding.BranchAuditCheckpointCore do
  @moduledoc """
  Pure, closed schema for resumable historical branch-audit proof checkpoints.

  Checkpoints are observations only. They are never a source of mutation
  authority and their scope must match the current repository and proof policy
  before an entry can be used. Successful proof entries are unsigned progress
  hints that must be live-revalidated before classification; only exactly bound
  deterministic preserve entries may skip proof work.
  """

  alias Arbor.Actions.Coding.BranchAuditCore

  @format "arbor.coding.branch_audit_checkpoint"
  @version 1
  @policy_version "branch-proof-policy-v1"
  @max_bytes 32 * 1024 * 1024
  @max_entries 4096
  @max_string_bytes 256
  @sha1_or_sha256 ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/
  @safe_status_string ~r/\A[A-Za-z0-9_.:-]+\z/
  @failure_categories ~w(
    not_adopted range_too_large invalid_input git_storage_validation_failed git_command_failed
    git_storage_identity_changed invalid_git_storage_path invalid_git_storage_directory
    git_config_audit_failed unsafe_git_configuration invalid_git_output output_limit timeout
    unknown
  )

  @type json :: map() | list() | String.t() | number() | boolean() | nil

  @spec format() :: String.t()
  def format, do: @format

  @spec version() :: pos_integer()
  def version, do: @version

  @spec policy_version() :: String.t()
  def policy_version, do: @policy_version

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @spec empty(map(), map(), map()) :: map()
  def empty(repository, destination, limits)
      when is_map(repository) and is_map(destination) and is_map(limits) do
    %{
      "format" => @format,
      "version" => @version,
      "policy_version" => @policy_version,
      "repository" => repository,
      "destination" => destination,
      "entries" => []
    }
  end

  @spec scope_matches?(map(), map()) :: boolean()
  def scope_matches?(cache, expected_scope) when is_map(cache) and is_map(expected_scope) do
    Map.take(cache, ["policy_version", "repository", "destination"]) ==
      Map.take(expected_scope, ["policy_version", "repository", "destination"])
  end

  def scope_matches?(_cache, _expected_scope), do: false

  @spec scope(map()) :: map()
  def scope(cache) when is_map(cache),
    do: Map.take(cache, ["policy_version", "repository", "destination"])

  @spec upsert(map(), map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def upsert(cache, branch, status, result)
      when is_map(cache) and is_map(branch) and is_binary(status) and is_map(result) do
    entry =
      Map.merge(%{"ref" => branch["ref"], "oid" => branch["oid"], "status" => status}, result)

    with :ok <- validate(cache),
         :ok <- validate_entry(entry),
         entries <- Enum.reject(cache["entries"], &(&1["ref"] == branch["ref"])),
         next <- Map.put(cache, "entries", Enum.sort_by([entry | entries], & &1["ref"])),
         :ok <- validate(next) do
      {:ok, next}
    end
  end

  def upsert(_cache, _branch, _status, _result), do: {:error, :invalid_checkpoint_entry}

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(cache) when is_map(cache) and not is_struct(cache) do
    with :ok <- validate_json(cache),
         :ok <-
           exact_keys(cache, ~w(format version policy_version repository destination entries)),
         true <- cache["format"] == @format,
         true <- cache["version"] == @version,
         true <- cache["policy_version"] == @policy_version,
         :ok <- validate_repository(cache["repository"]),
         :ok <- validate_destination(cache["destination"]),
         :ok <- validate_entries(cache["entries"]) do
      :ok
    else
      false -> {:error, :invalid_branch_audit_checkpoint}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_branch_audit_checkpoint}
    end
  end

  def validate(_cache), do: {:error, :invalid_branch_audit_checkpoint}

  @spec encode(map()) :: {:ok, binary()} | {:error, term()}
  def encode(cache) when is_map(cache) do
    with :ok <- validate(cache),
         bytes <- BranchAuditCore.canonical_json(cache),
         true <- byte_size(bytes) <= @max_bytes do
      {:ok, bytes}
    else
      false -> {:error, :checkpoint_size_exceeded}
      {:error, _reason} = error -> error
    end
  end

  def encode(_cache), do: {:error, :invalid_branch_audit_checkpoint}

  @spec decode_json(binary()) :: {:ok, map()} | {:error, term()}
  def decode_json(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    case Jason.decode(bytes, objects: :ordered_objects) do
      {:ok, ordered} ->
        with {:ok, decoded} <- normalize_ordered_json(ordered),
             :ok <- validate(decoded) do
          {:ok, decoded}
        end

      {:error, _reason} ->
        {:error, :invalid_branch_audit_checkpoint_json}
    end
  end

  def decode_json(_bytes), do: {:error, :checkpoint_size_exceeded}

  @spec failure_valid?(map()) :: boolean()
  def failure_valid?(failure) when is_map(failure), do: validate_failure(failure) == :ok
  def failure_valid?(_failure), do: false

  defp validate_repository(repository) when is_map(repository) and not is_struct(repository) do
    with :ok <- exact_keys(repository, ~w(identity path)),
         true <- bounded_string?(repository["identity"], 1, 4096),
         true <- bounded_string?(repository["path"], 1, 4096) do
      :ok
    else
      false -> {:error, :invalid_checkpoint_repository}
      {:error, _reason} = error -> error
    end
  end

  defp validate_repository(_repository), do: {:error, :invalid_checkpoint_repository}

  defp validate_destination(destination)
       when is_map(destination) and not is_struct(destination) do
    with :ok <- exact_keys(destination, ~w(ref oid)),
         true <- valid_ref?(destination["ref"]),
         true <- valid_oid?(destination["oid"]) do
      :ok
    else
      false -> {:error, :invalid_checkpoint_destination}
      {:error, _reason} = error -> error
    end
  end

  defp validate_destination(_destination), do: {:error, :invalid_checkpoint_destination}

  defp validate_entries(entries) when is_list(entries) do
    with true <- length(entries) <= @max_entries,
         true <- Enum.all?(entries, &(is_map(&1) and not is_struct(&1))),
         true <- entries == Enum.sort_by(entries, &Map.get(&1, "ref", "")),
         true <-
           length(Enum.map(entries, &Map.get(&1, "ref"))) ==
             length(Enum.uniq_by(entries, &Map.get(&1, "ref"))),
         :ok <- validate_each(entries) do
      :ok
    else
      false -> {:error, :invalid_checkpoint_entries}
      {:error, _reason} = error -> error
    end
  end

  defp validate_entries(_entries), do: {:error, :invalid_checkpoint_entries}

  defp validate_each([]), do: :ok

  defp validate_each([entry | rest]) do
    with :ok <- validate_entry(entry), :ok <- validate_each(rest) do
      :ok
    end
  end

  defp validate_entry(%{
         "ref" => ref,
         "oid" => oid,
         "status" => "verified_proof",
         "proof" => proof
       }) do
    with true <- valid_ref?(ref),
         true <- valid_oid?(oid),
         true <- is_map(proof) and not is_struct(proof),
         :ok <- validate_json(proof),
         true <-
           exact_keys?(
             proof,
             ~w(method base_commit candidate_commit destination_ref destination_commit candidate_commit_count audit)
           ) do
      :ok
    else
      false -> {:error, :invalid_checkpoint_entry}
      {:error, _reason} = error -> error
    end
  end

  defp validate_entry(%{"ref" => ref, "oid" => oid, "status" => status, "failure" => failure})
       when status in ["deterministic_preserve", "transient_failure"] do
    with true <- valid_ref?(ref),
         true <- valid_oid?(oid),
         :ok <- validate_failure(failure),
         true <-
           (status == "deterministic_preserve" and
              failure["category"] in ["not_adopted", "range_too_large"] and
              failure["retryable"] == false) or
             (status == "transient_failure" and failure["retryable"] == true) do
      :ok
    else
      false -> {:error, :invalid_checkpoint_entry}
      {:error, _reason} = error -> error
    end
  end

  defp validate_entry(_entry), do: {:error, :invalid_checkpoint_entry}

  defp validate_failure(failure) when is_map(failure) and not is_struct(failure) do
    with :ok <- exact_keys(failure, ~w(category detail code retryable)),
         true <- failure["category"] in @failure_categories,
         true <- safe_string?(failure["detail"], 1, @max_string_bytes),
         true <- safe_string?(failure["code"], 1, @max_string_bytes),
         true <- is_boolean(failure["retryable"]) do
      :ok
    else
      false -> {:error, :invalid_checkpoint_failure}
      {:error, _reason} = error -> error
    end
  end

  defp validate_failure(_failure), do: {:error, :invalid_checkpoint_failure}

  defp valid_ref?("refs/heads/" <> branch) when branch != "" do
    Arbor.Actions.Git.validate_branch_name(branch) == :ok
  end

  defp valid_ref?(_ref), do: false

  defp valid_oid?(oid), do: is_binary(oid) and Regex.match?(@sha1_or_sha256, oid)

  defp bounded_string?(value, min, max),
    do: is_binary(value) and String.valid?(value) and byte_size(value) in min..max

  defp safe_string?(value, min, max),
    do: bounded_string?(value, min, max) and Regex.match?(@safe_status_string, value)

  defp exact_keys(map, keys) do
    if MapSet.new(Map.keys(map)) == MapSet.new(keys),
      do: :ok,
      else: {:error, :invalid_checkpoint_schema}
  end

  defp exact_keys?(map, keys), do: exact_keys(map, keys) == :ok

  defp validate_json(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      if is_binary(key) and String.valid?(key) do
        case validate_json(item) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      else
        {:halt, {:error, :non_string_checkpoint_key}}
      end
    end)
  end

  defp validate_json(value) when is_list(value),
    do:
      Enum.reduce_while(value, :ok, fn item, :ok ->
        case validate_json(item) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

  defp validate_json(value) when is_binary(value),
    do: if(String.valid?(value), do: :ok, else: {:error, :invalid_json_string})

  defp validate_json(value) when is_number(value) or is_boolean(value) or is_nil(value), do: :ok
  defp validate_json(_value), do: {:error, :non_json_checkpoint_value}

  defp normalize_ordered_json(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) != length(Enum.uniq(keys)) do
      {:error, :duplicate_checkpoint_key}
    else
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        with true <- is_binary(key), {:ok, normalized} <- normalize_ordered_json(value) do
          {:cont, {:ok, Map.put(acc, key, normalized)}}
        else
          false -> {:halt, {:error, :non_string_checkpoint_key}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp normalize_ordered_json(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_ordered_json(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_ordered_json(value), do: {:ok, value}
end
