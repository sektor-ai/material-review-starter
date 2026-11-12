import { create } from "@bufbuild/protobuf";
import { describe, expect, it } from "vitest";
import { IssueSchema, UserSchema } from "@app/api";
import { conflictNotice } from "./IssuesTable.tsx";

const me = create(UserSchema, { id: "me", name: "Alice Morgan" });
const bob = create(UserSchema, { id: "bob", name: "Bob Chen" });

describe("conflictNotice", () => {
  it("names the other person when they changed it", () => {
    const current = create(IssueSchema, { title: "W/C", updatedBy: bob });
    expect(conflictNotice(current, me)).toMatch(/^Bob Chen changed “W\/C”/);
  });

  it("does not blame someone else for the user's own earlier change", () => {
    const current = create(IssueSchema, { title: "W/C", updatedBy: me });
    expect(conflictNotice(current, me)).toMatch(/^You changed “W\/C”/);
  });
});
