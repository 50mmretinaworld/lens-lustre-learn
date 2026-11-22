/**
 * A profile's About, Instagram-style (Owner 22 Nov 2026: "about is too long — show minimum, then See more / See less").
 * Three lines, then "See more"; open, it ends with "See less". The link shows only when the text is really longer.
 */
import { useLayoutEffect, useRef, useState, type CSSProperties } from "react";
import { useT } from "@/i18n/I18nContext";

export default function ClampedText({ text, className = "", style, lines = 3 }: { text: string; className?: string; style?: CSSProperties; lines?: number }) {
  const t = useT();
  const ref = useRef<HTMLParagraphElement>(null);
  const [open, setOpen] = useState(false);
  const [long, setLong] = useState(false);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el || open) return;
    setLong(el.scrollHeight > el.clientHeight + 1);
  }, [text, open]);
  return (
    <div className="min-w-0">
      <p
        ref={ref}
        className={`whitespace-pre-line break-words ${className}`}
        style={{ ...style, ...(open ? {} : { display: "-webkit-box", WebkitLineClamp: lines, WebkitBoxOrient: "vertical", overflow: "hidden" }) }}
        data-testid="profile-about"
      >
        {text}
      </p>
      {(long || open) && (
        <button type="button" onClick={() => setOpen((o) => !o)} className="mt-0.5 text-[13px] font-semibold text-muted-foreground hover:text-foreground" data-testid="profile-about-toggle">
          {open ? t("profile.seeLess", "See less") : t("profile.seeMore", "See more")}
        </button>
      )}
    </div>
  );
}
