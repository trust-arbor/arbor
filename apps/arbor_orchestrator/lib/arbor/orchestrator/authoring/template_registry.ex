defmodule Arbor.Orchestrator.Authoring.TemplateRegistry do
  @moduledoc "Discovers and loads built-in pipeline templates from priv/templates/."

  @doc "List all available templates."
  @spec list() :: [%{name: String.t(), description: String.t(), path: String.t()}]
  def list do
    dir = template_dir()

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".dot"))
      |> Enum.sort()
      |> Enum.map(fn filename ->
        name = Path.rootname(filename)
        path = Path.join(dir, filename)
        description = extract_description(path)
        %{name: name, description: description, path: path}
      end)
    else
      []
    end
  end

  @doc "Load a template by name."
  @spec load(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def load(name) do
    path = Path.join(template_dir(), "#{name}.dot")

    if File.exists?(path) do
      {:ok, File.read!(path)}
    else
      {:error, :not_found}
    end
  end

  @doc "Return the template directory path."
  @spec template_dir() :: String.t()
  def template_dir do
    case :code.priv_dir(:arbor_orchestrator) do
      {:error, _} ->
        Path.join([File.cwd!(), "priv", "templates"])

      priv ->
        Path.join(to_string(priv), "templates")
    end
  end

  defp extract_description(path) do
    case File.read(path) do
      {:ok, content} ->
        cond do
          match = Regex.run(~r/goal\s*=\s*"([^"]*)"/, content) ->
            Enum.at(match, 1)

          match = Regex.run(~r|^//\s*(.+)$|m, content) ->
            Enum.at(match, 1)

          true ->
            "(no description)"
        end

      _ ->
        "(unreadable)"
    end
  end
end
