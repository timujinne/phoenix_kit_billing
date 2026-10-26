defmodule PhoenixKitBilling.Invoice do
  @moduledoc """
  Invoice schema for PhoenixKit Billing system.

  Invoices are generated from orders and sent to customers for payment.
  They include receipt functionality once payment is confirmed.

  ## Schema Fields

  ### Identity & Relations
  - `user_uuid`: Foreign key to the user
  - `order_uuid`: Foreign key to the source order (optional)
  - `invoice_number`: Unique invoice identifier (e.g., "INV-2024-0001")
  - `status`: Invoice status workflow

  ### Financial
  - `subtotal`, `tax_amount`, `tax_rate`, `total`: Financial amounts
  - `currency`: ISO 4217 currency code
  - `due_date`: Payment due date

  ### Billing Details
  - `billing_details`: Full snapshot of billing profile
  - `line_items`: Copy of order line items
  - `payment_terms`: Payment terms text
  - `bank_details`: Bank account for payment

  ### Receipt
  - `receipt_number`: Receipt identifier (generated after payment)
  - `receipt_generated_at`: When receipt was generated
  - `receipt_data`: Additional receipt data (PDF URL, etc.)

  ### Trash
  - `trashed_at`, `trashed_by_uuid`: when and by whom a draft invoice was moved
    to the trash (`nil` while it is not in it). Billing's own: `changeset/2`
    cannot set or clear them, only `PhoenixKitBilling.trash_invoice/2` and
    `restore_invoice/2` write them. Only a draft that was never sent can be
    trashed; an issued invoice is voided instead.

  ## Status Workflow

  ```
  draft → sent → paid
              ↘
             overdue → paid
              ↘
              void
  ```

  ## Usage Examples

      # Generate invoice from order
      {:ok, invoice} = Billing.create_invoice_from_order(order)

      # Send invoice
      {:ok, invoice, _email_result} = Billing.send_invoice(invoice)

      # Mark as paid (generates receipt)
      {:ok, invoice} = Billing.mark_invoice_paid(invoice)

      # Get receipt
      receipt = Billing.get_receipt(invoice)
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitBilling.Order
  alias PhoenixKitBilling.Transaction

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @valid_statuses ~w(draft sent paid void overdue)

  schema "phoenix_kit_invoices" do
    field(:invoice_number, :string)
    field(:status, :string, default: "draft")

    # Financial
    field(:subtotal, :decimal, default: Decimal.new("0"))
    field(:tax_amount, :decimal, default: Decimal.new("0"))
    field(:tax_rate, :decimal, default: Decimal.new("0"))
    field(:total, :decimal)
    field(:paid_amount, :decimal, default: Decimal.new("0"))
    field(:currency, :string)
    field(:due_date, :date)

    # Billing details (snapshot)
    field(:billing_details, :map, default: %{})
    field(:line_items, {:array, :map}, default: [])
    field(:payment_terms, :string)
    field(:bank_details, :map, default: %{})
    field(:notes, :string)

    field(:metadata, :map, default: %{})

    # Receipt (integrated)
    field(:receipt_number, :string)
    field(:receipt_generated_at, :utc_datetime)
    field(:receipt_data, :map, default: %{})

    # Timestamps
    field(:sent_at, :utc_datetime)
    field(:paid_at, :utc_datetime)
    field(:voided_at, :utc_datetime)

    # Billing's own: written by `PhoenixKitBilling.trash_invoice/2` and
    # `restore_invoice/2` only, never cast from params.
    field(:trashed_at, :utc_datetime)
    field(:trashed_by_uuid, UUIDv7)

    # User reference (cross-package — FK constraint in core migrations)
    field(:user_uuid, UUIDv7)

    belongs_to(:user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7,
      define_field: false
    )

    belongs_to(:order, Order, foreign_key: :order_uuid, references: :uuid, type: UUIDv7)
    field(:subscription_uuid, UUIDv7)
    has_many(:transactions, Transaction, foreign_key: :invoice_uuid, references: :uuid)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for invoice creation.
  """
  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [
      :user_uuid,
      :order_uuid,
      :subscription_uuid,
      :invoice_number,
      :status,
      :subtotal,
      :tax_amount,
      :tax_rate,
      :total,
      :paid_amount,
      :currency,
      :due_date,
      :billing_details,
      :line_items,
      :payment_terms,
      :bank_details,
      :notes,
      :metadata,
      :receipt_number,
      :receipt_generated_at,
      :receipt_data,
      :sent_at,
      :paid_at,
      :voided_at
    ])
    |> keep_void_trail()
    |> keep_status()
    |> validate_required([:total, :currency])
    |> validate_payer()
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_length(:currency, is: 3)
    |> validate_number(:total, greater_than_or_equal_to: 0)
    |> validate_number(:paid_amount, greater_than_or_equal_to: 0)
    |> validate_line_items()
    |> unique_constraint(:invoice_number, name: :phoenix_kit_invoices_invoice_number_uidx)
    # The constraints are named by core's migration chain, not by Ecto's
    # `<table>_<field>_fkey` default, so they must be named explicitly or
    # Postgres' error never matches and a bad reference raises
    # `Ecto.ConstraintError` (a 500) instead of returning a changeset error.
    |> foreign_key_constraint(:user_uuid, name: :fk_invoices_user_uuid)
    |> foreign_key_constraint(:order_uuid, name: :fk_invoices_order_uuid)
    |> check_constraint(:user_uuid,
      name: :phoenix_kit_invoices_payer_check,
      message: "an invoice needs a user or a billing email"
    )
  end

  # `metadata["void"]` is billing's own (written by `PhoenixKitBilling.void_invoice/3`
  # and `record_payment_after_void/2`): an input can neither forge it nor wipe
  # it. A new invoice has none; a stored one keeps what it has.
  defp keep_void_trail(changeset) do
    case fetch_change(changeset, :metadata) do
      {:ok, %{} = metadata} ->
        kept = Map.take(changeset.data.metadata || %{}, ["void"])
        put_change(changeset, :metadata, metadata |> Map.drop(["void"]) |> Map.merge(kept))

      _ ->
        changeset
    end
  end

  # A stored invoice's status moves only through send, void and pay, which
  # check it on the locked row. An edit that carried a status along could undo
  # a void.
  defp keep_status(%Ecto.Changeset{data: %{__meta__: %{state: :loaded}}} = changeset) do
    if get_change(changeset, :status) do
      add_error(changeset, :status, "can only change by sending, voiding or paying the invoice")
    else
      changeset
    end
  end

  defp keep_status(changeset), do: changeset

  # A payer is EITHER a registered user OR someone reachable by email —
  # a guest paying for a booking has no account, and inventing one for
  # them splits their history and answers GDPR requests wrongly. The same
  # rule is a CHECK in the database (billing V5), so a direct insert cannot
  # skip it either.
  defp validate_payer(changeset) do
    user = get_field(changeset, :user_uuid)
    email = changeset |> get_field(:billing_details) |> payer_email()

    if is_nil(user) and is_nil(email) do
      add_error(changeset, :user_uuid, "an invoice needs a user or a billing email")
    else
      changeset
    end
  end

  @doc """
  The email a guest invoice is addressed to — `billing_details["email"]`
  (string or atom key), or nil when blank.
  """
  def payer_email(%{} = details) do
    case Map.get(details, "email") || Map.get(details, :email) do
      email when is_binary(email) ->
        case String.trim(email) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  def payer_email(_), do: nil

  @doc """
  The name to print for an individual payer: `first_name last_name`, else
  `name`, else — for a guest who gave only an email — `payer_email/1`.
  """
  def payer_name(%{} = details) do
    full =
      [details["first_name"], details["last_name"]]
      |> Enum.filter(&present?/1)
      |> Enum.join(" ")

    cond do
      full != "" -> full
      present?(details["name"]) -> details["name"]
      true -> payer_email(details)
    end
  end

  def payer_name(_), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp validate_line_items(changeset) do
    case get_change(changeset, :line_items) do
      nil ->
        changeset

      items when is_list(items) ->
        items
        |> Enum.with_index()
        |> Enum.reduce(changeset, fn {item, idx}, acc -> validate_line_item(acc, item, idx) end)

      _ ->
        add_error(changeset, :line_items, "must be a list")
    end
  end

  defp validate_line_item(changeset, item, idx) when is_map(item) do
    name = string_field(item, "name", "name")
    quantity = numeric_field(item, "quantity", "quantity")
    total = numeric_field(item, "total", "total")

    cond do
      is_nil(name) or name == "" ->
        add_error(changeset, :line_items, "line item #{idx + 1}: name is required")

      is_nil(quantity) or quantity <= 0 ->
        add_error(changeset, :line_items, "line item #{idx + 1}: quantity must be positive")

      is_nil(total) ->
        add_error(changeset, :line_items, "line item #{idx + 1}: total is required")

      true ->
        changeset
    end
  end

  defp validate_line_item(changeset, _item, idx) do
    add_error(changeset, :line_items, "line item #{idx + 1}: must be a map")
  end

  defp string_field(item, atom_key, string_key) do
    case Map.get(item, atom_key, Map.get(item, string_key)) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp numeric_field(item, atom_key, string_key) do
    case Map.get(item, atom_key, Map.get(item, string_key)) do
      v when is_integer(v) ->
        v

      v when is_float(v) ->
        v

      v when is_binary(v) ->
        case Float.parse(v) do
          {n, _} -> n
          :error -> nil
        end

      %Decimal{} = v ->
        Decimal.to_float(v)

      _ ->
        nil
    end
  end

  @doc """
  Changeset for status transitions.
  """
  def status_changeset(invoice, new_status) do
    changeset =
      invoice
      |> change(status: new_status)
      |> validate_status_transition(invoice.status, new_status)

    case new_status do
      "sent" -> put_change(changeset, :sent_at, UtilsDate.utc_now())
      "paid" -> put_change(changeset, :paid_at, UtilsDate.utc_now())
      "void" -> put_change(changeset, :voided_at, UtilsDate.utc_now())
      _ -> changeset
    end
  end

  @doc """
  Changeset for marking invoice as paid and generating receipt.
  """
  def paid_changeset(invoice, receipt_number) do
    now = UtilsDate.utc_now()

    # "Mark as paid" is an operator asserting the money arrived outside the
    # ledger (a bank transfer they can see in their account). It must move
    # paid_amount too: without that the invoice said PAID while the ledger
    # said nothing had been received, the receipt claimed the full total,
    # and remaining_amount/1 still showed a balance owed. Any amount
    # already recorded stays - this tops up, it does not overwrite.
    settled_amount = Decimal.max(invoice.paid_amount || Decimal.new("0"), invoice.total)

    invoice
    |> change(%{
      status: "paid",
      paid_at: now,
      paid_amount: settled_amount,
      receipt_number: receipt_number,
      receipt_generated_at: now,
      receipt_data: %{
        generated_at: DateTime.to_iso8601(now),
        amount_paid: Decimal.to_string(settled_amount),
        currency: invoice.currency
      }
    })
    |> validate_status_transition(invoice.status, "paid")
  end

  defp validate_status_transition(changeset, from, to) do
    valid_transitions = %{
      "draft" => ~w(sent void),
      "sent" => ~w(paid overdue void),
      "overdue" => ~w(paid void),
      "paid" => ~w(void),
      "void" => []
    }

    allowed = Map.get(valid_transitions, from, [])

    if to in allowed do
      changeset
    else
      add_error(changeset, :status, "cannot transition from #{from} to #{to}")
    end
  end

  @doc """
  Creates an invoice from an order.
  """
  def from_order(%Order{} = order, opts \\ []) do
    due_days = Keyword.get(opts, :due_days, 14)
    invoice_number = Keyword.get(opts, :invoice_number)
    bank_details = Keyword.get(opts, :bank_details, %{})
    payment_terms = Keyword.get(opts, :payment_terms)

    %__MODULE__{
      user_uuid: order.user_uuid,
      order_uuid: order.uuid,
      invoice_number: invoice_number,
      status: "draft",
      subtotal: order.subtotal,
      tax_amount: order.tax_amount,
      tax_rate: order.tax_rate,
      total: order.total,
      currency: order.currency,
      due_date: Date.add(Date.utc_today(), due_days),
      billing_details: order.billing_snapshot,
      line_items: order.line_items,
      payment_terms: payment_terms,
      bank_details: bank_details,
      notes: order.notes
    }
  end

  @doc """
  Checks if invoice can be edited.
  """
  def editable?(%__MODULE__{status: "draft", trashed_at: nil}), do: true
  def editable?(_), do: false

  @doc """
  Checks if invoice can be sent (first time - changes status to sent).
  """
  def sendable?(%__MODULE__{status: "draft", trashed_at: nil}), do: true
  def sendable?(_), do: false

  @doc """
  Checks if invoice can be resent (already sent, paid, or overdue).
  """
  def resendable?(%__MODULE__{status: status}) when status in ~w(sent paid overdue), do: true
  def resendable?(_), do: false

  @doc """
  Checks if invoice can be marked as paid.
  """
  def payable?(%__MODULE__{status: status}) when status in ~w(sent overdue), do: true
  def payable?(_), do: false

  @doc """
  Checks if the invoice's status allows voiding it: `draft`, `sent` or `overdue`,
  and not in the trash. It looks at nothing else - `PhoenixKitBilling.void_invoice/3`
  also refuses an invoice with payments (`{:error, :invoice_has_payments}`; a
  partial payment leaves the status at `sent`). See `void_offered?/1`.
  """
  def voidable?(%__MODULE__{trashed_at: %DateTime{}}), do: false
  def voidable?(%__MODULE__{status: status}) when status in ~w(draft sent overdue), do: true
  def voidable?(_), do: false

  @doc """
  Checks if voiding the invoice can succeed as far as the struct shows:
  `voidable?/1` and no payments on it. What the admin page offers a *Void*
  button for; `PhoenixKitBilling.void_invoice/3` decides again on the locked row.
  """
  def void_offered?(%__MODULE__{} = invoice),
    do: voidable?(invoice) and not has_payments?(invoice)

  @doc """
  Checks if an invoice still counts against its order: it has not been voided
  and is not in the trash.
  """
  def open?(%__MODULE__{status: "void"}), do: false
  def open?(%__MODULE__{trashed_at: %DateTime{}}), do: false
  def open?(%__MODULE__{}), do: true

  @doc """
  Checks if the invoice is in the trash.
  """
  def trashed?(%__MODULE__{trashed_at: %DateTime{}}), do: true
  def trashed?(%__MODULE__{}), do: false

  @doc """
  Checks if the invoice can be moved to the trash: a draft that was never sent
  and is not in it already. An issued invoice is voided, never trashed.
  """
  def trashable?(%__MODULE__{status: "draft", sent_at: nil, trashed_at: nil}), do: true
  def trashable?(%__MODULE__{}), do: false

  @doc """
  Changeset that moves an invoice to the trash. `actor_uuid` is the user who
  does it, or `nil`. Written here and by `restore_changeset/1` only:
  `changeset/2` cannot set these fields.
  """
  def trash_changeset(%__MODULE__{} = invoice, actor_uuid) do
    invoice
    |> change(trashed_at: UtilsDate.utc_now(), trashed_by_uuid: actor_uuid)
    |> keep_updated_at()
  end

  @doc """
  Changeset that takes an invoice out of the trash.
  """
  def restore_changeset(%__MODULE__{} = invoice) do
    invoice
    |> change(trashed_at: nil, trashed_by_uuid: nil)
    |> keep_updated_at()
  end

  # Moving to the trash is not an edit: `updated_at` stays what it was, for the
  # feeds and syncs that read it. Forced, because an unchanged value would be
  # dropped and `updated_at` autogenerated.
  defp keep_updated_at(changeset),
    do: force_change(changeset, :updated_at, changeset.data.updated_at)

  @doc """
  The reason a void invoice was voided with, from `metadata["void"]`, or `nil`
  (no reason was given, or the invoice was voided before the trail existed).
  """
  def void_reason(%__MODULE__{metadata: %{"void" => %{"reason" => reason}}})
      when is_binary(reason) and reason != "",
      do: reason

  def void_reason(%__MODULE__{}), do: nil

  @doc """
  The provider charges that arrived after the invoice was voided, from
  `metadata["void"]["payments_after_void"]`: money that is not on the ledger
  and has to be refunded at the provider. Empty when there are none.
  """
  def payments_after_void(%__MODULE__{metadata: %{"void" => %{"payments_after_void" => list}}})
      when is_list(list),
      do: list

  def payments_after_void(%__MODULE__{}), do: []

  @doc """
  Checks if invoice has a receipt.
  """
  def has_receipt?(%__MODULE__{receipt_number: nil}), do: false
  def has_receipt?(%__MODULE__{receipt_number: _}), do: true

  @doc """
  Checks if invoice is overdue.
  """
  def overdue?(%__MODULE__{status: "paid"}), do: false
  def overdue?(%__MODULE__{status: "void"}), do: false
  def overdue?(%__MODULE__{due_date: nil}), do: false

  def overdue?(%__MODULE__{due_date: due_date}) do
    Date.compare(due_date, Date.utc_today()) == :lt
  end

  @doc """
  Returns human-readable status label.
  """
  def status_label("draft"), do: "Draft"
  def status_label("sent"), do: "Sent"
  def status_label("paid"), do: "Paid"
  def status_label("void"), do: "Void"
  def status_label("overdue"), do: "Overdue"
  def status_label(_), do: "Unknown"

  @doc """
  Returns status badge color class.
  """
  def status_color("draft"), do: "badge-neutral"
  def status_color("sent"), do: "badge-info"
  def status_color("paid"), do: "badge-success"
  def status_color("void"), do: "badge-error"
  def status_color("overdue"), do: "badge-warning"
  def status_color(_), do: "badge-ghost"

  @doc """
  Returns the billing name from billing_details snapshot.
  """
  def billing_name(%__MODULE__{billing_details: %{"name" => name}}) when is_binary(name), do: name

  def billing_name(%__MODULE__{billing_details: %{"company_name" => name}}) when is_binary(name),
    do: name

  def billing_name(%__MODULE__{billing_details: %{"first_name" => first, "last_name" => last}}) do
    "#{first} #{last}" |> String.trim()
  end

  def billing_name(_), do: ""

  @doc """
  Returns the remaining amount to be paid.
  """
  def remaining_amount(%__MODULE__{total: total, paid_amount: paid_amount}) do
    Decimal.sub(total, paid_amount)
  end

  @doc """
  Checks if invoice is fully paid (paid_amount >= total).
  """
  def fully_paid?(%__MODULE__{total: total, paid_amount: paid_amount}) do
    Decimal.compare(paid_amount, total) != :lt
  end

  @doc """
  Checks if invoice has any payments (paid_amount > 0).
  """
  def has_payments?(%__MODULE__{paid_amount: paid_amount}) do
    Decimal.positive?(paid_amount)
  end

  @doc """
  Checks if invoice can receive a refund (has payments).
  """
  def refundable?(%__MODULE__{} = invoice) do
    has_payments?(invoice)
  end

  @doc """
  Changeset for updating paid_amount.
  """
  def paid_amount_changeset(invoice, paid_amount) do
    invoice
    |> change(paid_amount: paid_amount)
    |> validate_number(:paid_amount, greater_than_or_equal_to: 0)
  end

  # ============================================
  # PAYMENT METHODS AGGREGATION
  # ============================================

  @doc """
  Returns all unique payment methods used in transactions for this invoice.
  Requires transactions to be preloaded.

  ## Examples

      iex> Invoice.payment_methods(invoice_with_transactions)
      ["bank", "stripe"]

      iex> Invoice.payment_methods(invoice_without_transactions)
      []
  """
  def payment_methods(%__MODULE__{transactions: txns}) when is_list(txns) do
    txns
    |> Enum.map(& &1.payment_method)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def payment_methods(_), do: []

  @doc """
  Returns the primary payment method (most used in positive transactions).
  Useful for display when there are multiple payment methods.
  Requires transactions to be preloaded.

  ## Examples

      iex> Invoice.primary_payment_method(invoice)
      "stripe"

      iex> Invoice.primary_payment_method(invoice_without_transactions)
      nil
  """
  def primary_payment_method(%__MODULE__{transactions: txns}) when is_list(txns) do
    txns
    |> Enum.filter(&Decimal.positive?(&1.amount))
    |> Enum.frequencies_by(& &1.payment_method)
    |> Enum.max_by(fn {_method, count} -> count end, fn -> {nil, 0} end)
    |> elem(0)
  end

  def primary_payment_method(_), do: nil
end
