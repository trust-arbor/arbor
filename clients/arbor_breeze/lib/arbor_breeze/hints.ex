defmodule ArborBreeze.Hints do
  @moduledoc "Best-effort bounded non-authoritative target hint. No credential or private conversation data is stored."
  @max_bytes 4_096
  def default_path,
    do:
      Path.join(
        System.get_env("ARBOR_HOME") || Path.join(System.user_home!(), ".arbor"),
        "breeze.state"
      )

  def load(path, gateway) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_bytes <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= @max_bytes,
         {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(bytes, objects: :ordered_objects),
         true <- length(pairs) == 3 and map_size(Map.new(pairs)) == 3,
         %{"v" => 1, "gateway" => ^gateway, "target" => target} <- Map.new(pairs),
         true <- valid?(gateway, target) do
      target
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def save(path, gateway, target) do
    if valid?(gateway, target) do
      temp = path <> "." <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

      try do
        directory = Path.dirname(path)

        if not File.exists?(directory) do
          File.mkdir_p(directory)
          File.chmod(directory, 0o700)
        end

        with :ok <-
               File.write(temp, Jason.encode!(%{v: 1, gateway: gateway, target: target}), [
                 :binary,
                 :exclusive
               ]),
             :ok <- File.chmod(temp, 0o600),
             :ok <- File.rename(temp, path),
             do: :ok
      after
        File.rm(temp)
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp valid?(gateway, target), do: ArborBreeze.Drafts.scope?({gateway, "human_hint", target})
end
