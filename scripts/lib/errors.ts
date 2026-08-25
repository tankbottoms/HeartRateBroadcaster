/**
 * The message out of a caught value.
 *
 * `catch` hands back `unknown`, and every script here wants one line of prose
 * out of it for a console message. `instanceof` asks the question honestly —
 * casting to `Error` would lie about a thrown string, and `String(e)` alone
 * prints `Error: ...` twice.
 */
export const message = (e: unknown): string => (e instanceof Error ? e.message : String(e));
