import { useMutation } from "@tanstack/react-query";
import { publicUrl } from "@/lib/publicUrl";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "@/hooks/core/use-toast";
import { getCaptchaToken } from "@/lib/turnstile";

export function usePasswordReset() {
  return useMutation({
    mutationFn: async (email: string) => {
      const captchaToken = await getCaptchaToken(); // BUG-043
      const { error } = await supabase.auth.resetPasswordForEmail(email, {
        redirectTo: publicUrl("/reset-password"),
        captchaToken,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast({ title: "Password reset email sent", description: "Check your inbox for the reset link." });
    },
    onError: (error: any) => {
      toast({ title: "Failed to send reset email", description: error.message, variant: "destructive" });
    },
  });
}
