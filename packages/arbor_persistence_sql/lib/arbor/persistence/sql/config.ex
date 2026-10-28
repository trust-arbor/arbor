defmodule Arbor.Persistence.SQL.Config do
  @moduledoc """
  SQL-adapter configuration. A caller may also pass `:repo` explicitly to a backend.

  `:repo` defaults to the optional `Arbor.Persistence.SQL.Repo`; the adapter never
  starts that Repo itself. Arbor's host supplies its existing product Repo here.
  """

  @spec default_repo() :: module()
  def default_repo do
    case Application.get_env(:arbor_persistence_sql, :repo, Arbor.Persistence.SQL.Repo) do
      repo when is_atom(repo) and not is_nil(repo) -> repo
      _invalid -> raise ArgumentError, "invalid SQL repository configuration"
    end
  end
end
