defmodule PhoenixKitBilling.Web.Components.BillingProfileFields do
  @moduledoc """
  The billing profile form fields, defined once.

  The dashboard form, the admin form and the e-commerce checkout all collect
  the same billing details. They used to carry separate copies of this markup;
  this component renders them all, so the fields, labels and ids cannot drift.

  It renders the fields only — the `<form>` element, its events, the submit
  button and the surrounding page belong to the caller. Inputs bind to
  `@form[:field]`, so the caller picks the param namespace with
  `to_form(changeset, as: :checkout_billing)`. Pair it with
  `PhoenixKitBilling.BillingProfile.fields_changeset/3` and
  `PhoenixKitBilling.BillingProfile.form_fields/0` on the server side.

  ## Locale

  Labels, hints and the validation messages of `BillingProfile` are looked up on
  the module's own backend, `PhoenixKitBilling.Gettext` — not the host's. A
  caller outside billing's own LiveViews must put the request locale there
  before it renders or validates, e.g.
  `Gettext.put_locale(PhoenixKitBilling.Gettext, locale)` in `mount/3`
  (the locale is per process; `Gettext.with_locale/3` scopes it to a function).
  Catalogues ship for `en`, `et`, `ru`, `uk`, `de` and `fr`; the `de` and `fr`
  catalogues translate the fields shown here, other strings fall back to English.
  Core's own error messages ("can't be blank", length limits) follow the locale
  of core's backend.

  ## Example

      <.form for={@form} phx-change="validate" phx-submit="save">
        <.billing_profile_fields
          form={@form}
          type={@profile_type}
          countries={@countries}
          subdivision_label={@subdivision_label}
          require_email
          show_options={false}
        >
          <.checkbox field={@form[:save_profile]} label="Save for next time" />
        </.billing_profile_fields>
      </.form>

  The type radios emit `phx-click={@type_event}` with `phx-value-type`
  (`"individual"` or `"company"`); the caller handles it and passes the new
  value back as `type`. The radios are also form inputs named after the form's
  `type` field, so picking one fires the form's `phx-change` too and `type`
  arrives in the caller's validate params.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitBilling.Gettext

  import PhoenixKitWeb.Components.Core.Checkbox, only: [checkbox: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.Textarea, only: [textarea: 1]

  attr(:form, Phoenix.HTML.Form, required: true, doc: "form over a billing profile changeset")
  attr(:type, :string, required: true, values: ~w(individual company))

  attr(:countries, :list,
    required: true,
    doc: "`[{label, code}]`, as `PhoenixKit.Utils.CountryData.countries_for_select/0` returns"
  )

  attr(:subdivision_label, :string,
    default: nil,
    doc: ~s(label of the state/region field, falls back to "State / Region")
  )

  attr(:type_event, :string,
    default: "change_type",
    doc: "`phx-click` event the type radios emit, with `phx-value-type`"
  )

  attr(:target, :any, default: nil, doc: "`phx-target` for the type radios")

  attr(:id_prefix, :string,
    default: "billing-profile",
    doc: ~s(every id is derived from it, e.g. `billing-profile-type-company`)
  )

  attr(:show_options, :boolean,
    default: true,
    doc: "render the profile name and the default-profile checkbox"
  )

  attr(:require_email, :boolean, default: false, doc: "mark the email field as required")

  attr(:require_phone, :boolean, default: false, doc: "mark the phone field as required")

  attr(:require_address, :boolean,
    default: false,
    doc: "mark the street, city, postal code and country fields as required"
  )

  slot(:inner_block, doc: "rendered after the fields, e.g. extra checkboxes")

  def billing_profile_fields(assigns) do
    ~H"""
    <div id={@id_prefix} class="space-y-6">
      <.type_card form={@form} type={@type} type_event={@type_event} target={@target} id_prefix={@id_prefix} />

      <.individual_card
        :if={@type == "individual"}
        form={@form}
        id_prefix={@id_prefix}
        require_email={@require_email}
        require_phone={@require_phone}
      />

      <.company_card
        :if={@type == "company"}
        form={@form}
        id_prefix={@id_prefix}
        require_email={@require_email}
        require_phone={@require_phone}
      />

      <.address_card
        form={@form}
        countries={@countries}
        subdivision_label={@subdivision_label}
        id_prefix={@id_prefix}
        require_address={@require_address}
      />

      <.options_card :if={@show_options} form={@form} id_prefix={@id_prefix} />

      {render_slot(@inner_block)}
    </div>
    """
  end

  attr(:form, Phoenix.HTML.Form, required: true)
  attr(:type, :string, required: true)
  attr(:type_event, :string, required: true)
  attr(:target, :any, default: nil)
  attr(:id_prefix, :string, required: true)

  defp type_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-lg">
      <div class="card-body">
        <h2 id={"#{@id_prefix}-type-label"} class="card-title text-lg">
          <.icon name="hero-user-circle" class="w-5 h-5" /> {gettext("Profile Type")}
        </h2>

        <div
          role="radiogroup"
          aria-labelledby={"#{@id_prefix}-type-label"}
          class="flex flex-wrap gap-4 mt-2"
        >
          <label class="flex items-center gap-2 cursor-pointer">
            <input
              type="radio"
              id={"#{@id_prefix}-type-individual"}
              name={@form[:type].name}
              value="individual"
              class="radio radio-primary"
              checked={@type == "individual"}
              phx-click={@type_event}
              phx-target={@target}
              phx-value-type="individual"
            />
            <span class="fieldset-legend">
              <span class="font-medium">{gettext("Individual")}</span>
              <span class="text-base-content/60 block text-sm">
                {gettext("Personal billing profile")}
              </span>
            </span>
          </label>

          <label class="flex items-center gap-2 cursor-pointer">
            <input
              type="radio"
              id={"#{@id_prefix}-type-company"}
              name={@form[:type].name}
              value="company"
              class="radio radio-primary"
              checked={@type == "company"}
              phx-click={@type_event}
              phx-target={@target}
              phx-value-type="company"
            />
            <span class="fieldset-legend">
              <span class="font-medium">{gettext("Company")}</span>
              <span class="text-base-content/60 block text-sm">
                {gettext("Business billing profile")}
              </span>
            </span>
          </label>
        </div>
      </div>
    </div>
    """
  end

  attr(:form, Phoenix.HTML.Form, required: true)
  attr(:id_prefix, :string, required: true)
  attr(:require_email, :boolean, required: true)
  attr(:require_phone, :boolean, required: true)

  defp individual_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-lg">
      <div class="card-body">
        <h2 class="card-title text-lg">
          <.icon name="hero-user" class="w-5 h-5" /> {gettext("Personal Information")}
        </h2>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <.input
            field={@form[:first_name]}
            id={"#{@id_prefix}-first_name"}
            type="text"
            label={gettext("First Name")}
            placeholder={gettext("John")}
            required
          />

          <.input
            field={@form[:middle_name]}
            id={"#{@id_prefix}-middle_name"}
            type="text"
            label={gettext("Middle Name")}
          />

          <.input
            field={@form[:last_name]}
            id={"#{@id_prefix}-last_name"}
            type="text"
            label={gettext("Last Name")}
            placeholder={gettext("Doe")}
            required
          />
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4">
          <div>
            <.input
              field={@form[:email]}
              id={"#{@id_prefix}-email"}
              type="email"
              label={gettext("Email")}
              placeholder="john@example.com"
              required={@require_email}
            />
            <p class="fieldset-label mt-1">
              {gettext("Billing email (can differ from account email)")}
            </p>
          </div>

          <.input
            field={@form[:phone]}
            id={"#{@id_prefix}-phone"}
            type="tel"
            label={gettext("Phone")}
            placeholder="+372 5555 5555"
            required={@require_phone}
          />
        </div>
      </div>
    </div>
    """
  end

  attr(:form, Phoenix.HTML.Form, required: true)
  attr(:id_prefix, :string, required: true)
  attr(:require_email, :boolean, required: true)
  attr(:require_phone, :boolean, required: true)

  defp company_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-lg">
      <div class="card-body">
        <h2 class="card-title text-lg">
          <.icon name="hero-building-office" class="w-5 h-5" /> {gettext("Company Information")}
        </h2>

        <.input
          field={@form[:company_name]}
          id={"#{@id_prefix}-company_name"}
          type="text"
          label={gettext("Company Name")}
          placeholder={gettext("Acme Corp OÜ")}
          required
        />

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4">
          <div>
            <.input
              field={@form[:company_vat_number]}
              id={"#{@id_prefix}-company_vat_number"}
              type="text"
              label={gettext("VAT Number")}
              class="font-mono"
              placeholder="EE123456789"
            />
            <p class="fieldset-label mt-1">{gettext("EU VAT format: Country code + number")}</p>
          </div>

          <.input
            field={@form[:company_registration_number]}
            id={"#{@id_prefix}-company_registration_number"}
            type="text"
            label={gettext("Registration Number")}
            class="font-mono"
            placeholder="12345678"
          />
        </div>

        <div class="mt-4">
          <.textarea
            field={@form[:company_legal_address]}
            id={"#{@id_prefix}-company_legal_address"}
            label={gettext("Legal Address")}
            rows="2"
            placeholder={gettext("Registered legal address")}
          />
        </div>

        <div class="divider">{gettext("Contact")}</div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.input
            field={@form[:email]}
            id={"#{@id_prefix}-email"}
            type="email"
            label={gettext("Contact Email")}
            placeholder="billing@company.com"
            required={@require_email}
          />

          <.input
            field={@form[:phone]}
            id={"#{@id_prefix}-phone"}
            type="tel"
            label={gettext("Phone")}
            placeholder="+372 5555 5555"
            required={@require_phone}
          />
        </div>
      </div>
    </div>
    """
  end

  attr(:form, Phoenix.HTML.Form, required: true)
  attr(:countries, :list, required: true)
  attr(:subdivision_label, :string, default: nil)
  attr(:id_prefix, :string, required: true)
  attr(:require_address, :boolean, required: true)

  defp address_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-lg">
      <div class="card-body">
        <h2 class="card-title text-lg">
          <.icon name="hero-map-pin" class="w-5 h-5" /> {gettext("Billing Address")}
        </h2>

        <.select
          field={@form[:country]}
          id={"#{@id_prefix}-country"}
          label={gettext("Country")}
          prompt={gettext("Select country...")}
          options={@countries}
          required={@require_address}
        />

        <div class="mt-4">
          <.input
            field={@form[:address_line1]}
            id={"#{@id_prefix}-address_line1"}
            type="text"
            label={gettext("Address Line 1")}
            placeholder={gettext("Street address")}
            required={@require_address}
          />
        </div>

        <.input
          field={@form[:address_line2]}
          id={"#{@id_prefix}-address_line2"}
          type="text"
          label={gettext("Address Line 2")}
          placeholder={gettext("Apartment, suite, etc.")}
        />

        <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mt-4">
          <.input
            field={@form[:city]}
            id={"#{@id_prefix}-city"}
            type="text"
            label={gettext("City")}
            placeholder={gettext("Tallinn")}
            required={@require_address}
          />

          <.input
            field={@form[:state]}
            id={"#{@id_prefix}-state"}
            type="text"
            label={@subdivision_label || gettext("State / Region")}
            placeholder={gettext("Harju")}
          />

          <.input
            field={@form[:postal_code]}
            id={"#{@id_prefix}-postal_code"}
            type="text"
            label={gettext("Postal Code")}
            placeholder="10115"
            required={@require_address}
          />
        </div>
      </div>
    </div>
    """
  end

  attr(:form, Phoenix.HTML.Form, required: true)
  attr(:id_prefix, :string, required: true)

  defp options_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-lg">
      <div class="card-body">
        <h2 class="card-title text-lg">
          <.icon name="hero-cog-6-tooth" class="w-5 h-5" /> {gettext("Options")}
        </h2>

        <.checkbox
          field={@form[:is_default]}
          id={"#{@id_prefix}-is_default"}
          label={gettext("Set as default profile")}
        >
          <:description>
            {gettext("This profile will be used by default for new orders")}
          </:description>
        </.checkbox>

        <div class="mt-4">
          <.input
            field={@form[:name]}
            id={"#{@id_prefix}-name"}
            type="text"
            label={gettext("Profile Name (Optional)")}
            placeholder={gettext("e.g., Home Address, Work")}
          />
          <p class="fieldset-label mt-1">{gettext("Custom name to identify this profile")}</p>
        </div>
      </div>
    </div>
    """
  end
end
