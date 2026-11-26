/**
 * ╔══════════════════════════════════════════════════════════════╗
 * ║  CENTRALIZED QUERY KEY REGISTRY                             ║
 * ║                                                             ║
 * ║  RULES (enforced project-wide):                             ║
 * ║  1. ALL React Query keys MUST be defined here               ║
 * ║  2. NEVER create useQuery() calls inside components/pages   ║
 * ║  3. ALL data fetching goes through shared hooks in /hooks   ║
 * ║  4. NEVER create variant keys for the same table            ║
 * ║     ✗ ["profiles", "admin"]  ✗ ["profiles", userId]        ║
 * ║     ✓ queryKeys.profileMap(ids)                             ║
 * ║  5. If data overlaps with an existing query, REUSE the hook ║
 * ║  6. Global defaults (from QueryClient in App.tsx):          ║
 * ║     staleTime: 5 min, gcTime: 10 min,                      ║
 * ║     refetchOnWindowFocus: true (respects staleTime)         ║
 * ║     Do NOT override these per-hook unless explicitly needed  ║
 * ╚══════════════════════════════════════════════════════════════╝
 *
 * HOOK MAPPING:
 *   queryKeys.profileCore       → useProfileCore()          (useProfileData.ts)
 *   queryKeys.profileExtended   → useProfileExtended()      (useProfileData.ts)
 *   queryKeys.profileMap        → useProfileMap()            (useProfileMap.ts)
 *   queryKeys.profileNameMap    → useProfileNameMap()        (useCompetitionJudges.ts)
 *   queryKeys.isAdmin           → useIsAdmin()               (useIsAdmin.ts)
 *   queryKeys.juryUsers         → useJuryUsers()             (useCompetitionJudges.ts)
 *   queryKeys.navigationMenu    → useNavigationMenu()        (useNavigationMenu.ts)
 *   queryKeys.competitionJudges → useCompetitionJudgeAssignments() (useCompetitionJudges.ts)
 *   queryKeys.allCompetitionJudges → useAllCompetitionJudgeNames() (useCompetitionJudges.ts)
 *   queryKeys.feed              → useFeedQuery()               (useFeedQuery.ts)
 */
export const queryKeys = {
  /* ── Profiles ── */
  profileCore: (userId: string) => ["profile-core", userId] as const,
  profileExtended: (userId: string, currentUserId: string) =>
    ["profile-extended", userId, currentUserId] as const,
  profileMapPrefix: () => ["profile-map"] as const,
  profileMap: (sortedIds: string[]) => ["profile-map", sortedIds] as const,
  profileNameMapPrefix: () => ["profile-name-map"] as const,
  profileNameMap: (sortedIds: string[]) => ["profile-name-map", sortedIds] as const,
  profileDetailMapPrefix: () => ["profile-detail-map"] as const,
  profileDetailMap: (sortedIds: string[]) => ["profile-detail-map", sortedIds] as const,

  /* ── Auth / Roles ── */
  isAdmin: (userId: string) => ["is-admin", userId] as const,
  /** A4: rpc my_account_state() → 'active' | 'under_review' (useMyAccountState). */
  myAccountState: (userId: string) => ["my-account-state", userId] as const,
  /** A4: admin review page — rpc admin_list_account_reviews() (useAccountReviews). */
  accountReviews: () => ["account-reviews"] as const,
  /** A4: one member's state log — rpc admin_account_state_history(_user_id). */
  accountStateHistory: (userId: string) => ["account-state-history", userId] as const,
  /** Messages (M8): every key starts with "messages" so one invalidate refreshes them all. */
  messageAllowed: (userId: string) => ["messages", "allowed", userId] as const,
  messageCanReach: (me: string, other: string) => ["messages", "can-reach", me, other] as const,
  /** J5a: admin Job Engine page — rpc admin_jobs_overview() (useAdminJobs). */
  adminJobsOverview: () => ["admin-jobs-overview"] as const,
  /** J5a: recent jobs — rpc admin_jobs_list(_status, _kind). */
  adminJobsList: (status: string, kind: string) => ["admin-jobs-list", status, kind] as const,
  /** M8b: Admin → Messages — switch state, word list, held queue (useAdminMessages). */
  adminMessagesState: () => ["admin-messages-state"] as const,
  adminMessagesWords: () => ["admin-messages-words"] as const,
  adminMessagesReports: (status: string) => ["admin-messages-reports", status] as const,
  adminMessagesWatch: () => ["admin-messages-watch"] as const,
  adminMessagesMembers: (q: string, filter: string, sort: string, dir: string, page: number, size: number) => ["admin-messages-members", q, filter, sort, dir, page, size] as const,
  /** M12: Admin → Messages → Broadcast. Every key starts with "admin-broadcast" so one invalidate refreshes them all. */
  adminBroadcasts: (status: string, page: number, size: number) => ["admin-broadcasts", status, page, size] as const,
  adminBroadcastReport: (id: number) => ["admin-broadcast-report", id] as const,
  adminBroadcastRecipients: (id: number, filter: string, q: string, page: number, size: number) => ["admin-broadcast-recipients", id, filter, q, page, size] as const,
  adminBroadcastAudience: (audience: string) => ["admin-broadcast-audience", audience] as const,
  /** Admin → Users table — rpc admin_search_users_v4 + admin_user_facets (useAdminMembers). */
  adminMembers: () => ["admin-members"] as const,
  adminPush: () => ["admin-push"] as const,
  /** The set of admin user ids — who gets the brand name and the brand tick. */
  adminIds: () => ["admin-ids"] as const,
  juryUsers: () => ["jury-users"] as const,
  /** The members the signed-in viewer has blocked (Apple 1.2) — useBlockedUsers(). */
  blockedUsers: (userId: string) => ["blocked-users", userId] as const,

  /* ── Navigation ── */
  navigationMenu: () => ["navigation-menu"] as const,

  /* ── User Entries ── */
  userEntries: (userId: string) => ["user-entries", userId] as const,

  /* ── Competitions & Judges ── */
  competitionJudges: (competitionId: string) =>
    ["competition-judges", competitionId] as const,
  allCompetitionJudgesPrefix: () => ["all-competition-judges"] as const,
  allCompetitionJudges: (sortedIds: string[]) =>
    ["all-competition-judges", sortedIds] as const,

  /* ── Feed ── */
  /**
   * The feed, optionally filtered to a set of category slugs.
   *
   * ⚠ THE PARAMETER IS NOT OPTIONAL DECORATION. React Query caches by key, so
   * if every selection shared `["feed"]` then tapping Portrait would hit the
   * cache entry All had just filled and render All's posts as Portrait — worse
   * than stale, silently wrong.
   *
   * `null` is the "All" filter: no predicate, every post, including the ones
   * created before categories existed.
   *
   * Slugs are sorted so ["portrait","street"] and ["street","portrait"] are the
   * same cache entry rather than two.
   *
   * NOTE the prefix shape is unchanged, so every existing
   * `invalidateQueries({ queryKey: queryKeys.feed() })` still matches all
   * category variants — React Query invalidation is prefix-based. Exact-key
   * WRITES (`setQueryData`) are the ones that had to change; see
   * useFeedCacheUpdaters.ts.
   */
  feed: (categories?: string[] | null, tab?: "following" | "favourites" | null) =>
    // S12-F5: "For you" keeps the exact key it always had (no cache migration);
    // Following / Favourites add a third element, so the prefix still matches.
    (tab
      ? ["feed", categories && categories.length ? [...categories].sort() : null, tab]
      : ["feed", categories && categories.length ? [...categories].sort() : null]) as readonly unknown[],

  /** Prefix for every feed cache entry, whatever the category. */
  feedAll: () => ["feed"] as const,
  userWallPosts: (userId: string) => ["user-wall-posts", userId] as const,

  /* ── Post drafts (Stage C) ──
   * Scoped by member: a draft is private, and two accounts on one device must
   * never share a cache entry. RLS already stops the fetch, but a shared key
   * would let the previous member's drafts flash on screen before it does. */
  postDrafts: (userId: string) => ["post-drafts", userId] as const,
  postDraftsAll: () => ["post-drafts"] as const,

  /* ── Notifications ── */
  notifications: (userId: string) => ["notifications", userId] as const,

  /* ── Site Settings ── */
  siteLogo: () => ["site-logo"] as const,
  sidebarSections: () => ["sidebar-sections"] as const,

  /* ── Sidebar Pre-seeded ── */
  sidebarCompetitions: () => ["sidebar-competitions"] as const,
  sidebarCourses: () => ["sidebar-courses"] as const,
  sidebarJournal: () => ["sidebar-journal"] as const,
  sidebarWinners: () => ["sidebar-winners"] as const,

  /* ── Moderation ── */
  isBanned: (userId: string) => ["is-banned", userId] as const,
  reports: () => ["reports"] as const,

  /* ── Search ── */
  search: (query: string) => ["search", query] as const,

  /* ── Social ── */
  friendships: () => ["friendships"] as const,
  follows: () => ["follows"] as const,

  /* ── Dashboard ── */
  dashboard: (userId: string) => ["dashboard", userId] as const,

  /* ── Competitions ── */
  competitions: (filter: string) => ["competitions", filter] as const,
  competitionDetail: (slugOrId: string) => ["competition-detail", slugOrId] as const,

  /* ── Courses ── */
  courses: () => ["courses"] as const,
  courseDetail: (slug: string) => ["course-detail", slug] as const,

  /* ── Journal ── */
  journal: () => ["journal"] as const,

  /* ── Wallet Page ── */
  walletPageData: (userId: string) => ["wallet-page-data", userId] as const,
  walletSummary: (userId: string) => ["wallet-summary", userId] as const,
  walletTransactions: (userId: string) => ["wallet-transactions", userId] as const,
  walletGifts: (userId: string) => ["wallet-gifts", userId] as const,

  /* ── Admin Panel ── */
  adminCompetitions: () => ["admin-competitions"] as const,
  adminEntries: () => ["admin-entries"] as const,
  adminRoleApplications: () => ["admin-role-applications"] as const,
  adminComments: () => ["admin-comments"] as const,

  /* ── Judging — Participant/Status surfaces ── */
  entryPublicStatus: (entryId: string) => ["entry-public-status", entryId] as const,
  entryPublicStatusAll: () => ["entry-public-status"] as const,
  gatedEntryStatus: (sortedIds: string[]) => ["gated-entry-status", sortedIds] as const,
  gatedEntryStatusAll: () => ["gated-entry-status"] as const,
  submissionDetail: (entryId: string) => ["submission-detail", entryId] as const,
  submissionDetailAll: () => ["submission-detail"] as const,

  /* ── Judging — Judge/Consensus surfaces ── */
  judgePhotoData: (
    competitionId: string,
    roundId: string | null,
    judgeId: string | null,
  ) => ["judge-photo-data", competitionId, roundId, judgeId] as const,
  judgePhotoDataAll: () => ["judge-photo-data"] as const,
  perPhotoConsensus: (sortedIds: string[]) =>
    ["per-photo-consensus", sortedIds] as const,
  perPhotoConsensusAll: () => ["per-photo-consensus"] as const,

  /* ── Judging — Round lifecycle ── */
  judgingRounds: (competitionId: string) =>
    ["judging-rounds", competitionId] as const,
  judgingRoundsAll: () => ["judging-rounds"] as const,

  /* ── Home Page Data ── */
  homeBanners: () => ["home-banners"] as const,
  homeGallery: () => ["home-gallery"] as const,
  photoOfTheDay: () => ["photo-of-the-day"] as const,
  featuredArtistActive: () => ["featured-artist-active"] as const,
  footerPages: () => ["footer-pages"] as const,

  /* ── Premium Members (20261126_6000) — usePremiumHonour.ts ── */
  /** One member's Verified honour: held or not, and since when (user_badges 'verified'). */
  premiumHonour: (userId: string) => ["premium-honour", userId] as const,
  /** One member's Featured photo post id (premium_featured_posts). */
  premiumFeatured: (userId: string) => ["premium-featured", userId] as const,
  /** One member's Featured post itself, shaped for the wall grid (useFeaturedPost.ts). */
  premiumFeaturedPost: (userId: string) => ["premium-featured-post", userId] as const,
} as const;
