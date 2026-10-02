import type {ConversationTransport,RequestContext} from './store.mjs';
export const FIXTURE_QUESTION:Readonly<{id:string;revision:number;prompt:string;options:readonly{id:string;label:string}[]}>;
export interface FixtureTransport extends ConversationTransport {calls:RequestContext[];failNextSubmit(mode?:'admitted'|'not_found'|'terminal_uncertain'):void;overrideNextFrame(frame:string):void;setUnauthorized():void;disconnect():void;appendMessage(role:'user'|'assistant',text:string):void;replaceQuestion(revision:number):void;}
export function createFixtureTransport(options?:{caller?:string;target?:string;entryCount?:number;includeQuestion?:boolean;delayMs?:number}):FixtureTransport;
