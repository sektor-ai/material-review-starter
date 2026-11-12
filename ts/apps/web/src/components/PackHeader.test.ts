import { create } from "@bufbuild/protobuf";
import { describe, expect, it } from "vitest";
import { PackSchema, PackStatus, ReviewRunSchema, ReviewRunStatus } from "@app/api";
import { approveBlocker } from "./PackHeader.tsx";

describe("approveBlocker", () => {
  const pack = (status: PackStatus) => create(PackSchema, { status });
  const run = (status: ReviewRunStatus) => create(ReviewRunSchema, { status });
  const cases = [
    { name: "resolved, no run", pack: pack(PackStatus.RESOLVED), run: undefined, blocked: false },
    { name: "resolved, last run finished", pack: pack(PackStatus.RESOLVED), run: run(ReviewRunStatus.SUCCEEDED), blocked: false },
    { name: "resolved, review running", pack: pack(PackStatus.RESOLVED), run: run(ReviewRunStatus.RUNNING), blocked: true },
    { name: "resolved, review queued", pack: pack(PackStatus.RESOLVED), run: run(ReviewRunStatus.QUEUED), blocked: true },
    { name: "open", pack: pack(PackStatus.OPEN), run: undefined, blocked: true },
  ];
  for (const c of cases) {
    it(c.name, () => expect(approveBlocker(c.pack, c.run) !== null).toBe(c.blocked));
  }
});
