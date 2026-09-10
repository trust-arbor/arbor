defmodule Arbor.Scheduler.RoutineCatalog do
  @moduledoc false

  alias Arbor.Scheduler.{CapsFile, Config, PipelinePaths}
  alias Arbor.Scheduler.Cores.RoutineCore

  # This lane admits one source-reviewed program, not arbitrary signed DOT.
  @graph_hash "f4f85d816d26befcd5ab2140ed6bfcf443e19cb650d0fa91c9075918c8b6b605"
  @action_uri "arbor://action/reports/build_morning_digest"
  @lobby_uri "arbor://orchestrator/execute"
  @initial %{
    "reports_directory" => "reports",
    "topics" => ["upstream-deps", "upstream-deps-summary"]
  }

  def load("morning_digest") do
    with {:ok, paths} <- PipelinePaths.resolve_pipeline(Config.morning_digest_pipeline()),
         {:ok, attestation} <- CapsFile.load(paths.caps_path),
         true <-
           attestation.pipeline_root == paths.root_id and
             attestation.pipeline_path == paths.relative_path,
         @graph_hash <- attestation.graph_hash,
         {:ok, @graph_hash} <- PipelinePaths.hash_file(paths.path),
         true <- CapsFile.initial_args_match?(attestation.initial_args, @initial),
         {:ok, workdir} <- PipelinePaths.resolve_workdir(attestation.workdir),
         true <- workdir == attestation.workdir,
         true <-
           byte_size(workdir) <= 2048 and Regex.match?(~r/\A\/[A-Za-z0-9_\/.\-]+\z/, workdir),
         expected = resources(workdir),
         true <- exact_capabilities?(attestation.capabilities, expected) do
      {:ok,
       %{
         paths: paths,
         attestation: attestation,
         resources: expected,
         digest: RoutineCore.digest(CapsFile.signing_payload(attestation))
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :routine_manifest_mismatch}
    end
  end

  def load(_), do: {:error, :unknown_routine}

  def resources(workdir) do
    [
      @lobby_uri,
      @action_uri,
      file_uri(:read, Path.join(workdir, "reports/upstream-deps/**")),
      file_uri(:read, Path.join(workdir, "reports/upstream-deps-summary/**")),
      file_uri(:write, Path.join(workdir, "reports/morning-digest/**"))
    ]
  end

  def file_uri(operation, path) do
    if String.ends_with?(path, "/**") do
      file_uri(operation, String.trim_trailing(path, "/**")) <> "/**"
    else
      Arbor.Security.authorization_resource_uri("arbor://fs/#{operation}", file_path: path)
    end
  end

  def action_uri, do: @action_uri
  def lobby_uri, do: @lobby_uri

  defp exact_capabilities?(caps, expected) do
    # RunIdentity adds the lobby itself; a manifest may repeat that exact lobby.
    actual = Enum.map(caps, & &1.resource_uri)

    Enum.all?(caps, &(&1.constraints == %{})) and
      length(actual) == length(Enum.uniq(actual)) and
      Enum.sort(Enum.uniq([@lobby_uri | actual])) == Enum.sort(expected)
  end
end
