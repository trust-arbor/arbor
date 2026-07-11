defmodule Arbor.Actions.GitPRTest do
  use Arbor.Actions.ActionCase, async: false
  @moduletag :fast

  alias Arbor.Actions.Git

  @token "test_scm_token"

  setup %{tmp_dir: tmp_dir} do
    repo_path = Path.join(tmp_dir, "repo")
    create_git_repo(repo_path)
    {:ok, repo_path: repo_path}
  end

  describe "PR.run/2" do
    test "opens a draft GitHub pull request from the selected remote", %{repo_path: repo_path} do
      add_remote(repo_path, "origin", "https://github.com/acme/widgets.git")
      parent = self()

      http = fn :post, url, opts ->
        send(parent, {:http, url, opts})

        {:ok,
         %{
           status: 201,
           body: %{"number" => 42, "html_url" => "https://github.com/acme/widgets/pull/42"}
         }}
      end

      assert {:ok, result} =
               Git.PR.run(
                 %{
                   path: repo_path,
                   branch: "feature/pr-action",
                   base: "main",
                   title: "Add PR action",
                   body: "Reviewable change"
                 },
                 %{scm_token: @token, http_request: http}
               )

      assert result.provider == :github
      assert result.number == 42
      assert result.url == "https://github.com/acme/widgets/pull/42"
      assert result.draft? == true

      assert_receive {:http, "https://api.github.com/repos/acme/widgets/pulls", opts}
      assert opts[:json]["head"] == "feature/pr-action"
      assert opts[:json]["base"] == "main"
      assert opts[:json]["draft"] == true
      assert {"authorization", "Bearer #{@token}"} in opts[:headers]
    end

    test "opens a Forgejo/Gitea pull request from an on-prem remote override", %{
      repo_path: repo_path
    } do
      add_remote(repo_path, "origin", "https://github.com/acme/widgets.git")
      add_remote(repo_path, "forgejo", "http://10.42.42.6:3000/hysun/arbor.git")
      parent = self()

      http = fn :post, url, opts ->
        send(parent, {:http, url, opts})

        {:ok,
         %{
           status: 201,
           body: %{"number" => 5, "html_url" => "http://10.42.42.6:3000/hysun/arbor/pulls/5"}
         }}
      end

      assert {:ok, result} =
               Git.PR.run(
                 %{
                   path: repo_path,
                   remote: "forgejo",
                   branch: "feature/local-pr",
                   title: "Local review",
                   body: "Reviewable change"
                 },
                 %{scm_token: @token, http_request: http}
               )

      assert result.provider == :gitea
      assert result.owner == "hysun"
      assert result.repo == "arbor"
      assert result.url == "http://10.42.42.6:3000/hysun/arbor/pulls/5"

      assert_receive {:http, "http://10.42.42.6:3000/api/v1/repos/hysun/arbor/pulls", opts}
      assert opts[:json]["head"] == "feature/local-pr"
      assert opts[:json]["draft"] == true
      assert {"authorization", "token #{@token}"} in opts[:headers]

      assert Git.PR.egress_tier(%{path: repo_path, remote: "forgejo"}, %{}) == :on_premises
      assert Git.PR.egress_destination(%{path: repo_path, remote: "forgejo"}, %{}) == "10.42.42.6"
    end

    test "opens a GitLab merge request with GitLab field names", %{repo_path: repo_path} do
      add_remote(repo_path, "origin", "https://gitlab.com/acme/widgets.git")
      parent = self()

      http = fn :post, url, opts ->
        send(parent, {:http, url, opts})

        {:ok,
         %{
           status: 201,
           body: %{"iid" => 7, "web_url" => "https://gitlab.com/acme/widgets/-/merge_requests/7"}
         }}
      end

      assert {:ok, result} =
               Git.PR.run(
                 %{
                   path: repo_path,
                   branch: "feature/gitlab-mr",
                   base: "main",
                   title: "Add MR action",
                   body: "Reviewable change"
                 },
                 %{scm_token: @token, http_request: http}
               )

      assert result.provider == :gitlab
      assert result.kind == "merge_request"
      assert result.number == 7

      assert_receive {:http, "https://gitlab.com/api/v4/projects/acme%2Fwidgets/merge_requests",
                      opts}

      assert opts[:json]["source_branch"] == "feature/gitlab-mr"
      assert opts[:json]["target_branch"] == "main"
      assert opts[:json]["title"] == "Draft: Add MR action"
      assert opts[:json]["description"] == "Reviewable change"
      assert {"private-token", @token} in opts[:headers]
    end

    test "manual provider and owner overrides do not depend on the remote host", %{
      repo_path: repo_path
    } do
      add_remote(repo_path, "origin", "https://example.invalid/ignored/repo.git")
      parent = self()

      http = fn :post, url, opts ->
        send(parent, {:http, url, opts})

        {:ok,
         %{
           status: 201,
           body: %{"number" => 3, "html_url" => "https://github.com/acme/widgets/pull/3"}
         }}
      end

      assert {:ok, result} =
               Git.PR.run(
                 %{
                   path: repo_path,
                   provider: :github,
                   scm_base_url: "https://api.github.com",
                   owner: "acme",
                   repo: "widgets",
                   branch: "feature/manual",
                   title: "Manual target"
                 },
                 %{scm_token: @token, http_request: http}
               )

      assert result.provider == :github
      assert_receive {:http, "https://api.github.com/repos/acme/widgets/pulls", _opts}
    end

    test "fails before HTTP when no token is configured", %{repo_path: repo_path} do
      add_remote(repo_path, "origin", "https://github.com/acme/widgets.git")
      clear_scm_token_config(["ARBOR_SCM_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"])

      http = fn :post, _url, _opts ->
        send(self(), :unexpected_http)
        {:error, :unexpected}
      end

      assert {:error, reason} =
               Git.PR.run(
                 %{
                   path: repo_path,
                   branch: "feature/no-token",
                   title: "No token"
                 },
                 %{http_request: http}
               )

      assert reason =~ "SCM token is not configured"
      refute_received :unexpected_http
    end

    test "security regression: remote and branch option injection fail before Git or HTTP", %{
      repo_path: repo_path
    } do
      http = fn :post, _url, _opts ->
        send(self(), :unexpected_http)
        {:error, :unexpected}
      end

      assert {:error, remote_reason} =
               Git.PR.run(
                 %{
                   path: repo_path,
                   remote: "--upload-pack=/tmp/helper",
                   branch: "feature/safe",
                   title: "Rejected remote"
                 },
                 %{scm_token: @token, http_request: http}
               )

      assert remote_reason =~ "invalid git remote name"

      add_remote(repo_path, "origin", "https://github.com/acme/widgets.git")

      assert {:error, branch_reason} =
               Git.PR.run(
                 %{
                   path: repo_path,
                   branch: "--exec=/tmp/helper",
                   title: "Rejected branch"
                 },
                 %{scm_token: @token, http_request: http}
               )

      assert branch_reason =~ "invalid_git_branch"
      refute_received :unexpected_http
    end

    test "redacts token values from HTTP error details", %{repo_path: repo_path} do
      add_remote(repo_path, "origin", "https://github.com/acme/widgets.git")
      token = "token-redaction-value"

      http = fn :post, _url, _opts ->
        {:ok, %{status: 401, body: %{"message" => "bad token #{token}"}}}
      end

      assert {:error, reason} =
               Git.PR.run(
                 %{
                   path: repo_path,
                   branch: "feature/error",
                   title: "Error"
                 },
                 %{scm_token: token, http_request: http}
               )

      assert reason =~ "HTTP 401"
      refute reason =~ token
      assert reason =~ "[REDACTED]"
    end
  end

  defp add_remote(repo_path, name, url) do
    {_, 0} = System.cmd("git", ["remote", "add", name, url], cd: repo_path)
    :ok
  end

  defp clear_scm_token_config(env_vars) do
    saved_env = Map.new(env_vars, &{&1, System.get_env(&1)})
    saved_token = Application.get_env(:arbor_actions, :scm_token)
    saved_tokens = Application.get_env(:arbor_actions, :scm_tokens)

    Enum.each(env_vars, &System.delete_env/1)
    Application.delete_env(:arbor_actions, :scm_token)
    Application.delete_env(:arbor_actions, :scm_tokens)

    on_exit(fn ->
      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      restore_app_env(:scm_token, saved_token)
      restore_app_env(:scm_tokens, saved_tokens)
    end)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:arbor_actions, key)
  defp restore_app_env(key, value), do: Application.put_env(:arbor_actions, key, value)
end
