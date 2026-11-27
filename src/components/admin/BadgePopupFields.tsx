/**
 * Admin: "name next to the icon" + the popup's heading and message, for one badge or role
 * (Owner 27 Nov 2026). Empty boxes keep the standard words, shown as the placeholder.
 */
import { fillPopupText, popupTemplate, popupTitle } from "@/lib/badges/badgeText";

export interface PopupValues {
  show_label: boolean;
  popup_title: string;
  popup_message: string;
}

export const EMPTY_POPUP: PopupValues = { show_label: true, popup_title: "", popup_message: "" };

export const popupValues = (d: { show_label?: boolean; popup_title?: string | null; popup_message?: string | null }): PopupValues => ({
  show_label: d.show_label !== false,
  popup_title: d.popup_title ?? "",
  popup_message: d.popup_message ?? "",
});

/** What is stored: an empty box is null (= the standard words). */
export const popupColumns = (v: PopupValues) => ({
  show_label: v.show_label,
  popup_title: v.popup_title.trim() || null,
  popup_message: v.popup_message.trim() || null,
});

interface Props {
  badgeKey: string;
  label: string;
  role?: boolean;
  value: PopupValues;
  onChange: (v: PopupValues) => void;
}

const field = "w-full bg-transparent border border-border rounded-sm px-3 py-2 text-sm outline-none focus:border-primary";
const caption = "text-[11px] text-muted-foreground mb-1 block";

const BadgePopupFields = ({ badgeKey, label, role = false, value, onChange }: Props) => {
  // The ticks are only a symbol: there is no name next to them to switch.
  const tick = !role && (badgeKey === "verified" || badgeKey === "elite_member");
  const title = popupTitle(badgeKey, label || "Name", value.popup_title);
  const template = popupTemplate(badgeKey, role, value.popup_message);

  return (
    <div className="space-y-3">
      {!tick && (
        <label className="flex min-h-11 items-center gap-2 cursor-pointer">
          <input type="checkbox" checked={value.show_label} onChange={(e) => onChange({ ...value, show_label: e.target.checked })} className="accent-primary" />
          <span className="text-xs text-foreground">Show the name next to the icon</span>
        </label>
      )}
      <label className="block">
        <span className={caption}>Popup heading</span>
        <input value={value.popup_title} maxLength={80} placeholder={popupTitle(badgeKey, label || "Name")}
          onChange={(e) => onChange({ ...value, popup_title: e.target.value })} className={field} />
      </label>
      <label className="block">
        <span className={caption}>Popup message ({"{name}"} = member's name{role ? "" : ", {month} = month given"})</span>
        <textarea value={value.popup_message} maxLength={400} rows={3} placeholder={popupTemplate(badgeKey, role)}
          onChange={(e) => onChange({ ...value, popup_message: e.target.value })} className={field} />
      </label>
      <div className="max-w-[320px] rounded-2xl border border-border bg-card p-4" data-testid="popup-preview">
        <div className="text-[17px] font-bold leading-tight">{title}</div>
        <p className="mt-2 whitespace-pre-line text-[15px] leading-snug text-muted-foreground">{fillPopupText(template, "Member Name", role ? null : "Nov 2026")}</p>
      </div>
    </div>
  );
};

export default BadgePopupFields;
