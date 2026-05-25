defmodule Lavash.Integration.CheckboxBindTest do
  @moduledoc """
  Regression test for the checkbox bind value-vs-checked bug.
  Mirrors the shape in u2i-compliance-portal's attest flow.

  ## The bug

  `form_handler.handleInput` unconditionally read `target.value`,
  which for `<input type="checkbox">` is the static `value=""`
  attribute regardless of checked-state. So ticking a checkbox
  with `value="true"` wrote the STRING "true" to optimistic state
  on both check and uncheck — and downstream
  `data-lavash-enabled === true` strict checks (and any reactive
  graph relying on the field being boolean) silently failed.

  ## What we assert

  The probe directly inspects `hook.state` via JS eval. We
  confirm:

    - Before click: `confirmed: false` (boolean, server-rendered)
    - After click:  `confirmed: true`  (boolean, NOT the string)

  ## Why we don't assert the full button-enable path

  In a real Phoenix app, an optimistic calculation like
  `:ready_to_submit` is transpiled to JS and shipped via
  `Phoenix.LiveView.ColocatedJS` so the client can recompute
  derives on bind changes. Lavash's own test endpoint doesn't have
  the colocated-JS pipeline set up — calc functions never reach
  the browser in this test app.

  The bind-writes-boolean fix is what makes the rest possible.
  Tests covering the full enable-button-on-checkbox-tick path need
  the colocated-JS pipeline wired into the test app first (see
  the demo/ directory for an example of that setup).
  """
  use Lavash.IntegrationCase, async: false

  @hook_state_eval """
  (() => {
    const el = document.querySelector('[data-lavash-state]');
    return el && el.__lavash_hook__
      ? JSON.stringify(el.__lavash_hook__.state)
      : '(no hook)';
  })()
  """

  defp hook_state(session) do
    {:ok, json} = Wallabidi.Remote.Protocol.eval(session, @hook_state_eval)
    Jason.decode!(json)
  end

  test "checkbox bind writes boolean true, not string \"true\"", %{session: session} do
    session = visit(session, "/magic/checkbox-bind")

    # Sanity: server-rendered initial state
    assert hook_state(session)["confirmed"] === false

    # Tick the checkbox
    session = click(session, css("#confirm-box"))
    Process.sleep(50)

    # The bind must write the boolean true, not "true" (string).
    # If form_handler.js read `target.value`, this would be the
    # string "true" — passing this assertion but failing downstream
    # strict-boolean checks.
    assert hook_state(session)["confirmed"] === true
  end
end
