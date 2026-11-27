/**
 * The words in a badge / role popup (Owner 27 Nov 2026): the heading and message are written by Admin
 * (badge_definitions / role_display_config.popup_title / popup_message). Empty → the defaults below.
 * {name} = the member's name, {month} = the month the badge was given ("Nov 2026").
 * Only lazily loaded pieces and the Admin form import this (P13 byte ceiling).
 */
export const DEFAULT_MESSAGES: Record<string, string> = {
  verified: "{name} was honoured by the 50mm Retina World curators in {month}. This tick cannot be requested or bought.",
  elite_member: "{name} is an Elite Member of 50mm Retina World.",
  top_rated: "Recognized for exceptional quality",
  most_popular: "Loved by the community",
  most_trusted: "A reliable community member",
  rising_star: "Rapidly gaining recognition",
};

export const DEFAULT_ROLE_MESSAGES: Record<string, string> = {
  admin: "Platform management & oversight",
  judge: "Official competition jury member",
  content_editor: "Content contributor & curator",
  registered_photographer: "Verified photography professional",
  student: "Photography learner & enthusiast",
  user: "Community member",
};

export const DEFAULT_TITLES: Record<string, string> = { verified: "Verified Photographer" };

export const FALLBACK_MESSAGE = "Awarded by 50mm Retina World";

export const popupTitle = (key: string, label: string, custom?: string | null) =>
  custom?.trim() || DEFAULT_TITLES[key] || label;

export const popupTemplate = (key: string, role: boolean, custom?: string | null) =>
  custom?.trim() || (role ? DEFAULT_ROLE_MESSAGES : DEFAULT_MESSAGES)[key] || FALLBACK_MESSAGE;

/** Unknown month: "in {month}" is left out whole, so the sentence still reads. */
export function fillPopupText(template: string, name: string, month: string | null): string {
  const withMonth = month ? template.split("{month}").join(month) : template.replace(/\s*(\bin\s+)?\{month\}/gi, "");
  return withMonth.split("{name}").join(name);
}
