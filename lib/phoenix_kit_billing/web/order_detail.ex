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
  import PhoenixKitBilling.Web.Components.TrashMark

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Activity
  alias PhoenixKitBilling.Errors
  alias PhoenixKitBilling.Events
  alias PhoenixKitBilling.Order
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
    case Billing.get_order(id, preload: [:billing_profile, :user]) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Order not found"))
         |> push_navigate(to: Routes.path("/admin/billing/orders"))}

      order ->
        socket =
          if socket.assigns[:loaded?] do
            assign_order(socket, order)
          else
            socket
            |> assign(:loaded?, true)
            |> Trail.billing(order.order_number, [Trail.orders()])
            |> assign(:project_title, Settings.get_project_title())
            |> assign_order(order)
            |> assign(:show_status_modal, false)
            |> assign(:show_invoice_modal, false)
            |> assign(:show_cancel_modal, false)
            |> assign(:show_trash_modal, false)
            |> assign(:show_restore_modal, false)
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
             :order_cancelled,
             :order_trashed,
             :order_restored
           ] do
    {:noreply, refresh_order(socket)}
  end

  def handle_info({event, %{order_uuid: order_uuid}}, socket)
      when event in [
             :invoice_created,
             :invoice_paid,
             :invoice_voided,
             :invoice_sent,
             :invoice_trashed,
             :invoice_restored
           ] and
             not is_nil(order_uuid) do
    if socket.assigns[:order] && socket.assigns.order.uuid == order_uuid do
      {:noreply, refresh_order(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh_order(%{assigns: %{order: %{uuid: uuid}}} = socket) do
    case Billing.get_order(uuid, preload: [:billing_profile, :user]) do
      nil -> socket
      order -> assign_order(socket, order)
    end
  end

  defp refresh_order(socket), do: socket

  # The order and what the page derives from it: its invoices (those in the
  # trash are not shown), who trashed it, and whether the viewer may change it.
  defp assign_order(socket, order) do
    socket
    |> assign(:order, order)
    |> assign(:invoices, Billing.list_invoices_for_order(order.uuid))
    |> assign(
      :trashed_by,
      order |> List.wrap() |> trashed_by_emails() |> Map.get(order.trashed_by_uuid)
    )
    |> assign(:can_manage_orders, Authz.can?(socket, :manage_orders))
  end

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
             gettext("Failed to confirm order: %{reason}", reason: Errors.message(reason))
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
           put_flash(
             socket,
             :error,
             gettext("Failed to mark as paid: %{reason}", reason: Errors.message(reason))
           )}
      end
    end)
  end

  @impl true
  def handle_event("open_cancel_modal", _params, socket) do
    {:noreply, assign(socket, :show_cancel_modal, true)}
  end

  @impl true
  def handle_event("close_cancel_modal", _params, socket) do
    {:noreply, assign(socket, :show_cancel_modal, false)}
  end

  @impl true
  def handle_event("cancel_order", params, socket) do
    Authz.authorize(socket, :manage_orders, fn ->
      actor_uuid = Activity.actor_uuid(socket)

      case Billing.cancel_order(socket.assigns.order, params["reason"], actor_uuid: actor_uuid) do
        {:ok, order} ->
          Activity.log("billing.order_cancelled",
            actor_uuid: actor_uuid,
            actor_role: Activity.actor_role(socket),
            resource_type: "order",
            resource_uuid: order.uuid,
            # The operator's own reason, typed for the audit trail (not customer data).
            metadata:
              %{"order_number" => order.order_number, "status" => order.status}
              |> put_reason(params["reason"])
          )

          {:noreply,
           socket
           |> assign(:order, order)
           |> assign(:show_cancel_modal, false)
           |> put_flash(:info, gettext("Order cancelled"))}

        {:error, reason} ->
          {:noreply,
           socket
           |> refresh_order()
           |> assign(:show_cancel_modal, false)
           |> put_flash(
             :error,
             gettext("Failed to cancel order: %{reason}", reason: Errors.message(reason))
           )}
      end
    end)
  end

  @impl true
  def handle_event("open_trash_modal", _params, socket) do
    {:noreply, assign(socket, :show_trash_modal, true)}
  end

  @impl true
  def handle_event("close_trash_modal", _params, socket) do
    {:noreply, assign(socket, :show_trash_modal, false)}
  end

  @impl true
  def handle_event("trash_order", params, socket) do
    Authz.authorize(socket, :manage_orders, fn ->
      actor_uuid = Activity.actor_uuid(socket)

      case Billing.trash_order(socket.assigns.order,
             actor_uuid: actor_uuid,
             reason: params["reason"]
           ) do
        {:ok, order} ->
          Activity.log("billing.order_trashed",
            actor_uuid: actor_uuid,
            actor_role: Activity.actor_role(socket),
            resource_type: "order",
            resource_uuid: order.uuid,
            # The operator's own reason, typed for the audit trail (not customer data).
            metadata:
              %{"order_number" => order.order_number, "status" => order.status}
              |> put_reason(params["reason"])
          )

          {:noreply,
           socket
           |> refresh_order()
           |> assign(:show_trash_modal, false)
           |> put_flash(:info, gettext("Order moved to the trash"))}

        {:error, reason} ->
          {:noreply,
           socket
           |> refresh_order()
           |> assign(:show_trash_modal, false)
           |> put_flash(
             :error,
             gettext("Failed to move the order to the trash: %{reason}",
               reason: Errors.message(reason)
             )
           )}
      end
    end)
  end

  @impl true
  def handle_event("open_restore_modal", _params, socket) do
    {:noreply, assign(socket, :show_restore_modal, true)}
  end

  @impl true
  def handle_event("close_restore_modal", _params, socket) do
    {:noreply, assign(socket, :show_restore_modal, false)}
  end

  @impl true
  def handle_event("restore_order", _params, socket) do
    Authz.authorize(socket, :manage_orders, fn ->
      case Billing.restore_order(socket.assigns.order) do
        {:ok, order} ->
          Activity.log("billing.order_restored",
            actor_uuid: Activity.actor_uuid(socket),
            actor_role: Activity.actor_role(socket),
            resource_type: "order",
            resource_uuid: order.uuid,
            metadata: %{"order_number" => order.order_number, "status" => order.status}
          )

          {:noreply,
           socket
           |> refresh_order()
           |> assign(:show_restore_modal, false)
           |> put_flash(:info, gettext("Order restored from the trash"))}

        {:error, reason} ->
          {:noreply,
           socket
           |> refresh_order()
           |> assign(:show_restore_modal, false)
           |> put_flash(
             :error,
             gettext("Failed to restore the order: %{reason}", reason: Errors.message(reason))
           )}
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

        {:error, %Ecto.Changeset{} = changeset} ->
          errors = format_changeset_errors(changeset)

          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to create invoice: %{errors}", errors: errors)
           )}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to create invoice: %{errors}", errors: Errors.message(reason))
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

  defp put_reason(metadata, reason) do
    case Billing.normalize_reason(reason) do
      nil -> metadata
      reason -> Map.put(metadata, "reason", reason)
    end
  end
end
