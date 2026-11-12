import { useEffect, useRef, useState } from "react";
import { useQueryClient, type QueryClient } from "@tanstack/react-query";
import type { WatchPackResponse } from "@app/api";
import { clients } from "../api.ts";
import { userName } from "../format.ts";
import { advanceCursor, writeIssue, writeIssueEvent, writePack, writeRun } from "./cache.ts";

export type WatchStatus = "connecting" | "live" | "reconnecting";

// How long a row stays marked as changed by someone else.
const RECENT_MS = 6_000;
// The server sends a heartbeat every ~15 s; silence for this long means the
// connection is dead even if the socket has not noticed.
const SILENCE_MS = 45_000;
const MAX_BACKOFF_MS = 15_000;

// applyWatchUpdate writes one stream message into the query cache and
// returns the event seq it carried, if any. Applying an issue event also
// advances the cached cursor, so a stream opened later (e.g. on returning
// to the page) starts after it.
export function applyWatchUpdate(qc: QueryClient, res: WatchPackResponse): bigint | undefined {
  switch (res.update.case) {
    case "issueChanged": {
      const { issue, event } = res.update.value;
      if (issue) writeIssue(qc, issue);
      if (event) {
        writeIssueEvent(qc, event);
        advanceCursor(qc, event.packId, event.seq);
      }
      return event?.seq;
    }
    case "runUpdated":
      writeRun(qc, res.update.value);
      return undefined;
    case "packUpdated":
      writePack(qc, res.update.value);
      return undefined;
    default:
      return undefined;
  }
}

export function backoffMs(attempt: number): number {
  const base = Math.min(MAX_BACKOFF_MS, 500 * 2 ** attempt);
  return base / 2 + Math.random() * (base / 2);
}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener("abort", () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

// usePackWatch streams live changes to a pack into the query cache. It
// starts from the cursor the issue list was read at and, after a drop,
// reconnects from the last event it received. It also reports which issues
// someone else changed in the last few seconds, keyed by issue id, with the
// name of who changed them.
export function usePackWatch(packId: string, cursorSeq: bigint | undefined, meId: string | undefined) {
  const qc = useQueryClient();
  const [status, setStatus] = useState<WatchStatus>("connecting");
  const [recent, setRecent] = useState<Record<string, string>>({});
  const cursorRef = useRef(cursorSeq);
  cursorRef.current = cursorSeq;
  const meRef = useRef(meId);
  meRef.current = meId;
  const ready = cursorSeq !== undefined;

  useEffect(() => {
    if (!ready) return;
    const stop = new AbortController();
    const timers = new Set<ReturnType<typeof setTimeout>>();
    let seq = cursorRef.current ?? 0n;

    function markRecent(res: WatchPackResponse) {
      if (res.update.case !== "issueChanged") return;
      const { event, issue } = res.update.value;
      if (!event || !issue || event.actor?.id === meRef.current) return;
      const id = issue.id;
      setRecent((r) => ({ ...r, [id]: userName(event.actor) }));
      const timer = setTimeout(() => {
        timers.delete(timer);
        setRecent(({ [id]: _, ...rest }) => rest);
      }, RECENT_MS);
      timers.add(timer);
    }

    async function run() {
      let attempt = 0;
      while (!stop.signal.aborted) {
        const conn = new AbortController();
        const onStop = () => conn.abort();
        stop.signal.addEventListener("abort", onStop);
        let watchdog = setTimeout(() => conn.abort(), SILENCE_MS);
        try {
          const stream = clients().pack.watchPack({ packId, afterSeq: seq }, { signal: conn.signal });
          for await (const res of stream) {
            clearTimeout(watchdog);
            watchdog = setTimeout(() => conn.abort(), SILENCE_MS);
            attempt = 0;
            setStatus("live");
            const eventSeq = applyWatchUpdate(qc, res);
            // An event past the stream position is news, even if the issue
            // already reached the cache another way (a conflict response, a
            // refetch). Anything at or before it was seen already.
            if (eventSeq !== undefined && eventSeq > seq) {
              seq = eventSeq;
              markRecent(res);
            }
          }
        } catch {
          // Dropped, timed out, or the server went away: reconnect below.
        } finally {
          clearTimeout(watchdog);
          stop.signal.removeEventListener("abort", onStop);
        }
        if (stop.signal.aborted) return;
        setStatus("reconnecting");
        await sleep(backoffMs(attempt++), stop.signal);
      }
    }

    setStatus("connecting");
    void run();
    return () => {
      stop.abort();
      timers.forEach(clearTimeout);
      setRecent({});
    };
  }, [packId, ready, qc]);

  return { status, recent };
}
