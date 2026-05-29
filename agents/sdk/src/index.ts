export { findRepoRoot } from './repoRoot.js';
export type { RepoRootHints } from './repoRoot.js';

export { loadDeploymentManifest, getContractAddress } from './manifest.js';
export type {
  DeploymentManifest,
  ManifestContractRef,
  LoadDeploymentManifestParams,
} from './manifest.js';

export { loadAbi } from './abis.js';
export type { AbiNetwork, LoadAbiParams } from './abis.js';

export { createClaimRushClients, createClaimRushClientsAsync } from './clients.js';
export type { ClaimRushClients, CreateClaimRushClientsParams } from './clients.js';

export { getClaimRushContracts } from './contracts.js';
export type { ClaimRushContracts, GetClaimRushContractsParams } from './contracts.js';

export {
  quoteCurrentTakeoverPrice,
  quoteTakeoverWithToken,
  quoteTakeoverWithTokenMinOut,
  resolveTakeoverRoute,
  getFurnaceState,
  quoteEnterWithEth,
  quoteEnterWithClaim,
  quoteEnterWithToken,
  quoteSellLockToFurnace,
  minOutFromBps,
} from './quotes.js';
export type {
  FurnaceQuoteEnterResult,
  FurnaceQuoteSellLockToFurnaceResult,
  MineCoreTakeoverWithTokenQuote,
  MineCoreRegistryRoute,
} from './quotes.js';

export {
  getDexAdapterConfig,
  quoteDexAmountsOut,
  getFurnaceRegistryRouterConfig,
  getWethClaimHop,
  quoteEthToClaim,
  quoteClaimToEth,
  resolveMineCoreTakeoverRoute,
  resolveFurnaceEntryRoute,
  quoteEntryTokenToEth,
  quoteEntryTokenToClaim,
  toDexRoutes,
  reverseDexRoutes,
} from './dexQuotes.js';
export type { DexRoute, RegistryRoute, DexAdapterConfig, WethClaimHop } from './dexQuotes.js';

export { classifyViemError } from './errors.js';
export {
  TxManager,
  TxRevertedError,
  TxTimeoutError,
  DEFAULT_TX_REPLACEMENT_POLICY,
} from './tx/txManager.js';
export type {
  TxManagerParams,
  TxReplacementPolicy,
  TxReplacementPolicy as TxReplacementConfig,
} from './tx/txManager.js';
export type { ClaimRushErrorInfo, ClaimRushErrorKind } from './errors.js';

export { getGameStateSnapshot, stringifySnapshot } from './snapshot.js';
export type { ClaimRushSnapshot, SnapshotOptions } from './snapshot.js';

export { getLivePrices, createLivePricesCache } from './prices.js';
export type {
  GetLivePricesParams,
  LivePricesSnapshot,
  LiveEntryTokenPrice,
  SpotQuote,
  Erc20Meta,
  LivePricesCache,
  LivePricesCacheTtls,
  CreateLivePricesCacheParams,
  LiveEntryTokenFlags,
} from './prices.js';

export { startClaimRushEventStream, stringifyJson, parseEventStreamEnv } from './events.js';
export type {
  ClaimRushEvent,
  ClaimRushEventStreamOptions,
  ClaimRushEventStreamHandle,
} from './events.js';

export { runClaimRushHarness } from './harness/harness.js';
export type { HarnessOptions, HarnessResult, HarnessScenario } from './harness/harness.js';

export {
  runLiveAgent,
  buildActionPlan,
  runStrategies,
  createPolicyStrategy,
  loadStrategiesFromModules,
  stringifyPlan,
  parsePlan,
  toPlanJsonV1,
  fromPlanJsonV1,
  readPlanFromFile,
  writePlanToFile,
  executeAgentPlan,
  expandPlanWithAutoApprovals,
  startAgentMonitor,
  AgentMonitor,
  parseJsonWithBigInt,
  readAgentRunSession,
  replayAgentRun,
} from './agent/index.js';
export type {
  LiveAgentOptions,
  LiveAgentResult,
  AgentAction,
  AgentActionResult,
  AgentPlan,
  PolicyConfig,
  PolicyState,
  AgentStrategy,
  AgentStrategyContext,
  AgentStrategyResult,
  AgentStrategyTrace,
  AgentPlanJsonV1,
  AgentActionJsonV1,
  ExecuteAgentPlanParams,
  AutoApproveMode,
  AutoApproveOptions,
  AgentMonitorOptions,
  AgentMonitorState,
  AgentMonitorSnapshot,
  AgentMonitorPlan,
  AgentMonitorStrategy,
  AgentMonitorEvent,
  AgentMonitorTx,
  AgentRunSessionV1,
  AgentTickRecordV1,
  ReplayAgentRunParams,
  ReplayAgentRunResult,
} from './agent/index.js';

export {
  SubgraphClient,
  getSubgraphMeta,
  getSubgraphProtocol,
  getTokenPricingSnapshot,
  getSubgraphUser,
  getRecentTakeovers,
  getRecentFurnaceEnters,
  getRecentShareholderClaims,
  getRecentShareholderAutoCompounds,
  getEntryTokenConfigs,
  normalizeSubgraphAddress,
} from './subgraph.js';
export type {
  SubgraphClientParams,
  SubgraphMeta,
  SubgraphProtocol,
  SubgraphTokenPricingSnapshot,
  SubgraphEntryTokenRegistry,
  SubgraphEntryTokenConfig,
  SubgraphUser,
  SubgraphVeLock,
  SubgraphTakeover,
  SubgraphFurnaceEnterEvent,
  SubgraphShareholderClaimEvent,
  SubgraphShareholderAutoCompoundExecutedEvent,
} from './subgraph.js';

export {
  DELEGATION_HUB_EIP712_NAME,
  DELEGATION_HUB_EIP712_VERSION,
  SET_SESSION_PRIMARY_TYPE,
  SET_SESSION_TYPES,
  buildSetSessionTypedData,
  readDelegationNonce,
  getDelegationSession,
  isAuthorized,
  signSetSession,
  submitSetSessionBySig,
  P_TAKEOVER_FOR,
  P_ROUTE_REIGN_CLAIM_TO_CALLER,
  P_SET_REIGN_ETH_RECIPIENT,
  P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY,
  P_SET_REIGN_CLAIM_RECIPIENT,
  P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY,
  P_WITHDRAW_KING_BUCKET_FOR,
  P_CLAIM_SHAREHOLDER_FOR,
  P_CLAIM_ALL_FOR,
  P_FURNACE_ENTER_ETH_FOR,
  P_FURNACE_ENTER_CLAIM_FOR,
  P_FURNACE_ENTER_TOKEN_FOR,
  P_VE_EXTEND_LOCK_FOR,
  P_VE_MERGE_LOCKS_FOR,
  P_VE_UNLOCK_EXPIRED_FOR,
  P_SET_KING_AUTO_LOCK_CONFIG_FOR,
  P_SET_SHAREHOLDER_AUTOCOMPOUND_CONFIG_FOR,
  P_SET_LP_AUTOCOMPOUND_CONFIG_FOR,
  ALL,
  SAFE_AGENT_PERMS,
  permsMask,
  PERM_DEFINITIONS,
  PERM_NAME_TO_BIT,
  permsFromNames,
  parsePermsSpec,
  describePerms,
} from './delegation/index.js';

export type {
  SetSessionTypedDataParams,
  DelegationHubReadParams,
  DelegationSession,
  SetSessionBySigParams,
  DelegationPermInfo,
} from './delegation/index.js';

export {
  AchievementEngine,
  ACHIEVEMENT_SCHEMA_PATH,
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
} from './achievements/index.js';
export type {
  Achievement,
  AchievementKind,
  AchievementLevel,
  AchievementWriter,
  AchievementEngineOptions,
  AchievementTickInputs,
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
} from './achievements/index.js';
