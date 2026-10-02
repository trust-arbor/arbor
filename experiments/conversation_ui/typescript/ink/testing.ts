/**
 * The public Ink text input renders a blank cursor before its empty placeholder
 * when it owns focus. The surrounding composer contributes one padding space.
 * This observes rendered focus, but the input listener is a passive effect.
 * Harnesses must also await React act before injecting an input event.
 */
export function hasFocusedEmptyMessageInput(frame: string | undefined): boolean {
  return frame?.includes("│  Message · Enter to send") ?? false;
}
