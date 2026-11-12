import { create } from "@bufbuild/protobuf";
import { timestampFromMs, timestampNow } from "@bufbuild/protobuf/wkt";
import { IssueStatus, ReviewRunStatus, UpdateIssueRequestSchema, UserKind, UserSchema } from "@app/api";
import { findings } from "./agent.ts";
import type { MockStore } from "./store.ts";

export const mockUsers = {
  alice: create(UserSchema, {
    id: "00000000-0000-7000-8000-00000000a11c",
    name: "Alice Morgan",
    email: "alice@example.com",
    kind: UserKind.HUMAN,
  }),
  bob: create(UserSchema, {
    id: "00000000-0000-7000-8000-000000000b0b",
    name: "Bob Chen",
    email: "bob@example.com",
    kind: UserKind.HUMAN,
  }),
  agent: create(UserSchema, {
    id: "00000000-0000-7000-8000-0000000a6e47",
    name: "Review agent",
    email: "",
    kind: UserKind.AGENT,
  }),
};

const s001Text = `# Al Bayt Contracting W.L.L. – Material Submittal

Submittal no.: S-001
Title: Concrete mix design – Level 2 slab
Specification: QCS 2014, Section 05 Concrete (Parts 02, 03, 05, 06, 10)

Design basis (structural drawings, general notes): suspended slabs Grade C40, exposure class X1 (internal), 25 mm cover.

## Gulf Premix Concrete W.L.L. – Mix Design Report

| Property                       | Value                                                       |
|--------------------------------|-------------------------------------------------------------|
| Concrete grade                 | C40 (40 N/mm² cube)                                         |
| Free water/cementitious ratio  | 0.55                                                        |
| Admixture 2                    | Accelerator, calcium chloride based, 1.0% by mass of cement |
| Acid-soluble chloride          | 0.25% by mass of cementitious (calculated)                  |

### Curing

Spray-applied membrane curing compound after finishing. Curing period 3 days.
`;

const s002Text = `# Al Bayt Contracting W.L.L. – Material Submittal

Submittal no.: S-002
Title: Fire-rated doors – Core stair
Specification: QCS 2014, Section 18 Carpentry, Joinery and Ironmongery (Parts 05 and 07)

Design basis (door schedule): core stair doors are one-hour fire resisting door assemblies, self-closing.

| Item             | Submitted                                              |
|------------------|--------------------------------------------------------|
| Fire resistance  | 30/30 (30 minutes stability and integrity), BS 476     |
| Self-closing     | Rising butt hinges, 2 no. per leaf, aluminium alloy    |
| Hold-open        | Wall-mounted magnetic catch, manual release            |
| Certification    | Test certificate to follow                             |
`;

const encode = (text: string) => new TextEncoder().encode(text);
const noop = () => {};

// seed fills an empty store with two submittals: S-001 reviewed once, with
// issues and a human edit in its history, and S-002 not yet reviewed.
export function seed(store: MockStore) {
  const { alice, bob, agent } = mockUsers;
  let clock = Date.now() - 2 * 24 * 60 * 60 * 1000;
  const advance = (minutes: number) => (clock += minutes * 60_000);
  store.now = () => timestampFromMs(clock);
  try {
    const s001 = store.createPack(alice, {
      submittalNo: "S-001",
      title: "Concrete mix design – Level 2 slab",
      designBasis: "Suspended slabs Grade C40, exposure class X1 (internal), 25 mm cover",
    });
    advance(3);
    const doc1 = store.uploadDocument(
      alice,
      { packId: s001.id, filename: "Material submittal.md", mimeType: "text/markdown", content: encode(s001Text), title: "" },
      noop,
    );
    advance(2);
    const run = store.startReview(alice, s001.id);
    advance(1);
    store.updateRun(run.id, { status: ReviewRunStatus.RUNNING, startedAt: store.now(), agentSessionId: "sesn_mock_seed" });
    const raised = [findings["S-001"][0], findings["S-001"][1], findings["S-001"][3]].map((f) => {
      advance(1);
      const { progress: _, ...issue } = f;
      return store.createIssue(agent, { ...issue, documentId: doc1.id }, run.id).issue;
    });
    advance(1);
    store.finishRun(run.id, ReviewRunStatus.SUCCEEDED, {
      issuesCreated: raised.length,
      summary: "Found 3 non-compliances against QCS 2014. See the issue table for clause references.",
    });

    advance(60 * 20);
    store.updateIssue(
      bob,
      create(UpdateIssueRequestSchema, {
        id: raised[2].id,
        expectedVersion: raised[2].version,
        status: IssueStatus.CLOSED,
        note: "Accreditation certificate received from Gulf Premix by email.",
      }),
    );

    advance(60 * 3);
    const s002 = store.createPack(bob, {
      submittalNo: "S-002",
      title: "Fire-rated doors – Core stair",
      designBasis: "Core stair doors: one-hour fire resisting door assemblies, self-closing",
    });
    advance(4);
    store.uploadDocument(
      bob,
      { packId: s002.id, filename: "Material submittal.md", mimeType: "text/markdown", content: encode(s002Text), title: "" },
      noop,
    );
  } finally {
    store.now = timestampNow;
  }
}
