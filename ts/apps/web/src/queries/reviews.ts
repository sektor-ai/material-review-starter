import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { ReviewRun } from "@app/api";
import { clients } from "../api.ts";
import { keys, writeRun } from "./cache.ts";

export function useReviewRuns(packId: string, enabled = true) {
  return useQuery({
    queryKey: keys.runs(packId),
    queryFn: async (): Promise<ReviewRun[]> => (await clients().review.listReviewRuns({ packId })).runs,
    enabled,
  });
}

export function useStartReview(packId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (instructions: string) => clients().review.startReview({ packId, instructions }),
    onSuccess: ({ run }) => run && writeRun(qc, run),
  });
}

export function useCancelReviewRun() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => clients().review.cancelReviewRun({ id }),
    onSuccess: ({ run }) => run && writeRun(qc, run),
  });
}
