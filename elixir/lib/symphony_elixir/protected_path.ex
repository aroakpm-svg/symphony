defmodule SymphonyElixir.ProtectedPath do
  @moduledoc false

  alias SymphonyElixir.ProtectedPath.Native

  @system_sid "S-1-5-18"
  @administrators_sid "S-1-5-32-544"
  @windows_ancestor_safe_rights 0x001200A9

  @type validation_error :: {:error, :unsafe_protected_path}

  @doc false
  @spec validate_admission_gate(Path.t()) :: :ok | validation_error()
  def validate_admission_gate(path), do: Native.validate_admission_gate(path)

  @doc false
  @spec validate_secret_file(Path.t()) :: :ok | validation_error()
  def validate_secret_file(path), do: Native.validate_secret_file(path)

  @doc false
  @spec validate_posix_directory_evidence(
          term(),
          non_neg_integer(),
          0o700 | nil,
          :controller | :trusted,
          term()
        ) :: :ok | validation_error()
  def validate_posix_directory_evidence(
        %File.Stat{type: :directory, uid: uid, mode: mode},
        effective_uid,
        required_mode,
        owner_policy,
        acl_output
      )
      when is_integer(effective_uid) and effective_uid >= 0 and
             required_mode in [0o700, nil] and owner_policy in [:controller, :trusted] do
    with true <- permitted_posix_owner?(uid, effective_uid, owner_policy),
         :ok <- validate_posix_directory_mode(mode, required_mode),
         :ok <- validate_posix_acl_output(acl_output) do
      :ok
    else
      _unsafe -> {:error, :unsafe_protected_path}
    end
  end

  def validate_posix_directory_evidence(
        _stat,
        _effective_uid,
        _required_mode,
        _owner_policy,
        _acl_output
      ),
      do: {:error, :unsafe_protected_path}

  @doc false
  @spec validate_posix_gate_evidence(term(), non_neg_integer(), term()) ::
          :ok | validation_error()
  def validate_posix_gate_evidence(
        %File.Stat{type: :regular, uid: uid, mode: mode},
        effective_uid,
        acl_output
      )
      when is_integer(effective_uid) and effective_uid >= 0 do
    with true <- uid in [0, effective_uid],
         0 <- Bitwise.band(mode, 0o022),
         :ok <- validate_posix_acl_output(acl_output) do
      :ok
    else
      _unsafe -> {:error, :unsafe_protected_path}
    end
  end

  def validate_posix_gate_evidence(_stat, _effective_uid, _acl_output),
    do: {:error, :unsafe_protected_path}

  @doc false
  @spec validate_posix_secret_evidence(term(), non_neg_integer(), term()) ::
          :ok | validation_error()
  def validate_posix_secret_evidence(
        %File.Stat{type: :regular, uid: effective_uid, mode: mode},
        effective_uid,
        acl_output
      )
      when is_integer(effective_uid) and effective_uid >= 0 do
    with 0o600 <- Bitwise.band(mode, 0o777),
         :ok <- validate_posix_acl_output(acl_output) do
      :ok
    else
      _unsafe -> {:error, :unsafe_protected_path}
    end
  end

  def validate_posix_secret_evidence(_stat, _effective_uid, _acl_output),
    do: {:error, :unsafe_protected_path}

  @doc false
  @spec validate_posix_acl_output(term()) :: :ok | validation_error()
  def validate_posix_acl_output(output) when is_binary(output) do
    entries = output |> String.split("\n", trim: true) |> Enum.sort()

    if base_acl_entries?(entries),
      do: :ok,
      else: {:error, :unsafe_protected_path}
  end

  def validate_posix_acl_output(_output), do: {:error, :unsafe_protected_path}

  @doc false
  @spec validate_windows_acl_evidence(term(), atom(), term()) :: :ok | validation_error()
  def validate_windows_acl_evidence(
        %{
          "owner" => owner,
          "protected" => protected,
          "daclPresent" => true,
          "rules" => rules
        },
        policy,
        controller_sid
      )
      when policy in [:secret_entry, :secret_parent, :gate_entry, :gate_parent, :ancestor] and
             is_binary(owner) and is_boolean(protected) and is_list(rules) and
             is_binary(controller_sid) do
    trusted_sids = [controller_sid, @system_sid, @administrators_sid]

    with true <- valid_windows_sid?(controller_sid),
         true <- permitted_windows_owner?(owner, policy, controller_sid, trusted_sids),
         true <- permitted_windows_inheritance?(protected, policy),
         true <- Enum.all?(rules, &valid_windows_rule?/1),
         true <- Enum.all?(rules, &permitted_windows_rule?(&1, policy, trusted_sids)) do
      :ok
    else
      _unsafe -> {:error, :unsafe_protected_path}
    end
  end

  def validate_windows_acl_evidence(_evidence, _policy, _controller_sid),
    do: {:error, :unsafe_protected_path}

  defp permitted_posix_owner?(uid, effective_uid, :controller), do: uid == effective_uid
  defp permitted_posix_owner?(uid, effective_uid, :trusted), do: uid in [0, effective_uid]

  defp validate_posix_directory_mode(mode, 0o700) do
    if Bitwise.band(mode, 0o777) == 0o700,
      do: :ok,
      else: {:error, :unsafe_protected_path}
  end

  defp validate_posix_directory_mode(mode, nil) do
    if Bitwise.band(mode, 0o022) == 0,
      do: :ok,
      else: {:error, :unsafe_protected_path}
  end

  defp base_acl_entries?(entries) do
    Enum.count(entries) == 3 and
      Enum.any?(entries, &Regex.match?(~r/\Auser::[rwx-]{3}\z/, &1)) and
      Enum.any?(entries, &Regex.match?(~r/\Agroup::[rwx-]{3}\z/, &1)) and
      Enum.any?(entries, &Regex.match?(~r/\Aother::[rwx-]{3}\z/, &1))
  end

  defp permitted_windows_owner?(owner, policy, controller_sid, _trusted_sids)
       when policy in [:secret_entry, :secret_parent],
       do: owner == controller_sid

  defp permitted_windows_owner?(owner, _policy, _controller_sid, trusted_sids),
    do: owner in trusted_sids

  defp permitted_windows_inheritance?(protected, policy)
       when policy in [:secret_entry, :secret_parent, :gate_parent],
       do: protected

  defp permitted_windows_inheritance?(_protected, _policy), do: true

  defp valid_windows_rule?(%{"sid" => sid, "type" => type, "rights" => rights}) do
    valid_windows_sid?(sid) and type in ["Allow", "Deny"] and is_integer(rights) and rights >= 0
  end

  defp valid_windows_rule?(_invalid), do: false

  defp permitted_windows_rule?(%{"type" => "Deny"}, _policy, _trusted_sids), do: true

  defp permitted_windows_rule?(%{"sid" => sid}, policy, trusted_sids)
       when policy in [:secret_entry, :secret_parent, :gate_entry, :gate_parent],
       do: sid in trusted_sids

  defp permitted_windows_rule?(%{"sid" => sid, "rights" => rights}, :ancestor, trusted_sids) do
    sid in trusted_sids or Bitwise.band(rights, @windows_ancestor_safe_rights) == rights
  end

  defp valid_windows_sid?(sid) when is_binary(sid),
    do: Regex.match?(~r/\AS-[0-9]+(?:-[0-9]+)+\z/, sid)

  defp valid_windows_sid?(_invalid), do: false
end
