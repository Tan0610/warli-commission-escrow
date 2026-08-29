# Warli Commission Escrow

> Road to Devcon II — *Art, Culture & Ethereum in India*
> Problem 1: **The Advance That Never Shows Up**

Kalpana paints Warli scenes on cloth in a village three hours from Nashik. A collector in
Berlin wants to commission a large piece — good money, the kind that changes a month. But
the last two times a foreign buyer sent an advance, the agent who arranged it kept most of
it and Kalpana never saw the rest. The collector has her own worry: wiring money to someone
she has never met, for a painting that does not exist yet, with no way to get it back if it
never arrives.

`CommissionEscrow` makes the money itself hold the promise. It is locked in the contract
the moment the deal is struck, it can only reach Kalpana after delivery is confirmed
on-chain, and it returns to the collector automatically if the deadline passes with nothing
delivered. No agent ever touches it, and neither party has to trust the other.

---

## The commission lifecycle

```
                      openCommission()  [collector sends msg.value]
                              │
                              ▼
                          ┌────────┐
                          │ Funded │  money locked in the contract
                          └────────┘
                          │        │
        artisan:          │        │      anyone, after deadline:
        markDelivered()   │        │      refundAfterDeadline()
                          ▼        ▼
                   ┌───────────┐  ┌──────────┐
                   │ Delivered │  │ Refunded │  ◄── TERMINAL
                   └───────────┘  └──────────┘     collector made whole
                    │         │
   collector:       │         │   artisan, after the review window:
   confirmDelivery()│         │   claimAfterReviewWindow()
                    ▼         ▼
                   ┌────────────┐
                   │  Released  │  ◄── TERMINAL, artisan paid
                   └────────────┘

   From Funded or Delivered, either party may raiseDispute()
                              │
                              ▼
                        ┌──────────┐
                        │ Disputed │  only a neutral arbiter can settle
                        └──────────┘
                              │  resolveDispute(artisanShareBps)
                              ▼
                    Released  or  Refunded   ◄── TERMINAL
```

### Step by step

| Step | Who | What happens |
|---|---|---|
| `openCommission(artisan, deadline, reviewWindow, briefURI)` | collector | The payment is transferred into the contract in the same transaction. The recorded amount **is** `msg.value` — there is no amount argument. Status → `Funded`. |
| `markDelivered(id, evidenceURI)` | artisan | Submits proof of delivery and sets the delivery-confirmation state. **Moves no money.** Evidence is mandatory. Status → `Delivered`, clock starts on the review window. |
| `confirmDelivery(id)` | collector | The collector confirms the piece arrived. Status → `Released`, artisan paid. |
| `claimAfterReviewWindow(id)` | artisan | If the collector never confirms and never disputes, the artisan may claim once the review window elapses. Still requires `Delivered`. |
| `refundAfterDeadline(id)` | anyone | Once the deadline passes with the commission still `Funded`, the escrow returns to the collector. |
| `raiseDispute(id)` | collector or artisan | Either party can flag a disagreement. Moves no money; hands the decision to the arbiter. |
| `resolveDispute(id, artisanShareBps)` | arbiter only | A neutral third party splits the escrow. `0` refunds the collector in full, `10000` pays the artisan in full, anything between splits it. |
| `withdrawPending()` | anyone owed | Pulls a payout that a direct transfer could not deliver. |

`Released` and `Refunded` are terminal. Every state-changing entry point loads the
commission through `_open()`, which reverts on a settled commission — so nothing can pay
out twice.

---

## The guarantees, and how they are enforced

### The money is locked before work begins

`openCommission` is `payable` and reverts with `NoValueLocked` if `msg.value == 0`. A
commission cannot exist in a funded-looking state without the contract actually holding the
funds. `lockedAmount(id)` and `totalEscrowed` make that provable to both parties on-chain.

### Release is gated on a delivery state, not on who calls first

Payment can only be reached from `Delivered`. There is no function anywhere that pays the
artisan out of `Funded` — not for the collector, not for the artisan, not for the admin.
`test_NoPayoutIsPossibleBeforeDeliveryIsMarked` asserts exactly this from both directions.

The collector cannot skip or override the delivery state to force a release, and the
artisan cannot be paid for work they never marked as delivered.

The one asymmetry worth naming: a collector who simply goes silent could otherwise strand a
finished painting forever. `claimAfterReviewWindow` fixes that, and it is still gated on
`Delivered` — silence is not a way to avoid paying for work that was delivered.

### "Delivered" is a claim on the record, not a bare flag

This is the part that decides whether the collector is actually protected. If
`markDelivered` were a no-argument boolean the artisan could flip at will, then combined
with the review window it would amount to: assert delivery, wait seven days, get paid. The
collector in Berlin would be exactly where she started — money gone, no painting, nicer
interface.

So evidence is required, not optional. `markDelivered(id, evidenceURI)` reverts with
`DeliveryEvidenceRequired` on an empty string, and the URI is stored on the commission and
emitted in `DeliveryMarked`. Consequences:

- Nothing enters the `Delivered` state without a specific, attributable claim attached, so
  the review-window clock never starts on an empty assertion.
- The collector has something concrete to inspect before confirming, and something
  concrete to point at when disputing.
- If it does reach dispute, the arbiter is shown the artisan's own submission, timestamped
  by `deliveredAt` and immutable — read it back with `deliveryEvidence(id)`.

The contract cannot verify that a photograph shows the right painting; no contract can.
What it can do is make a false claim permanent, attributable, and the exact thing an
arbiter will be handed. That is the difference between a promise and a flag.

Tested by `test_DeliveryCannotBeMarkedWithoutEvidence`,
`test_DeliveryEvidenceIsRecordedAndTimestamped`, and
`test_CollectorCanDisputeTheEvidenceAndTheArbiterCanRuleAgainstTheArtisan`.

### State is written before any external call

Every payout goes through `_release`, `_refund`, or `resolveDispute`, and all three follow
the same order:

```solidity
c.status = Status.Released;   // terminal state written
c.amount = 0;                 // balance zeroed
totalEscrowed -= amount;      // accounting updated
_payOut(artisan, amount);     // ONLY THEN the external call
```

A malicious receiver that re-enters from its `receive()` finds a settled commission with a
zero balance and nothing to take. `nonReentrant` sits on every external entry point as a
second, independent barrier. Two tests exercise it: one where a re-entrant artisan tries to
be paid twice for its own commission, and one where it tries to drain a *different*
collector's commission held in the same contract.

### The deadline always leads somewhere

`refundAfterDeadline` is callable by **anyone** once the deadline passes on a still-`Funded`
commission, because the funds can only ever go to the collector. Making it permissionless
keeps the escape hatch reachable even if the collector cannot send a transaction.

It is deliberately unreachable from `Delivered`: a collector must not be able to wait out
the clock on work that actually arrived.

### Disputes are never settled by either party alone

`resolveDispute` carries two independent guards:

1. `onlyRole(ARBITER_ROLE)` — the caller must be the designated neutral party.
2. An explicit neutrality check that reverts with `ArbiterMustBeNeutral` if the caller is
   the collector or the artisan on *this* commission — even if they somehow hold the role.

The second guard is tested by granting the collector `ARBITER_ROLE` and confirming they
still cannot settle their own dispute. The arbiter is a role rather than a fixed address
precisely so it can be a multisig or a DAO.

**Trust assumption, stated plainly:** a disputed commission needs the arbiter to act. That
is the one place this design depends on a third party, and it is limited to the disputed
case — the happy path, the silent-collector path, and the deadline path all settle without
anyone's permission.

### Nothing gets stuck

If a payout transfer fails — a party using a contract wallet that reverts on receive — the
commission still settles and the money is credited to `pendingWithdrawals` for them to pull
later. A hostile fallback can never revert a settlement or hold a commission open.
`isSolvent()` asserts the contract's balance always covers `totalEscrowed + totalPending`.

---

## Tests

```
forge test -vv
```

38 unit and fuzz tests grouped under headings matching the guarantees above, plus a stateful invariant suite (see below).

| Guarantee | Tests |
|---|---|
| Funds locked at creation | `test_OpeningACommissionLocksTheMoneyImmediately`, `test_CannotOpenACommissionWithoutSendingValue` |
| Delivery is evidenced, not asserted | `test_DeliveryCannotBeMarkedWithoutEvidence`, `test_DeliveryEvidenceIsRecordedAndTimestamped`, `test_CollectorCanDisputeTheEvidenceAndTheArbiterCanRuleAgainstTheArtisan` |
| Release requires confirmed delivery | `test_NoPayoutIsPossibleBeforeDeliveryIsMarked`, `test_ConfirmedDeliveryPaysTheArtisan`, `test_OnlyTheArtisanCanMarkDelivered`, `test_OnlyTheCollectorCanConfirmDelivery`, `test_ArtisanCanClaimAfterAReviewWindowOfSilence` |
| State before external transfer | `test_ReentrantArtisanCannotBePaidTwice`, `test_ReentrancyCannotDrainAnotherCommission`, `test_SettlementSurvivesARecipientThatRejectsEther` |
| Timeout refund path | `test_RefundAfterDeadlineReturnsTheMoneyToTheCollector`, `test_NoRefundBeforeTheDeadline`, `test_AnyoneCanTriggerTheRefundButOnlyTheCollectorIsPaid`, `test_DeliveredWorkCannotBeRefundedByWaitingOutTheDeadline` |
| Neutral dispute resolution | `test_EitherPartyCanRaiseADisputeButNeitherCanSettleIt`, `test_APartyHoldingTheArbiterRoleStillCannotSettleTheirOwnDispute`, `test_ArbiterCanAwardTheArtisanInFull`, `test_ArbiterCanRefundTheCollectorInFull`, `test_ArbiterCanSplitTheEscrow` |
| Amount comes from `msg.value` | `testFuzz_StoredAmountAlwaysEqualsMsgValue`, `test_PayoutEqualsTheValueThatWasSent` |
| No double release | `test_ConfirmingTwiceDoesNotPayTwice`, `test_RefundingTwiceDoesNotRefundTwice`, `test_ASettledCommissionIsClosedToEveryPath`, `test_ResolvingADisputeTwiceReverts` |
| Value conservation (fuzz) | `testFuzz_DisputeSplitConservesTheEscrow`, `test_ContractStaysSolventAcrossManyCommissions` |

---

## Known limitations

Stated plainly, because a build that hides its edges is harder to trust than one that names
them.

**A dispute has no timeout.** `raiseDispute` has no deadline check, so either party can
raise one after the deadline has passed. That moves the commission to `Disputed`, and
`refundAfterDeadline` then reverts with `WrongStatus` from that point on. Recovery depends
entirely on the arbiter calling `resolveDispute`; there is no fallback that lets the
collector reclaim funds if a raised dispute is simply never settled.

This is an accepted trust assumption on the arbiter role — the same role check 5 already
requires to be independent of both parties — not a fund-loss bug. But it is worth knowing
before granting `ARBITER_ROLE` to an address that might go unresponsive, and it is the
argument for that role being a multisig rather than one key.

The alternative — auto-refunding a disputed commission after some longer timeout — was
considered and rejected: it hands a bad-faith collector a way to dispute delivered work and
then simply wait, which is a worse failure than an unresponsive arbiter.

**Evidence is a pointer, not a proof.** `markDelivered` requires a non-empty `evidenceURI`
and records it immutably, but the contract cannot verify that the URI resolves, that it
resolves to a photograph, or that the photograph shows the right painting. No contract can.
What it guarantees is that the claim is permanent, attributable, timestamped, and the exact
artefact an arbiter is handed. Pinning the content (IPFS rather than a mutable https URL)
is the submitter's responsibility.

**One arbiter role, not per-commission arbiters.** Every commission shares the same
`ARBITER_ROLE` set. A production version would likely let the two parties agree on a
specific arbiter at `openCommission` time.

---

## Beyond the brief: stateful invariant testing

Worked examples only prove the call orderings the author thought to write down. Checks 3
and 7 — state written before the external transfer, and no double release — are exactly the
properties that pass a hand-written test and then break on an interleaving nobody imagined.

`test/CommissionEscrow.invariant.t.sol` drives randomised sequences of every move the three
parties have: open, submit evidence, confirm, claim after silence, dispute, arbitrate,
refund at the deadline. **Time moves too** — the handler warps the clock, because the
refund and review-window paths are only reachable once a deadline has actually passed.

| Invariant | What it rules out |
|---|---|
| `balanceEqualsEscrowedPlusPending` | The contract's books drifting from the ETH it holds |
| `noCommissionSettlesTwice` | Any commission reaching a terminal state more than once |
| `settledCommissionsAreEmptied` | A settled commission still carrying a balance a second payout could find |
| `totalEscrowedMatchesTheOpenCommissions` | `totalEscrowed` drifting from the live commissions |
| `everyFundedWeiIsAccountedFor` | The contract holding more than was ever funded |

The first is an **exact equality**, not a lower bound:
`balance == totalEscrowed + totalPending`. Any wei that appeared or vanished for any reason
breaks it on the call that caused it.

```
Ran 1 test for test/CommissionEscrow.invariant.t.sol:CommissionEscrowInvariantTest
[PASS] invariant_balanceEqualsEscrowedPlusPending
[PASS] invariant_everyFundedWeiIsAccountedFor
[PASS] invariant_noCommissionSettlesTwice
[PASS] invariant_settledCommissionsAreEmptied
[PASS] invariant_totalEscrowedMatchesTheOpenCommissions
 CommissionEscrowInvariantTest invariants (runs: 256, calls: 51200, reverts: 0)

╭---------------+------------------------+-------+---------+----------╮
| Contract      | Selector               | Calls | Reverts | Discards |
+=====================================================================+
| EscrowHandler | claimAfterReviewWindow | 6484  | 0       | 0        |
| EscrowHandler | confirmDelivery        | 6368  | 0       | 0        |
| EscrowHandler | markDelivered          | 6381  | 0       | 0        |
| EscrowHandler | openCommission         | 6452  | 0       | 0        |
| EscrowHandler | passTime               | 6461  | 0       | 0        |
| EscrowHandler | raiseDispute           | 6372  | 0       | 0        |
| EscrowHandler | refundAfterDeadline    | 6228  | 0       | 0        |
| EscrowHandler | resolveDispute         | 6454  | 0       | 0        |
╰---------------+------------------------+-------+---------+----------╯

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 50.36s
```

256 runs × 200 calls — 51,200 calls, **0 reverts, 0 violations**. Every settlement path
(confirm, claim, refund, arbitrate) was exercised thousands of times against the same
commissions, in orders no hand-written test enumerates.

```bash
forge test --match-contract Invariant -v
```

---

## Build and deploy

Requires [Foundry](https://getfoundry.sh).

```bash
git clone --recursive <this repo>   # --recursive: forge-std and OpenZeppelin are submodules
cd warli-commission-escrow
forge build
forge test
```

Deploying to Base Sepolia:

```bash
cp .env.example .env                 # then edit; .env is gitignored
cast wallet import devcon --interactive      # encrypted keystore, no raw key on disk
forge script script/Deploy.s.sol:Deploy \
  --rpc-url base_sepolia --account devcon --broadcast --verify
```

No private key, API key, or authenticated URL is stored in this repository. `.env` is
gitignored; `.env.example` contains placeholders only, and the deploy script takes its
signer from the forge invocation rather than from a file.

---

## Stack

Solidity 0.8.28 · Foundry · OpenZeppelin v5.1.0 (`AccessControl`, `ReentrancyGuard`) ·
Base Sepolia.

## License

MIT
