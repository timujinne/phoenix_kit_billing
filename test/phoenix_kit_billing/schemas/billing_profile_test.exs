defmodule PhoenixKitBilling.Schemas.BillingProfileTest do
  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling.BillingProfile

  @individual %{
    user_uuid: Ecto.UUID.generate(),
    type: "individual",
    first_name: "John",
    last_name: "Doe",
    country: "EE"
  }

  @company %{
    user_uuid: Ecto.UUID.generate(),
    type: "company",
    company_name: "Acme OÜ",
    country: "EE"
  }

  describe "changeset/2" do
    test "individual is valid and auto-sets display name" do
      cs = BillingProfile.changeset(%BillingProfile{}, @individual)
      assert cs.valid?
      assert get_change(cs, :name) == "John Doe"
    end

    test "company is valid and auto-sets display name from company_name" do
      cs = BillingProfile.changeset(%BillingProfile{}, @company)
      assert cs.valid?
      assert get_change(cs, :name) == "Acme OÜ"
    end

    test "requires user_uuid and type" do
      errors = errors_on(BillingProfile.changeset(%BillingProfile{}, %{}))
      assert "can't be blank" in errors.user_uuid
      # type has a default ("individual") so it won't be blank; the
      # individual-specific required fields fire instead.
      assert Map.has_key?(errors, :first_name)
    end

    test "individual requires first_name and last_name" do
      cs =
        BillingProfile.changeset(%BillingProfile{}, %{
          user_uuid: Ecto.UUID.generate(),
          type: "individual"
        })

      errors = errors_on(cs)
      assert "is required for individuals" in errors.first_name
      assert "is required for individuals" in errors.last_name
    end

    test "company requires company_name" do
      cs =
        BillingProfile.changeset(%BillingProfile{}, %{
          user_uuid: Ecto.UUID.generate(),
          type: "company"
        })

      assert %{company_name: ["is required for companies"]} = errors_on(cs)
    end

    test "rejects invalid type" do
      cs = BillingProfile.changeset(%BillingProfile{}, %{@individual | type: "alien"})
      assert %{type: [_ | _]} = errors_on(cs)
    end

    test "country must be 2 chars" do
      cs = BillingProfile.changeset(%BillingProfile{}, %{@individual | country: "EST"})
      assert %{country: [_ | _]} = errors_on(cs)
    end

    test "invalid email format rejected" do
      cs =
        BillingProfile.changeset(%BillingProfile{}, Map.put(@individual, :email, "not an email"))

      assert %{email: [_ | _]} = errors_on(cs)
    end

    test "EU VAT number is upcased when valid" do
      attrs = Map.put(@company, :company_vat_number, "ee123456789")
      cs = BillingProfile.changeset(%BillingProfile{}, attrs)
      assert cs.valid?
      assert get_change(cs, :company_vat_number) == "EE123456789"
    end

    test "malformed EU VAT number is rejected" do
      attrs = Map.put(@company, :company_vat_number, "!!")
      cs = BillingProfile.changeset(%BillingProfile{}, attrs)
      assert %{company_vat_number: [_ | _]} = errors_on(cs)
    end
  end

  describe "fields_changeset/3" do
    @individual_fields %{"type" => "individual", "first_name" => "John", "last_name" => "Doe"}
    @company_fields %{"type" => "company", "company_name" => "Acme OÜ"}
    @address %{
      "address_line1" => "Main St 1",
      "city" => "Tallinn",
      "postal_code" => "10115",
      "country" => "EE"
    }

    test "individual is valid without a user and auto-sets the display name" do
      cs = BillingProfile.fields_changeset(%BillingProfile{}, @individual_fields)
      assert cs.valid?
      assert get_change(cs, :name) == "John Doe"
    end

    test "company is valid without a user and takes its name from company_name" do
      cs = BillingProfile.fields_changeset(%BillingProfile{}, @company_fields)
      assert cs.valid?
      assert get_change(cs, :name) == "Acme OÜ"
    end

    test "never requires user_uuid" do
      cs = BillingProfile.fields_changeset(%BillingProfile{}, @individual_fields)
      refute Map.has_key?(errors_on(cs), :user_uuid)
    end

    test "does not cast user_uuid, is_default or metadata" do
      cs =
        BillingProfile.fields_changeset(
          %BillingProfile{},
          Map.merge(@individual_fields, %{
            "user_uuid" => Ecto.UUID.generate(),
            "is_default" => "true",
            "metadata" => %{"a" => 1}
          })
        )

      refute Map.has_key?(cs.changes, :user_uuid)
      refute Map.has_key?(cs.changes, :is_default)
      refute Map.has_key?(cs.changes, :metadata)
    end

    test "individual requires first and last name" do
      errors = errors_on(BillingProfile.fields_changeset(%BillingProfile{}, %{}))
      assert "is required for individuals" in errors.first_name
      assert "is required for individuals" in errors.last_name
    end

    test "company requires company_name but not a person's name" do
      errors =
        errors_on(BillingProfile.fields_changeset(%BillingProfile{}, %{"type" => "company"}))

      assert "is required for companies" in errors.company_name
      refute Map.has_key?(errors, :first_name)
    end

    test "rejects an unknown type" do
      cs = BillingProfile.fields_changeset(%BillingProfile{}, %{"type" => "alien"})
      assert %{type: [_ | _]} = errors_on(cs)
    end

    test "country must be 2 chars" do
      cs =
        BillingProfile.fields_changeset(
          %BillingProfile{},
          Map.put(@individual_fields, "country", "EST")
        )

      assert %{country: [_ | _]} = errors_on(cs)
    end

    test "email is optional by default but must be well-formed when given" do
      assert BillingProfile.fields_changeset(%BillingProfile{}, @individual_fields).valid?

      cs =
        BillingProfile.fields_changeset(
          %BillingProfile{},
          Map.put(@individual_fields, "email", "not an email")
        )

      assert %{email: ["must be a valid email address"]} = errors_on(cs)
    end

    test "require_email: true requires the email" do
      cs =
        BillingProfile.fields_changeset(%BillingProfile{}, @individual_fields,
          require_email: true
        )

      assert %{email: ["can't be blank"]} = errors_on(cs)

      assert BillingProfile.fields_changeset(
               %BillingProfile{},
               Map.put(@individual_fields, "email", "john@example.com"),
               require_email: true
             ).valid?
    end

    test "require_email applies to companies too" do
      cs =
        BillingProfile.fields_changeset(%BillingProfile{}, @company_fields, require_email: true)

      assert %{email: ["can't be blank"]} = errors_on(cs)
    end

    test "the phone is optional by default" do
      assert BillingProfile.fields_changeset(%BillingProfile{}, @individual_fields).valid?
    end

    test "require_phone: true requires the phone, for both types" do
      for fields <- [@individual_fields, @company_fields] do
        cs = BillingProfile.fields_changeset(%BillingProfile{}, fields, require_phone: true)
        assert %{phone: ["can't be blank"]} = errors_on(cs)

        blank = Map.put(fields, "phone", "   ")

        assert %{phone: ["can't be blank"]} =
                 errors_on(
                   BillingProfile.fields_changeset(%BillingProfile{}, blank, require_phone: true)
                 )

        assert BillingProfile.fields_changeset(
                 %BillingProfile{},
                 Map.put(fields, "phone", "+372 5555 5555"),
                 require_phone: true
               ).valid?
      end
    end

    test "require_phone is independent of require_email and require_address" do
      cs =
        BillingProfile.fields_changeset(
          %BillingProfile{},
          Map.put(@individual_fields, "phone", "+372 5555 5555"),
          require_phone: true
        )

      assert cs.valid?
      refute Map.has_key?(errors_on(cs), :email)
    end

    test "the address is optional by default" do
      assert BillingProfile.fields_changeset(%BillingProfile{}, @individual_fields).valid?
    end

    test "require_address: true requires street, city, postal code and country" do
      profile = %BillingProfile{country: nil}

      errors =
        errors_on(
          BillingProfile.fields_changeset(profile, @individual_fields, require_address: true)
        )

      assert %{
               address_line1: ["can't be blank"],
               city: ["can't be blank"],
               postal_code: ["can't be blank"],
               country: ["can't be blank"]
             } = errors

      refute Map.has_key?(errors, :address_line2)
      refute Map.has_key?(errors, :state)
    end

    test "require_address: true treats a blank country param as missing" do
      string_keys =
        @individual_fields |> Map.merge(@address) |> Map.put("country", "")

      atom_keys = Map.new(string_keys, fn {k, v} -> {String.to_atom(k), v} end)

      for attrs <- [string_keys, atom_keys] do
        cs = BillingProfile.fields_changeset(%BillingProfile{}, attrs, require_address: true)
        assert %{country: ["can't be blank"]} = errors_on(cs)
      end
    end

    test "require_address: true keeps a country that is absent from the params" do
      attrs = Map.merge(@individual_fields, Map.delete(@address, "country"))
      cs = BillingProfile.fields_changeset(%BillingProfile{}, attrs, require_address: true)

      assert cs.valid?
      assert get_field(cs, :country) == "EE"
    end

    test "without require_address a blank country keeps the default, as changeset/2 does" do
      attrs = Map.put(@individual_fields, "country", "")

      assert get_field(BillingProfile.fields_changeset(%BillingProfile{}, attrs), :country) ==
               "EE"

      full =
        BillingProfile.changeset(
          %BillingProfile{},
          Map.put(attrs, "user_uuid", Ecto.UUID.generate())
        )

      assert get_field(full, :country) == "EE"
    end

    test "require_address: true passes with a full address" do
      attrs = Map.merge(@individual_fields, @address)

      assert BillingProfile.fields_changeset(%BillingProfile{}, attrs, require_address: true).valid?
    end

    test "both options together" do
      errors =
        errors_on(
          BillingProfile.fields_changeset(%BillingProfile{}, @individual_fields,
            require_email: true,
            require_address: true
          )
        )

      assert Map.has_key?(errors, :email)
      assert Map.has_key?(errors, :address_line1)
    end

    test "EU VAT number is upcased when valid and rejected when malformed" do
      ok =
        BillingProfile.fields_changeset(
          %BillingProfile{},
          Map.put(@company_fields, "company_vat_number", "ee123456789")
        )

      assert ok.valid?
      assert get_change(ok, :company_vat_number) == "EE123456789"

      bad =
        BillingProfile.fields_changeset(
          %BillingProfile{},
          Map.put(@company_fields, "company_vat_number", "!!")
        )

      assert %{company_vat_number: [_ | _]} = errors_on(bad)
    end

    test "a VAT number outside the EU is not format-checked" do
      cs =
        BillingProfile.fields_changeset(
          %BillingProfile{},
          Map.merge(@company_fields, %{"company_vat_number" => "!!", "country" => "US"})
        )

      assert cs.valid?
    end

    test "changes an existing profile" do
      profile = %BillingProfile{type: "individual", first_name: "John", last_name: "Doe"}
      cs = BillingProfile.fields_changeset(profile, %{"first_name" => "Jane"})
      assert cs.valid?
      assert get_change(cs, :first_name) == "Jane"
    end

    test "changeset/2 stays in step with it: same field errors plus the user" do
      attrs = %{"type" => "company", "company_vat_number" => "!!", "country" => "EE"}

      fields_errors = errors_on(BillingProfile.fields_changeset(%BillingProfile{}, attrs))
      full_errors = errors_on(BillingProfile.changeset(%BillingProfile{}, attrs))

      assert Map.delete(full_errors, :user_uuid) == fields_errors
      assert "can't be blank" in full_errors.user_uuid
    end
  end

  describe "length limits" do
    @limits [
      name: 255,
      first_name: 255,
      last_name: 255,
      middle_name: 255,
      phone: 255,
      email: 255,
      company_name: 255,
      company_vat_number: 20,
      company_registration_number: 30,
      address_line1: 255,
      address_line2: 255,
      city: 255,
      state: 255,
      postal_code: 20
    ]

    # Outside the EU, so the VAT field is not format-checked and a 20-char value is valid.
    @base %{
      "type" => "individual",
      "first_name" => "John",
      "last_name" => "Doe",
      "country" => "US"
    }

    defp long(field, size) do
      case field do
        :email -> String.duplicate("a", size - 4) <> "@b.c"
        _ -> String.duplicate("x", size)
      end
    end

    for {field, max} <- @limits do
      test "#{field} accepts #{max} characters and rejects #{max + 1}" do
        field = unquote(field)
        max = unquote(max)

        ok =
          BillingProfile.fields_changeset(
            %BillingProfile{},
            Map.put(@base, to_string(field), long(field, max))
          )

        assert ok.valid?, inspect(errors_on(ok))

        bad =
          BillingProfile.fields_changeset(
            %BillingProfile{},
            Map.put(@base, to_string(field), long(field, max + 1))
          )

        assert %{^field => [message]} = errors_on(bad)
        assert message =~ "at most #{max} character"
      end
    end

    test "the legal address is unbounded (text column)" do
      attrs = %{
        "type" => "company",
        "company_name" => "Acme",
        "company_legal_address" => String.duplicate("x", 5000)
      }

      assert BillingProfile.fields_changeset(%BillingProfile{}, attrs).valid?
    end

    test "an auto-generated name is cut to the column size" do
      attrs = Map.merge(@base, %{"first_name" => String.duplicate("a", 255), "last_name" => "b"})
      cs = BillingProfile.fields_changeset(%BillingProfile{}, attrs)

      assert cs.valid?
      assert String.length(get_change(cs, :name)) == 255
    end

    test "changeset/2 shares the limits" do
      attrs =
        Map.merge(@base, %{
          "postal_code" => String.duplicate("1", 21),
          "user_uuid" => Ecto.UUID.generate()
        })

      assert %{postal_code: [_]} = errors_on(BillingProfile.changeset(%BillingProfile{}, attrs))
    end

    test "limits count code points like the varchar columns, not graphemes" do
      # 20 graphemes, 40 code points: Postgres would reject it for varchar(20).
      combining = String.duplicate("e\u0301", 20)

      cs =
        BillingProfile.fields_changeset(
          %BillingProfile{},
          Map.put(@base, "postal_code", combining)
        )

      assert %{postal_code: [_]} = errors_on(cs)
    end

    test "a combining-accent name is truncated to the column's code points" do
      user = fixture_user()
      first = String.duplicate("e\u0301", 200)
      attrs = Map.merge(@base, %{"first_name" => String.duplicate("a", 100), "last_name" => "b"})

      cs =
        BillingProfile.fields_changeset(
          %BillingProfile{},
          Map.put(attrs, "first_name", first <> "x")
        )

      name = get_change(cs, :name)
      assert length(String.codepoints(name)) <= 255

      assert {:ok, _} =
               PhoenixKitBilling.create_billing_profile(
                 user.uuid,
                 Map.merge(@base, %{
                   "first_name" => String.duplicate("e\u0301", 120),
                   "last_name" => "b"
                 })
               )
    end

    test "an over-long value is an error from the context, not a database exception" do
      user = fixture_user()
      attrs = Map.put(@base, "postal_code", String.duplicate("1", 21))

      assert {:error, %Ecto.Changeset{}} =
               PhoenixKitBilling.create_billing_profile(user.uuid, attrs)
    end
  end

  describe "form_fields/0" do
    test "lists the fields fields_changeset/3 casts" do
      fields = BillingProfile.form_fields()

      attrs = Map.new(fields, &{to_string(&1), "x"})
      cs = BillingProfile.fields_changeset(%BillingProfile{}, attrs)

      assert MapSet.new(Map.keys(cs.changes)) |> MapSet.subset?(MapSet.new(fields))

      for field <- fields -- [:type, :country, :email, :company_vat_number, :name] do
        assert get_change(cs, field) == "x", "#{field} not cast"
      end
    end

    test "leaves out what a caller sets itself" do
      fields = BillingProfile.form_fields()

      refute :user_uuid in fields
      refute :is_default in fields
      refute :metadata in fields
    end

    test "covers every user-facing schema field" do
      owned = [:uuid, :user_uuid, :is_default, :metadata, :inserted_at, :updated_at, :user]
      schema_fields = BillingProfile.__schema__(:fields) -- owned

      assert Enum.sort(BillingProfile.form_fields()) == Enum.sort(schema_fields)
    end
  end

  describe "to_snapshot/1" do
    test "drops nil fields and includes a snapshot timestamp" do
      profile = %BillingProfile{
        uuid: Ecto.UUID.generate(),
        type: "individual",
        name: "John Doe",
        first_name: "John",
        last_name: "Doe",
        country: "EE"
      }

      snap = BillingProfile.to_snapshot(profile)
      assert snap.name == "John Doe"
      assert snap.country == "EE"
      assert Map.has_key?(snap, :snapshot_at)
      refute Map.has_key?(snap, :company_name)
    end
  end

  describe "display_name/1" do
    test "prefers name, falls back to type-specific" do
      assert BillingProfile.display_name(%BillingProfile{name: "Explicit"}) == "Explicit"

      assert BillingProfile.display_name(%BillingProfile{
               name: nil,
               type: "individual",
               first_name: "A",
               last_name: "B"
             }) == "A B"

      assert BillingProfile.display_name(%BillingProfile{
               name: nil,
               type: "company",
               company_name: "C OÜ"
             }) ==
               "C OÜ"
    end
  end
end
