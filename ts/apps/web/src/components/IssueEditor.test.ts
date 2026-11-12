import { create } from "@bufbuild/protobuf";
import { describe, expect, it } from "vitest";
import { IssueSchema, IssueSeverity, IssueStatus } from "@app/api";
import { diffFields, formFromIssue, rebaseForm } from "./IssueEditor.tsx";

const base = create(IssueSchema, {
  id: "i",
  version: 1,
  status: IssueStatus.OPEN,
  severity: IssueSeverity.MAJOR,
  title: "Title",
  description: "Desc",
  evidence: "Ev",
  specRef: { section: "05", part: "06", clause: "Table 6.4", clauseTitle: "", pdfPage: 652 },
});

describe("diffFields", () => {
  const cases = [
    { name: "nothing changed", edit: {}, want: {} },
    { name: "whitespace only", edit: { title: "  Title  " }, want: {} },
    { name: "one field", edit: { title: "New" }, want: { title: "New" } },
    { name: "status", edit: { status: IssueStatus.CLOSED }, want: { status: IssueStatus.CLOSED } },
    {
      name: "any spec ref field sends the whole reference",
      edit: { clause: "Table 6.5" },
      want: { specRef: { section: "05", part: "06", clause: "Table 6.5", clauseTitle: "", pdfPage: 652 } },
    },
    {
      name: "clearing the page unsets it",
      edit: { pdfPage: "" },
      want: { specRef: { section: "05", part: "06", clause: "Table 6.4", clauseTitle: "", pdfPage: undefined } },
    },
  ];
  for (const c of cases) {
    it(c.name, () => expect(diffFields(base, { ...formFromIssue(base), ...c.edit })).toEqual(c.want));
  }
});

describe("rebaseForm", () => {
  it("keeps their changes and lays only my edited fields over them", () => {
    const mine = { ...formFromIssue(base), evidence: "Mine" };
    const theirs = create(IssueSchema, { ...base, version: 2, severity: IssueSeverity.CRITICAL, title: "Theirs" });
    const rebased = rebaseForm(base, mine, theirs);
    expect(rebased).toMatchObject({ evidence: "Mine", severity: IssueSeverity.CRITICAL, title: "Theirs" });
    expect(diffFields(theirs, rebased)).toEqual({ evidence: "Mine" });
  });

  it("my edit wins where we both changed the same field", () => {
    const mine = { ...formFromIssue(base), title: "Mine" };
    const theirs = create(IssueSchema, { ...base, version: 2, title: "Theirs" });
    expect(rebaseForm(base, mine, theirs).title).toBe("Mine");
  });
});
