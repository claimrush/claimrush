export { AchievementEngine } from './engine.js';
export type { AchievementEngineOptions, AchievementTickInputs } from './engine.js';

export type { Achievement, AchievementKind, AchievementLevel, AchievementWriter } from './types.js';

export { ACHIEVEMENT_SCHEMA_PATH } from './schema.js';

// Frontend badge catalog (v1), excluding delegation-specific badges.
export {
  PROFILE_BADGES,
  rarityRank,
  tierToRoman,
  getBadgeTierRarity,
  getBadgeTierPriority,
  badgeLabelWithTier,
  expandBadgesForGrid,
  groupBadgesByCategory,
  selectTopBadges,
  BADGE_HOW_TO,
  getBadgeHowTo,
} from './profileBadges.js';
export type {
  ProfileBadgeRarity,
  ProfileBadgeTier,
  ProfileBadgeBase,
  ProfileBadgeSingle,
  ProfileBadgeTiered,
  ProfileBadge,
  ProfileBadgeId,
  BadgeGridItem,
  BadgeUnlockLike,
  TopBadge,
  BadgeHowTo,
} from './profileBadges.js';
