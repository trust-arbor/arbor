defmodule Mix.Tasks.Arbor.Scheduler.SignCaps do
  @shortdoc "Sign an exact scheduler pipeline execution attestation"

  @moduledoc """
  Build and sign a version 2 scheduler pipeline attestation in-place.

  The target file supplies only the issuer and capability declaration. This
  task resolves the exact sibling DOT under a configured pipeline root,
  computes its SHA-256, canonicalizes the workdir, parses exact JSON initial
  arguments, and signs all of those fields together.

  ## Usage and version 1 migration

      ./bin/mix arbor.scheduler.sign_caps \
        --key-file ~/.claude/arbor-personal/claude_cli_mbp.arbor.key \
        --workdir "$(pwd -P)" \
        --args-json '{}' \
        apps/arbor_scheduler/priv/pipelines/upstream_deps_summary.caps.json

  The sibling DOT path is inferred by replacing `.caps.json` with `.dot`.
  Use `--pipeline` only when making that relationship explicit. A version 1
  file may be used as migration input, but scheduler execution rejects it until
  this task rewrites it with a signature from the matching private key.

  ## Required options

    * `--key-file` - issuer `.arbor.key` file
    * `--workdir` - fixed existing execution directory
    * `--args-json` - exact initial argument object, including `{}`

  Signing does not enroll the issuer or widen its envelope. Runtime verification
  still checks the signature, issuer status, and every declared capability
  against `Arbor.Security.IssuerRegistry`.
  """

  use Mix.Task

  alias Arbor.Scheduler.{CapsFile, PipelinePaths}
  alias Arbor.Security.Crypto
  alias Arbor.Security.KeyFile

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [key_file: :string, pipeline: :string, workdir: :string, args_json: :string],
        aliases: [k: :key_file, p: :pipeline, w: :workdir]
      )

    with {:ok, caps_path} <- pick_positional(positional),
         {:ok, key_path} <- fetch_required(opts, :key_file),
         {:ok, workdir_input} <- fetch_required(opts, :workdir),
         {:ok, args_json} <- fetch_required(opts, :args_json),
         {:ok, pipeline_path} <- pipeline_path(opts, caps_path),
         {:ok, paths} <- PipelinePaths.resolve_pipeline(pipeline_path),
         :ok <- PipelinePaths.verify_caps_target(caps_path, paths),
         {:ok, workdir} <- PipelinePaths.resolve_workdir(workdir_input),
         {:ok, initial_args} <- parse_initial_args(args_json),
         {:ok, key_material} <- KeyFile.read(key_path),
         {:ok, raw} <- read_json(caps_path),
         {:ok, declaration} <- normalize_declaration(raw),
         :ok <- check_issuer_matches(declaration.issuer_id, key_material.agent_id),
         {:ok, graph_hash} <- PipelinePaths.hash_file(paths.path),
         {:ok, payload} <-
           CapsFile.build(declaration.issuer_id, declaration.capabilities,
             pipeline_root: paths.root_id,
             pipeline_path: paths.relative_path,
             graph_hash: graph_hash,
             workdir: workdir,
             initial_args: initial_args
           ),
         {:ok, signed_json} <- sign_and_serialize(payload, key_material.private_key),
         :ok <- atomic_write(caps_path, signed_json) do
      Mix.shell().info("Signed #{caps_path}")
      Mix.shell().info("  version:  2")
      Mix.shell().info("  issuer:   #{payload.issuer_id}")
      Mix.shell().info("  pipeline: #{payload.pipeline_root}:#{payload.pipeline_path}")
      Mix.shell().info("  sha256:   #{payload.graph_hash}")
      Mix.shell().info("  workdir:  #{payload.workdir}")
      Mix.shell().info("  args:     #{Jason.encode!(payload.initial_args)}")
      Mix.shell().info("  caps:     #{length(payload.capabilities)}")
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
      value -> {:ok, value}
    end
  end

  defp pipeline_path(opts, caps_path) do
    case Keyword.get(opts, :pipeline) do
      path when is_binary(path) ->
        {:ok, path}

      nil ->
        if String.ends_with?(caps_path, ".caps.json") do
          {:ok, String.replace_suffix(caps_path, ".caps.json", ".dot")}
        else
          {:error, :caps_file_must_end_in_caps_json}
        end
    end
  end

  defp parse_initial_args(json) do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, :args_json_must_be_an_object}
      {:error, reason} -> {:error, {:invalid_args_json, reason}}
    end
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, {:invalid_caps_json, reason}}
        end

      {:error, reason} ->
        {:error, {:caps_file_read_failed, reason}}
    end
  end

  defp normalize_declaration(raw) when is_map(raw) do
    with {:ok, version} <- fetch_int(raw, "version"),
         :ok <- migratable_version(version),
         {:ok, issuer_id} <- fetch_string(raw, "issuer_id"),
         {:ok, capabilities} <- fetch_list(raw, "capabilities") do
      {:ok, %{issuer_id: issuer_id, capabilities: capabilities}}
    end
  end

  defp normalize_declaration(_), do: {:error, :caps_file_not_an_object}

  defp migratable_version(version) when version in [1, 2], do: :ok
  defp migratable_version(version), do: {:error, {:unsupported_version, version}}

  defp fetch_int(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp fetch_list(map, key) do
    case Map.get(map, key) do
      value when is_list(value) -> {:ok, value}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp check_issuer_matches(file_issuer, key_issuer) when file_issuer == key_issuer, do: :ok

  defp check_issuer_matches(file_issuer, key_issuer) do
    {:error, {:issuer_mismatch, %{caps_file: file_issuer, key_file: key_issuer}}}
  end

  defp sign_and_serialize(payload, private_key) do
    signature = payload |> CapsFile.signing_payload() |> Crypto.sign(private_key)

    json =
      payload
      |> CapsFile.manifest_map(signature)
      |> Jason.encode!(pretty: true)

    {:ok, json <> "\n"}
  end

  defp atomic_write(path, content) do
    temporary = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(temporary, content),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, {:caps_file_write_failed, reason}}
    end
  end

  defp abort(reason) do
    Mix.shell().error("sign_caps failed: #{inspect(reason)}")
    exit({:shutdown, 1})
  end
end
