import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { clients, isUnauthenticated } from "./api.ts";

export const meKey = ["me"] as const;

// useMe returns the signed-in user, or null when signed out.
export function useMe() {
  return useQuery({
    queryKey: meKey,
    queryFn: async () => {
      try {
        const { user } = await clients().auth.getMe({});
        return user ?? null;
      } catch (error) {
        if (isUnauthenticated(error)) return null;
        throw error;
      }
    },
    retry: false,
  });
}

export function useSignIn() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (input: { email: string; password: string }) => clients().auth.signIn(input),
    onSuccess: ({ user }) => queryClient.setQueryData(meKey, user ?? null),
  });
}

export function useSignOut() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () => clients().auth.signOut({}),
    onSuccess: () => {
      // Drop everything cached under the previous user.
      queryClient.clear();
      queryClient.setQueryData(meKey, null);
    },
  });
}
