import { Code, ConnectError, createClient, type Client, type Transport } from "@connectrpc/connect";
import { createConnectTransport } from "@connectrpc/connect-web";
import { AuthService, IssueSchema, IssueService, PackService, ReviewService, type Issue } from "@app/api";

export type Clients = {
  auth: Client<typeof AuthService>;
  pack: Client<typeof PackService>;
  issue: Client<typeof IssueService>;
  review: Client<typeof ReviewService>;
};

function makeClients(transport: Transport): Clients {
  return {
    auth: createClient(AuthService, transport),
    pack: createClient(PackService, transport),
    issue: createClient(IssueService, transport),
    review: createClient(ReviewService, transport),
  };
}

// Same-origin: Vite proxies /api to the Go backend in dev, and the load
// balancer routes /api to Cloud Run in production. The session cookie is
// HttpOnly, so the browser sends it automatically.
let current = makeClients(createConnectTransport({ baseUrl: "/api" }));
let originalUrl = (documentId: string) => `/api/documents/${encodeURIComponent(documentId)}/original`;

// clients returns the API clients. Query hooks call it; components don't.
export function clients(): Clients {
  return current;
}

// documentOriginalUrl is where the browser downloads a document's original
// file. It is plain HTTP, not Connect.
export function documentOriginalUrl(documentId: string): string {
  return originalUrl(documentId);
}

// setTransport swaps the transport behind every client. Only the dev mock
// (src/mock) and tests call it, before anything is rendered.
export function setTransport(transport: Transport, originalUrlFor?: (documentId: string) => string) {
  current = makeClients(transport);
  if (originalUrlFor) originalUrl = originalUrlFor;
}

export function isUnauthenticated(error: unknown): boolean {
  return error instanceof ConnectError && error.code === Code.Unauthenticated;
}

export function hasCode(error: unknown, code: Code): boolean {
  return error instanceof ConnectError && error.code === code;
}

// conflictIssue returns the server's current issue when an UpdateIssue
// failed because expected_version was stale (Aborted with the Issue as a
// detail), and undefined for any other error.
export function conflictIssue(error: unknown): Issue | undefined {
  if (!(error instanceof ConnectError) || error.code !== Code.Aborted) return undefined;
  return error.findDetails(IssueSchema)[0];
}

// errorMessage turns an API error into text for the user. Server messages
// are shown for client errors only; internal errors are generic by design.
export function errorMessage(error: unknown): string {
  if (!(error instanceof ConnectError)) return error instanceof Error ? error.message : "Something went wrong";
  switch (error.code) {
    case Code.InvalidArgument:
    case Code.FailedPrecondition:
    case Code.AlreadyExists:
    case Code.NotFound:
    case Code.Aborted:
      return error.rawMessage;
    case Code.Unauthenticated:
      return "Your session has expired. Sign in again.";
    case Code.PermissionDenied:
      return "You don't have permission to do that.";
    case Code.Unimplemented:
      return "The server doesn't support this yet.";
    case Code.Unavailable:
      return "The server is unreachable. Try again shortly.";
    default:
      return "Something went wrong on the server.";
  }
}
