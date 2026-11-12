import { create, fromJson, type JsonValue } from "@bufbuild/protobuf";
import { timestampFromMs, ValueSchema } from "@bufbuild/protobuf/wkt";
import { describe, expect, it } from "vitest";
import { FieldChangeSchema } from "@app/api";
import { describeChange, formatJsonValue, formatRelative, formatSpecRef } from "./format.ts";

describe("formatSpecRef", () => {
  const cases = [
    { ref: { section: "05", part: "06", clause: "Table 6.4" }, want: "QCS 05-06 Table 6.4" },
    { ref: { section: "01", part: "07", clause: "" }, want: "QCS 01-07" },
    { ref: { section: "", part: "", clause: "" }, want: "" },
    { ref: undefined, want: "" },
  ];
  for (const c of cases) {
    it(`formats ${JSON.stringify(c.ref)}`, () => expect(formatSpecRef(c.ref)).toBe(c.want));
  }
});

describe("formatJsonValue", () => {
  const cases: { value: JsonValue; want: string }[] = [
    { value: "ISSUE_STATUS_CLOSED", want: "Closed" },
    { value: "ISSUE_SEVERITY_CRITICAL", want: "Critical" },
    { value: null, want: "—" },
    { value: "", want: "—" },
    { value: "plain text", want: "plain text" },
    { value: { section: "05", part: "06", clause: "Table 6.4", clauseTitle: "Max w/c" }, want: "QCS 05-06 Table 6.4 (Max w/c)" },
    { value: { section: "05", part: "06", clause: "Table 6.4", clause_title: "Max w/c" }, want: "QCS 05-06 Table 6.4 (Max w/c)" },
  ];
  for (const c of cases) {
    it(`formats ${JSON.stringify(c.value)}`, () => expect(formatJsonValue(c.value)).toBe(c.want));
  }
});

describe("describeChange", () => {
  it("renders an enum change from event JSON", () => {
    const change = create(FieldChangeSchema, {
      field: "status",
      oldValue: fromJson(ValueSchema, "ISSUE_STATUS_OPEN"),
      newValue: fromJson(ValueSchema, "ISSUE_STATUS_CLOSED"),
    });
    expect(describeChange(change)).toEqual({ field: "status", label: "Status", from: "Open", to: "Closed" });
  });

  it("renders a CREATED event's null old value", () => {
    const change = create(FieldChangeSchema, {
      field: "title",
      oldValue: fromJson(ValueSchema, null),
      newValue: fromJson(ValueSchema, "W/C too high"),
    });
    expect(describeChange(change)).toMatchObject({ from: "—", to: "W/C too high" });
  });
});

describe("formatRelative", () => {
  const now = Date.parse("2026-11-12T12:00:00Z");
  const cases = [
    { ago: 10_000, want: "just now" },
    { ago: 5 * 60_000, want: "5 min ago" },
    { ago: 3 * 3_600_000, want: "3 h ago" },
    { ago: 2 * 86_400_000, want: "2 d ago" },
  ];
  for (const c of cases) {
    it(c.want, () => expect(formatRelative(timestampFromMs(now - c.ago), now)).toBe(c.want));
  }
});
