export default {
  card_number_raw(state) {
    return (state.payment_params["card_number"] || "");
  }
,
  card_number_digits(state) {
    return (state.card_number_raw.replace(/\D/g, ""));
  }
,
  card_number_formatted(state) {
    return ((state.card_number_digits.match(/.{1,4}/g) || []).join(" "));
  }
,
  is_visa(state) {
    return (state.card_number_digits.startsWith("4"));
  }
,
  is_mastercard(state) {
    return (state.card_number_digits.startsWith("5"));
  }
,
  is_amex(state) {
    return ((state.card_number_digits.startsWith("34")) || (state.card_number_digits.startsWith("37")));
  }
,
  is_discover(state) {
    return (state.card_number_digits.startsWith("6011"));
  }
,
  has_card_type(state) {
    return (((state.is_visa || state.is_mastercard) || state.is_amex) || state.is_discover);
  }
,
  card_type_display(state) {
    return (state.is_visa ? "Visa" : (state.is_mastercard ? "Mastercard" : (state.is_amex ? "American Express" : (state.is_discover ? "Discover" : ""))));
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
  card_number_valid(state) {
    return (state.payment_card_number_valid && Lavash.Validators.validCardNumber(state.card_number_digits));
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
  expiry_length_valid(state) {
    return ((state.expiry_digits.length) === 4);
  }
,
  expiry_valid(state) {
    return ((state.payment_expiry_valid && state.expiry_month_valid) && state.expiry_length_valid);
  }
,
  expiry_formatted(state) {
    return ((state.expiry_digits.match(/.{1,2}/g) || []).join("/"));
  }
,
  cvv_raw(state) {
    return (state.payment_params["cvv"] || "");
  }
,
  cvv_digits(state) {
    return (state.cvv_raw.replace(/\D/g, ""));
  }
,
  cvv_length(state) {
    return (state.cvv_digits.length);
  }
,
  cvv_valid_for_card_type(state) {
    return (state.is_amex ? (state.cvv_length === 4) : (state.cvv_length === 3));
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
    return (state.payment_params?.["name"] != null && String(state.payment_params?.["name"]).trim().length > 0);
  }
,
  payment_cvv_valid(state) {
    return (state.payment_params?.["cvv"] != null && String(state.payment_params?.["cvv"]).trim().length > 0);
  }
,
  payment_expiry_valid(state) {
    return (state.payment_params?.["expiry"] != null && String(state.payment_params?.["expiry"]).trim().length > 0);
  }
,
  payment_card_number_valid(state) {
    return (state.payment_params?.["card_number"] != null && String(state.payment_params?.["card_number"]).trim().length > 0);
  }
,
  payment_valid(state) {
    return state.payment_card_number_valid && state.payment_expiry_valid && state.payment_cvv_valid && state.payment_name_valid;
  }
,
  payment_name_errors(state) {
    const v = state.payment_params?.["name"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.payment_params?.["name"] != null && String(state.payment_params?.["name"]).trim().length > 0, msg: "Enter the name on your card"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  payment_cvv_errors(state) {
    const v = state.payment_params?.["cvv"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.payment_params?.["cvv"] != null && String(state.payment_params?.["cvv"]).trim().length > 0, msg: "Enter the security code"}, {check: !((!state.cvv_valid_for_card_type && state.payment_cvv_valid)), msg: "Enter a valid security code"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  payment_expiry_errors(state) {
    const v = state.payment_params?.["expiry"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.payment_params?.["expiry"] != null && String(state.payment_params?.["expiry"]).trim().length > 0, msg: "Enter an expiration date"}, {check: !((!(state.expiry_month_valid && state.expiry_length_valid) && state.payment_expiry_valid)), msg: "Enter a valid expiration date"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  payment_card_number_errors(state) {
    const v = state.payment_params?.["card_number"];
    const isEmpty = v == null || String(v).trim().length === 0;
    const checks = [{check: state.payment_params?.["card_number"] != null && String(state.payment_params?.["card_number"]).trim().length > 0, msg: "Enter a card number"}, {check: !((!Lavash.Validators.validCardNumber(state.card_number_digits) && state.payment_card_number_valid)), msg: "Enter a valid card number"}];
    return checks
      .filter(c => !c.check && (true || !isEmpty))
      .map(c => c.msg);
  }
,
  payment_errors(state) {
    return [...(state.payment_card_number_errors || []), ...(state.payment_expiry_errors || []), ...(state.payment_cvv_errors || []), ...(state.payment_name_errors || [])];
  }
,
__derives__: ["card_number_raw","card_number_digits","card_number_formatted","is_visa","is_mastercard","is_amex","is_discover","has_card_type","card_type_display","show_visa","show_mastercard","show_amex","show_discover","card_number_valid","expiry_raw","expiry_digits","expiry_month_str","expiry_has_month","expiry_month_int","expiry_month_valid","expiry_length_valid","expiry_valid","expiry_formatted","cvv_raw","cvv_digits","cvv_length","cvv_valid_for_card_type","cvv_valid","card_form_valid","is_card_payment","form_valid","total","total_display","subtotal_display","shipping_display","payment_name_valid","payment_cvv_valid","payment_expiry_valid","payment_card_number_valid","payment_valid","payment_name_errors","payment_cvv_errors","payment_expiry_errors","payment_card_number_errors","payment_errors"],
__fields__: [],
__graph__: {"is_discover":{"deps":["card_number_digits"]},"has_card_type":{"deps":["is_discover","is_amex","is_mastercard","is_visa"]},"show_amex":{"deps":["has_card_type","is_amex"]},"expiry_has_month":{"deps":["expiry_month_str"]},"show_visa":{"deps":["has_card_type","is_visa"]},"payment_card_number_errors":{"deps":["payment_params","payment_card_number_valid","card_number_digits"]},"expiry_raw":{"deps":["payment_params"]},"payment_cvv_errors":{"deps":["payment_params","payment_cvv_valid","cvv_valid_for_card_type"]},"expiry_valid":{"deps":["expiry_length_valid","expiry_month_valid","payment_expiry_valid"]},"expiry_digits":{"deps":["expiry_raw"]},"card_form_valid":{"deps":["payment_name_valid","cvv_valid","expiry_valid","card_number_valid"]},"form_valid":{"deps":["card_form_valid","is_card_payment"]},"card_number_raw":{"deps":["payment_params"]},"card_number_digits":{"deps":["card_number_raw"]},"shipping_display":{"deps":["shipping"]},"show_discover":{"deps":["has_card_type","is_discover"]},"card_number_formatted":{"deps":["card_number_digits"]},"subtotal_display":{"deps":["subtotal"]},"cvv_valid_for_card_type":{"deps":["cvv_length","is_amex"]},"payment_name_valid":{"deps":["payment_params"]},"expiry_month_str":{"deps":["expiry_digits"]},"is_visa":{"deps":["card_number_digits"]},"show_mastercard":{"deps":["has_card_type","is_mastercard"]},"expiry_length_valid":{"deps":["expiry_digits"]},"card_number_valid":{"deps":["card_number_digits","payment_card_number_valid"]},"payment_name_errors":{"deps":["payment_params"]},"expiry_month_valid":{"deps":["expiry_month_int"]},"payment_expiry_valid":{"deps":["payment_params"]},"expiry_formatted":{"deps":["expiry_digits"]},"payment_errors":{"deps":["payment_card_number_errors","payment_expiry_errors","payment_cvv_errors","payment_name_errors"]},"is_card_payment":{"deps":["payment_method"]},"cvv_valid":{"deps":["cvv_valid_for_card_type","payment_cvv_valid"]},"is_amex":{"deps":["card_number_digits"]},"payment_card_number_valid":{"deps":["payment_params"]},"total":{"deps":["shipping","subtotal"]},"payment_expiry_errors":{"deps":["payment_params","payment_expiry_valid","expiry_length_valid","expiry_month_valid"]},"cvv_digits":{"deps":["cvv_raw"]},"payment_valid":{"deps":["payment_card_number_valid","payment_expiry_valid","payment_cvv_valid","payment_name_valid"]},"cvv_raw":{"deps":["payment_params"]},"is_mastercard":{"deps":["card_number_digits"]},"total_display":{"deps":["total"]},"payment_cvv_valid":{"deps":["payment_params"]},"cvv_length":{"deps":["cvv_digits"]},"expiry_month_int":{"deps":["expiry_month_str","expiry_has_month"]},"card_type_display":{"deps":["is_discover","is_amex","is_mastercard","is_visa"]}}
};
