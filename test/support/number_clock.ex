defmodule PhoenixKitBilling.Test.NumberClock do
  @moduledoc """
  Test double for the `:number_clock` config key (`utc_today/0` of the module
  that dates a document number). A test calls `set/1` with the dates the next
  reads return, in order, the last one repeating; `reads/0` says how many
  times the clock was asked. Without `set/1` it is `Date`. The script lives in
  the process dictionary of the test process, like `StaticFxRateProvider`.
  """

  @script :phoenix_kit_billing_test_number_clock_script
  @reads :phoenix_kit_billing_test_number_clock_reads

  @spec set([Date.t(), ...]) :: :ok
  def set([_ | _] = dates) do
    Process.put(@script, dates)
    Process.put(@reads, 0)
    :ok
  end

  @spec reads() :: non_neg_integer()
  def reads, do: Process.get(@reads, 0)

  @spec utc_today() :: Date.t()
  def utc_today do
    case Process.get(@script) do
      nil ->
        Date.utc_today()

      [date] ->
        read(date)

      [date | rest] ->
        Process.put(@script, rest)
        read(date)
    end
  end

  defp read(date) do
    Process.put(@reads, reads() + 1)
    date
  end
end
