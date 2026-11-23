/**
 * DashboardContext — ensures useDashboardInit is called exactly ONCE (in Layout)
 * and all consumers read from the same query instance.
 *
 * HARD LOCK: useDashboardInit lives ONLY here. No other component may call it.
 */
import { createContext, useContext, type ReactNode } from "react";
import { useDashboardInit, type SidebarData } from "@/hooks/core/useDashboardInit";
import { useAuth } from "@/hooks/core/useAuth";

interface DashboardContextValue {
  isReady: boolean;
  isLoading: boolean;
  sidebarData: SidebarData | null;
}

const DashboardContext = createContext<DashboardContextValue>({
  isReady: false,
  isLoading: true,
  sidebarData: null,
});

export const DashboardProvider = ({ children }: { children: ReactNode }) => {
  const { user, loading } = useAuth();
  // N3 (Owner 23 Nov: "build like Meta"): ask once sign-in is known. It used to ask as "no user" while the
  // session was still being read and AGAIN as the member — two 0.5–1 s calls per page load. The bootstrap
  // gate (dashboardInitGate) already holds the leaf reads until this first answer, so nothing races ahead.
  const query = useDashboardInit(user?.id, !loading);

  return (
    <DashboardContext.Provider
      value={{
        isReady: query.isReady,
        isLoading: query.isLoading,
        sidebarData: query.sidebarData,
      }}
    >
      {children}
    </DashboardContext.Provider>
  );
};

export const useDashboardContext = () => useContext(DashboardContext);
