defmodule SymphonyElixir.RuntimeReceiptContract do
  @moduledoc """
  Defines the portable field and encoded-size limits for runtime stop receipts.

  All string limits are UTF-8 bytes. Routing revisions and restart attempts are
  positive signed 64-bit integers so Elixir, PowerShell 7, and Windows PowerShell 5
  share one numeric domain.
  """

  @string_max_bytes %{
    at: 20,
    category: 15,
    receipt_path: 4_096,
    runtime_epoch: 128,
    profile_key: 128,
    issue_id: 128,
    issue_identifier: 128,
    repository: 256,
    workspace_namespace: 128,
    environment: 20,
    failure_category: 34,
    canonical_branch: 256,
    detail: 8_192
  }
  @max_routing_revision 9_223_372_036_854_775_807
  @max_iso8601_input_bytes 64
  @canonical_utc_timestamp ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

  # A UTF-8 byte can expand to at most six JSON bytes as a \u00XX escape. The extra
  # 1 KiB covers every fixed key, delimiter, boolean/null value, and the 19-digit integer.
  @worst_case_encoded_bytes Enum.sum(Map.values(@string_max_bytes)) * 6 + 1_024
  @max_encoded_bytes 96 * 1_024

  if @worst_case_encoded_bytes > @max_encoded_bytes do
    raise "runtime receipt encoded ceiling does not cover its field maxima"
  end

  @type string_field ::
          :at
          | :category
          | :receipt_path
          | :runtime_epoch
          | :profile_key
          | :issue_id
          | :issue_identifier
          | :repository
          | :workspace_namespace
          | :environment
          | :failure_category
          | :canonical_branch
          | :detail

  @spec max_string_bytes(string_field()) :: pos_integer()
  def max_string_bytes(field), do: Map.fetch!(@string_max_bytes, field)

  @spec valid_string_size?(string_field(), binary()) :: boolean()
  def valid_string_size?(field, value) when is_binary(value) do
    byte_size(value) in 1..max_string_bytes(field)
  end

  @spec within_string_limit?(string_field(), binary()) :: boolean()
  def within_string_limit?(field, value) when is_binary(value) do
    byte_size(value) <= max_string_bytes(field)
  end

  @spec max_routing_revision() :: pos_integer()
  def max_routing_revision, do: @max_routing_revision

  @spec valid_routing_revision?(term()) :: boolean()
  def valid_routing_revision?(value) do
    is_integer(value) and value in 1..@max_routing_revision
  end

  @spec max_restart_attempt() :: pos_integer()
  def max_restart_attempt, do: @max_routing_revision

  @spec valid_restart_attempt?(term()) :: boolean()
  def valid_restart_attempt?(value), do: valid_routing_revision?(value)

  @spec canonical_utc_timestamp(term()) :: {:ok, String.t()} | {:error, :invalid_timestamp}
  def canonical_utc_timestamp(%DateTime{} = datetime), do: normalize_utc_timestamp(datetime)

  def canonical_utc_timestamp(value)
      when is_binary(value) and byte_size(value) in 1..@max_iso8601_input_bytes do
    with true <- String.valid?(value),
         {:ok, %DateTime{} = datetime, _offset} <- DateTime.from_iso8601(value) do
      normalize_utc_timestamp(datetime)
    else
      _invalid -> {:error, :invalid_timestamp}
    end
  end

  def canonical_utc_timestamp(_value), do: {:error, :invalid_timestamp}

  @spec valid_utc_timestamp?(term()) :: boolean()
  def valid_utc_timestamp?(value) when is_binary(value) do
    byte_size(value) == @string_max_bytes.at and String.valid?(value) and
      Regex.match?(@canonical_utc_timestamp, value) and
      match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(value))
  end

  def valid_utc_timestamp?(_value), do: false

  @spec truncate_detail(String.t()) :: String.t()
  def truncate_detail(value) when byte_size(value) <= @string_max_bytes.detail, do: value

  def truncate_detail(value) when is_binary(value) do
    value
    |> binary_part(0, @string_max_bytes.detail)
    |> trim_incomplete_utf8()
  end

  @spec max_encoded_bytes() :: pos_integer()
  def max_encoded_bytes, do: @max_encoded_bytes

  @spec valid_encoded_size?(binary()) :: boolean()
  def valid_encoded_size?(payload) when is_binary(payload) do
    byte_size(payload) in 1..@max_encoded_bytes
  end

  defp trim_incomplete_utf8(value) do
    if String.valid?(value) do
      value
    else
      value |> binary_part(0, byte_size(value) - 1) |> trim_incomplete_utf8()
    end
  end

  defp normalize_utc_timestamp(datetime) do
    with unix_seconds when is_integer(unix_seconds) <- DateTime.to_unix(datetime, :second),
         {:ok, utc_datetime} <- DateTime.from_unix(unix_seconds, :second),
         timestamp = DateTime.to_iso8601(utc_datetime),
         true <- valid_utc_timestamp?(timestamp) do
      {:ok, timestamp}
    else
      _invalid -> {:error, :invalid_timestamp}
    end
  rescue
    _exception -> {:error, :invalid_timestamp}
  end
end
