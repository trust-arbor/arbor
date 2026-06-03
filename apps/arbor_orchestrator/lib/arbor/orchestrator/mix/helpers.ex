defmodule Arbor.Orchestrator.Mix.Helpers do
  @moduledoc "Shared CLI utilities for Mix tasks: color output, tables, prompts, progress."

  # Color output

  def info(msg), do: Mix.shell().info(msg)
  def success(msg), do: Mix.shell().info([:green, to_string(msg)])
  def warn(msg), do: Mix.shell().info([:yellow, to_string(msg)])
  def error(msg), do: Mix.shell().error([:red, to_string(msg)])

  # Table formatting

  @doc "Print a formatted table with headers and rows."
  def table(headers, rows) do
    all = [headers | rows]

    widths =
      Enum.reduce(all, List.duplicate(0, length(headers)), fn row, acc ->
        row
        |> Enum.map(&String.length(to_string(&1)))
        |> Enum.zip(acc)
        |> Enum.map(fn {a, b} -> max(a, b) end)
      end)

    separator = Enum.map_join(widths, "+", &String.duplicate("-", &1 + 2))
    info("+" <> separator <> "+")

    header_line =
      headers
      |> Enum.zip(widths)
      |> Enum.map_join("|", fn {h, w} -> " " <> String.pad_trailing(to_string(h), w) <> " " end)

    Mix.shell().info([:bright, "| " <> header_line <> "|"])
    info("+" <> separator <> "+")

    Enum.each(rows, fn row ->
      line =
        row
        |> Enum.zip(widths)
        |> Enum.map_join("|", fn {c, w} -> " " <> String.pad_trailing(to_string(c), w) <> " " end)

      info("| " <> line <> "|")
    end)

    info("+" <> separator <> "+")
  end

  # Application startup

  @doc """
  Start the orchestrator without the full umbrella app tree.

  Avoids port conflicts when the dev server is already running
  (e.g., gateway's :ranch listener). Only starts the orchestrator
  and its minimal deps (logger, jason).
  """
  def ensure_orchestrator_started do
    Mix.Task.run("compile")

    for app <- [:logger, :jason, :arbor_orchestrator] do
      Application.ensure_all_started(app)
    end
  end

  # Progress

  @doc "Show a spinner while running a function."
  def spinner(label, fun) do
    info("#{label}...")
    result = fun.()
    success("#{label}... done")
    result
  end

  # File operations

  @doc "Read and parse a DOT file, printing errors on failure."
  def parse_dot_file(path) do
    unless File.exists?(path) do
      error("File not found: #{path}")
      System.halt(1)
    end

    case File.read(path)
         |> then(fn
           {:ok, src} -> Arbor.Orchestrator.parse(src)
           err -> err
         end) do
      {:ok, graph} ->
        {:ok, graph}

      {:error, reason} ->
        error("Parse error: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Load the operator's identity key for signing CLI-initiated pipelines.

  Tries in order:
    1. The explicit `--identity-key <path>` opt
    2. The `ARBOR_KEY` environment variable
    3. `~/.arbor/identity.key`

  Returns a keyword list suitable for merging into engine run opts:
  `[signer: signer_fn, identity_private_key: <bytes>, agent_id: <id>]`.

  Halts with a clear error message when no key can be found OR the key
  file is malformed. This is intentional: as of the checkpoint HMAC
  migration (Option D), engine resume requires identity, so CLI tasks
  must surface key-loading failures up front rather than letting them
  produce confusing downstream errors.
  """
  @spec load_identity(keyword()) :: keyword()
  def load_identity(opts) do
    case resolve_key_path(opts) do
      nil ->
        error("""
        No Arbor identity key found. Pipeline operations require an identity
        for checkpoint integrity. Provide one via:

          --identity-key <path>   (CLI flag)
          ARBOR_KEY=<path>        (environment variable)
          ~/.arbor/identity.key   (default location)

        See docs/arbor/IDENTITY.md for how to generate a key file.
        """)

        System.halt(1)

      path ->
        load_identity_from(path)
    end
  end

  defp resolve_key_path(opts) do
    explicit = Keyword.get(opts, :identity_key)
    env_var = System.get_env("ARBOR_KEY")
    default = Path.expand("~/.arbor/identity.key")

    cond do
      is_binary(explicit) and File.exists?(explicit) -> explicit
      is_binary(env_var) and File.exists?(env_var) -> env_var
      File.exists?(default) -> default
      true -> nil
    end
  end

  defp load_identity_from(path) do
    # Runtime bridges — arbor_orchestrator is Standalone in the library
    # hierarchy (see CLAUDE.md), so we resolve Gateway + Contracts modules
    # at runtime instead of via static aliases.
    proxy_core = Module.concat([:Arbor, :Gateway, :Signer, :ProxyCore])
    signed_request = Module.concat([:Arbor, :Contracts, :Security, :SignedRequest])

    cond do
      not Code.ensure_loaded?(proxy_core) ->
        error(
          "Arbor.Gateway.Signer.ProxyCore not loaded — arbor_gateway must be " <>
            "available to parse identity keys."
        )

        System.halt(1)

      not Code.ensure_loaded?(signed_request) ->
        error(
          "Arbor.Contracts.Security.SignedRequest not loaded — arbor_contracts " <>
            "must be available to sign requests."
        )

        System.halt(1)

      true ->
        with {:ok, contents} <- File.read(path),
             {:ok, %{agent_id: agent_id, private_key: private_key}} <-
               proxy_core.parse_key_file(contents) do
          signer = fn resource ->
            signed_request.sign(resource, agent_id, private_key)
          end

          [
            signer: signer,
            identity_private_key: private_key,
            agent_id: agent_id
          ]
        else
          {:error, reason} ->
            error("Failed to load identity key at #{path}: #{inspect(reason)}")
            System.halt(1)
        end
    end
  end
end
