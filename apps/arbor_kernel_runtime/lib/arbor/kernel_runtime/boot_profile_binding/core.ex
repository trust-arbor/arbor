defmodule Arbor.KernelRuntime.BootProfileBinding.Core do
  @moduledoc """
  Pure construct core for the VM-lifetime boot-profile snapshot.

  `project/1` admits the Envelope.verify_boot_profile/3 success map.
  `identity_token/1` and `verifier_input/2` are closed data transforms.
  No Process, IO, Application, or time is consulted.
  """

  @schema "arbor.kernel_runtime.boot_profile_binding.v1"
  @version 1

  @verify_result_keys ["manifest", "manifest_sha256", "signer_id", "signer_key_id"]

  @snapshot_keys [
    "boot_epoch",
    "manifest_sha256",
    "payload_digests",
    "platform_key_id",
    "platform_public_key",
    "profile_id",
    "release_id",
    "revocation_input_id",
    "schema",
    "signer_id",
    "signer_key_id",
    "valid_from",
    "valid_until",
    "version"
  ]

  @identity_keys [
    "expected_payload_digests",
    "expected_profile_id",
    "expected_release_id",
    "expected_revocation_input_id",
    "manifest_bytes",
    "min_boot_epoch",
    "revoked_platform_key_ids",
    "revoked_signer_key_ids",
    "signature_bytes",
    "trusted_signers"
  ]

  @payload_digest_keys ["id", "sha256"]
  @max_list 32
  @max_id_bytes 128
  @max_digest_bytes 64
  @max_time_bytes 32
  @max_epoch 1_000_000_000

  @doc "Closed snapshot schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "Admit an Envelope success map and return the closed snapshot."
  @spec project(term()) :: {:ok, map()} | {:error, :invalid_verify_result}
  def project(result) when is_map(result) and not is_struct(result) do
    with :ok <- exact_keys(result, @verify_result_keys),
         manifest when is_map(manifest) and not is_struct(manifest) <- result["manifest"],
         snapshot <- snapshot_from(result, manifest),
         {:ok, snapshot} <- admit_snapshot(snapshot) do
      {:ok, snapshot}
    else
      _ -> {:error, :invalid_verify_result}
    end
  end

  def project(_), do: {:error, :invalid_verify_result}

  @doc "Admit a closed snapshot map or reject it as invalid."
  @spec admit_snapshot(term()) :: {:ok, map()} | {:error, :invalid_snapshot}
  def admit_snapshot(snapshot) when is_map(snapshot) and not is_struct(snapshot) do
    with :ok <- exact_keys(snapshot, @snapshot_keys),
         :ok <- exact(snapshot["schema"], @schema),
         :ok <- exact(snapshot["version"], @version),
         :ok <- bounded_string(snapshot["manifest_sha256"], @max_digest_bytes),
         :ok <- bounded_string(snapshot["release_id"], @max_id_bytes),
         :ok <- bounded_string(snapshot["profile_id"], @max_id_bytes),
         :ok <- bounded_epoch(snapshot["boot_epoch"]),
         :ok <- bounded_string(snapshot["platform_public_key"], @max_digest_bytes),
         :ok <- bounded_string(snapshot["platform_key_id"], @max_digest_bytes),
         :ok <- payload_digests(snapshot["payload_digests"]),
         :ok <- bounded_string(snapshot["revocation_input_id"], @max_id_bytes),
         :ok <- bounded_string(snapshot["valid_from"], @max_time_bytes),
         :ok <- bounded_string(snapshot["valid_until"], @max_time_bytes),
         :ok <- bounded_string(snapshot["signer_id"], @max_id_bytes),
         :ok <- bounded_string(snapshot["signer_key_id"], @max_digest_bytes) do
      {:ok, snapshot}
    else
      _ -> {:error, :invalid_snapshot}
    end
  end

  def admit_snapshot(_), do: {:error, :invalid_snapshot}

  @doc "SHA-256 identity token over stage-zero fields excluding clock."
  @spec identity_token(term()) :: {:ok, binary()} | {:error, :malformed_stage_zero}
  def identity_token(stage_zero) when is_map(stage_zero) and not is_struct(stage_zero) do
    with :ok <- exact_keys(stage_zero, @identity_keys) do
      tuple =
        {stage_zero["manifest_bytes"], stage_zero["signature_bytes"],
         stage_zero["trusted_signers"], stage_zero["expected_release_id"],
         stage_zero["expected_profile_id"], stage_zero["expected_revocation_input_id"],
         stage_zero["expected_payload_digests"], stage_zero["min_boot_epoch"],
         stage_zero["revoked_signer_key_ids"], stage_zero["revoked_platform_key_ids"]}

      {:ok, :crypto.hash(:sha256, :erlang.term_to_binary(tuple, [:deterministic]))}
    else
      _ -> {:error, :malformed_stage_zero}
    end
  end

  def identity_token(_), do: {:error, :malformed_stage_zero}

  @doc "True when two identity tokens are the same 32-byte digest."
  @spec same_identity?(term(), term()) :: boolean()
  def same_identity?(left, right)
      when is_binary(left) and is_binary(right) and byte_size(left) == 32 and
             byte_size(right) == 32 do
    left == right
  end

  def same_identity?(_, _), do: false

  @doc "Assemble the exact Envelope verifier map from admitted stage-zero plus now."
  @spec verifier_input(map(), String.t()) :: map()
  def verifier_input(stage_zero, now) when is_map(stage_zero) and is_binary(now) do
    %{
      "expected_payload_digests" => stage_zero["expected_payload_digests"],
      "expected_profile_id" => stage_zero["expected_profile_id"],
      "expected_release_id" => stage_zero["expected_release_id"],
      "expected_revocation_input_id" => stage_zero["expected_revocation_input_id"],
      "min_boot_epoch" => stage_zero["min_boot_epoch"],
      "now" => now,
      "revoked_platform_key_ids" => stage_zero["revoked_platform_key_ids"],
      "revoked_signer_key_ids" => stage_zero["revoked_signer_key_ids"],
      "trusted_signers" => stage_zero["trusted_signers"]
    }
  end

  defp snapshot_from(result, manifest) do
    %{
      "schema" => @schema,
      "version" => @version,
      "manifest_sha256" => result["manifest_sha256"],
      "release_id" => manifest["release_id"],
      "profile_id" => manifest["profile_id"],
      "boot_epoch" => manifest["boot_epoch"],
      "platform_public_key" => manifest["platform_public_key"],
      "platform_key_id" => manifest["platform_key_id"],
      "payload_digests" => manifest["payload_digests"],
      "revocation_input_id" => manifest["revocation_input_id"],
      "valid_from" => manifest["valid_from"],
      "valid_until" => manifest["valid_until"],
      "signer_id" => result["signer_id"],
      "signer_key_id" => result["signer_key_id"]
    }
  end

  defp payload_digests(list) do
    case take_proper_list(list, @max_list) do
      {:ok, []} ->
        :error

      {:ok, items} ->
        Enum.reduce_while(items, :ok, fn item, :ok ->
          case payload_digest(item) do
            :ok -> {:cont, :ok}
            :error -> {:halt, :error}
          end
        end)

      :error ->
        :error
    end
  end

  defp payload_digest(map) when is_map(map) and not is_struct(map) do
    with :ok <- exact_keys(map, @payload_digest_keys),
         :ok <- bounded_string(map["id"], @max_id_bytes) do
      bounded_string(map["sha256"], @max_digest_bytes)
    else
      _ -> :error
    end
  end

  defp payload_digest(_), do: :error

  defp bounded_epoch(value) when is_integer(value) and value >= 1 and value <= @max_epoch do
    :ok
  end

  defp bounded_epoch(_), do: :error

  defp bounded_string(value, max) when is_binary(value) and max > 0 do
    size = byte_size(value)

    if size >= 1 and size <= max do
      :ok
    else
      :error
    end
  end

  defp bounded_string(_, _), do: :error

  defp take_proper_list(list, max) when is_list(list) and is_integer(max) and max >= 0 do
    take_proper_list(list, max, 0, [])
  end

  defp take_proper_list(_, _), do: :error

  defp take_proper_list([], _max, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp take_proper_list([head | tail], max, count, acc) do
    if count >= max do
      :error
    else
      take_proper_list(tail, max, count + 1, [head | acc])
    end
  end

  defp take_proper_list(_, _, _, _), do: :error

  defp exact(value, value), do: :ok
  defp exact(_, _), do: :error

  defp exact_keys(map, keys) when is_map(map) and not is_struct(map) do
    actual = Map.keys(map)

    cond do
      Enum.any?(actual, &is_atom/1) and Enum.any?(actual, &is_binary/1) ->
        {:error, :mixed_keys}

      Enum.any?(actual, &(not is_binary(&1))) ->
        {:error, :non_string_keys}

      Enum.sort(actual) == Enum.sort(keys) ->
        :ok

      true ->
        {:error, :closed_keys}
    end
  end

  defp exact_keys(_, _), do: {:error, :invalid_map}
end
