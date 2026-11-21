/**
 * Messages · full-screen view of one chat photo: pinch / double-tap zoom (the site's ONE zoomable photograph), Close, and Save.
 * Save fetches the picture into a file on this device (a signed link is on another domain, so a plain download link would
 * only open it in a tab). Esc closes. Private photos: no engagement, no ads, no credit lines — just the picture.
 */
import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { Download, X } from "lucide-react";
import ZoomableImage from "@/components/media/ZoomableImage";

export default function PhotoViewer({ url, onClose }: { url: string; onClose: () => void }) {
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    window.addEventListener("keydown", onKey);
    return () => { document.body.style.overflow = prev; window.removeEventListener("keydown", onKey); };
  }, [onClose]);

  async function save() {
    setSaving(true);
    setFailed(false);
    try {
      const blob = await (await fetch(url)).blob();
      const href = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = href;
      a.download = `50mm-chat-photo.${blob.type === "image/png" ? "png" : blob.type === "image/jpeg" ? "jpg" : "webp"}`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(href), 10_000);
    } catch {
      setFailed(true);
    } finally {
      setSaving(false);
    }
  }

  return createPortal(
    <div role="dialog" aria-modal="true" aria-label="Photo" data-testid="photo-viewer" className="fixed inset-0 z-[100] flex flex-col bg-black/95">
      <div className="flex items-center justify-between px-4 py-3">
        <button type="button" onClick={onClose} aria-label="Close" className="grid h-10 w-10 place-items-center rounded-full bg-white/10 text-white hover:bg-white/20"><X className="h-5 w-5" /></button>
        <div className="flex items-center gap-3">
          {failed && <span className="text-xs text-white/80">Couldn't save — try again</span>}
          <button type="button" onClick={() => void save()} disabled={saving} aria-label="Save photo" className="inline-flex h-10 items-center gap-2 rounded-full bg-white/10 px-4 text-sm font-semibold text-white hover:bg-white/20 disabled:opacity-60">
            <Download className="h-4 w-4" /> Save
          </button>
        </div>
      </div>
      <div className="min-h-0 flex-1">
        <ZoomableImage src={url} alt="Photo in this chat" />
      </div>
    </div>,
    document.body,
  );
}
