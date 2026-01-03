export default {
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
__derives__: ["edit_form_updated_at_valid","edit_form_inserted_at_valid","edit_form_price_valid","edit_form_name_valid","edit_form_valid","edit_form_updated_at_errors","edit_form_inserted_at_errors","edit_form_price_errors","edit_form_name_errors","edit_form_errors"],
__fields__: [],
__graph__: {"edit_form_errors":{"deps":["edit_form_name_errors","edit_form_price_errors","edit_form_inserted_at_errors","edit_form_updated_at_errors"]},"edit_form_inserted_at_errors":{"deps":["edit_form_params"]},"edit_form_inserted_at_valid":{"deps":["edit_form_params"]},"edit_form_name_errors":{"deps":["edit_form_params"]},"edit_form_name_valid":{"deps":["edit_form_params"]},"edit_form_price_errors":{"deps":["edit_form_params"]},"edit_form_price_valid":{"deps":["edit_form_params"]},"edit_form_updated_at_errors":{"deps":["edit_form_params"]},"edit_form_updated_at_valid":{"deps":["edit_form_params"]},"edit_form_valid":{"deps":["edit_form_name_valid","edit_form_price_valid","edit_form_inserted_at_valid","edit_form_updated_at_valid"]}}
};
