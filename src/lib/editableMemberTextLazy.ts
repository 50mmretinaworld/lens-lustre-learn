/**
 * The ONE lazy door to src/lib/editableMemberText.ts (opening stored member text
 * for editing / translating as "@Name"). One import site keeps the entry bundle
 * small (P13): every editor calls this instead of its own `import()`.
 */
export const editableText = () => import("@/lib/editableMemberText");
