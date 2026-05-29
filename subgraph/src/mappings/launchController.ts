import {
  DeploymentValidated,
  GenesisFinalized,
  SkimFailed,
  TokenSwept,
} from "../generated/LaunchController/LaunchController";
import { ethereum } from "@graphprotocol/graph-ts";

import {
  GenesisState,
  LaunchControllerDeploymentValidatedEvent,
  LaunchControllerSkimFailedEvent,
  LaunchControllerTokenSweptEvent,
} from "../generated/schema";

import { loadOrCreateProtocol, setBytesIfZero } from "../utils/protocol";

const GENESIS_STATE_ID = "1";

function eventId(event: ethereum.Event): string {
  return event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
}

function loadOrCreateGenesisState(): GenesisState {
  let g = GenesisState.load(GENESIS_STATE_ID);
  if (g == null) {
    g = new GenesisState(GENESIS_STATE_ID);
    g.genesisFinalized = false;
    g.finalizedAt = null;
    g.finalizedTxHash = null;
    g.genesisLpVaultLockStart = null;
    g.genesisLpVaultUnlockTime = null;
    g.save();
  }
  return g as GenesisState;
}

export function handleGenesisFinalized(event: GenesisFinalized): void {
  const protocol = loadOrCreateProtocol(event.block.number);
  protocol.launchController = event.address;
  protocol.genesisLpVault24m = event.params.genesisLpVault;
  // in the event parameters but the handler does not populate them on Protocol.
  // This is acceptable because other handlers (VeClaimNFT, EntryTokenRegistry) fill
  // those fields, but it's a missed opportunity for early backfill.
  protocol.save();

  const g = loadOrCreateGenesisState();
  g.genesisFinalized = true;
  g.finalizedAt = event.params.timestamp;
  g.finalizedTxHash = event.transaction.hash;
  g.save();
}

export function handleDeploymentValidated(event: DeploymentValidated): void {
  const row = new LaunchControllerDeploymentValidatedEvent(eventId(event));
  row.claim = event.params.claim;
  row.mineCore = event.params.mineCore;
  row.genesisLpVault = event.params.genesisLpVault;
  row.guardian = event.params.guardian;
  row.expectedPool = event.params.expectedPool;
  row.timestamp = event.block.timestamp;
  row.txHash = event.transaction.hash;
  row.save();
}

export function handleTokenSwept(event: TokenSwept): void {
  const row = new LaunchControllerTokenSweptEvent(eventId(event));
  row.token = event.params.token;
  row.to = event.params.to;
  row.amountWei = event.params.amount;
  row.timestamp = event.block.timestamp;
  row.txHash = event.transaction.hash;
  row.save();
}

export function handleSkimFailed(event: SkimFailed): void {
  const row = new LaunchControllerSkimFailedEvent(eventId(event));
  row.pool = event.params.pool;
  row.reason = event.params.reason;
  row.timestamp = event.block.timestamp;
  row.txHash = event.transaction.hash;
  row.save();
}
