// Small helpers for the fixed plain-language messages services send back.

// "a pending", "an active": the article follows the word. Statuses are fixed lower-case
// words, so the first letter is enough. Shared by account and anchoring refusals, so both
// read the same way ("Only an active account…", "Only a failed step…").
export const withArticle = (word) => `${/^[aeiou]/.test(word) ? 'an' : 'a'} ${word}`;
