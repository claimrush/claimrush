import { DelegationSessionUsed } from "../generated/ClaimAllHelper/ClaimAllHelper";

import { recordDelegationSessionUsed } from "../utils/delegation";

export function handleDelegationSessionUsed(event: DelegationSessionUsed): void {
  recordDelegationSessionUsed(
    event,
    event.params.user,
    event.params.delegate,
    event.params.actionType,
    event.params.permsUsed,
    event.params.refId,
    event.params.timestamp
  );
}
