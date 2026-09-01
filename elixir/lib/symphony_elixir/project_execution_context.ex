defmodule SymphonyElixir.ProjectExecutionContext do
  @moduledoc """
  Immutable, validated execution authority derived from an authorized Linear issue.
  """

  alias SymphonyElixir.Linear.Issue

  @enforce_keys [
    :issue_id,
    :issue_identifier,
    :profile_key,
    :linear_project_id,
    :repository,
    :canonical_branch,
    :workspace_namespace,
    :credential_ref,
    :environment,
    :routing_revision
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          issue_id: String.t(),
          issue_identifier: String.t(),
          profile_key: String.t(),
          linear_project_id: String.t(),
          repository: String.t(),
          canonical_branch: String.t(),
          workspace_namespace: String.t(),
          credential_ref: String.t(),
          environment: String.t(),
          routing_revision: pos_integer()
        }

  @type reason ::
          :missing_project_profile
          | :invalid_project_profile
          | :invalid_issue_id
          | :invalid_issue_identifier
          | :invalid_project_id
          | :project_id_mismatch
          | :repository_mismatch
          | :invalid_workspace_namespace
          | :invalid_canonical_branch
          | :invalid_credential_ref
          | :environment_not_allowed
          | :missing_routing_revision

  @spec from_issue(Issue.t()) :: {:ok, t()} | {:error, reason()}
  def from_issue(%Issue{} = issue) do
    with {:ok, profile} <- validated_profile(issue.project_profile),
         :ok <- validate_issue_identity(issue),
         :ok <- validate_project_id(issue.project_id, profile.linear_project_id),
         :ok <- validate_repository(issue.repository, profile.repository),
         :ok <- validate_routing_revision(issue.routing_revision) do
      {:ok,
       %__MODULE__{
         issue_id: issue.id,
         issue_identifier: issue.identifier,
         profile_key: profile.key,
         linear_project_id: profile.linear_project_id,
         repository: profile.repository,
         canonical_branch: profile.canonical_branch,
         workspace_namespace: profile.workspace_namespace,
         credential_ref: profile.credential_ref,
         environment: profile.environment,
         routing_revision: issue.routing_revision
       }}
    end
  end

  def from_issue(_issue), do: {:error, :invalid_project_profile}

  @spec safe_metadata(t()) :: map()
  def safe_metadata(%__MODULE__{} = context) do
    Map.take(context, [
      :issue_id,
      :issue_identifier,
      :profile_key,
      :repository,
      :canonical_branch,
      :workspace_namespace,
      :environment,
      :routing_revision
    ])
  end

  defp validated_profile(nil), do: {:error, :missing_project_profile}

  defp validated_profile(profile) when is_map(profile) do
    with {:ok, key} <- required_string(profile, :key, :invalid_project_profile),
         {:ok, linear_project_id} <- required_string(profile, :linear_project_id, :invalid_project_id),
         {:ok, repository} <- required_string(profile, :repository, :invalid_project_profile),
         {:ok, canonical_branch} <- required_string(profile, :canonical_branch, :invalid_canonical_branch),
         {:ok, workspace_namespace} <-
           required_string(profile, :workspace_namespace, :invalid_workspace_namespace),
         {:ok, credential_ref} <- required_string(profile, :credential_ref, :invalid_credential_ref),
         {:ok, environment} <- required_string(profile, :environment, :environment_not_allowed),
         :ok <- validate_uuid(linear_project_id),
         :ok <- validate_workspace_namespace(workspace_namespace),
         :ok <- validate_environment(environment) do
      {:ok,
       %{
         key: key,
         linear_project_id: linear_project_id,
         repository: repository,
         canonical_branch: canonical_branch,
         workspace_namespace: workspace_namespace,
         credential_ref: credential_ref,
         environment: environment
       }}
    end
  end

  defp validated_profile(_profile), do: {:error, :invalid_project_profile}

  defp required_string(profile, key, error) do
    case Map.get(profile, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _value -> {:error, error}
    end
  end

  defp validate_issue_identity(%Issue{id: id, identifier: identifier}) do
    with :ok <- validate_nonempty_string(id, :invalid_issue_id),
         :ok <- validate_nonempty_string(identifier, :invalid_issue_identifier) do
      :ok
    end
  end

  defp validate_nonempty_string(value, _error) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp validate_nonempty_string(_value, error), do: {:error, error}

  defp validate_project_id(issue_project_id, profile_project_id) do
    with {:ok, issue_uuid} <- Ecto.UUID.cast(issue_project_id),
         {:ok, profile_uuid} <- Ecto.UUID.cast(profile_project_id) do
      if issue_uuid == profile_uuid, do: :ok, else: {:error, :project_id_mismatch}
    else
      :error -> {:error, :invalid_project_id}
    end
  end

  defp validate_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_project_id}
    end
  end

  defp validate_repository(repository, profile_repository)
       when is_binary(repository) and repository == profile_repository,
       do: :ok

  defp validate_repository(_repository, _profile_repository), do: {:error, :repository_mismatch}

  defp validate_workspace_namespace(namespace) do
    if Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, namespace),
      do: :ok,
      else: {:error, :invalid_workspace_namespace}
  end

  defp validate_environment("local_non_production"), do: :ok
  defp validate_environment(_environment), do: {:error, :environment_not_allowed}

  defp validate_routing_revision(revision) when is_integer(revision) and revision > 0, do: :ok
  defp validate_routing_revision(_revision), do: {:error, :missing_routing_revision}
end
