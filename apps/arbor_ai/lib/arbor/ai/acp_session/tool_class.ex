defmodule Arbor.AI.AcpSession.ToolClass do
  @moduledoc """
  Pure classification of native ACP execution tools.

  Execution kind takes precedence over a non-execution display/name field.
  Opaque provider capabilities (`kiro`/`codex`) and subagent dispatch (`task`)
  cover execution too, so they must not confer weaker authority than shell.
  Command input must be structured; descriptive titles never supply it.
  """

  @shell_tools ~w(
    bash execute shell terminal run_terminal_cmd run_terminal_command
    exec_command run_shell_command shell_command local_shell commandexecution
    run_in_terminal terminal_exec kiro codex task write_stdin
  )

  @spec shell?(term(), map()) :: boolean()
  def shell?(name, call \\ %{}) do
    identities = [name | values(call, [:name, :toolName, :tool_name, :kind])]
    typed_ids = Enum.map(values(call, [:toolCallId]), &typed_tool_name/1)
    Enum.any?(identities ++ typed_ids, &shell_name?/1)
  end

  @doc "Remove shell pre-approvals after all caller and derived adapter options are merged."
  def require_shell_callbacks(client_opts) do
    case Keyword.get(client_opts, :adapter_opts) do
      opts when is_list(opts) ->
        opts =
          case Keyword.fetch(opts, :allowed_tools) do
            {:ok, tools} when is_list(tools) ->
              Keyword.put(opts, :allowed_tools, Enum.filter(tools, &preallow?/1))

            {:ok, _invalid} ->
              Keyword.delete(opts, :allowed_tools)

            :error ->
              opts
          end

        Keyword.put(client_opts, :adapter_opts, opts)

      _ ->
        client_opts
    end
  end

  @doc "Read one unambiguous command and execution directory from ACP rawInput."
  def shell_input(call, workspace_root) do
    with {:ok, input} when is_map(input) <- one_value(call, [:rawInput], nil),
         {:ok, command} <- one_value(input, [:command, :cmd], nil),
         true <- is_binary(command) and command != "",
         {:ok, cwd} <- one_value(input, [:cwd, :workdir], workspace_root),
         {:ok, env} <- one_value(input, [:env], %{}) do
      {:ok, command, [cwd: cwd, env: env]}
    else
      _ -> {:error, :unverifiable_acp_shell_input}
    end
  end

  defp shell_name?(name) when is_atom(name) and name not in [nil, true, false],
    do: shell_name?(Atom.to_string(name))

  defp shell_name?(name) when is_binary(name), do: String.downcase(name) in @shell_tools
  defp shell_name?(_), do: false

  defp preallow?(name) when is_binary(name) do
    # CLI allow rules support argument patterns and wildcards. A pattern must
    # never turn a removed exact shell pre-approval back into implicit authority.
    base = name |> String.split("(", parts: 2) |> hd()
    not shell_name?(base) and not String.contains?(name, ["*", "?"])
  end

  defp preallow?(_), do: false

  defp one_value(map, keys, default) do
    case values(map, keys) do
      [] -> {:ok, default}
      [value] -> {:ok, value}
      _ -> {:error, :ambiguous_acp_shell_input}
    end
  end

  defp values(map, keys) when is_map(map) do
    for key <- keys,
        form <- [key, Atom.to_string(key)],
        {:ok, value} <- [Map.fetch(map, form)],
        do: value
  end

  defp values(_map, _keys), do: []

  defp typed_tool_name(id) when is_binary(id) do
    case String.split(id, "__", parts: 2) do
      [name, _] -> name
      _ -> nil
    end
  end

  defp typed_tool_name(_id), do: nil
end
