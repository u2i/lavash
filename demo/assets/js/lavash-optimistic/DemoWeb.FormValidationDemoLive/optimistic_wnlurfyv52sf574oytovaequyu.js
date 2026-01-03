export default {
  email_has_at(state) {
    return ((state.registration_params["email"] || "").includes("@"));
  }
,
  email_valid(state) {
    return (state.registration_email_valid && state.email_has_at);
  }
,
  form_valid(state) {
    return ((state.registration_name_valid && state.email_valid) && state.registration_age_valid);
  }
,
  registration_age_valid(state) {
    return (state.registration_params?.["age"] != null && String(state.registration_params?.["age"]).trim().length > 0) && (parseInt(state.registration_params?.["age"] || '0', 10) >= 18);
  }
,
  registration_email_valid(state) {
    return (state.registration_params?.["email"] != null && String(state.registration_params?.["email"]).trim().length > 0);
  }
,
  registration_name_valid(state) {
    return (state.registration_params?.["name"] != null && String(state.registration_params?.["name"]).trim().length > 0) && (String(state.registration_params?.["name"] || '').trim().length >= 2);
  }
,
  registration_valid(state) {
    return state.registration_name_valid && state.registration_email_valid && state.registration_age_valid;
  }
,
  registration_age_errors(state) {
    const v = state.registration_params?.["age"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.registration_params?.["age"] != null && String(state.registration_params?.["age"]).trim().length > 0, msg: "is required"}, {check: parseInt(state.registration_params?.["age"] || '0', 10) >= 18, msg: "must be at least 18"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  registration_email_errors(state) {
    const v = state.registration_params?.["email"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.registration_params?.["email"] != null && String(state.registration_params?.["email"]).trim().length > 0, msg: "is required"}, {check: !(!((state.registration_params["email"] || "").includes("@"))), msg: "Must contain @"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  registration_name_errors(state) {
    const v = state.registration_params?.["name"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.registration_params?.["name"] != null && String(state.registration_params?.["name"]).trim().length > 0, msg: "is required"}, {check: String(state.registration_params?.["name"] || '').trim().length >= 2, msg: "must be at least 2 characters"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  registration_errors(state) {
    return [...(state.registration_name_errors || []), ...(state.registration_email_errors || []), ...(state.registration_age_errors || [])];
  }
,
__derives__: ["email_has_at","email_valid","form_valid","registration_age_valid","registration_email_valid","registration_name_valid","registration_valid","registration_age_errors","registration_email_errors","registration_name_errors","registration_errors"],
__fields__: [],
__graph__: {"email_has_at":{"deps":["registration_params"]},"email_valid":{"deps":["email_has_at","registration_email_valid"]},"form_valid":{"deps":["registration_age_valid","email_valid","registration_name_valid"]},"registration_age_errors":{"deps":["registration_params"]},"registration_age_valid":{"deps":["registration_params"]},"registration_email_errors":{"deps":["registration_params"]},"registration_email_valid":{"deps":["registration_params"]},"registration_errors":{"deps":["registration_name_errors","registration_email_errors","registration_age_errors"]},"registration_name_errors":{"deps":["registration_params"]},"registration_name_valid":{"deps":["registration_params"]},"registration_valid":{"deps":["registration_name_valid","registration_email_valid","registration_age_valid"]}}
};
