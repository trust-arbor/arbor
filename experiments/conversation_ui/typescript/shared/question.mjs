import {exact, identifier} from './wire.mjs';
export const QUESTION_PREFIX = '@conversation-question/v1 ';
export const ANSWER_PREFIX = '@conversation-answer/v1 ';

// This controlled fixture convention is ordinary transcript text, not an Arbor
// approval capability or a newly implemented production interaction contract.
export function parseQuestion(message) {
  if (message.role !== 'assistant' || !message.text.startsWith(QUESTION_PREFIX)) return null;
  let value;
  try { value = JSON.parse(message.text.slice(QUESTION_PREFIX.length)); } catch { return null; }
  if (!exact(value, ['id', 'revision', 'prompt', 'options']) || !identifier(value.id) ||
      !Number.isSafeInteger(value.revision) || value.revision < 1 || typeof value.prompt !== 'string' ||
      !value.prompt.trim() || value.prompt.length > 1000 || !Array.isArray(value.options) || value.options.length !== 3 ||
      value.options.some(option => !exact(option, ['id', 'label']) || !identifier(option.id) ||
        typeof option.label !== 'string' || !option.label.trim() || option.label.length > 200) ||
      new Set(value.options.map(option => option.id)).size !== 3) return null;
  return {...value, sourceMessageId: message.id, sourceOrdinal: message.ordinal};
}

export function answerText(question, optionId) {
  return ANSWER_PREFIX + JSON.stringify({question_id: question.id, revision: question.revision, option_id: optionId});
}

export function parseAnswer(value) {
  if (typeof value !== 'string' || !value.startsWith(ANSWER_PREFIX)) return null;
  try {
    const answer = JSON.parse(value.slice(ANSWER_PREFIX.length));
    return exact(answer, ['question_id', 'revision', 'option_id']) && identifier(answer.question_id) &&
      Number.isSafeInteger(answer.revision) && answer.revision > 0 && identifier(answer.option_id) ? answer : null;
  } catch { return null; }
}

export function displayMessageText(message) {
  const question = parseQuestion(message);
  if (question) return question.prompt;
  const answer = message.role === 'user' ? parseAnswer(message.text) : null;
  return answer ? `Selected ${answer.option_id} (question ${answer.question_id}, revision ${answer.revision}).` : message.text;
}
