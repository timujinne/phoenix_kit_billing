defmodule PhoenixKitBilling.Web.Components.BillingProfileFieldsTest do
  @moduledoc """
  Render tests for the shared billing profile fields: which sections each type
  shows, how ids and param names are derived, and what the required markers
  follow. No database — the component only reads a form.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias PhoenixKitBilling.BillingProfile
  alias PhoenixKitBilling.Web.Components.BillingProfileFields

  @countries [{"Estonia", "EE"}, {"Latvia", "LV"}]

  defp profile_form(attrs \\ %{}, opts \\ []) do
    %BillingProfile{}
    |> BillingProfile.fields_changeset(attrs, opts)
    |> Map.put(:action, :validate)
    |> to_form()
  end

  defp render_fields(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{form: profile_form(), type: "individual", countries: @countries},
        Map.new(overrides)
      )

    (&BillingProfileFields.billing_profile_fields/1)
    |> render_component(assigns)
    |> LazyHTML.from_fragment()
  end

  defp present?(doc, selector), do: LazyHTML.query(doc, selector) |> Enum.count() > 0

  defp attribute_of(doc, selector, name),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()

  defp required?(doc, id), do: present?(doc, "##{id}[required]")

  defp star?(doc, id), do: present?(doc, "label[for='#{id}'] .text-error")

  describe "type sections" do
    test "individual shows the person fields and no company fields" do
      doc = render_fields(type: "individual")

      for field <- ~w(first_name middle_name last_name email phone) do
        assert present?(doc, "#billing-profile-#{field}"), "missing #{field}"
      end

      for field <-
            ~w(company_name company_vat_number company_registration_number company_legal_address) do
        refute present?(doc, "#billing-profile-#{field}"), "unexpected #{field}"
      end
    end

    test "company shows the company fields and no person name fields" do
      doc = render_fields(type: "company")

      for field <- ~w(company_name company_vat_number company_registration_number email phone) do
        assert present?(doc, "#billing-profile-#{field}"), "missing #{field}"
      end

      assert present?(doc, "textarea#billing-profile-company_legal_address")

      for field <- ~w(first_name middle_name last_name) do
        refute present?(doc, "#billing-profile-#{field}"), "unexpected #{field}"
      end
    end

    test "the type radios reflect the current type" do
      individual = render_fields(type: "individual")
      assert present?(individual, "#billing-profile-type-individual[checked]")
      refute present?(individual, "#billing-profile-type-company[checked]")

      company = render_fields(type: "company")
      assert present?(company, "#billing-profile-type-company[checked]")
      refute present?(company, "#billing-profile-type-individual[checked]")
    end

    test "both types share the address section" do
      for type <- ~w(individual company) do
        doc = render_fields(type: type)

        for field <- ~w(address_line1 address_line2 city state postal_code) do
          assert present?(doc, "#billing-profile-#{field}"), "#{type}: missing #{field}"
        end

        assert present?(doc, "select#billing-profile-country")
      end
    end
  end

  describe "type radios" do
    test "are grouped and labelled" do
      doc = render_fields(id_prefix: "pf")

      assert attribute_of(doc, "[role=radiogroup]", "aria-labelledby") == "pf-type-label"
      assert present?(doc, "#pf-type-label")
    end

    test "emit the default event with the type as phx-value-type" do
      doc = render_fields()

      assert attribute_of(doc, "#billing-profile-type-individual", "phx-click") == "change_type"

      assert attribute_of(doc, "#billing-profile-type-individual", "phx-value-type") ==
               "individual"

      assert attribute_of(doc, "#billing-profile-type-company", "phx-click") == "change_type"
      assert attribute_of(doc, "#billing-profile-type-company", "phx-value-type") == "company"
      assert attribute_of(doc, "#billing-profile-type-company", "phx-target") == nil
    end

    test "honour a custom event and target" do
      doc = render_fields(type_event: "pick_type", target: "#checkout-form")

      assert attribute_of(doc, "#billing-profile-type-company", "phx-click") == "pick_type"
      assert attribute_of(doc, "#billing-profile-type-company", "phx-target") == "#checkout-form"
    end
  end

  describe "ids and param names" do
    test "every id derives from id_prefix" do
      doc = render_fields(id_prefix: "checkout-billing", type: "individual")

      ids =
        doc
        |> LazyHTML.query("[id]")
        |> LazyHTML.attribute("id")

      assert "checkout-billing-first_name" in ids
      assert "checkout-billing-type-company" in ids
      assert "checkout-billing-country" in ids
      assert "checkout-billing-is_default" in ids
      assert Enum.all?(ids, &String.starts_with?(&1, "checkout-billing")), inspect(ids)
    end

    test "default prefix is billing-profile" do
      doc = render_fields()

      ids = doc |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")
      assert Enum.all?(ids, &String.starts_with?(&1, "billing-profile")), inspect(ids)
    end

    test "input names follow the namespace the caller gave the form" do
      form = to_form(%{"first_name" => "Ada"}, as: :checkout_billing)
      doc = render_fields(form: form)

      assert attribute_of(doc, "#billing-profile-first_name", "name") ==
               "checkout_billing[first_name]"

      assert attribute_of(doc, "#billing-profile-first_name", "value") == "Ada"
      assert attribute_of(doc, "#billing-profile-country", "name") == "checkout_billing[country]"

      assert attribute_of(doc, "#billing-profile-type-company", "name") ==
               "checkout_billing[type]"
    end
  end

  describe "address" do
    test "country options come from the countries attr and select the form value" do
      doc = render_fields(form: profile_form(%{"country" => "LV"}))

      options = LazyHTML.query(doc, "#billing-profile-country option")
      assert LazyHTML.attribute(options, "value") == ["", "EE", "LV"]

      assert doc
             |> LazyHTML.query("#billing-profile-country option[selected]")
             |> LazyHTML.attribute("value") == ["LV"]
    end

    test "the state field is labelled by subdivision_label, with a fallback" do
      custom = render_fields(subdivision_label: "County")

      assert custom |> LazyHTML.query("label[for='billing-profile-state']") |> LazyHTML.text() =~
               "County"

      fallback = render_fields()

      assert fallback
             |> LazyHTML.query("label[for='billing-profile-state']")
             |> LazyHTML.text() =~ "State / Region"
    end
  end

  describe "options" do
    test "show_options renders the profile name and the default checkbox" do
      doc = render_fields()

      assert present?(doc, "input#billing-profile-name[name='billing_profile[name]']")
      assert present?(doc, "input#billing-profile-is_default[type=checkbox]")
    end

    test "show_options: false leaves both out" do
      doc = render_fields(show_options: false)

      refute present?(doc, "#billing-profile-name")
      refute present?(doc, "#billing-profile-is_default")
    end
  end

  describe "required markers" do
    test "the name fields of the shown type are always required" do
      individual = render_fields(type: "individual")

      for field <- ~w(first_name last_name) do
        assert required?(individual, "billing-profile-#{field}")
      end

      refute required?(individual, "billing-profile-middle_name")
      assert star?(individual, "billing-profile-first_name")

      company = render_fields(type: "company")
      assert required?(company, "billing-profile-company_name")
      assert star?(company, "billing-profile-company_name")
    end

    test "email is required only with require_email, for both types" do
      for type <- ~w(individual company) do
        optional = render_fields(type: type)
        refute required?(optional, "billing-profile-email")
        refute star?(optional, "billing-profile-email")

        marked = render_fields(type: type, require_email: true)
        assert required?(marked, "billing-profile-email")
        assert star?(marked, "billing-profile-email")
      end
    end

    test "phone is required only with require_phone, for both types" do
      for type <- ~w(individual company) do
        optional = render_fields(type: type)
        refute required?(optional, "billing-profile-phone")
        refute star?(optional, "billing-profile-phone")

        marked = render_fields(type: type, require_phone: true)
        assert required?(marked, "billing-profile-phone")
        assert star?(marked, "billing-profile-phone")
      end
    end

    test "street, city, postal code and country are required only with require_address" do
      optional = render_fields()

      for field <- ~w(address_line1 city postal_code country) do
        refute required?(optional, "billing-profile-#{field}")
      end

      marked = render_fields(require_address: true)

      for field <- ~w(address_line1 city postal_code country) do
        assert required?(marked, "billing-profile-#{field}")
        assert star?(marked, "billing-profile-#{field}")
      end

      refute required?(marked, "billing-profile-address_line2")
      refute required?(marked, "billing-profile-state")
    end
  end

  describe "errors" do
    test "show the changeset errors of the fields on display" do
      doc = render_fields(form: profile_form(%{"type" => "individual"}, require_email: true))

      text = LazyHTML.text(doc)
      assert text =~ "is required for individuals"
      assert text =~ "can't be blank"
    end

    test "show nothing on a pristine form" do
      pristine = to_form(BillingProfile.fields_changeset(%BillingProfile{}, %{}))
      doc = render_fields(form: pristine)

      refute LazyHTML.text(doc) =~ "is required for individuals"
    end
  end

  describe "locale" do
    setup do
      original = Gettext.get_locale(PhoenixKitBilling.Gettext)
      on_exit(fn -> Gettext.put_locale(PhoenixKitBilling.Gettext, original) end)
    end

    defp label_text(doc, field),
      do: doc |> LazyHTML.query("label[for='billing-profile-#{field}']") |> LazyHTML.text()

    test "labels follow the locale set on PhoenixKitBilling.Gettext" do
      for {locale, first, address} <- [
            {"de", "Vorname", "Adresszeile 1"},
            {"fr", "Prénom", "Adresse, ligne 1"},
            {"et", "Eesnimi", "Aadressirida 1"},
            {"en", "First Name", "Address Line 1"}
          ] do
        Gettext.put_locale(PhoenixKitBilling.Gettext, locale)
        doc = render_fields()

        assert label_text(doc, "first_name") =~ first, locale
        assert label_text(doc, "address_line1") =~ address, locale
      end
    end

    test "validation messages follow the locale" do
      Gettext.put_locale(PhoenixKitBilling.Gettext, "de")

      assert %{first_name: ["ist für Privatpersonen erforderlich"]} =
               %BillingProfile{}
               |> BillingProfile.fields_changeset(%{})
               |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)

      Gettext.put_locale(PhoenixKitBilling.Gettext, "fr")

      assert %{email: ["doit être une adresse e-mail valide"]} =
               %BillingProfile{}
               |> BillingProfile.fields_changeset(%{"type" => "company", "email" => "x y"})
               |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    end
  end

  describe "catalogues" do
    @sources [
      "lib/phoenix_kit_billing/web/components/billing_profile_fields.ex",
      "lib/phoenix_kit_billing/schemas/billing_profile.ex"
    ]

    defp source_msgids do
      for path <- @sources,
          [_, id] <- Regex.scan(~r/gettext\(\s*"((?:[^"\\]|\\.)*)"/, File.read!(path)),
          uniq: true,
          do: id
    end

    for locale <- ~w(de fr et ru uk) do
      test "#{locale} translates every string the shared form uses" do
        path = "priv/gettext/#{unquote(locale)}/LC_MESSAGES/default.po"
        %Expo.Messages{messages: messages} = Expo.PO.parse_file!(path)

        translated =
          for %Expo.Message.Singular{msgid: id, msgstr: str} <- messages,
              IO.iodata_to_binary(str) != "",
              into: MapSet.new(),
              do: IO.iodata_to_binary(id)

        missing = Enum.reject(source_msgids(), &MapSet.member?(translated, &1))
        assert missing == [], "#{unquote(locale)} lacks: #{inspect(missing)}"
      end
    end
  end

  describe "inner_block" do
    test "renders after the fields" do
      assigns = %{form: profile_form(), countries: @countries}

      html =
        rendered_to_string(~H"""
        <BillingProfileFields.billing_profile_fields form={@form} type="individual" countries={@countries}>
          <label id="extra-checkbox">Save for next time</label>
        </BillingProfileFields.billing_profile_fields>
        """)

      doc = LazyHTML.from_fragment(html)
      assert present?(doc, "#billing-profile #extra-checkbox")

      {options_at, _} = :binary.match(html, "billing-profile-is_default")
      {extra_at, _} = :binary.match(html, "extra-checkbox")
      assert options_at < extra_at
    end
  end
end
