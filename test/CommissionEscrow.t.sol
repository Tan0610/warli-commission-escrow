// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CommissionEscrow} from "../src/CommissionEscrow.sol";
import {ReentrantArtisan, RejectingParty} from "./mocks/Parties.sol";

/// @notice Tests for the commission escrow, grouped by the guarantee each one defends.
///
///         The story under test: a collector in Berlin commissions a large Warli piece
///         from Kalpana. The money must be locked the moment they agree, must reach her
///         only once delivery is confirmed, must come back to the collector if nothing
///         ever arrives, and must never be paid out twice.
contract CommissionEscrowTest is Test {
    CommissionEscrow internal escrow;

    address internal admin = makeAddr("admin");
    address internal arbiter = makeAddr("arbiter");
    address internal collector = makeAddr("berlinCollector");
    address internal kalpana = makeAddr("kalpana");
    address internal outsider = makeAddr("outsider");

    uint256 internal constant PRICE = 5 ether;
    uint32 internal constant REVIEW = 7 days;
    uint64 internal deadline;

    bytes32 internal arbiterRole;

    /// @dev Cached: calling escrow.TOTAL_BPS() inline would be an external call that
    ///      consumes a pending vm.prank before the guarded call is reached.
    uint256 internal totalBps;

    function setUp() public {
        escrow = new CommissionEscrow(admin, arbiter);
        arbiterRole = escrow.ARBITER_ROLE();
        totalBps = escrow.TOTAL_BPS();
        deadline = uint64(block.timestamp + 30 days);

        vm.deal(collector, 100 ether);
        vm.deal(outsider, 10 ether);
    }

    // -----------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------

    function _open() internal returns (uint256 id) {
        vm.prank(collector);
        id = escrow.openCommission{value: PRICE}(kalpana, deadline, REVIEW, "ipfs://brief");
    }

    function _openAndDeliver() internal returns (uint256 id) {
        id = _open();
        vm.prank(kalpana);
        escrow.markDelivered(id);
    }

    // =================================================================
    // 1. Escrow holds the funds before work begins
    // =================================================================

    function test_OpeningACommissionLocksTheMoneyImmediately() public {
        uint256 collectorBefore = collector.balance;

        uint256 id = _open();

        assertEq(address(escrow).balance, PRICE, "the money is in the contract, not with an agent");
        assertEq(collector.balance, collectorBefore - PRICE, "and it has left the collector");
        assertEq(escrow.lockedAmount(id), PRICE, "provably locked against this commission");
        assertEq(escrow.totalEscrowed(), PRICE);
        assertEq(uint8(escrow.statusOf(id)), uint8(CommissionEscrow.Status.Funded));
        assertEq(kalpana.balance, 0, "nothing has reached the artisan yet");
    }

    function test_CannotOpenACommissionWithoutSendingValue() public {
        vm.prank(collector);
        vm.expectRevert(CommissionEscrow.NoValueLocked.selector);
        escrow.openCommission{value: 0}(kalpana, deadline, REVIEW, "ipfs://brief");

        assertEq(escrow.nextCommissionId(), 1, "no commission was created");
    }

    function test_CommissionRecordsBothParties() public {
        uint256 id = _open();
        CommissionEscrow.Commission memory c = escrow.getCommission(id);

        assertEq(c.collector, collector);
        assertEq(c.artisan, kalpana);
        assertEq(c.deadline, deadline);
        assertEq(c.briefURI, "ipfs://brief");
    }

    function test_CannotCommissionYourself() public {
        vm.prank(collector);
        vm.expectRevert(CommissionEscrow.ArtisanCannotBeCollector.selector);
        escrow.openCommission{value: PRICE}(collector, deadline, REVIEW, "ipfs://brief");
    }

    function test_DeadlineMustBeInTheFuture() public {
        uint64 past = uint64(block.timestamp);
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(CommissionEscrow.DeadlineNotInFuture.selector, past, block.timestamp)
        );
        escrow.openCommission{value: PRICE}(kalpana, past, REVIEW, "ipfs://brief");
    }

    // =================================================================
    // 2. Release requires confirmed delivery
    // =================================================================

    /// @notice The core guarantee. Before `markDelivered`, there is no path that moves
    ///         money to the artisan — not for the collector, not for the artisan, not
    ///         for anyone.
    function test_NoPayoutIsPossibleBeforeDeliveryIsMarked() public {
        uint256 id = _open();

        // The collector cannot force an early release.
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(
                CommissionEscrow.WrongStatus.selector,
                id,
                CommissionEscrow.Status.Funded,
                CommissionEscrow.Status.Delivered
            )
        );
        escrow.confirmDelivery(id);

        // Nor can the artisan claim without having marked delivery.
        vm.prank(kalpana);
        vm.expectRevert(
            abi.encodeWithSelector(
                CommissionEscrow.WrongStatus.selector,
                id,
                CommissionEscrow.Status.Funded,
                CommissionEscrow.Status.Delivered
            )
        );
        escrow.claimAfterReviewWindow(id);

        assertEq(kalpana.balance, 0);
        assertEq(address(escrow).balance, PRICE, "still locked");
    }

    function test_ConfirmedDeliveryPaysTheArtisan() public {
        uint256 id = _openAndDeliver();

        assertEq(kalpana.balance, 0, "marking delivery alone moves no money");
        assertEq(uint8(escrow.statusOf(id)), uint8(CommissionEscrow.Status.Delivered));

        vm.prank(collector);
        escrow.confirmDelivery(id);

        assertEq(kalpana.balance, PRICE, "paid in full, directly, with no agent taking a cut");
        assertEq(uint8(escrow.statusOf(id)), uint8(CommissionEscrow.Status.Released));
        assertEq(escrow.lockedAmount(id), 0);
        assertEq(escrow.totalEscrowed(), 0);
    }

    function test_OnlyTheArtisanCanMarkDelivered() public {
        uint256 id = _open();

        vm.prank(collector);
        vm.expectRevert(abi.encodeWithSelector(CommissionEscrow.NotTheArtisan.selector, collector));
        escrow.markDelivered(id);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(CommissionEscrow.NotTheArtisan.selector, outsider));
        escrow.markDelivered(id);
    }

    function test_OnlyTheCollectorCanConfirmDelivery() public {
        uint256 id = _openAndDeliver();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(CommissionEscrow.NotTheCollector.selector, outsider));
        escrow.confirmDelivery(id);

        vm.prank(kalpana);
        vm.expectRevert(abi.encodeWithSelector(CommissionEscrow.NotTheCollector.selector, kalpana));
        escrow.confirmDelivery(id);
    }

    /// @notice A collector who simply goes quiet cannot strand a finished painting: after
    ///         the review window the artisan can claim. Still gated on delivery state.
    function test_ArtisanCanClaimAfterAReviewWindowOfSilence() public {
        uint256 id = _openAndDeliver();

        vm.prank(kalpana);
        vm.expectRevert();
        escrow.claimAfterReviewWindow(id); // too early

        vm.warp(block.timestamp + REVIEW + 1);
        vm.prank(kalpana);
        escrow.claimAfterReviewWindow(id);

        assertEq(kalpana.balance, PRICE);
        assertEq(uint8(escrow.statusOf(id)), uint8(CommissionEscrow.Status.Released));
    }

    function test_OnlyTheArtisanCanClaimAfterTheReviewWindow() public {
        uint256 id = _openAndDeliver();
        vm.warp(block.timestamp + REVIEW + 1);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(CommissionEscrow.NotTheArtisan.selector, outsider));
        escrow.claimAfterReviewWindow(id);
    }

    // =================================================================
    // 3. State is updated before the external transfer
    // =================================================================

    /// @notice An artisan contract that re-enters from its `receive()` is paid once.
    ///         By the time the transfer happens the commission is already Released with a
    ///         zeroed balance, so the nested call finds nothing to take.
    function test_ReentrantArtisanCannotBePaidTwice() public {
        ReentrantArtisan attacker = new ReentrantArtisan(escrow);

        vm.prank(collector);
        uint256 id = escrow.openCommission{value: PRICE}(address(attacker), deadline, REVIEW, "ipfs://x");
        attacker.setCommission(id);

        attacker.markDelivered();
        vm.warp(block.timestamp + REVIEW + 1);
        attacker.claim();

        assertFalse(attacker.reentrySucceeded(), "the nested claim was rejected");
        assertEq(address(attacker).balance, PRICE, "exactly the commission amount, once");
        assertEq(address(escrow).balance, 0);
        assertEq(uint8(escrow.statusOf(id)), uint8(CommissionEscrow.Status.Released));
    }

    /// @notice Funding a second commission and re-entering cannot drain the first.
    function test_ReentrancyCannotDrainAnotherCommission() public {
        ReentrantArtisan attacker = new ReentrantArtisan(escrow);

        // A second, unrelated commission holds funds in the same contract.
        uint256 innocent = _open();

        vm.prank(collector);
        uint256 id = escrow.openCommission{value: 1 ether}(address(attacker), deadline, REVIEW, "ipfs://x");
        attacker.setCommission(id);

        attacker.markDelivered();
        vm.warp(block.timestamp + REVIEW + 1);
        attacker.claim();

        assertEq(address(attacker).balance, 1 ether, "only its own commission");
        assertEq(escrow.lockedAmount(innocent), PRICE, "the other commission is untouched");
        assertEq(address(escrow).balance, PRICE);
        assertTrue(escrow.isSolvent());
    }

    /// @notice A recipient with a reverting fallback cannot hold a commission open. It
    ///         settles anyway and the money moves to a pull ledger.
    function test_SettlementSurvivesARecipientThatRejectsEther() public {
        RejectingParty stubborn = new RejectingParty(escrow);

        vm.prank(collector);
        uint256 id = escrow.openCommission{value: PRICE}(address(stubborn), deadline, REVIEW, "ipfs://x");

        stubborn.markDelivered(id);
        vm.prank(collector);
        escrow.confirmDelivery(id);

        assertEq(uint8(escrow.statusOf(id)), uint8(CommissionEscrow.Status.Released), "still terminal");
        assertEq(escrow.pendingWithdrawals(address(stubborn)), PRICE, "credited for a later pull");
        assertTrue(escrow.isSolvent());
    }

    // =================================================================
    // 4. The timeout path refunds the collector
    // =================================================================

    function test_RefundAfterDeadlineReturnsTheMoneyToTheCollector() public {
        uint256 id = _open();
        uint256 before = collector.balance;

        vm.warp(uint256(deadline) + 1);
        escrow.refundAfterDeadline(id);

        assertEq(collector.balance, before + PRICE, "back in the collector's pocket");
        assertEq(kalpana.balance, 0, "and nobody else's");
        assertEq(uint8(escrow.statusOf(id)), uint8(CommissionEscrow.Status.Refunded));
        assertEq(escrow.totalEscrowed(), 0);
    }

    function test_NoRefundBeforeTheDeadline() public {
        uint256 id = _open();

        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(CommissionEscrow.DeadlineNotReached.selector, deadline, block.timestamp)
        );
        escrow.refundAfterDeadline(id);

        assertEq(address(escrow).balance, PRICE);
    }

    /// @notice The refund is reachable by anyone, because the funds can only go to the
    ///         collector. That keeps the escape hatch open even if the collector cannot
    ///         transact themselves.
    function test_AnyoneCanTriggerTheRefundButOnlyTheCollectorIsPaid() public {
        uint256 id = _open();
        uint256 before = collector.balance;

        vm.warp(uint256(deadline) + 1);
        vm.prank(outsider);
        escrow.refundAfterDeadline(id);

        assertEq(collector.balance, before + PRICE);
    }

    /// @notice A collector cannot wait out the clock on work that was actually delivered.
    function test_DeliveredWorkCannotBeRefundedByWaitingOutTheDeadline() public {
        uint256 id = _openAndDeliver();

        vm.warp(uint256(deadline) + 1);
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(
                CommissionEscrow.WrongStatus.selector,
                id,
                CommissionEscrow.Status.Delivered,
                CommissionEscrow.Status.Funded
            )
        );
        escrow.refundAfterDeadline(id);

        // The artisan can still be paid for it.
        vm.prank(kalpana);
        escrow.claimAfterReviewWindow(id);
        assertEq(kalpana.balance, PRICE);
    }

    // =================================================================
    // 5. Disputes are never settled by either party alone
    // =================================================================

    function test_EitherPartyCanRaiseADisputeButNeitherCanSettleIt() public {
        uint256 id = _openAndDeliver();

        vm.prank(collector);
        escrow.raiseDispute(id);
        assertEq(uint8(escrow.statusOf(id)), uint8(CommissionEscrow.Status.Disputed));

        // Neither party holds ARBITER_ROLE, so neither can resolve it.
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, collector, arbiterRole
            )
        );
        escrow.resolveDispute(id, 0);

        vm.prank(kalpana);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, kalpana, arbiterRole
            )
        );
        escrow.resolveDispute(id, totalBps);

        assertEq(address(escrow).balance, PRICE, "the money has not moved");
    }

    function test_OutsidersCannotRaiseADispute() public {
        uint256 id = _openAndDeliver();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(CommissionEscrow.NotAParty.selector, outsider));
        escrow.raiseDispute(id);
    }

    /// @notice Even if a party somehow holds the arbiter role, the neutrality check stops
    ///         them settling their own dispute.
    function test_APartyHoldingTheArbiterRoleStillCannotSettleTheirOwnDispute() public {
        uint256 id = _openAndDeliver();
        vm.prank(collector);
        escrow.raiseDispute(id);

        vm.prank(admin);
        escrow.grantRole(arbiterRole, collector);

        vm.prank(collector);
        vm.expectRevert(abi.encodeWithSelector(CommissionEscrow.ArbiterMustBeNeutral.selector, collector));
        escrow.resolveDispute(id, totalBps);

        assertEq(address(escrow).balance, PRICE);
    }

    function test_ArbiterCanAwardTheArtisanInFull() public {
        uint256 id = _openAndDeliver();
        vm.prank(kalpana);
        escrow.raiseDispute(id);

        vm.prank(arbiter);
        escrow.resolveDispute(id, totalBps);

        assertEq(kalpana.balance, PRICE);
        assertEq(uint8(escrow.statusOf(id)), uint8(CommissionEscrow.Status.Released));
    }

    function test_ArbiterCanRefundTheCollectorInFull() public {
        uint256 id = _openAndDeliver();
        uint256 before = collector.balance;

        vm.prank(collector);
        escrow.raiseDispute(id);

        vm.prank(arbiter);
        escrow.resolveDispute(id, 0);

        assertEq(collector.balance, before + PRICE);
        assertEq(kalpana.balance, 0);
        assertEq(uint8(escrow.statusOf(id)), uint8(CommissionEscrow.Status.Refunded));
    }

    function test_ArbiterCanSplitTheEscrow() public {
        uint256 id = _openAndDeliver();
        uint256 before = collector.balance;

        vm.prank(collector);
        escrow.raiseDispute(id);

        vm.prank(arbiter);
        escrow.resolveDispute(id, 6_000); // 60% to the artisan

        assertEq(kalpana.balance, (PRICE * 6_000) / 10_000);
        assertEq(collector.balance, before + (PRICE * 4_000) / 10_000);
        assertEq(address(escrow).balance, 0, "the whole escrow was distributed");
        assertEq(escrow.totalEscrowed(), 0);
    }

    function test_DisputeCanBeRaisedBeforeDeliveryToo() public {
        uint256 id = _open();
        vm.prank(collector);
        escrow.raiseDispute(id);
        assertEq(uint8(escrow.statusOf(id)), uint8(CommissionEscrow.Status.Disputed));
    }

    /// @notice A disputed commission is out of the deadline path: it is the arbiter's
    ///         call, not a race against the clock.
    function test_DisputedCommissionCannotBeRefundedByDeadline() public {
        uint256 id = _open();
        vm.prank(collector);
        escrow.raiseDispute(id);

        vm.warp(uint256(deadline) + 1);
        vm.expectRevert();
        escrow.refundAfterDeadline(id);
    }

    // =================================================================
    // 6. The amount comes from the value actually sent
    // =================================================================

    function testFuzz_StoredAmountAlwaysEqualsMsgValue(uint96 sent) public {
        sent = uint96(bound(sent, 1, 90 ether));

        vm.prank(collector);
        uint256 id = escrow.openCommission{value: sent}(kalpana, deadline, REVIEW, "ipfs://brief");

        assertEq(escrow.lockedAmount(id), sent, "recorded exactly what arrived");
        assertEq(address(escrow).balance, sent, "and the contract really holds it");
    }

    /// @notice There is no caller-supplied amount argument to disagree with msg.value:
    ///         whatever is sent is what the artisan can eventually be paid.
    function test_PayoutEqualsTheValueThatWasSent() public {
        vm.prank(collector);
        uint256 id = escrow.openCommission{value: 1.234 ether}(kalpana, deadline, REVIEW, "ipfs://b");

        vm.prank(kalpana);
        escrow.markDelivered(id);
        vm.prank(collector);
        escrow.confirmDelivery(id);

        assertEq(kalpana.balance, 1.234 ether);
    }

    // =================================================================
    // 7. No double release of the same commission
    // =================================================================

    function test_ConfirmingTwiceDoesNotPayTwice() public {
        uint256 id = _openAndDeliver();

        vm.prank(collector);
        escrow.confirmDelivery(id);
        assertEq(kalpana.balance, PRICE);

        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(
                CommissionEscrow.CommissionAlreadySettled.selector, id, CommissionEscrow.Status.Released
            )
        );
        escrow.confirmDelivery(id);

        assertEq(kalpana.balance, PRICE, "paid once");
        assertEq(address(escrow).balance, 0);
    }

    function test_RefundingTwiceDoesNotRefundTwice() public {
        uint256 id = _open();
        uint256 before = collector.balance;

        vm.warp(uint256(deadline) + 1);
        escrow.refundAfterDeadline(id);
        assertEq(collector.balance, before + PRICE);

        vm.expectRevert(
            abi.encodeWithSelector(
                CommissionEscrow.CommissionAlreadySettled.selector, id, CommissionEscrow.Status.Refunded
            )
        );
        escrow.refundAfterDeadline(id);

        assertEq(collector.balance, before + PRICE, "refunded once");
    }

    /// @notice A released commission cannot then be refunded, or vice versa.
    function test_ASettledCommissionIsClosedToEveryPath() public {
        uint256 id = _openAndDeliver();
        vm.prank(collector);
        escrow.confirmDelivery(id);

        vm.warp(uint256(deadline) + 1);

        vm.expectRevert();
        escrow.refundAfterDeadline(id);

        vm.prank(kalpana);
        vm.expectRevert();
        escrow.claimAfterReviewWindow(id);

        vm.prank(collector);
        vm.expectRevert();
        escrow.raiseDispute(id);

        vm.prank(arbiter);
        vm.expectRevert();
        escrow.resolveDispute(id, 0);

        assertEq(address(escrow).balance, 0);
    }

    function test_ResolvingADisputeTwiceReverts() public {
        uint256 id = _openAndDeliver();
        vm.prank(collector);
        escrow.raiseDispute(id);

        vm.prank(arbiter);
        escrow.resolveDispute(id, 5_000);
        uint256 balanceAfter = kalpana.balance;

        vm.prank(arbiter);
        vm.expectRevert();
        escrow.resolveDispute(id, 5_000);

        assertEq(kalpana.balance, balanceAfter);
    }

    function test_UnknownCommissionReverts() public {
        vm.expectRevert(abi.encodeWithSelector(CommissionEscrow.CommissionDoesNotExist.selector, 999));
        escrow.refundAfterDeadline(999);
    }

    // =================================================================
    // Solvency across the whole lifecycle
    // =================================================================

    function test_ContractStaysSolventAcrossManyCommissions() public {
        uint256 a = _open();
        uint256 b = _open();
        uint256 c = _open();

        assertEq(escrow.totalEscrowed(), 3 * PRICE);
        assertTrue(escrow.isSolvent());

        // a: delivered and confirmed
        vm.prank(kalpana);
        escrow.markDelivered(a);
        vm.prank(collector);
        escrow.confirmDelivery(a);

        // b: disputed and split
        vm.prank(collector);
        escrow.raiseDispute(b);
        vm.prank(arbiter);
        escrow.resolveDispute(b, 2_500);

        // c: never delivered, refunded at the deadline
        vm.warp(uint256(deadline) + 1);
        escrow.refundAfterDeadline(c);

        assertEq(escrow.totalEscrowed(), 0);
        assertEq(address(escrow).balance, 0, "every wei left to a rightful owner");
        assertTrue(escrow.isSolvent());
    }

    function testFuzz_DisputeSplitConservesTheEscrow(uint96 sent, uint16 shareBps) public {
        sent = uint96(bound(sent, 1, 90 ether));
        uint256 share = bound(shareBps, 0, 10_000);

        vm.prank(collector);
        uint256 id = escrow.openCommission{value: sent}(kalpana, deadline, REVIEW, "ipfs://b");

        uint256 collectorBefore = collector.balance;

        vm.prank(collector);
        escrow.raiseDispute(id);
        vm.prank(arbiter);
        escrow.resolveDispute(id, share);

        uint256 paidOut = kalpana.balance + (collector.balance - collectorBefore);
        assertEq(paidOut, sent, "the escrow was distributed exactly, no more and no less");
        assertEq(escrow.lockedAmount(id), 0);
    }
}
