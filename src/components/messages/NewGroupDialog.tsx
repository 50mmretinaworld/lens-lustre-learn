/**
 * Messages · "New group": a name and 2 to 19 of your friends who have chat. Only friends with the chat facility are listed
 * (the server filters them and checks again when the group is created).
 */
import { useMemo, useState } from "react";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { toast } from "@/hooks/core/use-toast";
import { useT } from "@/i18n/I18nContext";
import { useGroupFriends } from "@/hooks/messages/useGroups";
import { createGroup } from "@/lib/messages/groups";
import { MessageSendError } from "@/lib/messages/api";
import { PersonAvatar, refusalText } from "@/components/messages/MessageParts";

export default function NewGroupDialog({ open, onOpenChange, onCreated }: { open: boolean; onOpenChange: (o: boolean) => void; onCreated: (conversationId: string) => void }) {
  const t = useT();
  const friends = useGroupFriends(open);
  const [title, setTitle] = useState("");
  const [picked, setPicked] = useState<string[]>([]);
  const [q, setQ] = useState("");
  const [busy, setBusy] = useState(false);
  const shown = useMemo(() => {
    const needle = q.trim().toLowerCase();
    return (friends.data ?? []).filter((f) => !needle || (f.fullName ?? "").toLowerCase().includes(needle) || (f.username ?? "").toLowerCase().includes(needle));
  }, [friends.data, q]);
  const toggle = (id: string) => setPicked((p) => (p.includes(id) ? p.filter((x) => x !== id) : p.length >= 19 ? p : [...p, id]));
  const ready = title.trim().length > 0 && picked.length >= 2 && picked.length <= 19;

  const create = async () => {
    if (!ready || busy) return;
    setBusy(true);
    try {
      const id = await createGroup(title.trim(), picked);
      setTitle(""); setPicked([]); setQ("");
      onOpenChange(false);
      onCreated(id);
    } catch (e) {
      toast({ title: t("messages.group.failed", "Could not create the group"), description: refusalText(e instanceof MessageSendError ? e.refusal : "unknown"), variant: "destructive" });
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md" data-testid="new-group-dialog">
        <DialogHeader>
          <DialogTitle>{t("messages.group.new", "New group")}</DialogTitle>
          <DialogDescription>{t("messages.group.hint", "Name the group and pick 2 to 19 friends who have chat.")}</DialogDescription>
        </DialogHeader>
        <Input value={title} onChange={(e) => setTitle(e.target.value)} maxLength={120} placeholder={t("messages.group.name", "Group name")} aria-label={t("messages.group.name", "Group name")} data-testid="new-group-name" />
        <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder={t("messages.group.search", "Search your friends")} aria-label={t("messages.group.search", "Search your friends")} />
        <div className="max-h-64 space-y-0.5 overflow-y-auto" role="group" aria-label={t("messages.group.friends", "Friends")}>
          {friends.isLoading && <p className="py-6 text-center text-sm text-muted-foreground">{t("common.loading", "Loading…")}</p>}
          {!friends.isLoading && shown.length === 0 && <p className="py-6 text-center text-sm text-muted-foreground">{t("messages.group.noFriends", "None of your friends can be added yet. They must be your friends and have chat.")}</p>}
          {shown.map((f) => (
            <label key={f.userId} className="flex cursor-pointer items-center gap-3 rounded-xl px-2 py-1.5 hover:bg-muted">
              <input type="checkbox" checked={picked.includes(f.userId)} onChange={() => toggle(f.userId)} className="h-4 w-4 accent-primary" data-testid="new-group-friend" />
              <PersonAvatar person={f} size={34} />
              <span className="min-w-0 flex-1 truncate text-sm font-medium">{f.fullName || f.username || "Member"}</span>
            </label>
          ))}
        </div>
        <DialogFooter className="items-center gap-2 sm:justify-between">
          <span className="text-xs text-muted-foreground">{picked.length} / 19</span>
          <Button onClick={() => void create()} disabled={!ready || busy} data-testid="new-group-create">
            {busy && <Loader2 className="mr-1 h-4 w-4 animate-spin" aria-hidden="true" />}{t("messages.group.create", "Create group")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
