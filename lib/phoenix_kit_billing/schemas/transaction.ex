defmodule PhoenixKitBilling.Transaction do
  @moduledoc """
  Schema for payment transactions.

  Transactions record actual payments and refunds for invoices.
  - Positive amount = payment
  - Negative amount = refund

  Transactions are created when:
  - Admin marks invoice as paid (creates payment transaction)
  - Admin issues a refund (creates refund transaction)

  There are no pending/failed statuses - a transaction is only recorded
  when the payment/refund has actually occurred.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKitBilling.Invoice

  # Every provider a payment can arrive through must be listed: the webhook
  # processor records a provider payment with `payment_method: "<provider>"`.
  # EveryPay was added as a provider without being added here, so every
  # EveryPay payment failed its insert — the customer charged, the invoice
  # left unpaid. `Providers.all_providers/0` is pinned to this list by a test.
  @payment_methods ~w(bank stripe paypal razorpay everypay)

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_transactions" do
    field(:transaction_number, :string)
    field(:amount, :decimal)
    field(:currency, :string)
    field(:payment_method, :string, default: "bank")
    field(:description, :string)
    field(:metadata, :map, default: %{})

    # For future payment provider integrations
    field(:provider_transaction_id, :string)
    field(:provider_data, :map, default: %{})

    belongs_to(:invoice, Invoice, foreign_key: :invoice_uuid, references: :uuid, type: UUIDv7)
    # User reference (cross-package — FK constraint in core migrations)
    field(:user_uuid, UUIDv7)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a transaction.
  """
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :transaction_number,
      :amount,
      :currency,
      :payment_method,
      :description,
      :metadata,
      :provider_transaction_id,
      :provider_data,
      :invoice_uuid,
      :user_uuid
    ])
    |> validate_required([
      :transaction_number,
      :amount,
      :currency,
      :payment_method,
      :invoice_uuid
    ])
    # No user required: a provider-confirmed payment on a GUEST invoice has
    # neither an admin actor nor an invoice user. Requiring one failed the
    # insert after the card was charged (billing V5 dropped the column's
    # NOT NULL for the same reason).
    |> validate_inclusion(:payment_method, @payment_methods)
    |> validate_number(:amount, not_equal_to: 0)
    |> validate_length(:currency, is: 3)
    |> unique_constraint(:transaction_number,
      name: :phoenix_kit_transactions_transaction_number_uidx
    )
    |> foreign_key_constraint(:invoice_uuid)
    |> foreign_key_constraint(:user_uuid)
  end

  @doc """
  Returns true if this transaction is a payment (positive amount).
  """
  def payment?(%__MODULE__{amount: amount}) do
    Decimal.positive?(amount)
  end

  @doc """
  Returns true if this transaction is a refund (negative amount).
  """
  def refund?(%__MODULE__{amount: amount}) do
    Decimal.negative?(amount)
  end

  @doc """
  Returns the transaction type as a string.
  """
  def type(%__MODULE__{} = transaction) do
    if payment?(transaction), do: "payment", else: "refund"
  end

  @doc """
  Returns the absolute amount (always positive).
  """
  def absolute_amount(%__MODULE__{amount: amount}) do
    Decimal.abs(amount)
  end

  @doc """
  Returns the list of valid payment methods.
  """
  def payment_methods, do: @payment_methods
end
