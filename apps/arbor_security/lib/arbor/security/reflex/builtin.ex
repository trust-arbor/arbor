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

  @doc """
  Returns all built-in reflexes.
  """
  @spec all() :: [Reflex.t()]
  def all do
    shell_reflexes() ++ file_reflexes() ++ network_reflexes()
  end

  @doc """
  Shell-related dangerous patterns.
  """
  @spec shell_reflexes() :: [Reflex.t()]
  def shell_reflexes do
    [
      # Block rm -rf on root or home directories
      Reflex.pattern(
        "rm_rf_root",
        ~r/rm\s+(-[rf]+\s+)*[\/~]/,
        id: "rm_rf_root",
        response: :block,
        message: "Blocked: recursive delete of root or home directory",
        priority: 100
      ),
      # Block sudo/su commands
      Reflex.pattern(
        "sudo_su",
        ~r/\b(sudo|su)\s+/,
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
        ~r/https?:\/\/169\.254\./,
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
  Get built-in reflexes by category.
  """
  @spec by_category(atom()) :: [Reflex.t()]
  def by_category(:shell), do: shell_reflexes()
  def by_category(:file), do: file_reflexes()
  def by_category(:network), do: network_reflexes()
  def by_category(_), do: []

  @doc """
  Get the IDs of all built-in reflexes.
  """
  @spec ids() :: [String.t()]
  def ids do
    Enum.map(all(), & &1.id)
  end
end
