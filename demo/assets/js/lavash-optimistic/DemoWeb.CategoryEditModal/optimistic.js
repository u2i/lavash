export default {
  category_id_async_ready(state) {
    return ((state.category_id_phase === "visible") || (state.form !== null));
  }
,
  category_id_animating(state) {
    return ((state.category_id_phase === "entering") || (state.category_id_phase === "exiting"));
  }
,
  category_id_visible(state) {
    return (state.category_id_phase !== "idle");
  }
,
  is_open(state) {
    return (state.category_id !== null);
  }
,
  form_updated_at_valid(state) {
    return (state.form_params?.["updated_at"] != null && String(state.form_params?.["updated_at"]).trim().length > 0);
  }
,
  form_inserted_at_valid(state) {
    return (state.form_params?.["inserted_at"] != null && String(state.form_params?.["inserted_at"]).trim().length > 0);
  }
,
  form_slug_valid(state) {
    return (state.form_params?.["slug"] != null && String(state.form_params?.["slug"]).trim().length > 0);
  }
,
  form_name_valid(state) {
    return (state.form_params?.["name"] != null && String(state.form_params?.["name"]).trim().length > 0);
  }
,
  form_valid(state) {
    return state.form_name_valid && state.form_slug_valid && state.form_inserted_at_valid && state.form_updated_at_valid;
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
  form_slug_errors(state) {
    const v = state.form_params?.["slug"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.form_params?.["slug"] != null && String(state.form_params?.["slug"]).trim().length > 0, msg: "is required"}];
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
    return [...(state.form_name_errors || []), ...(state.form_slug_errors || []), ...(state.form_inserted_at_errors || []), ...(state.form_updated_at_errors || [])];
  }
,
__derives__: ["category_id_async_ready","category_id_animating","category_id_visible","is_open","form_updated_at_valid","form_inserted_at_valid","form_slug_valid","form_name_valid","form_valid","form_updated_at_errors","form_inserted_at_errors","form_slug_errors","form_name_errors","form_errors"],
__fields__: [],
__graph__: {"category_id_animating":{"deps":["category_id_phase"]},"category_id_async_ready":{"deps":["category_id_phase","form"]},"category_id_visible":{"deps":["category_id_phase"]},"form_errors":{"deps":["form_name_errors","form_slug_errors","form_inserted_at_errors","form_updated_at_errors"]},"form_inserted_at_errors":{"deps":["form_params"]},"form_inserted_at_valid":{"deps":["form_params"]},"form_name_errors":{"deps":["form_params"]},"form_name_valid":{"deps":["form_params"]},"form_slug_errors":{"deps":["form_params"]},"form_slug_valid":{"deps":["form_params"]},"form_updated_at_errors":{"deps":["form_params"]},"form_updated_at_valid":{"deps":["form_params"]},"form_valid":{"deps":["form_name_valid","form_slug_valid","form_inserted_at_valid","form_updated_at_valid"]},"is_open":{"deps":["category_id"]}},
__animated__: [{"async":"form","field":"category_id","duration":200,"phaseField":"category_id_phase","preserveDom":true}]
};
