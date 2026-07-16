defmodule Arbor.Commands.CodingBenchmark.Materializer do
  @moduledoc """
  Deterministic owner that materializes a coding-benchmark catalog into
  standalone fixture repositories plus a validated harness manifest.

  Target evidence is written as a separate closed sidecar for a future trusted
  objective verifier. The generated manifest remains data-only and never selects
  executable modules or commands.
  """

  alias Arbor.Commands.CodingBenchmark
  alias Arbor.Commands.CodingBenchmark.{Catalog, Git}
  alias Arbor.Common.SafePath

  @target_evidence_schema "arbor.coding_benchmark.target_evidence.v1"
  @publication_schema "arbor.coding_benchmark.publication.v1"
  @broad_root_paths ["/", Path.expand("~")]
  @default_timeout_ms 300_000
  @max_timeout_ms 3_600_000
  @private_dir_mode 0o700
  @private_file_mode 0o600

  @type result :: %{
          output_path: String.t(),
          manifest_path: String.t(),
          publication_path: String.t(),
          target_evidence_path: String.t(),
          catalog_digest: String.t()
        }

  @doc """
  Materialize `catalog_path` into `output_path` under the trusted root.

  Options:

    * `:root` - trusted command root (defaults to current working directory)
    * `:source` - optional source Git repository path within the trusted root
    * `:timeout_ms` - per-fixture reconstruction timeout
  """
  @spec prepare(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, map()}
  def prepare(catalog_path, output_path, opts \\ [])

  def prepare(catalog_path, output_path, opts)
      when is_binary(catalog_path) and is_binary(output_path) and is_list(opts) do
    case do_prepare(catalog_path, output_path, opts) do
      {:ok, _result} = ok ->
        ok

      {:error, staging, error} ->
        case cleanup_staging(staging) do
          :ok -> {:error, error}
          {:error, reason} -> {:error, Map.put(error, "cleanup_error", cleanup_reason(reason))}
        end
    end
  end

  def prepare(_catalog_path, _output_path, _opts),
    do: materializer_error("arguments", "expected_paths")

  defp do_prepare(catalog_path, output_path, opts) do
    case prepare_context(catalog_path, output_path, opts) do
      {:ok, context} ->
        case materialize_all(context) do
          {:ok, result} ->
            {:ok, result}

          {:error, error} ->
            {:error, context.staging, error}
        end

      {:error, error} ->
        {:error, nil, error}
    end
  end

  defp prepare_context(catalog_path, output_path, opts) do
    with {:ok, root} <- trusted_root(opts),
         {:ok, catalog_real} <- existing_regular_file(catalog_path, root, "catalog"),
         {:ok, source} <- resolve_source(Keyword.get(opts, :source), root),
         {:ok, output} <- resolve_output_path(output_path, root),
         :ok <- refuse_existing(output),
         :ok <- disjoint_paths(output, catalog_real, source),
         {:ok, timeout_ms} <- timeout_ms(Keyword.get(opts, :timeout_ms, @default_timeout_ms)),
         {:ok, catalog} <- read_catalog(catalog_real),
         {:ok, catalog} <- Catalog.validate(catalog),
         catalog_digest = Catalog.digest(catalog),
         :ok <- verify_source_pins(source, catalog, timeout_ms),
         {:ok, staging} <- create_staging(output) do
      {:ok,
       %{
         catalog: catalog,
         catalog_digest: catalog_digest,
         output: output,
         source: source,
         staging: staging,
         timeout_ms: timeout_ms
       }}
    end
  end

  defp materialize_all(context) do
    %{
      catalog: catalog,
      catalog_digest: catalog_digest,
      output: output,
      source: source,
      staging: staging,
      timeout_ms: timeout_ms
    } = context

    staging_path = staging.path

    with {:ok, fixture_paths} <-
           materialize_fixtures(source, staging_path, catalog, timeout_ms),
         {:ok, manifest} <- build_manifest(catalog, fixture_paths),
         {:ok, normalized_manifest} <- CodingBenchmark.validate_manifest(manifest),
         target_evidence =
           build_target_evidence(catalog, catalog_digest, manifest, normalized_manifest),
         publication = build_publication(catalog_digest, manifest, target_evidence),
         :ok <- write_json(Path.join(staging_path, "target-evidence.json"), target_evidence),
         :ok <- write_json(Path.join(staging_path, "manifest.json"), manifest),
         :ok <- publish(staging, output, publication) do
      {:ok,
       %{
         catalog_digest: catalog_digest,
         manifest_path: Path.join(output, "manifest.json"),
         output_path: output,
         publication_path: Path.join(output, "publication.json"),
         target_evidence_path: Path.join(output, "target-evidence.json")
       }}
    end
  end

  defp trusted_root(opts) do
    path = Keyword.get(opts, :root) || File.cwd!()

    with :ok <- SafePath.validate(path),
         {:ok, root} <- SafePath.resolve_real(path),
         true <- File.dir?(root),
         :ok <- reject_broad_root(root) do
      {:ok, root}
    else
      {:error, %{} = error} -> {:error, error}
      _other -> materializer_error("root", "directory_not_found")
    end
  end

  defp reject_broad_root(root) do
    system_temp =
      case SafePath.resolve_real(System.tmp_dir!()) do
        {:ok, canonical} -> canonical
        _other -> Path.expand(System.tmp_dir!())
      end

    if root in @broad_root_paths or root == system_temp,
      do: materializer_error("root", "broad_trusted_root"),
      else: :ok
  end

  defp resolve_source(nil, root) do
    if git_work_tree?(root) do
      {:ok, root}
    else
      materializer_error("source", "unsafe_or_missing_repository")
    end
  end

  defp resolve_source(path, root) when is_binary(path) do
    with :ok <- safe_cli_path(path, "source"),
         {:ok, real} <- resolve_within_root(path, root, "source"),
         {:ok, %{type: :directory}} <- File.lstat(real),
         true <- git_work_tree?(real) do
      {:ok, real}
    else
      {:error, %{} = error} -> {:error, error}
      _other -> materializer_error("source", "unsafe_or_missing_repository")
    end
  end

  defp resolve_source(_path, _root), do: materializer_error("source", "expected_path")

  defp git_work_tree?(path) do
    case Git.run(path, ["rev-parse", "--is-inside-work-tree"], 5_000) do
      {:ok, output} -> String.trim(output) == "true"
      _other -> false
    end
  end

  defp resolve_output_path(path, root) when is_binary(path) do
    with :ok <- safe_cli_path(path, "output"),
         {:ok, lexical} <- candidate_path(path, root, "output"),
         parent = Path.dirname(lexical),
         {:ok, real_parent} <- SafePath.resolve_real(parent),
         {:ok, ^real_parent} <- SafePath.resolve_within(real_parent, root),
         output = Path.join(real_parent, Path.basename(lexical)),
         :ok <- reject_broad_output(output, root),
         :ok <- safe_output_leaf(output) do
      {:ok, output}
    else
      {:error, %{} = error} -> {:error, error}
      _other -> materializer_error("output", "unsafe_path")
    end
  end

  defp resolve_output_path(_path, _root), do: materializer_error("output", "expected_path")

  defp reject_broad_output(path, root) do
    if path == root do
      materializer_error("output", "would_replace_root")
    else
      :ok
    end
  end

  defp safe_output_leaf(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :directory}} -> :ok
      {:ok, _other} -> materializer_error("output", "non_directory_path")
      {:error, _reason} -> materializer_error("output", "unreadable_path")
    end
  end

  defp refuse_existing(output) do
    case File.lstat(output) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> materializer_error("output", "destination_exists")
    end
  end

  defp disjoint_paths(output, catalog_path, source) do
    source_git = Path.join(source, ".git")

    cond do
      path_within?(output, source_git) or output == source_git ->
        materializer_error("output", "overlaps_source_git")

      path_within?(catalog_path, output) or path_within?(output, catalog_path) ->
        materializer_error("output", "overlaps_catalog")

      true ->
        :ok
    end
  end

  defp path_within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp existing_regular_file(path, root, field) do
    with :ok <- safe_cli_path(path, field),
         {:ok, real} <- resolve_within_root(path, root, field),
         {:ok, %{type: :regular}} <- File.lstat(real) do
      {:ok, real}
    else
      {:error, %{} = error} -> {:error, error}
      _other -> materializer_error(field, "unsafe_or_missing_path")
    end
  end

  defp resolve_within_root(path, root, field) do
    with {:ok, candidate} <- candidate_path(path, root, field),
         {:ok, real} <- SafePath.resolve_real(candidate),
         {:ok, ^real} <- SafePath.resolve_within(real, root) do
      {:ok, real}
    else
      {:error, %{} = error} -> {:error, error}
      _other -> materializer_error(field, "unsafe_or_missing_path")
    end
  end

  defp candidate_path(path, root, _field) do
    candidate =
      if Path.type(path) == :absolute,
        do: Path.expand(path),
        else: Path.expand(path, root)

    {:ok, candidate}
  end

  defp safe_cli_path(path, field) do
    components = Path.split(path)

    cond do
      not String.valid?(path) or String.contains?(path, <<0>>) ->
        materializer_error(field, "invalid_path")

      path == "." ->
        :ok

      Enum.any?(components, &(&1 in [".", "..", ""])) ->
        materializer_error(field, "unsafe_path")

      true ->
        case SafePath.validate(path) do
          :ok -> :ok
          {:error, _reason} -> materializer_error(field, "unsafe_path")
        end
    end
  end

  defp timeout_ms(value) when is_integer(value) and value > 0 and value <= @max_timeout_ms,
    do: {:ok, value}

  defp timeout_ms(_value), do: materializer_error("timeout_ms", "out_of_bounds")

  defp read_catalog(path) do
    with {:ok, json} <- read_bounded_file(path, Catalog.max_bytes()),
         {:ok, catalog} <- Jason.decode(json) do
      {:ok, catalog}
    else
      {:error, :file_too_large} -> materializer_error("catalog", "file_too_large")
      {:error, %Jason.DecodeError{}} -> materializer_error("catalog", "invalid_json")
      {:error, _reason} -> materializer_error("catalog", "unreadable")
    end
  end

  defp read_bounded_file(path, maximum) do
    case File.open(path, [:read, :binary], fn io -> IO.binread(io, maximum + 1) end) do
      {:ok, data} when is_binary(data) and byte_size(data) <= maximum -> {:ok, data}
      {:ok, data} when is_binary(data) -> {:error, :file_too_large}
      {:ok, :eof} -> {:ok, ""}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_source_pins(source, catalog, timeout_ms) do
    Enum.reduce_while(catalog["fixtures"], :ok, fn fixture, :ok ->
      case verify_fixture_pins(source, fixture, Git.deadline(timeout_ms)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp verify_fixture_pins(source, fixture, timeout_ms) do
    with :ok <-
           verify_commit_tree(
             source,
             fixture["base_commit_oid"],
             fixture["base_tree_oid"],
             fixture["fixture_id"],
             "base",
             timeout_ms
           ),
         :ok <-
           verify_commit_tree(
             source,
             fixture["target_commit_oid"],
             fixture["target_tree_oid"],
             fixture["fixture_id"],
             "target",
             timeout_ms
           ),
         :ok <- verify_direct_transition(source, fixture, timeout_ms) do
      :ok
    end
  end

  defp verify_direct_transition(source, fixture, timeout_ms) do
    target = fixture["target_commit_oid"]
    expected_parent = fixture["base_commit_oid"]

    case git_output(source, ["rev-parse", "--verify", "#{target}^1^{commit}"], timeout_ms) do
      {:ok, ^expected_parent} ->
        :ok

      {:ok, _other_parent} ->
        materializer_error(
          "fixtures.#{fixture["fixture_id"]}.target",
          "target_not_direct_child_of_base"
        )

      {:error, reason} when is_binary(reason) ->
        materializer_error("fixtures.#{fixture["fixture_id"]}.target", reason)
    end
  end

  defp verify_commit_tree(source, commit_oid, tree_oid, fixture_id, role, timeout_ms) do
    with {:ok, actual_commit} <-
           git_output(source, ["rev-parse", "--verify", "#{commit_oid}^{commit}"], timeout_ms),
         true <- String.downcase(actual_commit) == commit_oid,
         {:ok, actual_tree} <-
           git_output(source, ["rev-parse", "--verify", "#{commit_oid}^{tree}"], timeout_ms),
         true <- String.downcase(actual_tree) == tree_oid do
      :ok
    else
      false ->
        materializer_error(
          "fixtures.#{fixture_id}.#{role}",
          "pinned_oid_mismatch"
        )

      {:error, reason} when is_binary(reason) ->
        materializer_error("fixtures.#{fixture_id}.#{role}", reason)

      _other ->
        materializer_error("fixtures.#{fixture_id}.#{role}", "commit_not_found")
    end
  end

  defp create_staging(output) do
    fixtures = Path.join(output, "fixtures")

    case Arbor.Shell.create_private_owned_tree(output) do
      {:ok, identity} ->
        case create_private_subdirectory(fixtures) do
          :ok ->
            {:ok, %{identity: identity, path: output}}

          {:error, reason} ->
            cleanup_failed_staging_create(identity, reason)
        end

      {:error, {:owned_tree_cleanup_retained, _reason, _evidence}} ->
        materializer_error("staging", "create_cleanup_retained")

      {:error, :root_exists} ->
        materializer_error("output", "destination_exists")

      {:error, reason} ->
        materializer_error("staging", "create_failed:#{cleanup_reason(reason)}")
    end
  end

  defp create_private_subdirectory(path) do
    with :ok <- File.mkdir(path),
         :ok <- File.chmod(path, @private_dir_mode) do
      :ok
    end
  end

  defp cleanup_failed_staging_create(identity, reason) do
    case Arbor.Shell.remove_owned_tree(identity, cleanup_opts()) do
      :ok ->
        materializer_error("staging", "create_failed:#{cleanup_reason(reason)}")

      {:error, cleanup_error} ->
        {:error,
         %{
           "error" => "invalid_coding_benchmark_prepare",
           "field" => "staging",
           "reason" => "create_cleanup_retained",
           "cleanup_error" => cleanup_reason(cleanup_error)
         }}
    end
  end

  defp materialize_fixtures(source, staging_path, catalog, timeout_ms) do
    Enum.reduce_while(catalog["fixtures"], {:ok, %{}}, fn fixture, {:ok, acc} ->
      fixture_id = fixture["fixture_id"]
      relative = Path.join("fixtures", fixture_id)
      destination = Path.join(staging_path, relative)

      case CodingBenchmark.reconstruct_fixture_repository(
             source,
             destination,
             fixture["base_commit_oid"],
             fixture["base_tree_oid"],
             timeout_ms: timeout_ms
           ) do
        :ok ->
          case File.chmod(destination, @private_dir_mode) do
            :ok ->
              {:cont, {:ok, Map.put(acc, fixture_id, relative)}}

            {:error, reason} ->
              {:halt, materializer_error("fixtures.#{fixture_id}", "chmod_failed:#{reason}")}
          end

        {:error, reason} ->
          {:halt, materializer_error("fixtures.#{fixture_id}", reason)}
      end
    end)
  end

  defp build_manifest(catalog, fixture_paths) do
    fixtures =
      Enum.map(catalog["fixtures"], fn fixture ->
        %{
          "base_tree_oid" => fixture["base_tree_oid"],
          "fixture_id" => fixture["fixture_id"],
          "fixture_path" => Map.fetch!(fixture_paths, fixture["fixture_id"]),
          "input" => fixture["input"],
          "verifier_id" => fixture["verifier_id"]
        }
      end)

    {:ok,
     %{
       "fixtures" => fixtures,
       "schema" => CodingBenchmark.manifest_schema(),
       "seed" => catalog["seed"]
     }}
  end

  defp build_target_evidence(catalog, catalog_digest, manifest, normalized_manifest) do
    input_hashes =
      Map.new(normalized_manifest["fixtures"], fn fixture ->
        {fixture["fixture_id"], fixture["normalized_input_hash"]}
      end)

    fixtures =
      catalog["fixtures"]
      |> Enum.map(fn fixture ->
        {fixture["fixture_id"],
         %{
           "base_commit_oid" => fixture["base_commit_oid"],
           "base_tree_oid" => fixture["base_tree_oid"],
           "normalized_input_hash" => Map.fetch!(input_hashes, fixture["fixture_id"]),
           "target_commit_oid" => fixture["target_commit_oid"],
           "target_tree_oid" => fixture["target_tree_oid"]
         }}
      end)
      |> Map.new()

    %{
      "catalog_digest" => catalog_digest,
      "fixtures" => fixtures,
      "manifest_digest" => Catalog.canonical_digest(manifest),
      "schema" => @target_evidence_schema,
      "source_repository_label" => catalog["source_repository_label"]
    }
  end

  defp build_publication(catalog_digest, manifest, target_evidence) do
    %{
      "catalog_digest" => catalog_digest,
      "manifest_digest" => Catalog.canonical_digest(manifest),
      "schema" => @publication_schema,
      "target_evidence_digest" => Catalog.canonical_digest(target_evidence)
    }
  end

  defp write_json(path, value) do
    encoded = [Catalog.canonical_encode(value), "\n"]

    case File.open(path, [:write, :binary, :exclusive], fn io -> IO.binwrite(io, encoded) end) do
      {:ok, :ok} ->
        case File.chmod(path, @private_file_mode) do
          :ok -> :ok
          {:error, reason} -> materializer_error("output", "chmod_failed:#{reason}")
        end

      {:ok, {:error, reason}} ->
        materializer_error("output", "write_failed:#{reason}")

      {:error, reason} ->
        materializer_error("output", "write_failed:#{reason}")
    end
  rescue
    exception -> materializer_error("output", "encode_failed:#{Exception.message(exception)}")
  end

  defp publish(%{identity: identity, path: output}, output, publication) do
    encoded = Catalog.canonical_encode(publication) <> "\n"

    temporary =
      Path.join(
        output,
        ".publication-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}.tmp"
      )

    final = Path.join(output, "publication.json")

    with :ok <- verify_output_identity(output, identity),
         :ok <- write_json(temporary, publication),
         :ok <- verify_private_marker(temporary, encoded),
         :ok <- verify_output_identity(output, identity) do
      publish_marker(temporary, final)
    end
  end

  defp verify_private_marker(path, expected) do
    with {:ok, %{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == @private_file_mode,
         {:ok, ^expected} <- read_bounded_file(path, byte_size(expected)) do
      :ok
    else
      _other -> materializer_error("output", "publication_marker_verification_failed")
    end
  end

  defp publish_marker(temporary, final) do
    case File.ln(temporary, final) do
      :ok ->
        _ = File.rm(temporary)
        :ok

      {:error, reason} ->
        materializer_error("output", "publication_marker_failed:#{reason}")
    end
  end

  defp verify_output_identity(output, identity) do
    case File.lstat(output, time: :posix) do
      {:ok,
       %File.Stat{
         type: :directory,
         major_device: device,
         minor_device: minor_device,
         inode: inode,
         mode: mode
       }}
      when device == identity.device and minor_device == identity.minor_device and
             inode == identity.inode ->
        if Bitwise.band(mode, 0o777) == @private_dir_mode,
          do: :ok,
          else: materializer_error("output", "publish_mode_mismatch")

      _other ->
        materializer_error("output", "publish_identity_mismatch")
    end
  end

  defp cleanup_staging(%{identity: identity}),
    do: Arbor.Shell.remove_owned_tree(identity, cleanup_opts())

  defp cleanup_staging(_staging), do: :ok

  defp cleanup_opts, do: [max_entries: 1_000_000, timeout_ms: 10_000]

  defp cleanup_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp cleanup_reason(reason) do
    reason
    |> inspect(limit: 10, printable_limit: 200)
    |> String.slice(0, 200)
  end

  defp git_output(workdir, args, timeout_ms) do
    case Git.run(workdir, args, timeout_ms) do
      {:ok, output} -> {:ok, String.trim(output)}
      error -> error
    end
  end

  defp materializer_error(field, reason) do
    {:error,
     %{
       "error" => "invalid_coding_benchmark_prepare",
       "field" => field,
       "reason" => reason
     }}
  end
end
