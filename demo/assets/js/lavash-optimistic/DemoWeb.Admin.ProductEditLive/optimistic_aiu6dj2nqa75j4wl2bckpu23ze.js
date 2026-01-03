export default {
  form_updated_at_valid(state) {
    return (state.form_params?.["updated_at"] != null && String(state.form_params?.["updated_at"]).trim().length > 0);
  }
,
  form_inserted_at_valid(state) {
    return (state.form_params?.["inserted_at"] != null && String(state.form_params?.["inserted_at"]).trim().length > 0);
  }
,
  form_price_valid(state) {
    return (state.form_params?.["price"] != null && String(state.form_params?.["price"]).trim().length > 0);
  }
,
  form_name_valid(state) {
    return (state.form_params?.["name"] != null && String(state.form_params?.["name"]).trim().length > 0);
  }
,
  form_valid(state) {
    return state.form_name_valid && state.form_price_valid && state.form_inserted_at_valid && state.form_updated_at_valid;
  }
,
  form_updated_at_errors(state) {
    const v = state.form_params?.["updated_at"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.form_params?.["updated_at"] != null && String(state.form_params?.["updated_at"]).trim().length > 0, msg: "is required"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  form_inserted_at_errors(state) {
    const v = state.form_params?.["inserted_at"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.form_params?.["inserted_at"] != null && String(state.form_params?.["inserted_at"]).trim().length > 0, msg: "is required"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  form_price_errors(state) {
    const v = state.form_params?.["price"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.form_params?.["price"] != null && String(state.form_params?.["price"]).trim().length > 0, msg: "is required"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  form_name_errors(state) {
    const v = state.form_params?.["name"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.form_params?.["name"] != null && String(state.form_params?.["name"]).trim().length > 0, msg: "is required"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  form_errors(state) {
    return [...(state.form_name_errors || []), ...(state.form_price_errors || []), ...(state.form_inserted_at_errors || []), ...(state.form_updated_at_errors || [])];
  }
,
__derives__: ["form_updated_at_valid","form_inserted_at_valid","form_price_valid","form_name_valid","form_valid","form_updated_at_errors","form_inserted_at_errors","form_price_errors","form_name_errors","form_errors"],
__fields__: [],
__graph__: {"form_errors":{"deps":["form_name_errors","form_price_errors","form_inserted_at_errors","form_updated_at_errors"]},"form_inserted_at_errors":{"deps":["form_params"]},"form_inserted_at_valid":{"deps":["form_params"]},"form_name_errors":{"deps":["form_params"]},"form_name_valid":{"deps":["form_params"]},"form_price_errors":{"deps":["form_params"]},"form_price_valid":{"deps":["form_params"]},"form_updated_at_errors":{"deps":["form_params"]},"form_updated_at_valid":{"deps":["form_params"]},"form_valid":{"deps":["form_name_valid","form_price_valid","form_inserted_at_valid","form_updated_at_valid"]}}
};
