export default {
  payment_name_valid(state) {
    return (state.payment_params?.["name"] != null && String(state.payment_params?.["name"]).trim().length > 0) && (String(state.payment_params?.["name"] || '').trim().length >= 2);
  }
,
  payment_cvv_valid(state) {
    return (state.payment_params?.["cvv"] != null && String(state.payment_params?.["cvv"]).trim().length > 0) && (String(state.payment_params?.["cvv"] || '').trim().length >= 3) && (String(state.payment_params?.["cvv"] || '').trim().length <= 4);
  }
,
  payment_expiry_valid(state) {
    return (state.payment_params?.["expiry"] != null && String(state.payment_params?.["expiry"]).trim().length > 0) && (String(state.payment_params?.["expiry"] || '').trim().length >= 4) && (String(state.payment_params?.["expiry"] || '').trim().length <= 5);
  }
,
  payment_card_number_valid(state) {
    return (state.payment_params?.["card_number"] != null && String(state.payment_params?.["card_number"]).trim().length > 0) && (String(state.payment_params?.["card_number"] || '').trim().length >= 15) && (String(state.payment_params?.["card_number"] || '').trim().length <= 16);
  }
,
  payment_valid(state) {
    return state.payment_card_number_valid && state.payment_expiry_valid && state.payment_cvv_valid && state.payment_name_valid;
  }
,
  payment_name_errors(state) {
    const v = state.payment_params?.["name"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.payment_params?.["name"] != null && String(state.payment_params?.["name"]).trim().length > 0, msg: "is required"}, {check: String(state.payment_params?.["name"] || '').trim().length >= 2, msg: "must be at least 2 characters"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  payment_cvv_errors(state) {
    const v = state.payment_params?.["cvv"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.payment_params?.["cvv"] != null && String(state.payment_params?.["cvv"]).trim().length > 0, msg: "is required"}, {check: String(state.payment_params?.["cvv"] || '').trim().length >= 3, msg: "must be at least 3 characters"}, {check: String(state.payment_params?.["cvv"] || '').trim().length <= 4, msg: "must be at most 4 characters"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  payment_expiry_errors(state) {
    const v = state.payment_params?.["expiry"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.payment_params?.["expiry"] != null && String(state.payment_params?.["expiry"]).trim().length > 0, msg: "is required"}, {check: String(state.payment_params?.["expiry"] || '').trim().length >= 4, msg: "must be at least 4 characters"}, {check: String(state.payment_params?.["expiry"] || '').trim().length <= 5, msg: "must be at most 5 characters"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  payment_card_number_errors(state) {
    const v = state.payment_params?.["card_number"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.payment_params?.["card_number"] != null && String(state.payment_params?.["card_number"]).trim().length > 0, msg: "is required"}, {check: String(state.payment_params?.["card_number"] || '').trim().length >= 15, msg: "must be at least 15 characters"}, {check: String(state.payment_params?.["card_number"] || '').trim().length <= 16, msg: "must be at most 16 characters"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  payment_errors(state) {
    return [...(state.payment_card_number_errors || []), ...(state.payment_expiry_errors || []), ...(state.payment_cvv_errors || []), ...(state.payment_name_errors || [])];
  }
,
__derives__: ["payment_name_valid","payment_cvv_valid","payment_expiry_valid","payment_card_number_valid","payment_valid","payment_name_errors","payment_cvv_errors","payment_expiry_errors","payment_card_number_errors","payment_errors"],
__fields__: [],
__graph__: {"payment_card_number_errors":{"deps":["payment_params"]},"payment_card_number_valid":{"deps":["payment_params"]},"payment_cvv_errors":{"deps":["payment_params"]},"payment_cvv_valid":{"deps":["payment_params"]},"payment_errors":{"deps":["payment_card_number_errors","payment_expiry_errors","payment_cvv_errors","payment_name_errors"]},"payment_expiry_errors":{"deps":["payment_params"]},"payment_expiry_valid":{"deps":["payment_params"]},"payment_name_errors":{"deps":["payment_params"]},"payment_name_valid":{"deps":["payment_params"]},"payment_valid":{"deps":["payment_card_number_valid","payment_expiry_valid","payment_cvv_valid","payment_name_valid"]}}
};
