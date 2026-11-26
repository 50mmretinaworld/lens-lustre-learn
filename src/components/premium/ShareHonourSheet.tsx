/**
 * The "Share my honour" sheet: both sizes drawn on the device (honourImage.ts),
 * shown as previews, each with its own Share button. If the photo cannot be
 * drawn (no photo, CDN refused CORS, decode failed) a clear toast says so and
 * the sheet closes — never a blank image.
 */
import { useEffect, useState } from "react";
import { Loader2, Share2 } from "lucide-react";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { toast } from "@/hooks/core/use-toast";
import {
  drawHonourImages,
  honourFileName,
  resolveHonourPhoto,
  shareHonourImage,
  HONOUR_IMAGE_FAILED,
  type HonourSize,
} from "@/lib/premium/honourImage";
import { SHARE_HONOUR_TEXT } from "@/components/premium/ShareHonourButton";

interface Props {
  userId: string;
  name: string;
  handle: string | null;
  onClose: () => void;
}

type Made = Record<HonourSize, { blob: Blob; url: string }>;

const NO_PHOTO = "Choose a Featured photo first: open one of your public photos, tap ⋯ and pick “Set as Featured photo”.";

const ShareHonourSheet = ({ userId, name, handle, onClose }: Props) => {
  const [made, setMade] = useState<Made | null>(null);
  const [busy, setBusy] = useState<HonourSize | null>(null);

  useEffect(() => {
    let live = true;
    let urls: string[] = [];
    void (async () => {
      const photo = await resolveHonourPhoto(userId);
      if (!live) return;
      if (!photo) {
        toast({ title: "No photo to share yet", description: NO_PHOTO, variant: "destructive" });
        onClose();
        return;
      }
      try {
        const b = await drawHonourImages({ photoUrl: photo, name, handle });
        if (!live) return;
        const next: Made = {
          post: { blob: b.post, url: URL.createObjectURL(b.post) },
          story: { blob: b.story, url: URL.createObjectURL(b.story) },
        };
        urls = [next.post.url, next.story.url];
        setMade(next);
      } catch {
        if (!live) return;
        toast({ title: "Couldn't make your image", description: HONOUR_IMAGE_FAILED, variant: "destructive" });
        onClose();
      }
    })();
    return () => {
      live = false;
      urls.forEach((u) => URL.revokeObjectURL(u));
    };
  }, [userId, name, handle, onClose]);

  const share = async (size: HonourSize) => {
    if (!made) return;
    setBusy(size);
    try {
      const how = await shareHonourImage(made[size].blob, honourFileName(handle, size));
      if (how === "saved") toast({ title: "Image saved", description: "Post it on Instagram from your photos." });
    } catch (e) {
      toast({ title: "Not shared", description: e instanceof Error ? e.message : undefined, variant: "destructive" });
    } finally {
      setBusy(null);
    }
  };

  const tile = (size: HonourSize, label: string, aspect: string) => (
    <div className="flex min-w-0 flex-1 flex-col gap-2">
      <div className={`w-full overflow-hidden rounded-md bg-muted ${aspect}`}>
        {made ? (
          <img src={made[size].url} alt={`${label} preview`} className="h-full w-full object-cover" />
        ) : (
          <div className="flex h-full w-full items-center justify-center" aria-busy="true">
            <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
          </div>
        )}
      </div>
      <button
        type="button"
        disabled={!made || busy !== null}
        onClick={() => share(size)}
        className="inline-flex min-h-11 items-center justify-center gap-1.5 rounded-lg bg-primary px-3 text-[13px] font-semibold text-primary-foreground disabled:opacity-40"
      >
        {busy === size ? <Loader2 className="h-4 w-4 animate-spin" /> : <Share2 className="h-4 w-4" />}
        {label}
      </button>
    </div>
  );

  return (
    <Dialog open onOpenChange={(o) => { if (!o) onClose(); }}>
      <DialogContent style={{ maxWidth: "min(480px, calc(100vw - 32px))" }}>
        <DialogTitle>{SHARE_HONOUR_TEXT}</DialogTitle>
        <DialogDescription>Made on your phone from your Featured photo. Post size or story size.</DialogDescription>
        <div className="flex items-start gap-3">
          {tile("post", "Post", "aspect-[4/5]")}
          {tile("story", "Story", "aspect-[9/16]")}
        </div>
      </DialogContent>
    </Dialog>
  );
};

export default ShareHonourSheet;
