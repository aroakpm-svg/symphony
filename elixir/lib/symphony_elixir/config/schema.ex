defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.{PathSafety, ProjectProfiles}

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule ProjectProfilesType do
    @moduledoc false
    @behaviour Ecto.Type

    alias SymphonyElixir.ProjectProfiles

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, ProjectProfiles.t()} | {:error, keyword()}
    def cast(value) do
      case ProjectProfiles.parse(value) do
        {:ok, profiles} -> {:ok, profiles}
        {:error, reason} -> {:error, message: safe_error(reason)}
      end
    end

    @spec load(term()) :: {:ok, map()} | :error
    def load(value) when is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, map()} | :error
    def dump(value) when is_map(value), do: {:ok, value}
    def dump(_value), do: :error

    defp safe_error(:invalid_project_profiles), do: "must match the approved project-profile contract"
    defp safe_error(:key_collision), do: "contains conflicting keys"
    defp safe_error(:unsupported_version), do: "uses an unsupported version"
    defp safe_error(:unknown_fields), do: "contains unknown fields"
    defp safe_error({:missing_profiles, _profiles}), do: "must contain the complete approved profile set"
    defp safe_error(:unknown_profile), do: "contains an unapproved profile"
    defp safe_error({:duplicate_identity, field}), do: "contains duplicate #{field} values"

    defp safe_error({:profile_mismatch, key, field}),
      do: "profile #{key} does not match approved field #{field}"
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:required_labels, {:array, :string}, default: [])
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:kind, :endpoint, :api_key, :project_slug, :assignee, :required_labels, :active_states, :terminal_states],
        empty_values: []
      )
      |> update_change(:required_labels, fn labels ->
        labels
        |> Enum.map(&(String.trim(&1) |> String.downcase()))
        |> Enum.uniq()
      end)
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Claim do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @claim_call_timeout_ms 15_000

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:database_url, :string)
      field(:ca_cert_file, :string)
      field(:node_id, :string)
      field(:node_instance_id, :string)
      field(:lease_ms, :integer, default: 60_000)
      field(:heartbeat_ms, :integer, default: 20_000)
      field(:fallback_grace_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [
        :enabled,
        :database_url,
        :ca_cert_file,
        :node_id,
        :node_instance_id,
        :lease_ms,
        :heartbeat_ms,
        :fallback_grace_ms
      ])
      |> validate_number(:lease_ms, greater_than: 0)
      |> validate_number(:heartbeat_ms, greater_than: 0)
      |> validate_number(:fallback_grace_ms, greater_than_or_equal_to: 0)
      |> validate_heartbeat_before_lease()
      |> validate_renewal_window()
    end

    defp validate_heartbeat_before_lease(changeset) do
      heartbeat_ms = get_field(changeset, :heartbeat_ms)
      lease_ms = get_field(changeset, :lease_ms)

      if is_integer(heartbeat_ms) and is_integer(lease_ms) and heartbeat_ms >= lease_ms do
        add_error(changeset, :heartbeat_ms, "must be less than lease_ms")
      else
        changeset
      end
    end

    defp validate_renewal_window(changeset) do
      heartbeat_ms = get_field(changeset, :heartbeat_ms)
      lease_ms = get_field(changeset, :lease_ms)

      if is_integer(heartbeat_ms) and is_integer(lease_ms) and
           lease_ms - heartbeat_ms <= @claim_call_timeout_ms do
        add_error(changeset, :heartbeat_ms, "must leave more than #{@claim_call_timeout_ms}ms before lease expiry")
      else
        changeset
      end
    end
  end

  defmodule ReviewConvergence do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:repository, :string)
      field(:review_state, :string, default: "In Review")
      field(:in_progress_state, :string, default: "In Progress")
      field(:max_fix_rounds, :integer, default: 3)
      field(:human_owner, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:enabled, :repository, :review_state, :in_progress_state, :max_fix_rounds, :human_owner],
        empty_values: []
      )
      |> validate_number(:max_fix_rounds, greater_than: 0)
      |> validate_format(:repository, ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, message: "must use owner/name format")
      |> validate_required_if_enabled()
    end

    defp validate_required_if_enabled(changeset) do
      if get_field(changeset, :enabled) do
        validate_required(changeset, [:repository, :review_state, :in_progress_state])
      else
        changeset
      end
    end
  end

  defmodule Landing do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:mode, Ecto.Enum, values: [human: "human"], default: :human)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:mode], empty_values: [])
      |> validate_required([:mode])
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @default_runtime_state_root :filename.basedir(:user_data, "symphony_elixir")
                                |> to_string()
                                |> then(&Path.join([&1, "health", "runtime-state"]))
                                |> Path.expand()
    @primary_key false

    @type t :: %__MODULE__{}

    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
      field(:runtime_state_root, :string, default: @default_runtime_state_root)
      field(:notification_command, :string)
      field(:notification_receiver, :string)
      field(:restart_limit, :integer, default: 3)
      field(:notification_timeout_ms, :integer, default: 5_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :dashboard_enabled,
          :refresh_ms,
          :render_interval_ms,
          :runtime_state_root,
          :notification_command,
          :notification_receiver,
          :restart_limit,
          :notification_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:runtime_state_root])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
      |> validate_number(:restart_limit, greater_than: 0)
      |> validate_number(:notification_timeout_ms, greater_than: 0)
      |> validate_runtime_state_root()
      |> validate_notification_config()
    end

    defp validate_runtime_state_root(changeset) do
      validate_change(changeset, :runtime_state_root, fn :runtime_state_root, root ->
        valid? =
          is_binary(root) and String.trim(root) == root and Path.type(root) == :absolute and
            not filesystem_root?(root) and not production_path?(root) and not secret_bearing?(root)

        if valid?, do: [], else: [runtime_state_root: "must be an absolute non-Production path"]
      end)
    end

    defp validate_notification_config(changeset) do
      command = get_field(changeset, :notification_command)
      receiver = get_field(changeset, :notification_receiver)

      if is_nil(command) and is_nil(receiver) do
        changeset
      else
        changeset
        |> validate_required([:notification_command, :notification_receiver])
        |> validate_change(:notification_command, fn :notification_command, value ->
          if safe_command?(value),
            do: [],
            else: [notification_command: "must be a nonblank secret-free local command"]
        end)
        |> validate_change(:notification_receiver, fn :notification_receiver, value ->
          if safe_receiver?(value),
            do: [],
            else: [notification_receiver: "must be an opaque secret-free receiver identifier"]
        end)
      end
    end

    defp safe_command?(value) when is_binary(value) do
      byte_size(value) in 1..4_096 and String.valid?(value) and String.trim(value) != "" and
        not String.contains?(value, <<0>>) and not secret_bearing?(value)
    end

    defp safe_command?(_value), do: false

    defp safe_receiver?(value) when is_binary(value) do
      byte_size(value) in 1..128 and String.valid?(value) and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:@+-]*\z/, value) and
        not secret_bearing?(value)
    end

    defp safe_receiver?(_value), do: false

    defp secret_bearing?(value) do
      Regex.match?(~r/(?i)(authorization|bearer|credential|password|secret|api[_-]?key|token)\s*[:= ]/, value) or
        Regex.match?(~r/(?i)(^|[_:\/-])(credential|password|secret|api[_-]?key|token)([_:\/-]|$)/, value) or
        Regex.match?(~r/(?i)\bsk-(?:proj-)?[a-z0-9_-]{16,}\b/, value) or
        Regex.match?(~r/(?i)\bgh[pousr]_[a-z0-9]{20,}\b/, value) or
        Regex.match?(~r/(?i)\bgithub_pat_[a-z0-9_]{20,}\b/, value) or
        Regex.match?(~r/\b(?:AKIA|ASIA|AIDA|AROA|AIPA|ANPA|ANVA)[A-Z0-9]{16}\b/, value) or
        Regex.match?(~r/(?i)\bxox[baprs]-[a-z0-9-]{20,}\b/, value) or
        Regex.match?(~r/\bAIza[0-9A-Za-z_-]{20,}\b/, value) or
        Regex.match?(~r/(?i)\b[rs]k_(?:live|test)_[a-z0-9]{16,}\b/, value) or
        Regex.match?(~r/(?i)\b(?:glpat-|npm_|pypi-|hf_)[a-z0-9_-]{20,}\b/, value) or
        Regex.match?(~r/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/, value) or
        Regex.match?(~r/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/, value) or
        Regex.match?(~r|(?i)://[^/@\s]+:[^/@\s]+@|, value)
    end

    defp production_path?(path) do
      path
      |> Path.expand()
      |> String.split(~r{[\\/]}, trim: true)
      |> Enum.any?(&(String.downcase(&1) |> String.contains?("production")))
    end

    defp filesystem_root?(path) do
      case path |> Path.expand() |> Path.split() do
        [_root] -> true
        _parts -> false
      end
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    field(:project_profiles, ProjectProfilesType)
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:claim, Claim, on_replace: :update, defaults_to_struct: true)
    embeds_one(:review_convergence, ReviewConvergence, on_replace: :update, defaults_to_struct: true)
    embeds_one(:landing, Landing, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    with :ok <- validate_raw_project_profiles(config) do
      config
      |> normalize_keys()
      |> drop_nil_values()
      |> changeset()
      |> apply_action(:validate)
      |> case do
        {:ok, settings} ->
          settings = finalize_settings(settings)

          with :ok <- validate_runtime_state_workspace_separation(settings) do
            validate_resolved_claim_settings(settings)
          end

        {:error, changeset} ->
          {:error, {:invalid_workflow_config, format_errors(changeset)}}
      end
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:project_profiles], empty_values: [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:claim, with: &Claim.changeset/2)
    |> cast_embed(:review_convergence, with: &ReviewConvergence.changeset/2)
    |> cast_embed(:landing, with: &Landing.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
  end

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    claim = %{
      settings.claim
      | database_url: resolve_secret_setting(settings.claim.database_url, System.get_env("SYMPHONY_CLAIM_DATABASE_URL")),
        ca_cert_file: resolve_secret_setting(settings.claim.ca_cert_file, System.get_env("SYMPHONY_CLAIM_CA_CERT_FILE")),
        node_id: resolve_secret_setting(settings.claim.node_id, System.get_env("SYMPHONY_NODE_ID")),
        node_instance_id: resolve_secret_setting(settings.claim.node_instance_id, System.get_env("SYMPHONY_NODE_INSTANCE_ID"))
    }

    %{settings | tracker: tracker, workspace: workspace, codex: codex, claim: claim}
  end

  defp validate_resolved_claim_settings(%{claim: %{enabled: false}} = settings), do: {:ok, settings}

  defp validate_resolved_claim_settings(%{claim: claim} = settings) do
    missing =
      Enum.filter([:database_url, :ca_cert_file, :node_id, :node_instance_id], fn field ->
        value = Map.get(claim, field)
        not is_binary(value) or String.trim(value) == ""
      end)

    case missing do
      [] ->
        {:ok, settings}

      fields ->
        message = Enum.map_join(fields, ", ", &"claim.#{&1} can't be blank")
        {:error, {:invalid_workflow_config, message}}
    end
  end

  defp validate_runtime_state_workspace_separation(%{
         workspace: %{root: workspace_root},
         observability: %{runtime_state_root: runtime_state_root}
       })
       when is_binary(workspace_root) and is_binary(runtime_state_root) do
    if Path.type(runtime_state_root) == :absolute do
      with {:ok, canonical_workspace_root} <- PathSafety.canonicalize(Path.expand(workspace_root)),
           {:ok, canonical_runtime_state_root} <- PathSafety.canonicalize(runtime_state_root),
           false <- path_inside?(canonical_runtime_state_root, canonical_workspace_root),
           false <- path_inside?(canonical_workspace_root, canonical_runtime_state_root) do
        :ok
      else
        _invalid ->
          {:error, {:invalid_workflow_config, "observability.runtime_state_root must stay outside workspace.root"}}
      end
    else
      :ok
    end
  end

  defp validate_runtime_state_workspace_separation(_settings), do: :ok

  defp path_inside?(path, parent) do
    path = normalized_local_path(path)
    parent = parent |> normalized_local_path() |> String.trim_trailing("/")
    path == parent or String.starts_with?(path, parent <> "/")
  end

  defp normalized_local_path(path) do
    normalized = path |> Path.expand() |> String.replace("\\", "/")
    if match?({:win32, _}, :os.type()), do: String.downcase(normalized), else: normalized
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp validate_raw_project_profiles(config) do
    candidates =
      for {key, value} <- config,
          normalize_key(key) == "project_profiles",
          do: value

    case candidates do
      [] ->
        :ok

      [nil] ->
        invalid_project_profiles()

      [candidate] ->
        case ProjectProfiles.parse(candidate) do
          {:ok, _profiles} -> :ok
          {:error, _reason} -> invalid_project_profiles()
        end

      _colliding_keys ->
        invalid_project_profiles()
    end
  end

  defp invalid_project_profiles,
    do: {:error, {:invalid_workflow_config, "project_profiles must match the approved project-profile contract"}}

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
