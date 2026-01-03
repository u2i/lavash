export default {
  selected_count(state) {
    return (state.roast.length);
  }
,
  has_selection(state) {
    return (state.selected_count > 0);
  }
,
  summary_text(state) {
    return (state.has_selection ? `${state.selected_count} roast${((state.selected_count === 1) ? "" : "s")} selected` : "No roasts selected");
  }
,
__derives__: ["selected_count","has_selection","summary_text"],
__fields__: [],
__graph__: {"has_selection":{"deps":["selected_count"]},"selected_count":{"deps":["roast"]},"summary_text":{"deps":["selected_count","has_selection"]}}
};
