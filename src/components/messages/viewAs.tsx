/**
 * Messages · "view as". Admin → Messages opens a member's message box with the member's OWN screens
 * (ConversationList + ChatPane), switched to read-only by this context: the lists and threads come from the
 * admin read functions (admin_view_inbox / admin_view_thread), nothing can be sent, accepted, reported or marked
 * read, and "mine" means the member being viewed. Outside the admin page this context is empty and nothing changes.
 */
import { createContext, useContext } from "react";

export interface ViewAs { userId: string; name: string }
const ViewAsContext = createContext<ViewAs | null>(null);
export const ViewAsProvider = ViewAsContext.Provider;
export const useViewAs = (): ViewAs | null => useContext(ViewAsContext);
