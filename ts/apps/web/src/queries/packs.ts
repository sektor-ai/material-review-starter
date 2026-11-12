import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { DocumentStatus, type GetPackResponse } from "@app/api";
import { clients } from "../api.ts";
import { keys, mergePackResponse, writePack } from "./cache.ts";

// The server rejects larger uploads; checking first saves sending 20 MB to
// be told so.
export const MAX_UPLOAD_BYTES = 20 * 1024 * 1024;

export function usePacks() {
  return useQuery({
    queryKey: keys.packs,
    queryFn: () => clients().pack.listPacks({}),
    // The pack list has no live stream; keep it reasonably fresh.
    refetchInterval: 30_000,
    refetchOnWindowFocus: true,
  });
}

function hasProcessingDocuments(data: GetPackResponse | undefined): boolean {
  return data?.documents.some((d) => d.status === DocumentStatus.PROCESSING) ?? false;
}

export function usePack(id: string) {
  const qc = useQueryClient();
  return useQuery({
    queryKey: keys.pack(id),
    queryFn: async () => mergePackResponse(qc.getQueryData(keys.pack(id)), await clients().pack.getPack({ id })),
    // WatchPack keeps the pack and its run current, so there is nothing to
    // gain from refetching on focus.
    refetchOnWindowFocus: false,
    // WatchPack does not report document parsing, so poll while any
    // document is still being processed.
    refetchInterval: (query) => (hasProcessingDocuments(query.state.data) ? 2_000 : false),
  });
}

export function useCreatePack() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: { submittalNo: string; title: string; designBasis: string }) =>
      clients().pack.createPack(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.packs }),
  });
}

export function useUpdatePack(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: { title?: string; designBasis?: string }) => clients().pack.updatePack({ id, ...input }),
    onSuccess: ({ pack }) => pack && writePack(qc, pack),
  });
}

export function useApprovePack(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => clients().pack.approvePack({ id }),
    onSuccess: ({ pack }) => pack && writePack(qc, pack),
  });
}

export function useCancelPack(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (reason: string) => clients().pack.cancelPack({ id, reason }),
    onSuccess: ({ pack }) => {
      if (pack) writePack(qc, pack);
      // Cancelling a pack also cancels its review.
      void qc.invalidateQueries({ queryKey: keys.pack(id) });
      void qc.invalidateQueries({ queryKey: keys.runs(id) });
    },
  });
}

const mimeByExtension: Record<string, string> = {
  md: "text/markdown",
  markdown: "text/markdown",
  txt: "text/plain",
  pdf: "application/pdf",
};

// guessMimeType fills in what browsers leave empty (they often do for .md).
export function guessMimeType(file: { name: string; type: string }): string {
  if (file.type) return file.type;
  const ext = file.name.split(".").pop()?.toLowerCase() ?? "";
  return mimeByExtension[ext] ?? "application/octet-stream";
}

export function useUploadDocument(packId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (input: { file: File; title?: string }) => {
      if (input.file.size > MAX_UPLOAD_BYTES) throw new Error("Files over 20 MB can't be uploaded.");
      const content = new Uint8Array(await input.file.arrayBuffer());
      return clients().pack.uploadDocument({
        packId,
        filename: input.file.name,
        mimeType: guessMimeType(input.file),
        content,
        title: input.title ?? "",
      });
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: keys.pack(packId) });
      void qc.invalidateQueries({ queryKey: keys.packs });
    },
  });
}

export function useDocument(id: string | undefined, status: DocumentStatus) {
  return useQuery({
    queryKey: keys.document(id ?? "", status),
    queryFn: () => clients().pack.getDocument({ id: id! }),
    enabled: id !== undefined,
  });
}
