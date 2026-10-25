defmodule PhoenixKitBilling.NumberSequence do
  @moduledoc """
  The counter behind order, invoice, receipt and transaction numbers: the last
  value handed out for a scope (`"order"`, `"invoice"`, `"receipt"` or
  `"transaction"`) in a year.

  The context takes the next value inside the transaction that inserts the row
  using it (see `PhoenixKitBilling`), so nothing else reads or writes this
  table. Created by migration V7.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key false

  schema "phoenix_kit_billing_number_sequences" do
    field(:scope, :string, primary_key: true)
    field(:year, :integer, primary_key: true)
    field(:last_value, :integer)
    field(:updated_at, :utc_datetime)
  end
end
