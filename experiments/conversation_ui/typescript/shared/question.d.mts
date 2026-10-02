import type {ConversationMessage, ConversationQuestion} from './store.mjs';
export const QUESTION_PREFIX:string;
export const ANSWER_PREFIX:string;
export function parseQuestion(message:ConversationMessage):Omit<ConversationQuestion,'selection'|'status'>|null;
export function parseAnswer(text:string):{question_id:string;revision:number;option_id:string}|null;
export function answerText(question:{id:string;revision:number},optionId:string):string;
export function displayMessageText(message:ConversationMessage):string;
