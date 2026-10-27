defmodule PhoenixKitBilling.Web.SubscriptionTypeForm do
  @moduledoc """
  Subscription type form LiveView for creating and editing subscription types.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.Components.Core.AdminPageHeader
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Web.Authz
  import PhoenixKitWeb.Components.Core.Checkbox
  import PhoenixKitWeb.Components.Core.DecimalInput
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.Textarea
  import PhoenixKitBilling.Web.Components.CurrencyDisplay

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Number
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Activity
  alias PhoenixKitBilling.Errors
  alias PhoenixKitBilling.SubscriptionType
  alias PhoenixKitBilling.Web.Trail

  @impl true
  def mount(params, session, socket) do
    # No tab names this page, so core's route gate admits any "billing"
    # holder; the page itself checks the capability its records need.
    Authz.authorize_mount(socket, :manage_subscriptions, fn ->
      do_mount(params, session, socket)
    end)
  end

  defp do_mount(params, _session, socket) do
    if Billing.enabled?() do
      project_title = Settings.get_project_title()
      # §3.3: base = is_default row (billing_default_currency is no longer read)
      default_currency = (Billing.get_base_currency() || %{code: nil}).code

      {type, mode} =
        case params do
          %{"id" => id} ->
            case Billing.get_subscription_type(id) do
              {:ok, type} -> {type, :edit}
              {:error, _} -> {nil, :not_found}
            end

          _ ->
            {%SubscriptionType{
               currency: default_currency,
               interval: "month",
               interval_count: 1,
               active: true
             }, :new}
        end

      if type do
        changeset = SubscriptionType.changeset(type, %{})

        socket =
          socket
          |> assign_trail(type, mode)
          |> assign(:project_title, project_title)
          |> assign(:mode, mode)
          |> assign(:subscription_type, type)
          |> assign(:changeset, changeset)
          |> assign(:features_input, format_features(type.features))
          |> assign(:form, to_form(changeset))

        {:ok, socket}
      else
        {:ok,
         socket
         |> put_flash(:error, gettext("Subscription type not found"))
         |> push_navigate(to: Routes.path("/admin/billing/subscription-types"))}
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

  # A type has no page of its own, so on the edit page its crumb is text.
  defp assign_trail(socket, _type, :new),
    do: Trail.billing(socket, gettext("New subscription type"), [Trail.subscription_types()])

  defp assign_trail(socket, type, :edit),
    do:
      Trail.billing(socket, gettext("Edit"), [Trail.subscription_types(), Trail.crumb(type.name)])

  @impl true
  def handle_event("validate", %{"subscription_type" => params}, socket) do
    params = process_params(params, socket.assigns.features_input)

    changeset =
      socket.assigns.subscription_type
      |> SubscriptionType.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("update_features", %{"features" => features}, socket) do
    {:noreply, assign(socket, :features_input, features)}
  end

  @impl true
  def handle_event("save", params, socket) do
    Authz.authorize(socket, :manage_subscriptions, fn -> gated_event("save", params, socket) end)
  end

  defp process_params(params, features_input) do
    # Parse features from textarea (one per line)
    features =
      features_input
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    # Parse price from string to decimal. On garbage input, pass the raw
    # string through so Ecto's own :decimal cast rejects it as a normal
    # changeset error instead of `Decimal.new/1` raising.
    price =
      case params["price"] do
        "" -> nil
        nil -> nil
        p when is_binary(p) -> normalize_price(p)
        p -> p
      end

    params
    |> Map.put("features", features)
    |> Map.put("price", price)
  end

  defp normalize_price(p) do
    case Number.parse_decimal(p) do
      {:ok, decimal} -> decimal
      {:error, _reason} -> p
    end
  end

  defp format_features(nil), do: ""
  defp format_features(features) when is_list(features), do: Enum.join(features, "\n")
  defp format_features(_), do: ""

  defp type_saved_message(:new), do: gettext("Subscription type created successfully")
  defp type_saved_message(:edit), do: gettext("Subscription type updated successfully")

  @doc false
  def interval_phrase("day", 1), do: ngettext("per day", "per day", 1)

  def interval_phrase("day", n),
    do: ngettext("per %{count} days", "per %{count} days", n, count: n)

  def interval_phrase("week", 1), do: ngettext("per week", "per week", 1)

  def interval_phrase("week", n),
    do: ngettext("per %{count} weeks", "per %{count} weeks", n, count: n)

  def interval_phrase("month", 1), do: ngettext("per month", "per month", 1)

  def interval_phrase("month", n),
    do: ngettext("per %{count} months", "per %{count} months", n, count: n)

  def interval_phrase("year", 1), do: ngettext("per year", "per year", 1)

  def interval_phrase("year", n),
    do: ngettext("per %{count} years", "per %{count} years", n, count: n)

  def interval_phrase(other, n), do: "#{n} #{other}(s)"

  # Form params arrive as strings on validate; ngettext requires an integer
  # count. Falls back to 1 for blank/invalid input.
  @doc false
  def normalize_count(n) when is_integer(n) and n > 0, do: n

  def normalize_count(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, _} when int > 0 -> int
      _ -> 1
    end
  end

  def normalize_count(_), do: 1

  defp gated_event("save", %{"subscription_type" => params}, socket) do
    params = process_params(params, socket.assigns.features_input)

    result =
      case socket.assigns.mode do
        :new -> Billing.create_subscription_type(params)
        :edit -> Billing.update_subscription_type(socket.assigns.subscription_type, params)
      end

    case result do
      {:ok, type} ->
        action =
          if socket.assigns.mode == :new,
            do: "billing.subscription_type_created",
            else: "billing.subscription_type_updated"

        Activity.log(action,
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "subscription_type",
          resource_uuid: type.uuid,
          metadata: %{"active" => type.active}
        )

        {:noreply,
         socket
         |> put_flash(:info, type_saved_message(socket.assigns.mode))
         |> push_navigate(to: Routes.path("/admin/billing/subscription-types"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to save subscription type: %{reason}", reason: Errors.message(reason))
         )}
    end
  end
end
