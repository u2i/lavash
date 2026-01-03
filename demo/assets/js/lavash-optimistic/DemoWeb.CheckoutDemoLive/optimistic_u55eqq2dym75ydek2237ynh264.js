export default {
  card_number_raw(state) {
    return (state.payment_params["card_number"] || "");
  }
,
  card_number_digits(state) {
    return (state.card_number_raw.replace(/\D/g, ""));
  }
,
  card_number_length(state) {
    return (state.card_number_digits.length);
  }
,
  card_starts_with_4(state) {
    return (state.card_number_digits.startsWith("4"));
  }
,
  card_starts_with_5(state) {
    return (state.card_number_digits.startsWith("5"));
  }
,
  card_starts_with_34(state) {
    return (state.card_number_digits.startsWith("34"));
  }
,
  card_starts_with_37(state) {
    return (state.card_number_digits.startsWith("37"));
  }
,
  card_starts_with_6011(state) {
    return (state.card_number_digits.startsWith("6011"));
  }
,
  is_visa(state) {
    return state.card_starts_with_4;
  }
,
  is_mastercard(state) {
    return state.card_starts_with_5;
  }
,
  is_amex(state) {
    return (state.card_starts_with_34 || state.card_starts_with_37);
  }
,
  is_discover(state) {
    return state.card_starts_with_6011;
  }
,
  has_card_type(state) {
    return (((state.is_visa || state.is_mastercard) || state.is_amex) || state.is_discover);
  }
,
  show_visa(state) {
    return (state.is_visa || !state.has_card_type);
  }
,
  show_mastercard(state) {
    return (state.is_mastercard || !state.has_card_type);
  }
,
  show_amex(state) {
    return (state.is_amex || !state.has_card_type);
  }
,
  show_discover(state) {
    return (state.is_discover || !state.has_card_type);
  }
,
  expiry_raw(state) {
    return (state.payment_params["expiry"] || "");
  }
,
  expiry_digits(state) {
    return (state.expiry_raw.replace(/\D/g, ""));
  }
,
  expiry_month_str(state) {
    return (state.expiry_digits.slice(0, 2));
  }
,
  expiry_has_month(state) {
    return ((state.expiry_month_str.length) === 2);
  }
,
  expiry_month_int(state) {
    return (state.expiry_has_month ? parseInt(state.expiry_month_str, 10) : 0);
  }
,
  expiry_month_valid(state) {
    return ((state.expiry_month_int >= 1) && (state.expiry_month_int <= 12));
  }
,
  cvv_raw(state) {
    return (state.payment_params["cvv"] || "");
  }
,
  cvv_length(state) {
    return ((state.cvv_raw.replace(/\D/g, "")).length);
  }
,
  cvv_valid_for_card_type(state) {
    return (state.is_amex ? (state.cvv_length === 4) : (state.cvv_length === 3));
  }
,
  card_valid_for_type(state) {
    return (state.is_amex ? (state.card_number_length === 15) : (state.card_number_length === 16));
  }
,
  card_number_valid(state) {
    return (state.payment_card_number_valid && state.card_valid_for_type);
  }
,
  expiry_valid(state) {
    return (state.payment_expiry_valid && state.expiry_month_valid);
  }
,
  cvv_valid(state) {
    return (state.payment_cvv_valid && state.cvv_valid_for_card_type);
  }
,
  card_form_valid(state) {
    return (((state.card_number_valid && state.expiry_valid) && state.cvv_valid) && state.payment_name_valid);
  }
,
  is_card_payment(state) {
    return (state.payment_method === "card");
  }
,
  form_valid(state) {
    return (state.is_card_payment ? state.card_form_valid : true);
  }
,
  total(state) {
    return (undefined /* untranspilable: ___., _line_ 1_, _____aliases__, _line_ 1_, __Decimal__, _add__, _line_ 1_, ___@, _line_ 1_, ___subtotal, _line_ 1_, nil___, __@, _line_ 1_, ___shipping, _line_ 1_, nil_____ */);
  }
,
  total_display(state) {
    return ("$" + (undefined /* untranspilable: ___., _line_ 1_, _____aliases__, _line_ 1_, __Decimal__, _to_string__, _line_ 1_, ___@, _line_ 1_, ___total, _line_ 1_, nil_____ */));
  }
,
  subtotal_display(state) {
    return ("$" + (undefined /* untranspilable: ___., _line_ 1_, _____aliases__, _line_ 1_, __Decimal__, _to_string__, _line_ 1_, ___@, _line_ 1_, ___subtotal, _line_ 1_, nil_____ */));
  }
,
  shipping_display(state) {
    return ("$" + (undefined /* untranspilable: ___., _line_ 1_, _____aliases__, _line_ 1_, __Decimal__, _to_string__, _line_ 1_, ___@, _line_ 1_, ___shipping, _line_ 1_, nil_____ */));
  }
,
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
    const checks = [{check: state.payment_params?.["cvv"] != null && String(state.payment_params?.["cvv"]).trim().length > 0, msg: "is required"}, {check: String(state.payment_params?.["cvv"] || '').trim().length >= 3, msg: "must be at least 3 characters"}, {check: String(state.payment_params?.["cvv"] || '').trim().length <= 4, msg: "must be at most 4 characters"}, {check: !(((state.cvv_valid_for_card_type === false) && (state.cvv_length > 0))), msg: ((state.is_amex ? "Amex requires 4 digits" : "Must be 3 digits"))}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  payment_expiry_errors(state) {
    const v = state.payment_params?.["expiry"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.payment_params?.["expiry"] != null && String(state.payment_params?.["expiry"]).trim().length > 0, msg: "is required"}, {check: String(state.payment_params?.["expiry"] || '').trim().length >= 4, msg: "must be at least 4 characters"}, {check: String(state.payment_params?.["expiry"] || '').trim().length <= 5, msg: "must be at most 5 characters"}, {check: !(((state.expiry_month_valid === false) && ((state.expiry_digits.length) >= 2))), msg: "Month must be 01-12"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  payment_card_number_errors(state) {
    const v = state.payment_params?.["card_number"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.payment_params?.["card_number"] != null && String(state.payment_params?.["card_number"]).trim().length > 0, msg: "is required"}, {check: String(state.payment_params?.["card_number"] || '').trim().length >= 15, msg: "must be at least 15 characters"}, {check: String(state.payment_params?.["card_number"] || '').trim().length <= 16, msg: "must be at most 16 characters"}, {check: !(((state.card_valid_for_type === false) && (state.card_number_length > 0))), msg: ((state.is_amex ? "Amex requires 15 digits" : "Must be 16 digits"))}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  payment_errors(state) {
    return [...(state.payment_card_number_errors || []), ...(state.payment_expiry_errors || []), ...(state.payment_cvv_errors || []), ...(state.payment_name_errors || [])];
  }
,
__derives__: ["card_number_raw","card_number_digits","card_number_length","card_starts_with_4","card_starts_with_5","card_starts_with_34","card_starts_with_37","card_starts_with_6011","is_visa","is_mastercard","is_amex","is_discover","has_card_type","show_visa","show_mastercard","show_amex","show_discover","expiry_raw","expiry_digits","expiry_month_str","expiry_has_month","expiry_month_int","expiry_month_valid","cvv_raw","cvv_length","cvv_valid_for_card_type","card_valid_for_type","card_number_valid","expiry_valid","cvv_valid","card_form_valid","is_card_payment","form_valid","total","total_display","subtotal_display","shipping_display","payment_name_valid","payment_cvv_valid","payment_expiry_valid","payment_card_number_valid","payment_valid","payment_name_errors","payment_cvv_errors","payment_expiry_errors","payment_card_number_errors","payment_errors"],
__fields__: [],
__graph__: {"is_discover":{"deps":["card_starts_with_6011"]},"has_card_type":{"deps":["is_discover","is_amex","is_mastercard","is_visa"]},"show_amex":{"deps":["has_card_type","is_amex"]},"expiry_has_month":{"deps":["expiry_month_str"]},"show_visa":{"deps":["has_card_type","is_visa"]},"payment_card_number_errors":{"deps":["payment_params"]},"card_starts_with_34":{"deps":["card_number_digits"]},"card_starts_with_6011":{"deps":["card_number_digits"]},"expiry_raw":{"deps":["payment_params"]},"payment_cvv_errors":{"deps":["payment_params"]},"expiry_valid":{"deps":["expiry_month_valid","payment_expiry_valid"]},"expiry_digits":{"deps":["expiry_raw"]},"card_form_valid":{"deps":["payment_name_valid","cvv_valid","expiry_valid","card_number_valid"]},"card_starts_with_4":{"deps":["card_number_digits"]},"form_valid":{"deps":["card_form_valid","is_card_payment"]},"card_number_raw":{"deps":["payment_params"]},"card_number_digits":{"deps":["card_number_raw"]},"shipping_display":{"deps":["shipping"]},"show_discover":{"deps":["has_card_type","is_discover"]},"subtotal_display":{"deps":["subtotal"]},"cvv_valid_for_card_type":{"deps":["cvv_length","is_amex"]},"payment_name_valid":{"deps":["payment_params"]},"expiry_month_str":{"deps":["expiry_digits"]},"is_visa":{"deps":["card_starts_with_4"]},"card_starts_with_5":{"deps":["card_number_digits"]},"card_number_length":{"deps":["card_number_digits"]},"card_valid_for_type":{"deps":["card_number_length","is_amex"]},"show_mastercard":{"deps":["has_card_type","is_mastercard"]},"card_number_valid":{"deps":["card_valid_for_type","payment_card_number_valid"]},"payment_name_errors":{"deps":["payment_params"]},"expiry_month_valid":{"deps":["expiry_month_int"]},"payment_expiry_valid":{"deps":["payment_params"]},"payment_errors":{"deps":["payment_card_number_errors","payment_expiry_errors","payment_cvv_errors","payment_name_errors"]},"is_card_payment":{"deps":["payment_method"]},"cvv_valid":{"deps":["cvv_valid_for_card_type","payment_cvv_valid"]},"is_amex":{"deps":["card_starts_with_37","card_starts_with_34"]},"payment_card_number_valid":{"deps":["payment_params"]},"total":{"deps":["shipping","subtotal"]},"payment_expiry_errors":{"deps":["payment_params"]},"payment_valid":{"deps":["payment_card_number_valid","payment_expiry_valid","payment_cvv_valid","payment_name_valid"]},"cvv_raw":{"deps":["payment_params"]},"is_mastercard":{"deps":["card_starts_with_5"]},"total_display":{"deps":["total"]},"payment_cvv_valid":{"deps":["payment_params"]},"cvv_length":{"deps":["cvv_raw"]},"expiry_month_int":{"deps":["expiry_month_str","expiry_has_month"]},"card_starts_with_37":{"deps":["card_number_digits"]}}
};
