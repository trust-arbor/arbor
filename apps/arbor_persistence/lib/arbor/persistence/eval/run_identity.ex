defmodule Arbor.Persistence.Eval.RunIdentity do
  @moduledoc false

  # Captures run-identity fields for eval runs (git sha, dataset hash, config
  # fingerprint). Public access is via Arbor.Persistence only.
  #
  # All capture is best-effort and fail-safe: any failure simply omits the
  # field. Caller-provided values are never overwritten.

  @spec capture(map()) :: map()
  def capture(attrs) when is_map(attrs) do
    attrs
    |> put_new_lazy_safe(:git_sha, &git_sha/0)
    |> put_new_lazy_safe(:git_dirty, &git_dirty/0)
    |> put_new_lazy_safe(:dataset_hash, fn -> dataset_hash(attrs[:dataset]) end)
    |> put_new_lazy_safe(:config_fingerprint, fn -> config_fingerprint(attrs[:config]) end)
  end

  @spec git_sha() :: String.t() | nil
  def git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @spec git_dirty() :: boolean() | nil
  def git_dirty do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) != ""
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @spec dataset_hash(String.t() | nil) :: String.t() | nil
  def dataset_hash(nil), do: nil

  def dataset_hash(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def dataset_hash(_), do: nil

  @spec config_fingerprint(map() | nil) :: String.t() | nil
  def config_fingerprint(nil), do: nil
  def config_fingerprint(config) when config == %{}, do: nil

  def config_fingerprint(config) when is_map(config) do
    binary = :erlang.term_to_binary(config, [:deterministic])
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, binary), case: :lower)
  rescue
    _ -> nil
  end

  def config_fingerprint(_), do: nil

  defp put_new_lazy_safe(attrs, key, fun) do
    if Map.has_key?(attrs, key) do
      attrs
    else
      case fun.() do
        nil -> attrs
        value -> Map.put(attrs, key, value)
      end
    end
  rescue
    _ -> attrs
  end
end
