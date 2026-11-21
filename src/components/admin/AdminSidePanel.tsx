/**
 * The ONE side panel for admin tables (Owner order 21 Nov 2026: "side info"). Click a row → this slides in from
 * the right (a full-width sheet on a phone) with the details of that row and its actions. Same frame everywhere:
 * title + one-line subtitle, scrolling body, footer for the buttons.
 */
import type { ReactNode } from "react";
import { Sheet, SheetContent, SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";

export default function AdminSidePanel({ open, onClose, title, subtitle, children, footer, testId, wide }: {
  open: boolean;
  onClose: () => void;
  title: ReactNode;
  subtitle?: ReactNode;
  children: ReactNode;
  footer?: ReactNode;
  testId?: string;
  /** a wider panel (a chat is shown inside) */
  wide?: boolean;
}) {
  return (
    <Sheet open={open} onOpenChange={(o) => { if (!o) onClose(); }}>
      <SheetContent side="right" className={`flex w-full flex-col gap-0 p-0 ${wide ? "sm:max-w-xl" : "sm:max-w-md"}`} data-testid={testId ?? "admin-side-panel"}>
        <SheetHeader className="border-b border-border px-5 py-4 text-left">
          <SheetTitle className="pr-6 text-base">{title}</SheetTitle>
          <SheetDescription asChild><div className="text-sm text-muted-foreground">{subtitle ?? "Details"}</div></SheetDescription>
        </SheetHeader>
        <div className="min-h-0 flex-1 space-y-4 overflow-y-auto px-5 py-4">{children}</div>
        {footer && <SheetFooter className="flex-row flex-wrap gap-2 border-t border-border px-5 py-3 sm:justify-start">{footer}</SheetFooter>}
      </SheetContent>
    </Sheet>
  );
}

/** A label above a value, for the details list inside a side panel. */
export function PanelField({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div>
      <p className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">{label}</p>
      <div className="mt-0.5 text-sm">{children}</div>
    </div>
  );
}
