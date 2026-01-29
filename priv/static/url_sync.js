/**
 * URL synchronization utilities for Lavash optimistic state.
 *
 * Handles bidirectional sync between Lavash state and browser URL query parameters,
 * using Elixir-style array encoding (field[]=val1&field[]=val2).
 */

/**
 * Sync state fields to browser URL without triggering navigation.
 *
 * @param {Array<string>} urlFields - List of state field names to sync to URL
 * @param {Object} state - Current state object
 *
 * Features:
 * - Uses Elixir-style array params: field[]=val1&field[]=val2
 * - Preserves non-Lavash query parameters
 * - Only updates URL if changes detected (prevents unnecessary history entries)
 * - Skips null, undefined, and empty string values
 */
export function syncStateToUrl(urlFields, state) {
  if (urlFields.length === 0) return;

  const url = new URL(window.location.href);

  // Build query string manually to avoid URLSearchParams encoding [] as %5B%5D
  const params = [];

  for (const field of urlFields) {
    const value = state[field];

    if (Array.isArray(value)) {
      // Elixir-style array params: field[]=val1&field[]=val2
      for (const v of value) {
        params.push(`${encodeURIComponent(field)}[]=${encodeURIComponent(v)}`);
      }
    } else if (value !== null && value !== undefined && value !== "") {
      params.push(`${encodeURIComponent(field)}=${encodeURIComponent(value)}`);
    }
  }

  // Preserve non-lavash params from the current URL
  for (const [key, val] of url.searchParams.entries()) {
    // Skip lavash-managed fields (both scalar and array forms)
    const baseKey = key.replace(/\[\]$/, "");
    if (!urlFields.includes(baseKey)) {
      params.push(`${encodeURIComponent(key)}=${encodeURIComponent(val)}`);
    }
  }

  const newSearch = params.length > 0 ? `?${params.join("&")}` : "";
  const newUrl = url.origin + url.pathname + newSearch + url.hash;

  if (newUrl !== window.location.href) {
    window.history.replaceState(window.history.state, "", newUrl);
  }
}
