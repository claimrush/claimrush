// Achievements v1.0.0 badge catalog.
// Source of truth: docs/ui/achievements-v1.0.0.md
//
// NOTE: Delegation-specific badges (DELEGATION_* / DELEGATED_*) are intentionally omitted
// from this SDK catalog by default (self-play agents).

export type ProfileBadgeRarity = 'Common' | 'Uncommon' | 'Rare' | 'Epic' | 'Legendary';

export type ProfileBadgeTier = {
  tier: number;
  rarity: ProfileBadgeRarity;
  priority?: number;
};

export type ProfileBadgeBase = {
  id: string;
  category: string;
  label: string;
};

export type ProfileBadgeSingle = ProfileBadgeBase & {
  kind: 'single';
  rarity: ProfileBadgeRarity;
  priority?: number;
};

export type ProfileBadgeTiered = ProfileBadgeBase & {
  kind: 'tiered';
  tiers: readonly ProfileBadgeTier[];
};

export type ProfileBadge = ProfileBadgeSingle | ProfileBadgeTiered;

export const PROFILE_BADGES = [
  // Crown
  {
    id: 'CROWN_USURPER',
    category: 'Crown',
    label: 'Usurper',
    kind: 'single',
    rarity: 'Uncommon',
    priority: 1,
  },
  {
    id: 'CROWN_FIRST_REIGN_FINALIZED',
    category: 'Crown',
    label: 'Crowned',
    kind: 'single',
    rarity: 'Uncommon',
    priority: 1,
  },
  {
    id: 'CROWN_LOW_COST_BUYER',
    category: 'Crown',
    label: 'Bargain Hunter',
    kind: 'single',
    rarity: 'Uncommon',
    priority: 2,
  },
  {
    id: 'CROWN_HIGH_COST_SNIPER',
    category: 'Crown',
    label: 'High Cost Sniper',
    kind: 'single',
    rarity: 'Uncommon',
    priority: 2,
  },
  {
    id: 'CROWN_MID_COST_TAKER',
    category: 'Crown',
    label: 'Sweet Spot',
    kind: 'single',
    rarity: 'Uncommon',
    priority: 2,
  },
  {
    id: 'CROWN_REVENGE',
    category: 'Crown',
    label: 'Revenge',
    kind: 'single',
    rarity: 'Uncommon',
    priority: 4,
  },
  {
    id: 'CROWN_DETHRONED_THE_HOUSE',
    category: 'Crown',
    label: 'House Breaker',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Rare', priority: 3 },
      { tier: 2, rarity: 'Epic', priority: 3 },
    ],
  },
  {
    id: 'CROWN_COST_TIER_BALANCED',
    category: 'Crown',
    label: 'Triple Threat',
    kind: 'single',
    rarity: 'Uncommon',
    priority: 5,
  },
  {
    id: 'CROWN_LOW_COST_SPECIALIST',
    category: 'Crown',
    label: 'Penny Pincher',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Uncommon', priority: 6 },
      { tier: 2, rarity: 'Rare', priority: 6 },
    ],
  },
  {
    id: 'CROWN_DUELIST',
    category: 'Crown',
    label: 'Duelist',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Uncommon', priority: 6 },
      { tier: 2, rarity: 'Rare', priority: 6 },
    ],
  },
  {
    id: 'CROWN_WARLORD',
    category: 'Crown',
    label: 'Warlord',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Uncommon', priority: 6 },
      { tier: 2, rarity: 'Rare', priority: 6 },
      { tier: 3, rarity: 'Epic', priority: 6 },
    ],
  },

  {
    id: 'CROWN_AUTOLOCK_CONFIGURED',
    category: 'Crown',
    label: 'Locksmith',
    kind: 'single',
    rarity: 'Uncommon',
    priority: 1,
  },
  {
    id: 'CROWN_AUTOLOCK_EXECUTED',
    category: 'Crown',
    label: 'Clockwork',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Uncommon', priority: 2 },
      { tier: 2, rarity: 'Rare', priority: 2 },
      { tier: 3, rarity: 'Epic', priority: 2 },
    ],
  },

  // Furnace
  {
    id: 'FURNACE_FORGED',
    category: 'Furnace',
    label: 'Forged',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'FURNACE_DUAL_INPUT',
    category: 'Furnace',
    label: 'Dual Fuel',
    kind: 'single',
    rarity: 'Common',
    priority: 3,
  },
  {
    id: 'FURNACE_ALCHEMIST',
    category: 'Furnace',
    label: 'Alchemist',
    kind: 'single',
    rarity: 'Common',
    priority: 2,
  },
  {
    id: 'FURNACE_BONUS_HUNTER',
    category: 'Furnace',
    label: 'Bonus Hunter',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Uncommon', priority: 4 },
      { tier: 2, rarity: 'Rare', priority: 4 },
      { tier: 3, rarity: 'Epic', priority: 4 },
    ],
  },
  {
    id: 'FURNACE_HIGH_BONUS_STREAK',
    category: 'Furnace',
    label: 'Hot Streak',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Uncommon', priority: 5 },
      { tier: 2, rarity: 'Rare', priority: 5 },
    ],
  },

  // Barons
  {
    id: 'BARON_AUTOMAX_ON',
    category: 'Barons',
    label: 'Maximizer',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'BARON_REFORGER',
    category: 'Barons',
    label: 'Reforger',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'BARON_ARMORER',
    category: 'Barons',
    label: 'Armorer',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'BARON_MERGER',
    category: 'Barons',
    label: 'Merger',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'BARON_UNSEALED',
    category: 'Barons',
    label: 'Unsealed',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'BARON_KEEPER',
    category: 'Barons',
    label: 'Keeper',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Uncommon', priority: 2 },
      { tier: 2, rarity: 'Rare', priority: 2 },
      { tier: 3, rarity: 'Epic', priority: 2 },
      { tier: 4, rarity: 'Legendary', priority: 2 },
    ],
  },
  {
    id: 'BARON_COLLECTOR',
    category: 'Barons',
    label: 'Multi-Locker',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Common', priority: 3 },
      { tier: 2, rarity: 'Uncommon', priority: 3 },
    ],
  },
  {
    id: 'BARON_RENEW_ON_TIME',
    category: 'Barons',
    label: 'Renewed',
    kind: 'single',
    rarity: 'Common',
    priority: 2,
  },

  // Royalties
  {
    id: 'ROYALTY_COLLECTOR',
    category: 'Royalties',
    label: 'First Royalty',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'ROYALTY_COMPOUNDER',
    category: 'Royalties',
    label: 'Compounder',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Common', priority: 4 },
      { tier: 2, rarity: 'Uncommon', priority: 4 },
      { tier: 3, rarity: 'Rare', priority: 4 },
      { tier: 4, rarity: 'Epic', priority: 4 },
    ],
  },
  {
    id: 'ROYALTY_DUAL_MODE',
    category: 'Royalties',
    label: 'Versatile',
    kind: 'single',
    rarity: 'Uncommon',
    priority: 3,
  },
  {
    id: 'ROYALTY_AUTOPILOT',
    category: 'Royalties',
    label: 'Autopilot',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'ROYALTY_AUTOPILOT_EXECUTED',
    category: 'Royalties',
    label: 'Cruise Control',
    kind: 'single',
    rarity: 'Common',
    priority: 2,
  },
  {
    id: 'ROYALTY_STREAK',
    category: 'Royalties',
    label: 'Royalty Streak',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Uncommon', priority: 5 },
      { tier: 2, rarity: 'Rare', priority: 5 },
      { tier: 3, rarity: 'Epic', priority: 5 },
      { tier: 4, rarity: 'Legendary', priority: 5 },
    ],
  },

  // Market
  {
    id: 'MARKET_FIRST_LISTING',
    category: 'Market',
    label: 'First Listing',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'MARKET_MARKET_MAKER',
    category: 'Market',
    label: 'Market Maker',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Common', priority: 3 },
      { tier: 2, rarity: 'Uncommon', priority: 3 },
    ],
  },
  {
    id: 'MARKET_LISTING_SETTLED',
    category: 'Market',
    label: 'Deal Sealed',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'MARKET_OFFER_MAKER',
    category: 'Market',
    label: 'First Bid',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'MARKET_AUTOFILL_ORDER_AUTO_FURNACE',
    category: 'Market',
    label: 'Offer Filled',
    kind: 'single',
    rarity: 'Common',
    priority: 2,
  },
  {
    id: 'MARKET_SELL_TO_FURNACE',
    category: 'Market',
    label: 'Recycler',
    kind: 'single',
    rarity: 'Common',
    priority: 2,
  },

  // LP Vault
  {
    id: 'LP_FIRST_STAKE',
    category: 'LP Vault',
    label: 'First Stake',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'LP_HARVESTER',
    category: 'LP Vault',
    label: 'Harvester',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'LP_AUTOCOMPOUND_ON',
    category: 'LP Vault',
    label: 'Auto-Grower',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'LP_HARVEST_AND_LOCK',
    category: 'LP Vault',
    label: 'Harvest & Lock',
    kind: 'single',
    rarity: 'Common',
    priority: 2,
  },
  {
    id: 'LP_AUTOCOMPOUND_EXECUTED',
    category: 'LP Vault',
    label: 'Compounded',
    kind: 'single',
    rarity: 'Common',
    priority: 3,
  },
  {
    id: 'LP_UNBOND_STARTED',
    category: 'LP Vault',
    label: 'Unbonding',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'LP_UNBOND_COMPLETE',
    category: 'LP Vault',
    label: 'Unbonded',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'LP_LONG_STAKER',
    category: 'LP Vault',
    label: 'Long Staker',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Uncommon', priority: 2 },
      { tier: 2, rarity: 'Rare', priority: 2 },
      { tier: 3, rarity: 'Epic', priority: 2 },
      { tier: 4, rarity: 'Legendary', priority: 2 },
    ],
  },

  // Social
  {
    id: 'SOCIAL_REFERRED',
    category: 'Social',
    label: 'Referred',
    kind: 'single',
    rarity: 'Common',
    priority: 1,
  },
  {
    id: 'SOCIAL_HERALD',
    category: 'Social',
    label: 'Herald',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Uncommon', priority: 2 },
      { tier: 2, rarity: 'Rare', priority: 2 },
      { tier: 3, rarity: 'Epic', priority: 2 },
      { tier: 4, rarity: 'Legendary', priority: 2 },
    ],
  },

  // Explorer
  {
    id: 'META_DUAL_ROLE',
    category: 'Explorer',
    label: 'Crossover',
    kind: 'single',
    rarity: 'Common',
    priority: 7,
  },
  {
    id: 'META_FULL_STACK',
    category: 'Explorer',
    label: 'Full Stack',
    kind: 'single',
    rarity: 'Common',
    priority: 7,
  },
  {
    id: 'META_SEVEN_DAY_ACTIVE',
    category: 'Explorer',
    label: 'Dedicated',
    kind: 'tiered',
    tiers: [
      { tier: 1, rarity: 'Common', priority: 9 },
      { tier: 2, rarity: 'Uncommon', priority: 9 },
      { tier: 3, rarity: 'Rare', priority: 9 },
      { tier: 4, rarity: 'Epic', priority: 9 },
    ],
  },
  {
    id: 'META_AUTOMATION_ARCHITECT',
    category: 'Explorer',
    label: 'Automation Architect',
    kind: 'single',
    rarity: 'Uncommon',
    priority: 7,
  },
  {
    id: 'META_AUTOMATION_TRIFECTA',
    category: 'Explorer',
    label: 'Automation Trifecta',
    kind: 'single',
    rarity: 'Uncommon',
    priority: 7,
  },
  {
    id: 'META_BOT_USER',
    category: 'Explorer',
    label: 'Bot User',
    kind: 'single',
    rarity: 'Common',
    priority: 8,
  },
  {
    id: 'META_BOT_CROWN_AUTOPILOT',
    category: 'Explorer',
    label: 'Bot King',
    kind: 'single',
    rarity: 'Common',
    priority: 8,
  },
] as const satisfies readonly ProfileBadge[];

export type ProfileBadgeId = (typeof PROFILE_BADGES)[number]['id'];

export function rarityRank(rarity: ProfileBadgeRarity): number {
  switch (rarity) {
    case 'Legendary':
      return 5;
    case 'Epic':
      return 4;
    case 'Rare':
      return 3;
    case 'Uncommon':
      return 2;
    case 'Common':
    default:
      return 1;
  }
}

const ROMAN = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX'];

export function tierToRoman(tier: number): string {
  if (tier <= 0) return '';
  return ROMAN[tier - 1] ?? String(tier);
}

export type BadgeGridItem = {
  key: string;
  id: ProfileBadgeId;
  category: string;
  label: string;
  tier: number | null;
  rarity: ProfileBadgeRarity;
};

function safeTiers(badge: ProfileBadgeTiered): readonly ProfileBadgeTier[] {
  // Defensive guard: catalog data is static, but we prefer not to hard-crash the UI
  // if an entry is accidentally malformed at runtime.
  return Array.isArray(badge.tiers) ? badge.tiers : [];
}

export function getBadgeTierRarity(badge: ProfileBadge, tier: number | null): ProfileBadgeRarity {
  if (badge.kind === 'single') return badge.rarity;
  const tiers = safeTiers(badge);
  if (tier === null) return tiers[tiers.length - 1]?.rarity ?? 'Common';
  return tiers.find((t) => t.tier === tier)?.rarity ?? tiers[0]?.rarity ?? 'Common';
}

export function getBadgeTierPriority(badge: ProfileBadge, tier: number | null): number {
  if (badge.kind === 'single') return badge.priority ?? 999;
  const tiers = safeTiers(badge);
  if (tier === null) return tiers[tiers.length - 1]?.priority ?? 999;
  return tiers.find((t) => t.tier === tier)?.priority ?? tiers[0]?.priority ?? 999;
}

export function badgeLabelWithTier(label: string, tier: number | null): string {
  if (!tier) return label;
  const roman = tierToRoman(tier);
  return roman ? `${label} ${roman}` : label;
}

export function expandBadgesForGrid(badges: readonly ProfileBadge[]): BadgeGridItem[] {
  const out: BadgeGridItem[] = [];
  for (const badge of badges) {
    if (badge.kind === 'single') {
      out.push({
        key: badge.id,
        id: badge.id as ProfileBadgeId,
        category: badge.category,
        label: badge.label,
        tier: null,
        rarity: badge.rarity,
      });
      continue;
    }

    for (const tier of safeTiers(badge)) {
      out.push({
        key: `${badge.id}:${tier.tier}`,
        id: badge.id as ProfileBadgeId,
        category: badge.category,
        label: badgeLabelWithTier(badge.label, tier.tier),
        tier: tier.tier,
        rarity: tier.rarity,
      });
    }
  }
  return out;
}

export function groupBadgesByCategory<T extends { category: string }>(badges: readonly T[]) {
  return badges.reduce<Record<string, T[]>>((acc, badge) => {
    acc[badge.category] = acc[badge.category] ?? [];
    acc[badge.category].push(badge);
    return acc;
  }, {});
}

export type BadgeUnlockLike = {
  id: ProfileBadgeId;
  tier: number | null;
  unlockedAt: number | null;
  tierUnlockedAt?: Record<number, number | null | undefined>;
};

export type TopBadge = {
  id: ProfileBadgeId;
  label: string;
  rarity: ProfileBadgeRarity;
  tier: number | null;
  unlockedAt: number | null;
};

export function selectTopBadges(
  catalog: readonly ProfileBadge[],
  unlocked: readonly BadgeUnlockLike[],
  limit = 3,
): TopBadge[] {
  const unlockMap = new Map<string, BadgeUnlockLike>();
  for (const u of unlocked) unlockMap.set(u.id, u);

  const candidates: TopBadge[] = [];

  for (const badge of catalog) {
    const u = unlockMap.get(badge.id) ?? null;
    if (!u) continue;

    if (badge.kind === 'single') {
      candidates.push({
        id: badge.id as ProfileBadgeId,
        label: badge.label,
        rarity: badge.rarity,
        tier: null,
        unlockedAt: u.unlockedAt,
      });
      continue;
    }

    const tier = u.tier;
    if (!tier) continue;
    const rarity = getBadgeTierRarity(badge, tier);
    candidates.push({
      id: badge.id as ProfileBadgeId,
      label: badgeLabelWithTier(badge.label, tier),
      rarity,
      tier,
      unlockedAt: u.unlockedAt,
    });
  }

  candidates.sort((a, b) => {
    // Primary: higher rarity first.
    const r = rarityRank(b.rarity) - rarityRank(a.rarity);
    if (r !== 0) return r;

    // Tie-breaker 1: higher tier (if tiered).
    const tierA = a.tier ?? 0;
    const tierB = b.tier ?? 0;
    if (tierA !== tierB) return tierB - tierA;

    // Tie-breaker 2: earlier unlock timestamp.
    const atA = a.unlockedAt ?? Number.POSITIVE_INFINITY;
    const atB = b.unlockedAt ?? Number.POSITIVE_INFINITY;
    if (atA !== atB) return atA - atB;

    // Tie-breaker 3: badge id alphabetical.
    return a.id.localeCompare(b.id);
  });

  return candidates.slice(0, limit);
}

export type BadgeHowTo = string | Record<number, string>;

// Tooltip content. Keep these short: they are displayed in the browser's native tooltip.
export const BADGE_HOW_TO = {
  // Crown
  CROWN_USURPER: 'Become King for the first time.',
  CROWN_FIRST_REIGN_FINALIZED: 'Finalize your first reign as King.',
  CROWN_LOW_COST_BUYER: 'Become King in the Low cost tier (>= 35m since previous takeover).',
  CROWN_HIGH_COST_SNIPER: 'Become King in the High cost tier (< 25m since previous takeover).',
  CROWN_MID_COST_TAKER: 'Become King in the Mid cost tier (25m to 35m since previous takeover).',
  CROWN_REVENGE: 'Get dethroned by an address, then dethrone that same address within 24h.',
  CROWN_DETHRONED_THE_HOUSE: {
    1: 'Dethrone the House 1 time.',
    2: 'Dethrone the House 3 times.',
  },
  CROWN_COST_TIER_BALANCED: 'Become King in all three cost tiers (High, Mid, Low).',
  CROWN_LOW_COST_SPECIALIST: {
    1: 'Become King in the Low cost tier 3 times.',
    2: 'Become King in the Low cost tier 10 times.',
  },
  CROWN_DUELIST: {
    1: 'Dethrone the same address 2 times.',
    2: 'Dethrone the same address 5 times.',
  },
  CROWN_WARLORD: {
    1: 'Become King 5 times.',
    2: 'Become King 20 times.',
    3: 'Become King 50 times.',
  },

  CROWN_AUTOLOCK_CONFIGURED: 'Configure King auto-lock at least once.',
  CROWN_AUTOLOCK_EXECUTED: {
    1: 'Have King auto-lock execute 1 time.',
    2: 'Have King auto-lock execute 10 times.',
    3: 'Have King auto-lock execute 25 times.',
  },

  // Barons
  BARON_AUTOMAX_ON: 'Create or enable AutoMax on a lock.',
  BARON_REFORGER: 'Extend a lock.',
  BARON_ARMORER: 'Increase the amount in a lock.',
  BARON_MERGER: 'Merge locks.',
  BARON_UNSEALED: 'Unlock (withdraw) a lock.',
  BARON_KEEPER: {
    1: 'Keep at least one active lock for 1 year.',
    2: 'Keep at least one active lock for 2 years.',
    3: 'Keep at least one active lock for 3 years.',
    4: 'Keep at least one active lock for 4 years.',
  },
  BARON_COLLECTOR: {
    1: 'Hold 10 veCLAIM tokenIds simultaneously.',
    2: 'Hold 20 veCLAIM tokenIds simultaneously.',
  },
  BARON_RENEW_ON_TIME: 'Extend a lock within 7 days of its previous end.',

  // Royalties
  ROYALTY_COLLECTOR: 'Collect royalties for the first time.',
  ROYALTY_COMPOUNDER: {
    1: 'Collect royalties in Collect & Lock mode 1 time.',
    2: 'Collect royalties in Collect & Lock mode 5 times.',
    3: 'Collect royalties in Collect & Lock mode 20 times.',
    4: 'Collect royalties in Collect & Lock mode 50 times.',
  },
  ROYALTY_DUAL_MODE:
    'Collect royalties at least once in Collect ETH mode and once in Collect & Lock mode.',
  ROYALTY_AUTOPILOT: 'Enable auto-compounding for royalties.',
  ROYALTY_AUTOPILOT_EXECUTED: 'Have auto-compounding execute at least once.',
  ROYALTY_STREAK: {
    1: 'Collect royalties (manual collection or auto-compound) in 52 distinct weeks (1 year).',
    2: 'Collect royalties (manual collection or auto-compound) in 104 distinct weeks (2 years).',
    3: 'Collect royalties (manual collection or auto-compound) in 156 distinct weeks (3 years).',
    4: 'Collect royalties (manual collection or auto-compound) in 208 distinct weeks (4 years).',
  },

  // Furnace
  FURNACE_FORGED: 'Enter the Furnace for the first time.',
  FURNACE_DUAL_INPUT: 'Enter the Furnace via both ETH and CLAIM paths.',
  FURNACE_ALCHEMIST: 'Enter the Furnace via the token path.',
  FURNACE_BONUS_HUNTER: {
    1: 'Make 5 Furnace entries in the top 10% bonus (24h window).',
    2: 'Make 5 Furnace entries in the top 5% bonus (24h window).',
    3: 'Make 5 Furnace entries in the top 1% bonus (24h window).',
  },
  FURNACE_HIGH_BONUS_STREAK: {
    1: 'Make 3 top-10% bonus entries within 30d.',
    2: 'Make 10 top-10% bonus entries within 30d.',
  },

  // Market
  MARKET_FIRST_LISTING: 'List your first lock for sale.',
  MARKET_MARKET_MAKER: 'List 3 and 10 locks for sale.',
  MARKET_LISTING_SETTLED: 'Have one of your listings settled.',
  MARKET_OFFER_MAKER: 'Create your first offer (bid/limit buy).',
  MARKET_AUTOFILL_ORDER_AUTO_FURNACE: 'Have an offer execute into a lock.',
  MARKET_SELL_TO_FURNACE: 'Sell a lock directly back to the Furnace for liquid CLAIM.',

  // LP Vault
  LP_FIRST_STAKE: 'Stake in the LP vault for the first time.',
  LP_HARVESTER: 'Collect LP rewards for the first time.',
  LP_AUTOCOMPOUND_ON: 'Enable LP auto-compounding.',
  LP_HARVEST_AND_LOCK: 'Lock LP rewards for the first time.',
  LP_AUTOCOMPOUND_EXECUTED: 'Have LP auto-compounding execute at least once.',
  LP_UNBOND_STARTED: 'Start an LP unbond.',
  LP_UNBOND_COMPLETE: 'Withdraw after completing an unbond.',
  LP_LONG_STAKER: {
    1: 'Keep an LP stake active for 1 year.',
    2: 'Keep an LP stake active for 2 years.',
    3: 'Keep an LP stake active for 3 years.',
    4: 'Keep an LP stake active for 4 years.',
  },

  // Social
  SOCIAL_REFERRED: 'Redeem a referral after your first meaningful onchain action.',
  SOCIAL_HERALD: {
    1: 'Refer 1 qualified player.',
    2: 'Refer 5 qualified players.',
    3: 'Refer 25 qualified players.',
    4: 'Refer 100 qualified players.',
  },

  // Explorer
  META_DUAL_ROLE: 'Be both a King (take over) and a Baron (create a lock).',
  META_FULL_STACK: 'Touch Crown, Barons, Royalties, Furnace, Market, and LP at least once.',
  META_SEVEN_DAY_ACTIVE: {
    1: 'Be active on 3 distinct days (UTC).',
    2: 'Be active on 7 distinct days (UTC).',
    3: 'Be active on 30 distinct days (UTC).',
    4: 'Be active on 90 distinct days (UTC).',
  },

  META_AUTOMATION_ARCHITECT:
    'Enable Crown auto-lock, Royalties auto-compound, and LP auto-compound.',
  META_AUTOMATION_TRIFECTA:
    'Have all three automations execute at least once (Crown, Royalties, LP).',
  META_BOT_USER: 'Use Claimrush from a smart-contract address (any on-chain action).',
  META_BOT_CROWN_AUTOPILOT:
    'Use a smart-contract address and have Crown auto-lock execute at least once.',
} as const satisfies Record<ProfileBadgeId, BadgeHowTo>;

export function getBadgeHowTo(id: ProfileBadgeId, tier: number | null): string | null {
  const entry = BADGE_HOW_TO[id];
  if (typeof entry === 'string') return entry;
  if (tier === null) return null;
  // `as const` on BADGE_HOW_TO preserves literal numeric keys (e.g. `{1: "...", 2: "..."}`),
  // which aren't indexable by `number` without widening.
  const byTier = entry as Readonly<Record<number, string>>;
  return byTier[tier] ?? null;
}
