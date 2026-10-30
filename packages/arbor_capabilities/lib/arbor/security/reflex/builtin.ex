defmodule Arbor.Security.Reflex.Builtin do
  @moduledoc """
  Built-in reflex definitions for common dangerous patterns.

  These reflexes are loaded automatically when the registry starts.
  They provide a baseline safety layer against obviously dangerous actions.

  ## Categories

  - **Shell Patterns** - Dangerous shell commands (rm -rf, sudo, etc.)
  - **File Access** - Sensitive file/path patterns (.ssh, .env, etc.)
  - **Network** - Dangerous network operations
  - **Code Execution** - Dangerous code patterns

  ## Priority Levels

  - 100: Critical safety (rm -rf, sudo) — always checked first
  - 90: High security (SSH keys, credentials)
  - 80: Medium security (.env files, config)
  - 70: Lower security (warnings, logging)
  """

  alias Arbor.Contracts.Security.Reflex

  @protected_infrastructure_module_names [
    "Arbor.Monitor",
    "Arbor.Monitor.Poller",
    "Arbor.Monitor.AnomalyQueue",
    "Arbor.Monitor.Verification",
    "Arbor.Monitor.CascadeDetector",
    "Arbor.Monitor.RejectionTracker",
    "Arbor.Monitor.Fingerprint",
    "Arbor.Monitor.MetricsStore",
    "Arbor.Monitor.AnomalyDetector",
    "Arbor.Monitor.HealingSupervisor",
    "Arbor.Agent.DebugAgent",
    "Arbor.Security.Reflex",
    "Arbor.Security.Reflex.Registry",
    "Arbor.Security.Reflex.Builtin"
  ]

  @doc """
  Returns all built-in reflexes.
  """
  @spec all() :: [Reflex.t()]
  def all do
    shell_reflexes() ++ file_reflexes() ++ network_reflexes() ++ infrastructure_reflexes()
  end

  @doc """
  Shell-related dangerous patterns.
  """
  @spec shell_reflexes() :: [Reflex.t()]
  def shell_reflexes do
    [
      # Block rm -rf on root or home directories
      Reflex.custom(
        "rm_rf_root",
        &dangerous_recursive_delete?/1,
        id: "rm_rf_root",
        response: :block,
        message: "Blocked: recursive delete of root or home directory",
        priority: 100
      ),
      # Block sudo/su commands
      Reflex.pattern(
        "sudo_su",
        ~r/\b(?:sudo|su|doas|pkexec)(?:\s|$)/,
        id: "sudo_su",
        response: :block,
        message: "Blocked: privilege escalation command",
        priority: 100
      ),
      # Block chmod with dangerous permissions
      Reflex.pattern(
        "chmod_dangerous",
        ~r/chmod\s+(-[rR]+\s+)*(777|666|[\+\=]s)/,
        id: "chmod_dangerous",
        response: :block,
        message: "Blocked: dangerous permission change",
        priority: 95
      ),
      # Block dd if targeting disk devices
      Reflex.pattern(
        "dd_disk",
        ~r/dd\s+.*of=\/dev\/(sd[a-z]|hd[a-z]|nvme|disk)/,
        id: "dd_disk",
        response: :block,
        message: "Blocked: direct disk write",
        priority: 100
      ),
      # Block mkfs commands
      Reflex.pattern(
        "mkfs",
        ~r/mkfs(\.[a-z0-9]+)?\s+/,
        id: "mkfs",
        response: :block,
        message: "Blocked: filesystem format command",
        priority: 100
      ),
      # Warn on curl/wget piped to shell
      Reflex.pattern(
        "curl_pipe_shell",
        ~r/(curl|wget)\s+[^\|]*\|\s*(ba)?sh/,
        id: "curl_pipe_shell",
        response: :warn,
        message: "Warning: downloading and executing scripts",
        priority: 85
      ),
      # Block fork bombs
      Reflex.pattern(
        "fork_bomb",
        ~r/:\(\)\s*\{\s*:\|:&\s*\}\s*;?\s*:/,
        id: "fork_bomb",
        response: :block,
        message: "Blocked: fork bomb pattern detected",
        priority: 100
      )
    ]
  end

  # Tokenize first so quoting and option order do not create holes in a
  # security-critical command check. This remains deliberately conservative:
  # recursive deletion of any absolute path or any spelling of the home root
  # is blocked before capability authorization.
  defp dangerous_recursive_delete?(%{command: command}) when is_binary(command) do
    tokens = shell_tokens(command)

    tokens
    |> Enum.with_index()
    |> Enum.any?(fn {token, index} ->
      if rm_executable?(token) do
        args =
          tokens
          |> Enum.drop(index + 1)
          |> Enum.take_while(&(not shell_control_operator?(&1)))

        Enum.any?(args, &recursive_rm_option?/1) and Enum.any?(args, &dangerous_rm_target?/1)
      else
        false
      end
    end)
  end

  defp dangerous_recursive_delete?(_context), do: false

  defp shell_tokens(command) do
    command
    |> tokenize_shell(:unquoted, [], [], [])
    |> finish_shell_tokens()
  rescue
    _ -> String.split(command)
  end

  # A shell-aware lexical pass keeps quoted operator text as data while exposing
  # real command boundaries. Command substitutions need their own context:
  # OptionParser.split/1 leaves `$(rm` and `` `rm`` glued to the executable,
  # including when a substitution appears inside double quotes.
  defp tokenize_shell(<<>>, _mode, _contexts, current, tokens), do: {current, tokens}

  defp tokenize_shell(<<"\\", next, rest::binary>>, mode, contexts, current, tokens)
       when mode in [:unquoted, :double_quoted] do
    tokenize_shell(rest, mode, contexts, [<<next>> | current], tokens)
  end

  defp tokenize_shell(<<"$(", rest::binary>>, mode, contexts, current, tokens)
       when mode in [:unquoted, :double_quoted] do
    {current, tokens} = emit_shell_operator("$(", current, tokens)
    tokenize_shell(rest, :unquoted, [{:dollar_substitution, mode} | contexts], current, tokens)
  end

  defp tokenize_shell(
         <<"`", rest::binary>>,
         mode,
         [{:backtick, return_mode} | contexts],
         current,
         tokens
       )
       when mode in [:unquoted, :double_quoted] do
    {current, tokens} = emit_shell_operator("`", current, tokens)
    tokenize_shell(rest, return_mode, contexts, current, tokens)
  end

  defp tokenize_shell(<<"`", rest::binary>>, mode, contexts, current, tokens)
       when mode in [:unquoted, :double_quoted] do
    {current, tokens} = emit_shell_operator("`", current, tokens)
    tokenize_shell(rest, :unquoted, [{:backtick, mode} | contexts], current, tokens)
  end

  defp tokenize_shell(<<"'", rest::binary>>, :unquoted, contexts, current, tokens),
    do: tokenize_shell(rest, :single_quoted, contexts, current, tokens)

  defp tokenize_shell(<<"'", rest::binary>>, :single_quoted, contexts, current, tokens),
    do: tokenize_shell(rest, :unquoted, contexts, current, tokens)

  defp tokenize_shell(<<"\"", rest::binary>>, :unquoted, contexts, current, tokens),
    do: tokenize_shell(rest, :double_quoted, contexts, current, tokens)

  defp tokenize_shell(<<"\"", rest::binary>>, :double_quoted, contexts, current, tokens),
    do: tokenize_shell(rest, :unquoted, contexts, current, tokens)

  defp tokenize_shell(<<"(", rest::binary>>, :unquoted, contexts, current, tokens) do
    {current, tokens} = emit_shell_operator("(", current, tokens)
    tokenize_shell(rest, :unquoted, [{:parenthesis, :unquoted} | contexts], current, tokens)
  end

  defp tokenize_shell(
         <<")", rest::binary>>,
         :unquoted,
         [{kind, return_mode} | contexts],
         current,
         tokens
       )
       when kind in [:dollar_substitution, :parenthesis] do
    {current, tokens} = emit_shell_operator(")", current, tokens)
    tokenize_shell(rest, return_mode, contexts, current, tokens)
  end

  defp tokenize_shell(<<")", rest::binary>>, :unquoted, contexts, current, tokens) do
    {current, tokens} = emit_shell_operator(")", current, tokens)
    tokenize_shell(rest, :unquoted, contexts, current, tokens)
  end

  defp tokenize_shell(<<space, rest::binary>>, :unquoted, contexts, current, tokens)
       when space in [?\s, ?\t] do
    {current, tokens} = emit_shell_token(current, tokens)
    tokenize_shell(rest, :unquoted, contexts, current, tokens)
  end

  defp tokenize_shell(<<operator, rest::binary>>, :unquoted, contexts, current, tokens)
       when operator in [?;, ?|, ?&, ?\n, ?\r] do
    {current, tokens} = emit_shell_operator(<<operator>>, current, tokens)
    tokenize_shell(rest, :unquoted, contexts, current, tokens)
  end

  defp tokenize_shell(<<byte, rest::binary>>, mode, contexts, current, tokens) do
    tokenize_shell(rest, mode, contexts, [<<byte>> | current], tokens)
  end

  defp finish_shell_tokens({current, tokens}) do
    {_current, tokens} = emit_shell_token(current, tokens)
    Enum.reverse(tokens)
  end

  defp emit_shell_operator(operator, current, tokens) do
    {_current, tokens} = emit_shell_token(current, tokens)
    {[], [operator | tokens]}
  end

  defp emit_shell_token([], tokens), do: {[], tokens}

  defp emit_shell_token(current, tokens) do
    {[], [current |> Enum.reverse() |> IO.iodata_to_binary() | tokens]}
  end

  defp shell_control_operator?(token), do: token in [";", "|", "&", "(", ")", "$(", "`"]

  defp rm_executable?(token) do
    token
    |> trim_shell_separator()
    |> Path.basename()
    |> Kernel.==("rm")
  end

  defp recursive_rm_option?("--recursive"), do: true
  defp recursive_rm_option?("--recursive=" <> _), do: true

  defp recursive_rm_option?(<<"-", next, rest::binary>>) when next != ?- do
    String.contains?(<<next, rest::binary>>, ["r", "R"])
  end

  defp recursive_rm_option?(_token), do: false

  defp dangerous_rm_target?(token) do
    target = trim_shell_separator(token)
    home = System.user_home!()

    String.starts_with?(target, "/") or
      target == "~" or String.starts_with?(target, "~/") or
      target == "$HOME" or String.starts_with?(target, "$HOME/") or
      target == "${HOME}" or String.starts_with?(target, "${HOME}/") or
      target == home or String.starts_with?(target, home <> "/")
  rescue
    _ -> false
  end

  defp trim_shell_separator(token), do: String.trim(token, " \t\r\n;|&")

  @doc """
  File access dangerous patterns.
  """
  @spec file_reflexes() :: [Reflex.t()]
  def file_reflexes do
    [
      # Block SSH private key access
      Reflex.path(
        "ssh_private_keys",
        "~/.ssh/id_*",
        id: "ssh_private_keys",
        response: :block,
        message: "Blocked: access to SSH private keys",
        priority: 95
      ),
      # Block SSH config access
      Reflex.path(
        "ssh_config",
        "~/.ssh/config",
        id: "ssh_config",
        response: :warn,
        message: "Warning: accessing SSH configuration",
        priority: 80
      ),
      # Warn on .env file access
      Reflex.path(
        "env_files",
        "**/.env*",
        id: "env_files",
        response: :warn,
        message: "Warning: accessing environment file (may contain secrets)",
        priority: 80
      ),
      # Block access to system password files
      Reflex.path(
        "etc_passwd",
        "/etc/passwd",
        id: "etc_passwd",
        response: :block,
        message: "Blocked: access to system password file",
        priority: 90
      ),
      Reflex.path(
        "etc_shadow",
        "/etc/shadow",
        id: "etc_shadow",
        response: :block,
        message: "Blocked: access to system shadow file",
        priority: 100
      ),
      # Warn on AWS credentials
      Reflex.path(
        "aws_credentials",
        "~/.aws/credentials",
        id: "aws_credentials",
        response: :warn,
        message: "Warning: accessing AWS credentials",
        priority: 90
      ),
      # Block access to keychain/credential stores
      Reflex.path(
        "gnome_keyring",
        "~/.local/share/keyrings/*",
        id: "gnome_keyring",
        response: :block,
        message: "Blocked: access to GNOME keyring",
        priority: 95
      ),
      # Warn on NPM/Yarn token files
      Reflex.path(
        "npm_tokens",
        "~/.npmrc",
        id: "npm_tokens",
        response: :warn,
        message: "Warning: accessing NPM configuration (may contain tokens)",
        priority: 80
      ),
      # Warn on git credentials
      Reflex.path(
        "git_credentials",
        "~/.git-credentials",
        id: "git_credentials",
        response: :warn,
        message: "Warning: accessing git credentials",
        priority: 85
      )
    ]
  end

  @doc """
  Network-related dangerous patterns.
  """
  @spec network_reflexes() :: [Reflex.t()]
  def network_reflexes do
    [
      # Block requests to localhost/127.0.0.1 (SSRF prevention)
      Reflex.pattern(
        "ssrf_localhost",
        ~r/https?:\/\/(localhost|127\.0\.0\.1|0\.0\.0\.0)/i,
        id: "ssrf_localhost",
        response: :warn,
        message: "Warning: request to localhost/loopback address",
        priority: 85
      ),
      # Block requests to private IP ranges (169.254.x.x for cloud metadata)
      Reflex.pattern(
        "ssrf_metadata",
        # arbor:allow pii -- decimal cloud-metadata IPv4 literal, not a phone number
        ~r"https?://(?:169\.254(?:\.\d{1,3}){2}|metadata\.google\.internal|2852039166|\[(?:fe80::a9fe:a9fe|fd00:ec2::254)\])(?:[/:]|$)"i,
        id: "ssrf_metadata",
        response: :block,
        message: "Blocked: request to cloud metadata service",
        priority: 95
      ),
      # Block requests to internal 10.x.x.x range
      Reflex.pattern(
        "ssrf_internal_10",
        ~r/https?:\/\/10\.\d+\.\d+\.\d+/,
        id: "ssrf_internal_10",
        response: :warn,
        message: "Warning: request to internal network (10.x.x.x)",
        priority: 80
      ),
      # Block requests to internal 192.168.x.x range
      Reflex.pattern(
        "ssrf_internal_192",
        ~r/https?:\/\/192\.168\.\d+\.\d+/,
        id: "ssrf_internal_192",
        response: :warn,
        message: "Warning: request to internal network (192.168.x.x)",
        priority: 80
      )
    ]
  end

  @doc """
  Infrastructure protection reflexes.

  These block hot-loading of critical healing infrastructure modules.
  If an attacker could hot-load replacement code for the healing system,
  they could disable safety checks or inject malicious fixes.
  """
  @spec infrastructure_reflexes() :: [Reflex.t()]
  def infrastructure_reflexes do
    [
      # Block hot-loading of healing infrastructure modules
      Reflex.custom(
        "no_self_healing",
        fn context ->
          module = Map.get(context, :module)
          action = Map.get(context, :action)

          action == :code_hot_load and protected_infrastructure_module?(module)
        end,
        id: "no_self_healing",
        response: :block,
        message: "Blocked: cannot hot-load healing infrastructure modules",
        priority: 100
      ),
      # Block code_eval on protected modules
      Reflex.custom(
        "no_healing_eval",
        fn context ->
          module = Map.get(context, :module)
          action = Map.get(context, :action)

          action == :code_eval and protected_infrastructure_module?(module)
        end,
        id: "no_healing_eval",
        response: :block,
        message: "Blocked: cannot eval code in healing infrastructure context",
        priority: 100
      )
    ]
  end

  @doc """
  Get built-in reflexes by category.
  """
  @spec by_category(atom()) :: [Reflex.t()]
  def by_category(:shell), do: shell_reflexes()
  def by_category(:file), do: file_reflexes()
  def by_category(:network), do: network_reflexes()
  def by_category(:infrastructure), do: infrastructure_reflexes()
  def by_category(_), do: []

  defp protected_infrastructure_module?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> normalize_module_name()
    |> protected_infrastructure_module?()
  end

  defp protected_infrastructure_module?(module) when is_binary(module) do
    module
    |> normalize_module_name()
    |> then(&(&1 in @protected_infrastructure_module_names))
  end

  defp protected_infrastructure_module?(_), do: false

  defp normalize_module_name("Elixir." <> module), do: module
  defp normalize_module_name(module), do: module

  @doc """
  Get the IDs of all built-in reflexes.
  """
  @spec ids() :: [String.t()]
  def ids do
    Enum.map(all(), & &1.id)
  end
end
