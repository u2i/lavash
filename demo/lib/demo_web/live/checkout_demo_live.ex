defmodule DemoWeb.CheckoutDemoLive do
  @moduledoc """
  Shopify-style checkout demo showcasing Lavash styling capabilities.

  Demonstrates:
  - Ash `form` DSL for auto-generated validation from resource constraints
  - `data-lavash-form-field` shorthand for form input bindings
  - `data-lavash-toggle` for dynamic class switching on validation state
  - `data-lavash-enabled` for button enable/disable
  - `data-lavash-visible` for conditional section visibility
  - `data-lavash-display` for reactive text updates
  - `extend_errors` for custom validation messages beyond Ash constraints
  - `defrx` for reusable reactive validation functions
  """
  use Lavash.LiveView
  import Lavash.Rx
  import Lavash.LiveView.Components

  alias Demo.Forms.Payment

  # ─────────────────────────────────────────────────────────────────
  # Reusable Reactive Functions (defrx)
  # These are expanded inline at each call site and transpiled to JS
  # ─────────────────────────────────────────────────────────────────

  # Validates expiration date: MM must be 01-12 and total length must be 4 digits
  defrx valid_expiry?(digits) do
    String.length(digits) == 4 &&
      String.to_integer(String.slice(digits, 0, 2) || "0") >= 1 &&
      String.to_integer(String.slice(digits, 0, 2) || "0") <= 12
  end

  # Validates CVV length based on card type (4 for Amex, 3 for others)
  defrx valid_cvv?(digits, is_amex) do
    if(is_amex, do: String.length(digits) == 4, else: String.length(digits) == 3)
  end

  # Expected length for each card type (15 for Amex, 16 for others)
  defrx expected_card_length(is_amex) do
    if(is_amex, do: 15, else: 16)
  end

  # Luhn checksum - processes reversed digits with doubling at odd indices
  # Takes reversed list of digit integers, returns sum
  # Note: No intermediate variables allowed in defrx - must be single expression
  defrx luhn_sum(digits_reversed) do
    Enum.sum(
      Enum.map(
        Enum.with_index(digits_reversed),
        fn {digit, index} ->
          if(rem(index, 2) == 1,
            do: if(digit * 2 > 9, do: digit * 2 - 9, else: digit * 2),
            else: digit
          )
        end
      )
    )
  end

  # Convert digits string to reversed integer array for Luhn calculation
  defrx digits_to_reversed_ints(digits) do
    Enum.reverse(Enum.map(String.graphemes(digits), fn d -> String.to_integer(d) end))
  end

  # Full card number validation: all digits, correct length, passes Luhn
  defrx valid_card_number?(digits, is_amex) do
    String.match?(digits, ~r/^\d+$/) &&
      String.length(digits) == expected_card_length(is_amex) &&
      rem(luhn_sum(digits_to_reversed_ints(digits)), 10) == 0
  end

  # ─────────────────────────────────────────────────────────────────
  # State
  # ─────────────────────────────────────────────────────────────────

  # Payment form params - Lavash automatically populates from form events
  state :payment_params, :map, from: :ephemeral, default: %{}, optimistic: true

  # UI state
  state :payment_method, :string, from: :ephemeral, default: "card", optimistic: true
  state :use_shipping_as_billing, :boolean, from: :ephemeral, default: true, optimistic: true
  state :ship_to_expanded, :boolean, from: :ephemeral, default: true, optimistic: true
  state :submitted, :boolean, from: :ephemeral, default: false, optimistic: true

  # Order data (would come from cart in real app)
  state :subtotal, :decimal, from: :ephemeral, default: Decimal.new("20.00"), optimistic: false
  state :shipping, :decimal, from: :ephemeral, default: Decimal.new("8.00"), optimistic: false

  # ─────────────────────────────────────────────────────────────────
  # Ash Form - Auto-generates validation from Payment resource
  # ─────────────────────────────────────────────────────────────────

  # Auto-generates: payment_card_number_valid, payment_card_number_errors, etc.
  # Skip constraints for fields that use extend_errors with card-type-specific messages
  form :payment, Payment do
    create :pay
    skip_constraints [:card_number, :expiry, :cvv]
  end

  # ─────────────────────────────────────────────────────────────────
  # Card Type Detection (for badge highlighting and CVV length rules)
  # ─────────────────────────────────────────────────────────────────

  calculate :card_number_raw, rx(@payment_params["card_number"] || "")
  calculate :card_number_digits, rx(String.replace(@card_number_raw, ~r/\D/, ""))

  # Formatted card number display (4242 4242 4242 4242)
  calculate :card_number_formatted,
    rx(@card_number_digits |> String.chunk(4) |> Enum.join(" "))

  # Detect card type from first digit(s)
  calculate :is_visa, rx(String.starts_with?(@card_number_digits, "4"))
  calculate :is_mastercard, rx(String.starts_with?(@card_number_digits, "5"))
  calculate :is_amex, rx(String.starts_with?(@card_number_digits, "34") or String.starts_with?(@card_number_digits, "37"))
  calculate :is_discover, rx(String.starts_with?(@card_number_digits, "6011"))

  # Card type display for badges - highlight detected type, dim others
  calculate :has_card_type, rx(@is_visa or @is_mastercard or @is_amex or @is_discover)

  # Card type name for display (or empty if none detected)
  calculate :card_type_display,
    rx(
      if @is_visa do
        "Visa"
      else
        if @is_mastercard do
          "Mastercard"
        else
          if @is_amex do
            "American Express"
          else
            if @is_discover do
              "Discover"
            else
              ""
            end
          end
        end
      end
    )
  # Show badge only if: it's the detected type, OR no type detected yet
  calculate :show_visa, rx(@is_visa or not @has_card_type)
  calculate :show_mastercard, rx(@is_mastercard or not @has_card_type)
  calculate :show_amex, rx(@is_amex or not @has_card_type)
  calculate :show_discover, rx(@is_discover or not @has_card_type)

  # ─────────────────────────────────────────────────────────────────
  # Validation (using defrx functions defined above)
  # ─────────────────────────────────────────────────────────────────

  # Card number: validates all-digits, length for card type, and Luhn checksum
  # Uses defrx valid_card_number? which expands inline and transpiles to JS
  calculate :card_number_valid,
    rx(@payment_card_number_valid && valid_card_number?(@card_number_digits, @is_amex))

  extend_errors :payment_card_number_errors do
    error rx(!valid_card_number?(@card_number_digits, @is_amex) && @payment_card_number_valid),
      "Enter a valid card number"
  end

  # Expiration date: extract digits and validate using defrx
  calculate :expiry_raw, rx(@payment_params["expiry"] || "")
  calculate :expiry_digits, rx(String.replace(@expiry_raw, ~r/\D/, ""))
  calculate :expiry_valid, rx(@payment_expiry_valid && valid_expiry?(@expiry_digits))

  extend_errors :payment_expiry_errors do
    error rx(!valid_expiry?(@expiry_digits) && @payment_expiry_valid),
      "Enter a valid expiration date"
  end

  # Formatted expiry display (MM/YY)
  calculate :expiry_formatted,
    rx(@expiry_digits |> String.chunk(2) |> Enum.join("/"))

  # CVV: extract digits and validate using defrx
  calculate :cvv_raw, rx(@payment_params["cvv"] || "")
  calculate :cvv_digits, rx(String.replace(@cvv_raw, ~r/\D/, ""))
  calculate :cvv_valid, rx(@payment_cvv_valid && valid_cvv?(@cvv_digits, @is_amex))

  extend_errors :payment_cvv_errors do
    error rx(!valid_cvv?(@cvv_digits, @is_amex) && @payment_cvv_valid),
      "Enter a valid security code"
  end

  # ─────────────────────────────────────────────────────────────────
  # Combined Form Validity
  # ─────────────────────────────────────────────────────────────────

  calculate :card_form_valid, rx(@card_number_valid && @expiry_valid && @cvv_valid && @payment_name_valid)
  calculate :is_card_payment, rx(@payment_method == "card")
  calculate :form_valid, rx(if(@is_card_payment, do: @card_form_valid, else: true))

  # ─────────────────────────────────────────────────────────────────
  # Computed Values
  # ─────────────────────────────────────────────────────────────────

  # These use Decimal which can't be transpiled to JS, but since the source
  # values (subtotal, shipping) are optimistic: false, we mark these as well
  calculate :total, rx(Decimal.add(@subtotal, @shipping)), optimistic: false
  calculate :total_display, rx("$" <> Decimal.to_string(@total)), optimistic: false
  calculate :subtotal_display, rx("$" <> Decimal.to_string(@subtotal)), optimistic: false
  calculate :shipping_display, rx("$" <> Decimal.to_string(@shipping)), optimistic: false

  # ─────────────────────────────────────────────────────────────────
  # Actions
  # ─────────────────────────────────────────────────────────────────

  actions do
    action :select_card do
      set :payment_method, "card"
    end

    action :select_paypal do
      set :payment_method, "paypal"
    end

    action :toggle_billing_address do
      update :use_shipping_as_billing, &(not &1)
    end

    action :toggle_ship_to do
      update :ship_to_expanded, &(not &1)
    end

    action :save do
      submit :payment, on_success: :on_saved, on_error: :on_error
    end

    action :on_saved do
      set :submitted, true
    end

    action :on_error do
      # Form errors will be displayed via Ash form
    end

    action :reset do
      set :payment_params, %{}
      set :submitted, false
      set :payment_method, "card"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Template
  # ─────────────────────────────────────────────────────────────────

  template """
  <div id="checkout-demo" data-theme="shopify" class="bg-base-200 min-h-screen">
    <main class="mx-auto max-w-6xl p-4 lg:p-8">
      <%= if @submitted do %>
        <div class="card border border-base-300 bg-base-100 shadow-sm max-w-lg mx-auto">
          <div class="card-body text-center">
            <div class="text-6xl mb-4 text-success">✓</div>
            <h2 class="text-2xl font-bold mb-2">Payment Complete!</h2>
            <p class="text-base-content/70 mb-4">Thank you for your order.</p>
            <div class="bg-base-200 rounded-xl p-4 mb-4">
              <div class="flex justify-between mb-2">
                <span>Subtotal</span>
                <span>{@subtotal_display}</span>
              </div>
              <div class="flex justify-between mb-2">
                <span>Shipping</span>
                <span>{@shipping_display}</span>
              </div>
              <div class="divider my-2"></div>
              <div class="flex justify-between font-bold text-lg">
                <span>Total</span>
                <span data-lavash-display="total_display">{@total_display}</span>
              </div>
            </div>
            <button phx-click="reset" class="btn btn-primary">Start Over</button>
          </div>
        </div>
      <% else %>
        <div class="grid grid-cols-1 gap-6 lg:grid-cols-[1.6fr_1fr]">
          <!-- LEFT COLUMN -->
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body gap-6">
              <!-- Payment method buttons -->
              <div class="flex flex-col gap-3">
                <div class="join w-full">
                  <button class="btn join-item btn-primary w-1/3 font-bold">shop</button>
                  <button class="btn join-item w-1/3 bg-yellow-400 text-slate-900 border-yellow-400 font-bold hover:bg-yellow-500">
                    PayPal
                  </button>
                  <button class="btn join-item btn-info w-1/3 font-bold text-white">venmo</button>
                </div>

                <div class="divider text-xs font-semibold text-base-content/50 uppercase">OR</div>

                <!-- Signed-in row -->
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-3">
                    <div class="avatar placeholder">
                      <div class="w-9 rounded-full bg-base-200 text-base-content">
                        <span class="text-sm font-bold">T</span>
                      </div>
                    </div>
                    <div class="text-sm font-semibold text-base-content/70">tom.clarke@gmail.com</div>
                  </div>
                  <button class="btn btn-ghost btn-sm" aria-label="More">⋮</button>
                </div>
              </div>

              <!-- Ship to -->
              <div class="space-y-3">
                <div class="flex items-center justify-between">
                  <div class="text-sm font-semibold">Ship to</div>
                  <button
                    phx-click="toggle_ship_to"
                    class="btn btn-ghost btn-sm"
                    aria-label="Toggle"
                  >
                    <span data-lavash-visible="ship_to_expanded" class={unless @ship_to_expanded, do: "hidden"}>▴</span>
                    <span data-lavash-visible="ship_to_expanded" data-lavash-toggle="ship_to_expanded|hidden|" class={if @ship_to_expanded, do: "hidden"}>▾</span>
                  </button>
                </div>

                <div
                  data-lavash-visible="ship_to_expanded"
                  class={"flex items-start justify-between rounded-lg border border-base-300 bg-base-200/40 p-4" <> unless @ship_to_expanded, do: " hidden", else: ""}
                >
                  <div>
                    <div class="font-semibold">Thomas Clarke, 78 Example Street</div>
                    <div class="text-sm opacity-70">Red Hook, NY 12571, US</div>
                  </div>
                  <button class="btn btn-ghost btn-sm" aria-label="Edit address">⋮</button>
                </div>

                <a class="link link-primary inline-flex items-center gap-2 text-sm font-semibold" href="#">
                  <span class="text-lg leading-none">＋</span>
                  Use a different address
                </a>
              </div>

              <!-- Shipping method -->
              <div class="space-y-3">
                <div class="flex items-center justify-between">
                  <div class="text-sm font-semibold">Shipping method</div>
                  <button class="btn btn-ghost btn-sm" aria-label="Collapse">▾</button>
                </div>

                <div class="flex items-center justify-between border-t border-base-300 pt-3">
                  <div class="text-sm font-semibold">Light Shipping</div>
                  <div class="text-sm font-semibold" data-lavash-display="shipping_display">{@shipping_display}</div>
                </div>
              </div>

              <!-- Payment -->
              <div class="space-y-4 border-t border-base-300 pt-6">
                <div>
                  <div class="text-2xl font-bold">Payment</div>
                  <div class="text-sm opacity-70">All transactions are secure and encrypted.</div>
                </div>

                <!-- Credit Card Option -->
                <div
                  class="rounded-lg border border-base-300 p-4 cursor-pointer transition-all"
                  data-lavash-toggle="is_card_payment|border-primary ring-1 ring-primary|border-base-300"
                >
                  <div class="flex items-center gap-3 cursor-pointer" phx-click="select_card">
                    <input
                      type="radio"
                      name="payment_method"
                      class="radio radio-primary"
                      checked={@payment_method == "card"}
                    />
                    <span class="font-semibold">Credit card</span>
                    <span class="ml-auto flex items-center gap-1">
                      <span
                        data-lavash-visible="has_card_type"
                        data-lavash-display="card_type_display"
                        class={"text-sm font-medium text-primary" <> unless @has_card_type, do: " hidden", else: ""}
                      >{@card_type_display}</span>
                      <span
                        data-lavash-visible="show_visa"
                        class={"badge badge-outline badge-sm" <> unless @show_visa, do: " hidden", else: ""}
                      >VISA</span>
                      <span
                        data-lavash-visible="show_mastercard"
                        class={"badge badge-outline badge-sm" <> unless @show_mastercard, do: " hidden", else: ""}
                      >MC</span>
                      <span
                        data-lavash-visible="show_amex"
                        class={"badge badge-outline badge-sm" <> unless @show_amex, do: " hidden", else: ""}
                      >AMEX</span>
                      <span
                        data-lavash-visible="show_discover"
                        class={"badge badge-outline badge-sm" <> unless @show_discover, do: " hidden", else: ""}
                      >DISC</span>
                    </span>
                  </div>

                  <!-- Card form fields - only visible when card is selected -->
                  <.form
                    for={@payment}
                    phx-submit="save"
                    data-lavash-visible="is_card_payment"
                    class={"mt-4 space-y-3" <> if @payment_method != "card", do: " hidden", else: ""}
                  >
                    <!-- Card Number -->
                    <.input
                      field={@payment[:card_number]}
                      label="Card number"
                      valid={@card_number_valid}
                      valid_field="card_number_valid"
                      errors={@payment_card_number_errors}
                      show_errors={assigns[:payment_card_number_show_errors]}
                      autocomplete="cc-number"
                      inputmode="numeric"
                      format="credit-card"
                    />

                    <div class="grid grid-cols-2 gap-3">
                      <!-- Expiration -->
                      <.input
                        field={@payment[:expiry]}
                        label="Expiration (MM/YY)"
                        valid={@expiry_valid}
                        valid_field="expiry_valid"
                        errors={@payment_expiry_errors}
                        show_errors={assigns[:payment_expiry_show_errors]}
                        autocomplete="cc-exp"
                        inputmode="numeric"
                        maxlength="5"
                        format="expiry"
                      />

                      <!-- CVV -->
                      <.input
                        field={@payment[:cvv]}
                        label="Security code"
                        valid={@cvv_valid}
                        valid_field="cvv_valid"
                        errors={@payment_cvv_errors}
                        show_errors={assigns[:payment_cvv_show_errors]}
                        autocomplete="cc-csc"
                        inputmode="numeric"
                        maxlength="4"
                      />
                    </div>

                    <!-- Name on card -->
                    <.input
                      field={@payment[:name]}
                      label="Name on card"
                      valid={@payment_name_valid}
                      errors={@payment_name_errors}
                      show_errors={assigns[:payment_name_show_errors]}
                      autocomplete="cc-name"
                    />

                    <!-- Use shipping as billing -->
                    <label class="flex items-center gap-3 cursor-pointer pt-1">
                      <input
                        type="checkbox"
                        class="checkbox checkbox-sm"
                        checked={@use_shipping_as_billing}
                        phx-click="toggle_billing_address"
                      />
                      <span class="text-sm">Use shipping address as billing address</span>
                    </label>

                    <!-- Pay Button (inside form for submit) -->
                    <button
                      type="submit"
                      disabled={not @form_valid}
                      data-lavash-enabled="form_valid"
                      class={"btn btn-lg w-full " <>
                        if @form_valid do
                          "btn-primary"
                        else
                          "btn-disabled opacity-50 cursor-not-allowed"
                        end}
                      data-lavash-toggle="form_valid|btn-primary|btn-disabled opacity-50 cursor-not-allowed"
                    >
                      Pay now
                    </button>
                  </.form>
                </div>

                <!-- PayPal Option -->
                <div
                  class="flex items-center gap-3 rounded-lg border p-4 cursor-pointer transition-all"
                  phx-click="select_paypal"
                  data-lavash-toggle="is_card_payment|border-base-300|border-primary ring-1 ring-primary"
                >
                  <input
                    type="radio"
                    name="payment_method"
                    class="radio radio-primary"
                    checked={@payment_method == "paypal"}
                  />
                  <span class="font-semibold">PayPal</span>
                  <span class="ml-auto text-sm font-bold">
                    <span class="text-[#003087]">Pay</span><span class="text-[#009cde]">Pal</span>
                  </span>
                </div>

                <!-- Pay Button for PayPal (outside form) -->
                <%= if @payment_method == "paypal" do %>
                  <button
                    phx-click="on_saved"
                    class="btn btn-lg w-full btn-primary"
                  >
                    Pay with PayPal
                  </button>
                <% end %>
              </div>
            </div>
          </section>

          <!-- RIGHT COLUMN - Order Summary -->
          <aside class="lg:sticky lg:top-5 self-start">
            <section class="card border border-base-300 bg-base-100 shadow-sm">
              <div class="card-body gap-5">
                <!-- Item -->
                <div class="flex items-start gap-4">
                  <div class="relative">
                    <div class="avatar">
                      <div class="w-14 rounded-lg bg-base-200">
                        <svg viewBox="0 0 24 24" class="h-full w-full p-3 opacity-60" fill="none">
                          <path
                            d="M7 7h10v14H7V7Z"
                            stroke="currentColor"
                            stroke-width="1.5"
                            stroke-linejoin="round"
                          />
                          <path
                            d="M9 7V5h6v2"
                            stroke="currentColor"
                            stroke-width="1.5"
                            stroke-linecap="round"
                          />
                        </svg>
                      </div>
                    </div>
                    <div class="badge badge-neutral badge-sm absolute -right-2 -top-2">1</div>
                  </div>

                  <div class="flex-1">
                    <div class="font-bold">Bali Blue Moon</div>
                    <div class="text-sm opacity-70">12 oz</div>
                  </div>

                  <div class="text-sm font-bold" data-lavash-display="subtotal_display">{@subtotal_display}</div>
                </div>

                <!-- Gift card - Floating Label -->
                <div class="flex gap-3">
                  <label class="floating-label flex-1">
                    <input type="text" placeholder="Gift card or discount code" class="input input-bordered w-full" />
                    <span>Gift card or discount code</span>
                  </label>
                  <button class="btn btn-outline">Apply</button>
                </div>

                <!-- Totals -->
                <div class="space-y-2">
                  <div class="flex items-center justify-between">
                    <span class="opacity-80">Subtotal</span>
                    <span data-lavash-display="subtotal_display">{@subtotal_display}</span>
                  </div>
                  <div class="flex items-center justify-between">
                    <span class="opacity-80">Shipping</span>
                    <span data-lavash-display="shipping_display">{@shipping_display}</span>
                  </div>

                  <div class="divider my-2"></div>

                  <div class="flex items-end justify-between">
                    <div class="text-lg font-bold">Total</div>
                    <div class="flex items-baseline gap-2">
                      <div class="text-xs opacity-60">USD</div>
                      <div class="text-2xl font-bold" data-lavash-display="total_display">{@total_display}</div>
                    </div>
                  </div>
                </div>
              </div>
            </section>

            <!-- Test Card Numbers -->
            <div class="mt-4 p-4 bg-base-100 rounded-lg border border-base-300">
              <h3 class="font-semibold text-base-content mb-2">Test Card Numbers</h3>
              <ul class="text-sm text-base-content/70 space-y-1 font-mono">
                <li><span class="text-base-content font-semibold">Visa:</span> 4242 4242 4242 4242</li>
                <li><span class="text-base-content font-semibold">MC:</span> 5555 5555 5555 4444</li>
                <li><span class="text-base-content font-semibold">Amex:</span> 3782 822463 10005</li>
                <li><span class="text-base-content font-semibold">Disc:</span> 6011 1111 1111 1117</li>
              </ul>
              <p class="text-xs text-base-content/50 mt-2">Use any future date and any 3-4 digit CVV</p>
            </div>

            <!-- How it works -->
            <div class="mt-4 p-4 bg-base-100 rounded-lg border border-base-300">
              <h3 class="font-semibold text-base-content mb-2">Lavash Features</h3>
              <ul class="text-sm text-base-content/70 space-y-1">
                <li>• Ash <code class="bg-base-200 px-1 rounded text-xs">form</code> DSL for validation</li>
                <li>• <code class="bg-base-200 px-1 rounded text-xs">extend_errors</code> for custom messages</li>
                <li>• <code class="bg-base-200 px-1 rounded text-xs">data-lavash-toggle</code> class switching</li>
                <li>• <code class="bg-base-200 px-1 rounded text-xs">data-lavash-visible</code> show/hide</li>
                <li>• <code class="bg-base-200 px-1 rounded text-xs">data-lavash-enabled</code> button state</li>
                <li>• Card type detection via <code class="bg-base-200 px-1 rounded text-xs">rx()</code></li>
              </ul>
            </div>

            <div class="mt-4 text-center">
              <a href="/" class="text-primary hover:text-primary/80 text-sm">
                &larr; Back to Demos
              </a>
            </div>
          </aside>
        </div>
      <% end %>
    </main>
  </div>
  """
end
