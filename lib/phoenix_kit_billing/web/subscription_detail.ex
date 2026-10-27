defmodule PhoenixKitBilling.Web.SubscriptionDetail do
  @moduledoc """
  Subscription detail LiveView for the billing module.

  Displays complete subscription information and provides management actions.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.Components.Core.AdminPageHeader
  import PhoenixKitWeb.Components.Core.UserInfo
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.TimeDisplay
  import PhoenixKitBilling.Web.Components.CurrencyDisplay
  import PhoenixKitBilling.Web.Components.SubscriptionHelpers

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Activity
  alias PhoenixKitBilling.Errors
  alias PhoenixKitBilling.Subscription
  alias PhoenixKitBilling.Web.Authz
  alias PhoenixKitBilling.Web.Trail

  @impl true
  def mount(params, session, socket) do
    # No tab names this page, so core's route gate admits any "billing"
    # holder; the page itself checks the capability its records need.
    Authz.authorize_mount(socket, :manage_subscriptions, fn ->
      do_mount(params, session, socket)
    end)
  end

  defp do_mount(%{"id" => id}, _session, socket) do
    if Billing.enabled?() do
      case Billing.get_subscription(id, preload: [:subscription_type, :payment_method, :user]) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, gettext("Subscription not found"))
           |> push_navigate(to: Routes.path("/admin/billing/subscriptions"))}

        subscription ->
          project_title = Settings.get_project_title()
          types = Billing.list_subscription_types(active_only: true)

          socket =
            socket
            |> Trail.billing(subscription_name(subscription), [Trail.subscriptions()])
            |> assign(:project_title, project_title)
            |> assign(:subscription, subscription)
            |> assign(:subscription_types, types)
            |> assign(:show_change_subscription_type_modal, false)
            |> assign(:selected_new_subscription_type_uuid, nil)

          {:ok, socket}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_now", params, socket) do
    Authz.authorize(socket, :manage_subscriptions, fn ->
      gated_event("cancel_now", params, socket)
    end)
  end

  @impl true
  def handle_event("cancel_at_period_end", params, socket) do
    Authz.authorize(socket, :manage_subscriptions, fn ->
      gated_event("cancel_at_period_end", params, socket)
    end)
  end

  @impl true
  def handle_event("resume", params, socket) do
    Authz.authorize(socket, :manage_subscriptions, fn -> gated_event("resume", params, socket) end)
  end

  @impl true
  def handle_event("pause", params, socket) do
    Authz.authorize(socket, :manage_subscriptions, fn -> gated_event("pause", params, socket) end)
  end

  @impl true
  def handle_event("open_change_subscription_type_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_change_subscription_type_modal, true)
     |> assign(:selected_new_subscription_type_uuid, nil)}
  end

  @impl true
  def handle_event("close_change_subscription_type_modal", _params, socket) do
    {:noreply, assign(socket, :show_change_subscription_type_modal, false)}
  end

  @impl true
  def handle_event(
        "select_new_subscription_type",
        %{"subscription_type_uuid" => type_uuid},
        socket
      ) do
    type_uuid = if type_uuid == "", do: nil, else: type_uuid
    {:noreply, assign(socket, :selected_new_subscription_type_uuid, type_uuid)}
  end

  @impl true
  def handle_event("change_subscription_type", params, socket) do
    Authz.authorize(socket, :manage_subscriptions, fn ->
      gated_event("change_subscription_type", params, socket)
    end)
  end

  defp reload_subscription(id) do
    Billing.get_subscription(id, preload: [:subscription_type, :payment_method, :user])
  end

  defp log_subscription(socket, action, subscription, extra \\ %{}) do
    Activity.log(action,
      actor_uuid: Activity.actor_uuid(socket),
      actor_role: Activity.actor_role(socket),
      resource_type: "subscription",
      resource_uuid: subscription.uuid,
      metadata: Map.merge(%{"status" => subscription.status}, extra)
    )
  end

  # Helper functions for template

  def days_until_renewal(%Subscription{current_period_end: nil}), do: nil

  def days_until_renewal(%Subscription{current_period_end: period_end}) do
    Date.diff(DateTime.to_date(period_end), Date.utc_today())
  end

  def grace_period_remaining(%Subscription{grace_period_end: nil}), do: nil

  def grace_period_remaining(%Subscription{grace_period_end: grace_end}) do
    Date.diff(DateTime.to_date(grace_end), Date.utc_today())
  end

  defp gated_event("cancel_now", _params, socket) do
    case Billing.cancel_subscription(socket.assigns.subscription, immediately: true) do
      {:ok, subscription} ->
        log_subscription(socket, "billing.subscription_cancelled", subscription, %{
          "immediately" => true
        })

        {:noreply,
         socket
         |> assign(:subscription, reload_subscription(subscription.uuid))
         |> put_flash(:info, gettext("Subscription cancelled immediately"))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to cancel: %{reason}", reason: Errors.message(reason))
         )}
    end
  end

  defp gated_event("cancel_at_period_end", _params, socket) do
    case Billing.cancel_subscription(socket.assigns.subscription, immediately: false) do
      {:ok, subscription} ->
        log_subscription(socket, "billing.subscription_cancelled", subscription, %{
          "immediately" => false
        })

        {:noreply,
         socket
         |> assign(:subscription, reload_subscription(subscription.uuid))
         |> put_flash(:info, gettext("Subscription will cancel at period end"))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to cancel: %{reason}", reason: Errors.message(reason))
         )}
    end
  end

  defp gated_event("resume", _params, socket) do
    case Billing.resume_subscription(socket.assigns.subscription) do
      {:ok, subscription} ->
        log_subscription(socket, "billing.subscription_resumed", subscription)

        {:noreply,
         socket
         |> assign(:subscription, reload_subscription(subscription.uuid))
         |> put_flash(:info, gettext("Subscription resumed"))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to resume: %{reason}", reason: Errors.message(reason))
         )}
    end
  end

  defp gated_event("pause", _params, socket) do
    case Billing.pause_subscription(socket.assigns.subscription) do
      {:ok, subscription} ->
        log_subscription(socket, "billing.subscription_paused", subscription)

        {:noreply,
         socket
         |> assign(:subscription, reload_subscription(subscription.uuid))
         |> put_flash(:info, gettext("Subscription paused"))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to pause: %{reason}", reason: Errors.message(reason))
         )}
    end
  end

  defp gated_event("change_subscription_type", _params, socket) do
    %{subscription: subscription, selected_new_subscription_type_uuid: new_type_uuid} =
      socket.assigns

    if new_type_uuid && to_string(new_type_uuid) != to_string(subscription.subscription_type_uuid) do
      case Billing.change_subscription_type(subscription, new_type_uuid) do
        {:ok, updated_subscription} ->
          log_subscription(
            socket,
            "billing.subscription_type_changed",
            updated_subscription,
            %{"subscription_type_uuid" => updated_subscription.subscription_type_uuid}
          )

          {:noreply,
           socket
           |> assign(:subscription, reload_subscription(updated_subscription.uuid))
           |> assign(:show_change_subscription_type_modal, false)
           |> put_flash(:info, gettext("Subscription type changed successfully"))}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to change subscription type: %{reason}",
               reason: Errors.message(reason)
             )
           )}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Please select a different subscription type"))}
    end
  end
end
