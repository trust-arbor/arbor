# Starts the Arbor dev daemon's Erlang distribution behind a gate, before Mix.
#
# bin/arbor-dev-daemon-launch boots the VM with the operator's real HOME,
# `-nocookie`, `-proto_dist arbor_gated_tcp[6]` and no node name, and passes
# this file with `-r`. The node name rides in argv as `-arbor_dist_node <name>`
# (lifecycle tasks identify the daemon by it in `ps`); the name type and the
# cookie FILE path arrive in the environment. The cookie itself never appears
# in argv or the environment.
#
# Order matters:
#   1. compile and load the gated carrier from this directory (not from any
#      Mix code path, so no later compile or reload can redefine it);
#   2. read and validate the private cookie file;
#   3. start distribution (the node's cookie is the public `nocookie` here,
#      and the closed gate refuses every inbound handshake by name);
#   4. set the real cookie;
#   5. open the gate;
#   6. scrub the handoff variables.
# Any failure halts the VM with status 1 before Mix evaluates configuration.

gate_key = {:arbor_gated_dist, :gate}

protos = %{
  "arbor_gated_tcp" => :arbor_gated_tcp_dist,
  "arbor_gated_tcp6" => :arbor_gated_tcp6_dist
}

handoff_env =
  ~w(ARBOR_DIST_NAME_TYPE ARBOR_DIST_COOKIE_FILE ARBOR_COOKIE ARBOR_RUNTIME_ORIGINAL_HOME)

fail = fn reason ->
  IO.puts(:stderr, "arbor-gated-dist-bootstrap: refusing to start distribution: #{reason}")
  System.halt(1)
end

single_argument = fn flag ->
  case :init.get_argument(flag) do
    {:ok, [[value]]} -> {:ok, List.to_string(value)}
    {:ok, _many} -> {:error, "-#{flag} must be given exactly once with one value"}
    :error -> {:error, "-#{flag} is missing"}
  end
end

valid_cookie? = fn cookie ->
  byte_size(cookie) in 1..255 and
    cookie |> :binary.bin_to_list() |> Enum.all?(&(&1 in 33..126))
end

owner_only? = fn %File.Stat{mode: mode} -> Bitwise.band(mode, 0o077) == 0 end

# Reading updates atime, so compare only what a swap or rewrite would change.
identity = fn
  {:ok, %File.Stat{} = stat} ->
    {:ok, Map.take(stat, [:inode, :major_device, :size, :mtime, :ctime, :mode, :uid])}

  other ->
    other
end

read_cookie = fn path ->
  dir = Path.dirname(path)

  with {:abs, :absolute} <- {:abs, Path.type(path)},
       {:dir, {:ok, %File.Stat{type: :directory} = dir_stat}} <- {:dir, File.lstat(dir)},
       {:dir_mode, true} <- {:dir_mode, owner_only?.(dir_stat)},
       {:file, {:ok, %File.Stat{type: :regular, size: size} = stat}} <-
         {:file, File.lstat(path, time: :posix)},
       {:file_mode, true} <- {:file_mode, owner_only?.(stat)},
       {:size, true} <- {:size, size in 1..256},
       {:ok, before} = identity.({:ok, stat}),
       {:read, {:ok, raw}} <- {:read, File.read(path)},
       {:stable, {:ok, ^before}} <- {:stable, identity.(File.lstat(path, time: :posix))},
       cookie = String.replace_suffix(raw, "\n", ""),
       {:cookie, true} <- {:cookie, valid_cookie?.(cookie)} do
    {:ok, cookie}
  else
    {:abs, _} -> {:error, "cookie file path must be absolute"}
    {:dir, _} -> {:error, "cookie directory is missing or not a real directory"}
    {:dir_mode, _} -> {:error, "cookie directory must not be accessible to group or others"}
    {:file, _} -> {:error, "cookie file is missing, a symlink, or not a regular file"}
    {:file_mode, _} -> {:error, "cookie file must not be accessible to group or others"}
    {:size, _} -> {:error, "cookie file has an implausible size"}
    {:read, {:error, reason}} -> {:error, "cookie file is unreadable (#{inspect(reason)})"}
    {:stable, _} -> {:error, "cookie file changed while it was being read"}
    {:cookie, _} -> {:error, "cookie must be 1-255 printable ASCII characters"}
  end
end

load_gate = fn proto, module ->
  source = Path.join(__DIR__, proto <> "_dist.erl")

  # noenv_file ignores ERL_COMPILER_OPTIONS, so the environment cannot add
  # macros or parse transforms to the gate.
  with {:loaded, false} <- {:loaded, :code.is_loaded(module)},
       {:compile, {:ok, ^module, binary}} <-
         {:compile,
          :compile.noenv_file(String.to_charlist(source), [
            :binary,
            :return_errors,
            :deterministic
          ])},
       {:load, {:module, ^module}} <-
         {:load, :code.load_binary(module, String.to_charlist(source), binary)} do
    :ok
  else
    {:loaded, _} -> {:error, "#{module} was already loaded before the bootstrap"}
    {:compile, other} -> {:error, "could not compile #{source}: #{inspect(other)}"}
    {:load, other} -> {:error, "could not load #{module}: #{inspect(other)}"}
  end
end

try do
  :persistent_term.put(gate_key, :closed)

  with {:alive, false} <- {:alive, Node.alive?()},
       {:nocookie, {:ok, _}} <- {:nocookie, :init.get_argument(:nocookie)},
       {:setcookie, :error} <- {:setcookie, :init.get_argument(:setcookie)},
       {:ok, proto} <- single_argument.(:proto_dist),
       {:proto, {:ok, module}} <- {:proto, Map.fetch(protos, proto)},
       {:ok, node_name} <- single_argument.(:arbor_dist_node),
       {:node, true} <-
         {:node, Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}@[A-Za-z0-9._:-]{1,190}\z/, node_name)},
       {:name_type, {:ok, name_type}} <-
         {:name_type,
          Map.fetch(
            %{"longnames" => :longnames, "shortnames" => :shortnames},
            System.get_env("ARBOR_DIST_NAME_TYPE", "")
          )},
       {:cookie_path, path} when is_binary(path) and path != "" <-
         {:cookie_path, System.get_env("ARBOR_DIST_COOKIE_FILE")},
       {:ok, cookie} <- read_cookie.(path),
       :ok <- load_gate.(proto, module),
       # Safe: validated above against a bounded node-name pattern.
       # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
       node = String.to_atom(node_name),
       {:start, {:ok, _}} <- {:start, :net_kernel.start(node, %{name_domain: name_type})},
       {:node_started, ^node} <- {:node_started, Node.self()},
       # Safe: validated above as 1-255 printable ASCII; one atom per boot.
       # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
       cookie_atom = String.to_atom(cookie),
       true <- :erlang.set_cookie(cookie_atom),
       {:cookie_set, ^cookie_atom} <- {:cookie_set, :erlang.get_cookie()} do
    :persistent_term.put(gate_key, :open)
    Enum.each(handoff_env, &System.delete_env/1)
  else
    {:error, reason} -> fail.(reason)
    {:alive, _} -> fail.("distribution is already running")
    {:nocookie, _} -> fail.("the VM was not started with -nocookie")
    {:setcookie, _} -> fail.("the VM was started with -setcookie")
    {:proto, _} -> fail.("-proto_dist is not an Arbor gated carrier")
    {:node, _} -> fail.("-arbor_dist_node is not a valid node name")
    {:name_type, _} -> fail.("ARBOR_DIST_NAME_TYPE must be longnames or shortnames")
    {:cookie_path, _} -> fail.("ARBOR_DIST_COOKIE_FILE is not set")
    {:start, error} -> fail.("net_kernel did not start (#{inspect(error)}); is epmd running?")
    {:node_started, other} -> fail.("distribution started as #{inspect(other)}")
    {:cookie_set, _} -> fail.("the cookie did not take effect")
    other -> fail.("unexpected bootstrap result #{inspect(other)}")
  end
rescue
  error -> fail.(Exception.message(error))
catch
  kind, reason -> fail.("#{kind}: #{inspect(reason)}")
end
