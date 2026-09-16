defmodule SymphonyElixir.ProtectedPath.Native do
  @moduledoc false

  alias SymphonyElixir.{ProtectedPath, Workspace}

  @doc false
  @spec validate_admission_gate(Path.t()) :: :ok | ProtectedPath.validation_error()
  def validate_admission_gate(path) when is_binary(path) do
    case :os.type() do
      {:unix, _name} -> validate_unix_admission_gate(path)
      {:win32, _name} -> validate_windows_admission_gate(path)
      _unsupported -> {:error, :unsafe_protected_path}
    end
  end

  def validate_admission_gate(_path), do: {:error, :unsafe_protected_path}

  @doc false
  @spec validate_secret_file(Path.t()) :: :ok | ProtectedPath.validation_error()
  def validate_secret_file(path) when is_binary(path) do
    case :os.type() do
      {:unix, _name} -> validate_unix_secret_file(path)
      {:win32, _name} -> validate_windows_secret_file(path)
      _unsupported -> {:error, :unsafe_protected_path}
    end
  end

  def validate_secret_file(_path), do: {:error, :unsafe_protected_path}

  defp validate_unix_admission_gate(path) do
    with {:ok, effective_uid} <- effective_uid(),
         {:ok, getfacl} <- trusted_executable("getfacl", effective_uid),
         :ok <- validate_unix_ancestors(Path.dirname(path), effective_uid, getfacl, :trusted),
         :ok <- validate_unix_optional_gate(path, effective_uid, getfacl) do
      :ok
    else
      _failure -> {:error, :unsafe_protected_path}
    end
  end

  defp validate_unix_secret_file(path) do
    with {:ok, effective_uid} <- effective_uid(),
         {:ok, getfacl} <- trusted_executable("getfacl", effective_uid),
         :ok <- validate_unix_ancestors(Path.dirname(path), effective_uid, getfacl, :controller),
         :ok <- validate_unix_secret_entry(path, effective_uid, getfacl) do
      :ok
    else
      _failure -> {:error, :unsafe_protected_path}
    end
  end

  defp validate_unix_ancestors(path, effective_uid, getfacl, immediate_owner) do
    path
    |> path_and_ancestors()
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {component, index}, :ok ->
      required_mode = if index == 0, do: 0o700, else: nil
      owner_policy = if index == 0, do: immediate_owner, else: :trusted

      result =
        with :ok <- Workspace.validate_non_reparse_directory_for_worker(component),
             {:ok, stat} <- File.stat(component, time: :posix),
             {:ok, acl_output} <- read_posix_acl(component, getfacl),
             :ok <-
               ProtectedPath.validate_posix_directory_evidence(
                 stat,
                 effective_uid,
                 required_mode,
                 owner_policy,
                 acl_output
               ) do
          :ok
        else
          _failure -> {:error, :unsafe_protected_path}
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_unix_optional_gate(path, effective_uid, getfacl) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        with :ok <- Workspace.validate_non_reparse_regular_file_for_worker(path),
             {:ok, stat} <- File.stat(path, time: :posix),
             {:ok, acl_output} <- read_posix_acl(path, getfacl),
             :ok <- ProtectedPath.validate_posix_gate_evidence(stat, effective_uid, acl_output) do
          :ok
        else
          _failure -> {:error, :unsafe_protected_path}
        end

      _unsafe ->
        {:error, :unsafe_protected_path}
    end
  end

  defp validate_unix_secret_entry(path, effective_uid, getfacl) do
    with :ok <- Workspace.validate_non_reparse_regular_file_for_worker(path),
         {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, acl_output} <- read_posix_acl(path, getfacl),
         :ok <- ProtectedPath.validate_posix_secret_evidence(stat, effective_uid, acl_output) do
      :ok
    else
      _failure -> {:error, :unsafe_protected_path}
    end
  end

  defp read_posix_acl(path, getfacl) do
    case System.cmd(
           getfacl,
           ["--absolute-names", "--numeric", "--omit-header", path],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      _failure -> {:error, :unsafe_protected_path}
    end
  rescue
    _error -> {:error, :unsafe_protected_path}
  catch
    _kind, _reason -> {:error, :unsafe_protected_path}
  end

  defp validate_windows_admission_gate(path) do
    with {:ok, controller_sid} <-
           validate_windows_ancestors(Path.dirname(path), :gate_parent),
         :ok <- validate_windows_optional_gate(path, controller_sid) do
      :ok
    else
      _failure -> {:error, :unsafe_protected_path}
    end
  end

  defp validate_windows_secret_file(path) do
    with {:ok, controller_sid} <-
           validate_windows_ancestors(Path.dirname(path), :secret_parent),
         :ok <- Workspace.validate_non_reparse_regular_file_for_worker(path),
         {:ok, evidence, ^controller_sid} <- read_windows_acl(path),
         :ok <- ProtectedPath.validate_windows_acl_evidence(evidence, :secret_entry, controller_sid) do
      :ok
    else
      _failure -> {:error, :unsafe_protected_path}
    end
  end

  defp validate_windows_ancestors(path, immediate_policy) do
    [immediate | ancestors] = path_and_ancestors(path)

    with :ok <- Workspace.validate_non_reparse_directory_for_worker(immediate),
         {:ok, evidence, controller_sid} <- read_windows_acl(immediate),
         :ok <- ProtectedPath.validate_windows_acl_evidence(evidence, immediate_policy, controller_sid),
         :ok <- validate_windows_higher_ancestors(ancestors, controller_sid) do
      {:ok, controller_sid}
    else
      _failure -> {:error, :unsafe_protected_path}
    end
  end

  defp validate_windows_higher_ancestors(ancestors, controller_sid) do
    Enum.reduce_while(ancestors, :ok, fn component, :ok ->
      result =
        with :ok <- Workspace.validate_non_reparse_directory_for_worker(component),
             {:ok, evidence, ^controller_sid} <- read_windows_acl(component),
             :ok <- ProtectedPath.validate_windows_acl_evidence(evidence, :ancestor, controller_sid) do
          :ok
        else
          _failure -> {:error, :unsafe_protected_path}
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_windows_optional_gate(path, controller_sid) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        with :ok <- Workspace.validate_non_reparse_regular_file_for_worker(path),
             {:ok, evidence, ^controller_sid} <- read_windows_acl(path),
             :ok <- ProtectedPath.validate_windows_acl_evidence(evidence, :gate_entry, controller_sid) do
          :ok
        else
          _failure -> {:error, :unsafe_protected_path}
        end

      _unsafe ->
        {:error, :unsafe_protected_path}
    end
  end

  defp read_windows_acl(path) do
    with {:ok, executable} <- powershell_executable(),
         {:ok, script} <- windows_helper_script(),
         {output, 0} <-
           System.cmd(
             executable,
             ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script],
             env: [{"SYMPHONY_PROTECTED_PATH_TARGET", path}],
             stderr_to_stdout: true
           ),
         {:ok,
          %{
            "currentSid" => current_sid,
            "owner" => owner,
            "protected" => protected,
            "daclPresent" => dacl_present,
            "rules" => rules
          } = evidence} <- Jason.decode(output),
         true <- valid_windows_sid?(current_sid),
         true <- valid_windows_sid?(owner),
         true <- is_boolean(protected),
         true <- dacl_present == true,
         true <- is_list(rules) do
      {:ok, Map.take(evidence, ["owner", "protected", "daclPresent", "rules"]), current_sid}
    else
      _failure -> {:error, :unsafe_protected_path}
    end
  rescue
    _error -> {:error, :unsafe_protected_path}
  catch
    _kind, _reason -> {:error, :unsafe_protected_path}
  end

  defp powershell_executable do
    with root when is_binary(root) and root != "" <-
           System.get_env("SystemRoot") || System.get_env("SYSTEMROOT"),
         :absolute <- Path.type(root),
         executable =
           Path.join([root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"]),
         true <- File.regular?(executable) do
      {:ok, executable}
    else
      _failure -> {:error, :unsafe_protected_path}
    end
  end

  defp windows_helper_script do
    case :code.priv_dir(:symphony_elixir) do
      directory when is_list(directory) ->
        script = directory |> List.to_string() |> Path.join("protected_path_windows.ps1")

        case Workspace.validate_non_reparse_regular_file_for_worker(script) do
          :ok -> {:ok, script}
          _unsafe -> {:error, :unsafe_protected_path}
        end

      _failure ->
        {:error, :unsafe_protected_path}
    end
  end

  defp effective_uid do
    with {:ok, executable} <- trusted_executable_without_uid("id"),
         {output, 0} <- System.cmd(executable, ["-u"], stderr_to_stdout: true),
         trimmed = String.trim(output),
         true <- Regex.match?(~r/\A[0-9]{1,10}\z/, trimmed),
         {uid, ""} <- Integer.parse(trimmed) do
      {:ok, uid}
    else
      _failure -> {:error, :unsafe_protected_path}
    end
  rescue
    _error -> {:error, :unsafe_protected_path}
  catch
    _kind, _reason -> {:error, :unsafe_protected_path}
  end

  defp trusted_executable_without_uid(name) do
    [Path.join("/usr/bin", name), Path.join("/bin", name)]
    |> Enum.find(&File.regular?/1)
    |> case do
      executable when is_binary(executable) -> {:ok, executable}
      nil -> {:error, :unsafe_protected_path}
    end
  end

  defp trusted_executable(name, effective_uid) do
    case System.find_executable(name) do
      executable when is_binary(executable) ->
        executable = Path.expand(executable)

        with :absolute <- Path.type(executable),
             {:ok, %File.Stat{type: :regular, uid: uid, mode: mode}} <-
               File.lstat(executable, time: :posix),
             true <- uid in [0, effective_uid],
             0 <- Bitwise.band(mode, 0o022),
             :ok <- validate_tool_ancestors(Path.dirname(executable), effective_uid) do
          {:ok, executable}
        else
          _failure -> {:error, :unsafe_protected_path}
        end

      _missing ->
        {:error, :unsafe_protected_path}
    end
  end

  defp validate_tool_ancestors(path, effective_uid) do
    path
    |> path_and_ancestors()
    |> Enum.reduce_while(:ok, fn component, :ok ->
      component
      |> File.lstat(time: :posix)
      |> classify_tool_ancestor(effective_uid)
    end)
  end

  defp classify_tool_ancestor(
         {:ok, %File.Stat{type: :directory, uid: uid, mode: mode}},
         effective_uid
       ) do
    if uid in [0, effective_uid] and Bitwise.band(mode, 0o022) == 0,
      do: {:cont, :ok},
      else: {:halt, {:error, :unsafe_protected_path}}
  end

  defp classify_tool_ancestor(_unsafe, _effective_uid),
    do: {:halt, {:error, :unsafe_protected_path}}

  defp valid_windows_sid?(sid) when is_binary(sid),
    do: Regex.match?(~r/\AS-[0-9]+(?:-[0-9]+)+\z/, sid)

  defp valid_windows_sid?(_invalid), do: false

  defp path_and_ancestors(path) do
    Stream.unfold(Path.expand(path), fn
      nil ->
        nil

      current ->
        parent = Path.dirname(current)
        {current, if(parent == current, do: nil, else: parent)}
    end)
    |> Enum.to_list()
  end
end
