defmodule Mix.Tasks.Arbor.Scheduler.SignCaps do
  @shortdoc "Sign a scheduler pipeline .caps.json file with an issuer key"

  @moduledoc """
  Sign a `.caps.json` file in-place using the issuer's Ed25519 private key.

  Phase 4 of the scheduler-privesc redesign. The operator writes a
  `.caps.json` file declaring the capabilities their pipeline needs (with
  `signature: ""` as a placeholder), then runs this task to produce a
  signed file the scheduler will accept at load time.

  ## Usage

      mix arbor.scheduler.sign_caps \\
        --key-file ~/.claude/arbor-personal/claude_cli_mbp.arbor.key \\
        apps/arbor_scheduler/priv/pipelines/upstream_deps_summary.caps.json

  ## Options

    * `--key-file <path>` (required) — `.arbor.key` file containing the
      issuer's Ed25519 private key. Same format used by `mix arbor.signer`
      and the External Agents registration flow.

  ## Behavior

  Reads the target file, validates the schema (version, issuer_id,
  capabilities present), computes the canonical signing payload via
  `Arbor.Scheduler.CapsFile.signing_payload/1`, signs with the provided
  key, and writes the file back with the `signature` field populated.

  ## Verification chain

  Signing this file does NOT enroll the issuer or check the envelope —
  those are runtime checks done by `CapsFile.load/1` against
  `Arbor.Security.IssuerRegistry`. The task verifies one thing only:
  that the agent_id in the `.arbor.key` matches the `issuer_id` declared
  in the caps file. Signing under a mismatched identity would produce a
  file that fails signature verification at load time.

  ## Idempotency

  Re-running the task on an already-signed file overwrites the
  `signature` field with a fresh signature over the (potentially
  unchanged) payload. Useful when the capabilities list changes — edit
  the file, re-sign.
  """

  use Mix.Task

  alias Arbor.Scheduler.CapsFile
  alias Arbor.Security.Crypto
  alias Arbor.Security.KeyFile

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [key_file: :string],
        aliases: [k: :key_file]
      )

    with {:ok, caps_path} <- pick_positional(positional),
         {:ok, key_path} <- fetch_required(opts, :key_file),
         {:ok, key_material} <- load_key_file(key_path),
         {:ok, raw} <- read_json(caps_path),
         {:ok, parsed} <- normalize_for_signing(raw),
         :ok <- check_issuer_matches(parsed.issuer_id, key_material.agent_id),
         {:ok, signed_json} <- sign_and_serialize(parsed, key_material.private_key) do
      File.write!(caps_path, signed_json)
      Mix.shell().info("Signed #{caps_path}")
      Mix.shell().info("  issuer:   #{key_material.agent_id}")
      Mix.shell().info("  caps:     #{length(parsed.capabilities)}")
    else
      {:error, reason} -> abort(reason)
    end
  end

  defp pick_positional([path]) when is_binary(path), do: {:ok, path}
  defp pick_positional([]), do: {:error, :missing_caps_file_argument}
  defp pick_positional(_), do: {:error, :too_many_arguments}

  defp fetch_required(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_required_option, key}}
      v -> {:ok, v}
    end
  end

  defp load_key_file(path), do: KeyFile.read(path)

  defp read_json(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, {:caps_file_read_failed, reason}}
    end
  end

  defp normalize_for_signing(raw) do
    with {:ok, version} <- fetch_int(raw, "version"),
         {:ok, issuer_id} <- fetch_string(raw, "issuer_id"),
         {:ok, caps_raw} <- fetch_list(raw, "capabilities"),
         {:ok, capabilities} <- normalize_capabilities(caps_raw) do
      {:ok, %{version: version, issuer_id: issuer_id, capabilities: capabilities}}
    end
  end

  # Empty list is an explicit "this pipeline declares no caps" — valid;
  # matches CapsFile.load semantics. Shell-only pipelines use this form.
  defp normalize_capabilities([]), do: {:ok, []}

  defp normalize_capabilities(caps) do
    caps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, idx}, {:ok, acc} ->
      case normalize_capability(raw, idx) do
        {:ok, descriptor} -> {:cont, {:ok, [descriptor | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, ds} -> {:ok, Enum.reverse(ds)}
      err -> err
    end
  end

  defp normalize_capability(%{"resource_uri" => uri} = raw, _idx) when is_binary(uri) do
    constraints =
      case Map.get(raw, "constraints", %{}) do
        m when is_map(m) -> m
        _ -> %{}
      end

    {:ok, %{resource_uri: uri, constraints: constraints}}
  end

  defp normalize_capability(_, idx), do: {:error, {:capability_missing_resource_uri, idx}}

  defp fetch_int(map, key) do
    case Map.get(map, key) do
      v when is_integer(v) -> {:ok, v}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp fetch_list(map, key) do
    case Map.get(map, key) do
      v when is_list(v) -> {:ok, v}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp check_issuer_matches(file_issuer, key_issuer) when file_issuer == key_issuer, do: :ok

  defp check_issuer_matches(file_issuer, key_issuer) do
    {:error, {:issuer_mismatch, %{caps_file: file_issuer, key_file: key_issuer}}}
  end

  defp sign_and_serialize(parsed, private_key) do
    payload = CapsFile.signing_payload(parsed)
    signature = Crypto.sign(payload, private_key)

    json = %{
      "version" => parsed.version,
      "issuer_id" => parsed.issuer_id,
      "capabilities" =>
        Enum.map(parsed.capabilities, fn c ->
          %{"resource_uri" => c.resource_uri, "constraints" => c.constraints}
        end),
      "signature" => Base.encode64(signature)
    }

    {:ok, Jason.encode!(json, pretty: true) <> "\n"}
  end

  defp abort(reason) do
    Mix.shell().error("sign_caps failed: #{inspect(reason)}")
    exit({:shutdown, 1})
  end
end
