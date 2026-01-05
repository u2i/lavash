export default {
  tag_count(state) {
    return (state.tags.length);
  }
,
  tag_summary(state) {
    return (((state.tags.length) === 0) ? "No tags yet" : (((state.tags.length) === 1) ? "1 tag" : `${(state.tags.length)} tags`));
  }
,
  tags_display(state) {
    return (state.tags.join(", "));
  }
,
__derives__: ["tag_count","tag_summary","tags_display"],
__fields__: [],
__graph__: {"tag_count":{"deps":["tags"]},"tag_summary":{"deps":["tags"]},"tags_display":{"deps":["tags"]}},
__animated__: []
};
