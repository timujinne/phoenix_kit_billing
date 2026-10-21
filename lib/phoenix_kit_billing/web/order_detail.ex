defmodule PhoenixKitBilling.Web.OrderDetail do
  @moduledoc """
  Order detail LiveView for the billing module.

  Displays complete order information and provides actions for order management.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.Components.Core.AdminPageHeader
  import PhoenixKitWeb.Components.Core.UserInfo
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Web.Authz
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TimeDisplay
  import PhoenixKitBilling.Web.Components.CurrencyDisplay
  import PhoenixKitBilling.Web.Components.InvoiceStatusBadge
  import PhoenixKitBilling.Web.Components.OrderStatusBadge

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Activity
  alias PhoenixKitBilling.Events
  alias PhoenixKitBilling.Web.Trail

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      if connected?(socket) do
        Events.subscribe_orders()
        Events.subscribe_invoices()
      end

      {:ok, assign(socket, loaded?: false)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    case Billing.get_order(id, preload: [:billing_profile, :user, :invoices]) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Order not found"))
         |> push_navigate(to: Routes.path("/admin/billing/orders"))}

      order ->
        socket =
          if socket.assigns[:loaded?] do
            socket
            |> assign(:order, order)
            |> assign(:invoices, order.invoices)
          else
            socket
            |> assign(:loaded?, true)
            |> Trail.billing(order.order_number, [Trail.orders()])
            |> assign(:project_title, Settings.get_project_title())
            |> assign(:order, order)
            |> assign(:invoices, order.invoices)
            |> assign(:show_status_modal, false)
            |> assign(:show_invoice_modal, false)
          end

        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({event, %{uuid: uuid}}, %{assigns: %{order: %{uuid: uuid}}} = socket)
      when event in [
             :order_updated,
             :order_confirmed,
             :order_paid,
             :order_refunded,
             :order_cancelled
           ] do
    {:noreply, refresh_order(socket)}
  end

  def handle_info({event, %{order_uuid: order_uuid}}, socket)
      when event in [:invoice_created, :invoice_paid, :invoice_voided, :invoice_sent] and
             not is_nil(order_uuid) do
    if socket.assigns[:order] && socket.assigns.order.uuid == order_uuid do
      {:noreply, refresh_order(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh_order(%{assigns: %{order: %{uuid: uuid}}} = socket) do
    case Billing.get_order(uuid, preload: [:billing_profile, :user, :invoices]) do
      nil -> socket
      order -> assign(socket, order: order, invoices: order.invoices)
    end
  end

  defp refresh_order(socket), do: socket

  @impl true
  def handle_event("confirm_order", _params, socket) do
    Authz.authorize(socket, :manage_orders, fn ->
      case Billing.confirm_order(socket.assigns.order) do
        {:ok, order} ->
          Activity.log("billing.order_confirmed",
            actor_uuid: Activity.actor_uuid(socket),
            actor_role: Activity.actor_role(socket),
            resource_type: "order",
            resource_uuid: order.uuid,
            metadata: %{"order_number" => order.order_number, "status" => order.status}
          )

          {:noreply,
           socket
           |> assign(:order, order)
           |> put_flash(:info, gettext("Order confirmed successfully"))}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to confirm order: %{reason}", reason: reason)
           )}
      end
    end)
  end

  @impl true
  def handle_event("mark_paid", _params, socket) do
    Authz.authorize(socket, :manage_orders, fn ->
      case Billing.mark_order_paid(socket.assigns.order) do
        {:ok, order} ->
          Activity.log("billing.order_marked_paid",
            actor_uuid: Activity.actor_uuid(socket),
            actor_role: Activity.actor_role(socket),
            resource_type: "order",
            resource_uuid: order.uuid,
            metadata: %{"order_number" => order.order_number, "status" => order.status}
          )

          {:noreply,
           socket
           |> assign(:order, order)
           |> put_flash(:info, gettext("Order marked as paid"))}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, gettext("Failed to mark as paid: %{reason}", reason: reason))}
      end
    end)
  end

  @impl true
  def handle_event("cancel_order", _params, socket) do
    Authz.authorize(socket, :manage_orders, fn ->
      case Billing.cancel_order(socket.assigns.order) do
        {:ok, order} ->
          Activity.log("billing.order_cancelled",
            actor_uuid: Activity.actor_uuid(socket),
            actor_role: Activity.actor_role(socket),
            resource_type: "order",
            resource_uuid: order.uuid,
            metadata: %{"order_number" => order.order_number, "status" => order.status}
          )

          {:noreply,
           socket
           |> assign(:order, order)
           |> put_flash(:info, gettext("Order cancelled"))}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, gettext("Failed to cancel order: %{reason}", reason: reason))}
      end
    end)
  end

  @impl true
  def handle_event("generate_invoice", _params, socket) do
    Authz.authorize(socket, :manage_orders, fn ->
      case Billing.create_invoice_from_order(socket.assigns.order) do
        {:ok, invoice} ->
          Activity.log("billing.invoice_created",
            actor_uuid: Activity.actor_uuid(socket),
            actor_role: Activity.actor_role(socket),
            resource_type: "invoice",
            resource_uuid: invoice.uuid,
            metadata: %{
              "invoice_number" => invoice.invoice_number,
              "status" => invoice.status,
              "order_uuid" => socket.assigns.order.uuid
            }
          )

          invoices = Billing.list_invoices_for_order(socket.assigns.order.uuid)

          {:noreply,
           socket
           |> assign(:invoices, invoices)
           |> put_flash(
             :info,
             gettext("Invoice %{number} created", number: invoice.invoice_number)
           )}

        {:error, changeset} ->
          errors = format_changeset_errors(changeset)

          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to create invoice: %{errors}", errors: errors)
           )}
      end
    end)
  end

  @impl true
  def handle_event("view_invoice", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/billing/invoices/#{uuid}"))}
  end

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
  end
end
