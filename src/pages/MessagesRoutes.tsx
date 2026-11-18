/** /messages/* — the inbox, one chat by id, and "start a chat with a member". One lazy chunk for all three. */
import { Route, Routes } from "react-router-dom";
import Messages from "./Messages";
import MessageThread from "./MessageThread";

export default function MessagesRoutes() {
  return (
    <Routes>
      <Route index element={<Messages />} />
      <Route path="with/:userId" element={<MessageThread />} />
      <Route path=":conversationId" element={<MessageThread />} />
    </Routes>
  );
}
