defmodule SymphonyElixir.ReviewTarget do
  @moduledoc """
  Immutable identity for one pull-request review target.

  A repository and pull-request number are not sufficient to identify review
  state because a new commit invalidates the previous review. The target head
  SHA is therefore part of the identity and must remain stable for the entire
  control-plane run.
  """

  @enforce_keys [:repository, :pull_request_number, :head_sha, :required_checks]
  defstruct [:repository, :pull_request_number, :head_sha, :required_checks]

  @type required_check :: %{
          name: String.t(),
          app_slug: String.t(),
          app_id: pos_integer()
        }

  @type t :: %__MODULE__{
          repository: String.t(),
          pull_request_number: pos_integer(),
          head_sha: String.t(),
          required_checks: [required_check()]
        }

  @repository_format ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
  @head_sha_format ~r/\A[0-9a-f]{40}\z/

  @spec new(map() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = target), do: validate(target)

  def new(attrs) when is_map(attrs) do
    with {:ok, repository} <- required_binary(attrs, :repository),
         :ok <- validate_repository(repository),
         {:ok, pull_request_number} <- required_positive_integer(attrs, :pull_request_number),
         {:ok, head_sha} <- required_binary(attrs, :head_sha),
         :ok <- validate_head_sha(head_sha),
         {:ok, required_checks} <- required_checks_from_attrs(attrs) do
      {:ok,
       %__MODULE__{
         repository: repository,
         pull_request_number: pull_request_number,
         head_sha: head_sha,
         required_checks: required_checks
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_review_target}

  @spec identity(t()) :: %{
          repository: String.t(),
          pull_request_number: pos_integer(),
          head_sha: String.t()
        }
  def identity(%__MODULE__{} = target) do
    %{
      repository: target.repository,
      pull_request_number: target.pull_request_number,
      head_sha: target.head_sha
    }
  end

  @spec key(t()) :: String.t()
  def key(%__MODULE__{repository: repository, pull_request_number: number, head_sha: head_sha}) do
    "#{repository}##{number}@#{head_sha}"
  end

  @spec dedup_key(t(), atom(), term()) :: String.t()
  def dedup_key(%__MODULE__{} = target, action, subject) when is_atom(action) do
    :crypto.hash(:sha256, :erlang.term_to_binary({key(target), action, subject}))
    |> Base.encode16(case: :lower)
  end

  @spec assert_snapshot(t(), map()) :: :ok | {:error, term()}
  def assert_snapshot(%__MODULE__{} = target, snapshot) when is_map(snapshot) do
    checks = [
      {:repository, target.repository, Map.get(snapshot, :repository) || Map.get(snapshot, "repository")},
      {:pull_request_number, target.pull_request_number, Map.get(snapshot, :pull_request_number) || Map.get(snapshot, "pull_request_number")},
      {:head_sha, target.head_sha, Map.get(snapshot, :current_head_sha) || Map.get(snapshot, "current_head_sha")}
    ]

    case Enum.find(checks, fn {_field, expected, actual} -> expected != actual end) do
      nil -> :ok
      {field, expected, actual} -> {:error, {:target_identity_mismatch, field, expected, actual}}
    end
  end

  def assert_snapshot(_target, _snapshot), do: {:error, :invalid_review_snapshot}

  @spec validate_all([map() | t()]) :: {:ok, [t()]} | {:error, term()}
  def validate_all(targets) when is_list(targets) and targets != [] do
    with {:ok, parsed} <- parse_all(targets),
         :ok <- reject_duplicate_targets(parsed),
         :ok <- reject_duplicate_status_destinations(parsed) do
      {:ok, parsed}
    end
  end

  def validate_all([]), do: {:error, :review_target_allowlist_empty}
  def validate_all(_targets), do: {:error, :review_target_allowlist_invalid}

  defp validate(%__MODULE__{} = target) do
    with :ok <- validate_repository(target.repository),
         :ok <- validate_positive_integer(target.pull_request_number),
         :ok <- validate_head_sha(target.head_sha),
         {:ok, required_checks} <- validate_required_checks(target.required_checks) do
      target = %{target | required_checks: required_checks}
      {:ok, target}
    end
  end

  defp parse_all(targets) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, acc} ->
      case new(target) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_review_target, reason}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp reject_duplicate_targets(targets) do
    keys = Enum.map(targets, &key/1)

    case Enum.find(Enum.frequencies(keys), fn {_key, count} -> count > 1 end) do
      nil -> :ok
      {duplicate, _count} -> {:error, {:duplicate_target, duplicate}}
    end
  end

  defp reject_duplicate_status_destinations(targets) do
    destinations = Enum.map(targets, &status_destination/1)

    case Enum.find(Enum.frequencies(destinations), fn {_destination, count} -> count > 1 end) do
      nil -> :ok
      {duplicate, _count} -> {:error, {:duplicate_status_destination, duplicate}}
    end
  end

  defp status_destination(%__MODULE__{repository: repository, head_sha: head_sha}),
    do: "#{repository}@#{head_sha}"

  defp required_checks_from_attrs(attrs) do
    case Map.get(attrs, :required_checks) || Map.get(attrs, "required_checks") do
      checks when is_list(checks) -> validate_required_checks(checks)
      _ -> {:error, {:missing_or_invalid, :required_checks}}
    end
  end

  defp validate_required_checks(checks) when is_list(checks) and checks != [] do
    with {:ok, normalized} <- normalize_required_checks(checks),
         normalized <- Enum.reverse(normalized),
         :ok <- reject_duplicate_required_check_names(normalized) do
      {:ok, normalized}
    end
  end

  defp validate_required_checks(_checks), do: {:error, {:missing_or_invalid, :required_checks}}

  defp normalize_required_checks(checks) do
    Enum.reduce_while(checks, {:ok, []}, fn check, {:ok, acc} ->
      case normalize_required_check(check) do
        {:ok, normalized_check} -> {:cont, {:ok, [normalized_check | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_required_check(check) when is_map(check) do
    with {:ok, name} <- required_binary(check, :name),
         {:ok, app_slug} <- required_binary(check, :app_slug),
         {:ok, app_id} <- required_positive_integer(check, :app_id) do
      {:ok, %{name: name, app_slug: app_slug, app_id: app_id}}
    end
  end

  defp normalize_required_check(_check), do: {:error, :invalid_required_check}

  defp reject_duplicate_required_check_names(checks) do
    case Enum.find(Enum.frequencies(Enum.map(checks, & &1.name)), fn {_name, count} -> count > 1 end) do
      nil -> :ok
      {duplicate, _count} -> {:error, {:duplicate_required_check, duplicate}}
    end
  end

  defp required_binary(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp required_positive_integer(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp validate_repository(repository) when is_binary(repository) do
    if Regex.match?(@repository_format, repository),
      do: :ok,
      else: {:error, {:invalid_repository, repository}}
  end

  defp validate_repository(repository), do: {:error, {:invalid_repository, repository}}

  defp validate_positive_integer(number) when is_integer(number) and number > 0, do: :ok
  defp validate_positive_integer(number), do: {:error, {:invalid_pull_request_number, number}}

  defp validate_head_sha(head_sha) when is_binary(head_sha) do
    if Regex.match?(@head_sha_format, head_sha),
      do: :ok,
      else: {:error, {:invalid_head_sha, head_sha}}
  end

  defp validate_head_sha(head_sha), do: {:error, {:invalid_head_sha, head_sha}}
end
