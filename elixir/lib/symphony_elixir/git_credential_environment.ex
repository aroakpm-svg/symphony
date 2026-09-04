defmodule SymphonyElixir.GitCredentialEnvironment do
  @moduledoc "Builds the fixed, call-local credential-protocol environment for GitHub Git commands."

  alias SymphonyElixir.GitHubCredentialResolver.Credential

  @helper ~S"""
          !f() { test "$1" = get || exit 0; protocol=; host=; while IFS== read -r key value; do case "$key" in protocol) protocol="$value" ;; host) host="$value" ;; esac; done; test "$protocol" = https && test "$host" = github.com || exit 1; printf "username=x-access-token\npassword=%s\n" "$GH_TOKEN"; }; f
          """
          |> String.trim()

  @spec build(Credential.t()) :: {:ok, map()} | {:error, :invalid_git_credential}
  def build(%Credential{token: token}) when is_binary(token) and byte_size(token) > 0 do
    null_device = if match?({:win32, _}, :os.type()), do: "NUL", else: "/dev/null"

    {:ok,
     %{
       "GH_TOKEN" => token,
       "GITHUB_TOKEN" => false,
       "GIT_ASKPASS" => false,
       "SSH_ASKPASS" => false,
       "GCM_INTERACTIVE" => "Never",
       "GIT_CONFIG_COUNT" => "0",
       "GIT_CONFIG_GLOBAL" => null_device,
       "GIT_CONFIG_NOSYSTEM" => "1",
       "GIT_CONFIG_PARAMETERS" => "'credential.helper=' 'credential.helper=#{@helper}'",
       "GIT_CONFIG_SYSTEM" => null_device,
       "GIT_TERMINAL_PROMPT" => "0"
     }}
  end

  def build(_credential), do: {:error, :invalid_git_credential}
end
