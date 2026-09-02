defmodule SymphonyElixir.RuntimeReceiptContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RuntimeReceiptContract

  test "publishes the shared integer and encoded receipt ceilings" do
    assert RuntimeReceiptContract.max_routing_revision() == 9_223_372_036_854_775_807
    assert RuntimeReceiptContract.max_restart_attempt() == 9_223_372_036_854_775_807
    assert RuntimeReceiptContract.max_encoded_bytes() == 96 * 1_024
  end

  test "rejects non-string UTC timestamps" do
    refute RuntimeReceiptContract.valid_utc_timestamp?(nil)
  end

  test "fails closed for a malformed DateTime struct" do
    malformed = %DateTime{
      year: 2026,
      month: 1,
      day: 1,
      hour: 0,
      minute: 0,
      second: 0,
      microsecond: {0, 0},
      time_zone: "Etc/UTC",
      zone_abbr: "UTC",
      utc_offset: :invalid,
      std_offset: 0,
      calendar: Calendar.ISO
    }

    assert {:error, :invalid_timestamp} = RuntimeReceiptContract.canonical_utc_timestamp(malformed)
  end
end
