defmodule Arbor.Security.McpServerPackagePolicy do
  @moduledoc """
  Pure: pin, denylist, and deprecation decisions for agent-bound MCP
  package-runner commands (npx / uvx / bunx / pnpm dlx).

  `Arbor.Security.McpServerApprovalCore` fingerprints the command as-is, so an
  unpinned `npx @scope/pkg` approval would cover whatever npm serves at spawn
  time. This policy refuses that class of spec before the operator grant.
  Archived `@modelcontextprotocol/server-*` reference servers are refused even
  when pinned. Optional `npm view` deprecation is applied from an already
  fetched status — the core never talks to the network.
  """

  @exact_version ~r/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.]+)?$/

  @archived %{
    "@modelcontextprotocol/server-github" => "ghcr.io/github/github-mcp-server",
    "@modelcontextprotocol/server-gdrive" => nil,
    "@modelcontextprotocol/server-postgres" => nil,
    "@modelcontextprotocol/server-puppeteer" => nil,
    "@modelcontextprotocol/server-brave-search" => "@brave/brave-search-mcp-server",
    "@modelcontextprotocol/server-slack" => "https://github.com/zencoderai/slack-mcp-server",
    "@modelcontextprotocol/server-sqlite" => nil,
    "@modelcontextprotocol/server-redis" => nil,
    "@modelcontextprotocol/server-gitlab" => nil,
    "@modelcontextprotocol/server-google-maps" => nil,
    "@modelcontextprotocol/server-sentry" => nil,
    "@modelcontextprotocol/server-everart" => nil,
    "@modelcontextprotocol/server-aws-kb-retrieval" => nil
  }

  @npx_value_flags MapSet.new(~w(--package -p --prefix --node-options --shell))
  @npx_package_flags MapSet.new(~w(--package -p))
  @uvx_value_flags MapSet.new(
                     ~w(--from --python -p --with --index --with-requirements --with-editable)
                   )
  @uvx_package_flags MapSet.new(~w(--from))
  @bunx_value_flags MapSet.new(~w(--package -p --cwd))
  @bunx_package_flags MapSet.new(~w(--package -p))
  @pnpm_value_flags MapSet.new(~w(--package -p --allow-build))
  @pnpm_package_flags MapSet.new(~w(--package -p))
  @skip_flags MapSet.new(~w(
    -y --yes --no-install --quiet -q --prefer-offline --offline --no
    --ignore-existing --no-cache --refresh --isolated
  ))

  @type inspect_result ::
          :not_package_runner
          | {:local, String.t()}
          | {:package, String.t() | nil, String.t() | nil}

  @doc """
  Classify the command in an MCP server config.

  Returns `:not_package_runner` for docker/http/local binaries, `{:local, path}`
  for `./` / `/` / `file:` specs, or `{:package, name, version}` when an
  npx/uvx/bunx/pnpm-dlx package spec is present (`version` is nil when unpinned).
  """
  @spec inspect_command(map()) :: inspect_result()
  def inspect_command(config) when is_map(config) do
    config
    |> fetch(:command)
    |> tokens()
    |> classify()
  end

  def inspect_command(_config), do: :not_package_runner

  @doc """
  Admit or refuse a classified package-runner command.

  `opts`:
  - `:deprecation_mode` — `:off` | `:warn` | `:reject` (default `:off`)
  - `:deprecation_status` — `:unchecked` | `:ok` | `:unavailable` |
    `{:deprecated, message}`
  """
  @spec admit(inspect_result(), keyword()) ::
          :ok | {:warn, String.t()} | {:error, {atom(), String.t()}}
  def admit(inspected, opts \\ [])

  def admit(:not_package_runner, _opts), do: :ok
  def admit({:local, _path}, _opts), do: :ok

  def admit({:package, name, version}, opts) do
    with :ok <- admit_pin(name, version),
         :ok <- admit_denylist(name) do
      apply_deprecation(name, version, opts)
    end
  end

  @doc "The archived `@modelcontextprotocol` reference-server denylist."
  @spec archived_packages() :: %{String.t() => String.t() | nil}
  def archived_packages, do: @archived

  defp fetch(config, field) do
    case Map.fetch(config, field) do
      {:ok, value} -> value
      :error -> Map.get(config, Atom.to_string(field))
    end
  end

  defp tokens(nil), do: []
  defp tokens(command) when is_binary(command), do: String.split(command)

  defp tokens(command) when is_list(command) do
    Enum.map(command, fn
      token when is_binary(token) -> token
      token when is_atom(token) -> Atom.to_string(token)
      other -> to_string(other)
    end)
  end

  defp tokens(_other), do: []

  defp classify(["cmd", "/c" | rest]), do: classify(rest)

  defp classify(["npx" | rest]),
    do: classify_spec(extract_package_spec(rest, @npx_value_flags, @npx_package_flags))

  defp classify(["uvx" | rest]),
    do: classify_spec(extract_package_spec(rest, @uvx_value_flags, @uvx_package_flags))

  defp classify(["bunx" | rest]),
    do: classify_spec(extract_package_spec(rest, @bunx_value_flags, @bunx_package_flags))

  defp classify(["pnpm", "dlx" | rest]),
    do: classify_spec(extract_package_spec(rest, @pnpm_value_flags, @pnpm_package_flags))

  defp classify(_tokens), do: :not_package_runner

  defp classify_spec(nil), do: {:package, nil, nil}

  defp classify_spec(spec) when is_binary(spec) do
    if local_spec?(spec) do
      {:local, spec}
    else
      {name, version} = split_name_version(spec)
      {:package, name, version}
    end
  end

  defp extract_package_spec(tokens, value_flags, package_flags) do
    case take_explicit_package(tokens, value_flags, package_flags) do
      {:ok, spec} -> spec
      :none -> first_positional(tokens, value_flags)
    end
  end

  defp take_explicit_package([token | rest], value_flags, package_flags) do
    cond do
      match = explicit_assignment(token) ->
        {:ok, match}

      MapSet.member?(package_flags, token) ->
        case rest do
          [spec | _] -> {:ok, spec}
          [] -> :none
        end

      MapSet.member?(value_flags, token) ->
        rest |> skip_flag_value() |> then(&take_explicit_package(&1, value_flags, package_flags))

      true ->
        take_explicit_package(rest, value_flags, package_flags)
    end
  end

  defp take_explicit_package([], _value_flags, _package_flags), do: :none

  defp explicit_assignment(token) do
    cond do
      String.starts_with?(token, "--package=") -> String.replace_prefix(token, "--package=", "")
      String.starts_with?(token, "--from=") -> String.replace_prefix(token, "--from=", "")
      String.starts_with?(token, "-p=") -> String.replace_prefix(token, "-p=", "")
      true -> nil
    end
  end

  defp first_positional([token | rest], value_flags) do
    cond do
      MapSet.member?(@skip_flags, token) ->
        first_positional(rest, value_flags)

      MapSet.member?(value_flags, token) ->
        rest |> skip_flag_value() |> then(&first_positional(&1, value_flags))

      String.starts_with?(token, "--") and String.contains?(token, "=") ->
        first_positional(rest, value_flags)

      String.starts_with?(token, "-") ->
        first_positional(rest, value_flags)

      true ->
        token
    end
  end

  defp first_positional([], _value_flags), do: nil

  defp skip_flag_value([_value | rest]), do: rest
  defp skip_flag_value([]), do: []

  defp local_spec?(spec) do
    String.starts_with?(spec, ["./", "../", "/", "file:", "~/", ".\\"])
  end

  defp split_name_version("@" <> rest) do
    case String.split(rest, "@", parts: 2) do
      [scoped] -> {"@" <> scoped, nil}
      [scoped, version] -> {"@" <> scoped, version}
    end
  end

  defp split_name_version(spec) do
    case String.split(spec, "@", parts: 2) do
      [name] -> {name, nil}
      [name, version] -> {name, version}
    end
  end

  defp admit_pin(nil, _version) do
    {:error, {:unpinned_mcp_package, unpinned_message("<missing package>")}}
  end

  defp admit_pin(name, nil) do
    {:error, {:unpinned_mcp_package, unpinned_message(name)}}
  end

  defp admit_pin(name, version) do
    if Regex.match?(@exact_version, version) do
      :ok
    else
      {:error, {:unpinned_mcp_package, unpinned_message("#{name}@#{version}")}}
    end
  end

  defp admit_denylist(name) do
    case Map.fetch(@archived, name) do
      :error ->
        :ok

      {:ok, replacement} ->
        {:error, {:archived_mcp_package, archived_message(name, replacement)}}
    end
  end

  defp apply_deprecation(name, version, opts) do
    mode = Keyword.get(opts, :deprecation_mode, :off)
    status = Keyword.get(opts, :deprecation_status, :unchecked)

    case {mode, status} do
      {:off, _} ->
        :ok

      {_, :unchecked} ->
        :ok

      {_, :ok} ->
        :ok

      {_, :unavailable} ->
        :ok

      {:warn, {:deprecated, npm_message}} ->
        {:warn, deprecated_message(name, version, npm_message)}

      {:reject, {:deprecated, npm_message}} ->
        {:error, {:deprecated_mcp_package, deprecated_message(name, version, npm_message)}}

      {_other, {:deprecated, npm_message}} ->
        {:warn, deprecated_message(name, version, npm_message)}
    end
  end

  defp unpinned_message(spec) do
    "MCP package runner commands (npx/uvx/bunx/pnpm dlx) must pin an exact " <>
      "x.y.z version (got #{spec}). Example: npx @scope/pkg@1.2.3"
  end

  defp archived_message(name, nil) do
    "#{name} is an archived MCP reference server. Choose a maintained replacement."
  end

  defp archived_message(name, replacement) do
    "#{name} is an archived MCP reference server. Use #{replacement} instead."
  end

  defp deprecated_message(name, version, npm_message) do
    "#{name}@#{version} is deprecated: #{npm_message}"
  end
end
