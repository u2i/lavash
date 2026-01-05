export default {
  product_id_async_ready(state) {
    return ((state.product_id_phase === "visible") || (state.edit_form !== null));
  }
,
  product_id_animating(state) {
    return ((state.product_id_phase === "entering") || (state.product_id_phase === "exiting"));
  }
,
  product_id_visible(state) {
    return (state.product_id_phase !== "idle");
  }
,
  is_open(state) {
    return (state.product_id !== null);
  }
,
  edit_form_updated_at_valid(state) {
    return (state.edit_form_params?.["updated_at"] != null && String(state.edit_form_params?.["updated_at"]).trim().length > 0);
  }
,
  edit_form_inserted_at_valid(state) {
    return (state.edit_form_params?.["inserted_at"] != null && String(state.edit_form_params?.["inserted_at"]).trim().length > 0);
  }
,
  edit_form_price_valid(state) {
    return (state.edit_form_params?.["price"] != null && String(state.edit_form_params?.["price"]).trim().length > 0);
  }
,
  edit_form_name_valid(state) {
    return (state.edit_form_params?.["name"] != null && String(state.edit_form_params?.["name"]).trim().length > 0);
  }
,
  edit_form_valid(state) {
    return state.edit_form_name_valid && state.edit_form_price_valid && state.edit_form_inserted_at_valid && state.edit_form_updated_at_valid;
  }
,
  edit_form_updated_at_errors(state) {
    const v = state.edit_form_params?.["updated_at"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.edit_form_params?.["updated_at"] != null && String(state.edit_form_params?.["updated_at"]).trim().length > 0, msg: "is required"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  edit_form_inserted_at_errors(state) {
    const v = state.edit_form_params?.["inserted_at"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.edit_form_params?.["inserted_at"] != null && String(state.edit_form_params?.["inserted_at"]).trim().length > 0, msg: "is required"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  edit_form_price_errors(state) {
    const v = state.edit_form_params?.["price"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.edit_form_params?.["price"] != null && String(state.edit_form_params?.["price"]).trim().length > 0, msg: "is required"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  edit_form_name_errors(state) {
    const v = state.edit_form_params?.["name"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.edit_form_params?.["name"] != null && String(state.edit_form_params?.["name"]).trim().length > 0, msg: "is required"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  edit_form_errors(state) {
    return [...(state.edit_form_name_errors || []), ...(state.edit_form_price_errors || []), ...(state.edit_form_inserted_at_errors || []), ...(state.edit_form_updated_at_errors || [])];
  }
,
__derives__: ["product_id_async_ready","product_id_animating","product_id_visible","is_open","edit_form_updated_at_valid","edit_form_inserted_at_valid","edit_form_price_valid","edit_form_name_valid","edit_form_valid","edit_form_updated_at_errors","edit_form_inserted_at_errors","edit_form_price_errors","edit_form_name_errors","edit_form_errors"],
__fields__: [],
__graph__: {"edit_form_errors":{"deps":["edit_form_name_errors","edit_form_price_errors","edit_form_inserted_at_errors","edit_form_updated_at_errors"]},"edit_form_inserted_at_errors":{"deps":["edit_form_params"]},"edit_form_inserted_at_valid":{"deps":["edit_form_params"]},"edit_form_name_errors":{"deps":["edit_form_params"]},"edit_form_name_valid":{"deps":["edit_form_params"]},"edit_form_price_errors":{"deps":["edit_form_params"]},"edit_form_price_valid":{"deps":["edit_form_params"]},"edit_form_updated_at_errors":{"deps":["edit_form_params"]},"edit_form_updated_at_valid":{"deps":["edit_form_params"]},"edit_form_valid":{"deps":["edit_form_name_valid","edit_form_price_valid","edit_form_inserted_at_valid","edit_form_updated_at_valid"]},"is_open":{"deps":["product_id"]},"product_id_animating":{"deps":["product_id_phase"]},"product_id_async_ready":{"deps":["product_id_phase","edit_form"]},"product_id_visible":{"deps":["product_id_phase"]}},
__animated__: [{"async":"edit_form","field":"product_id","duration":200,"phaseField":"product_id_phase","preserveDom":true}]
};
