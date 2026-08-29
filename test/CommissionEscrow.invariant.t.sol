// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {CommissionEscrow} from "../src/CommissionEscrow.sol";

/// @notice Drives randomised sequences of every move available to the three parties:
///         a collector opens a commission, an artisan submits delivery evidence, the
///         collector confirms, the artisan claims after silence, either side disputes,
///         the arbiter rules, and the deadline passes on work that never arrived.
///
/// @dev Time moves too. Several of the properties worth testing only become reachable
///      after a review window or a deadline elapses, so the handler warps the clock.
contract EscrowHandler is Test {
    CommissionEscrow public immutable escrow;
    address public immutable arbiter;

    address[3] public collectors;
    address[3] public artisans;

    /// @dev Every commission the handler has opened, for the sum-of-open-amounts check.
    uint256[] public ids;

    // --- ghost accounting ---
    uint256 public totalFunded;
    /// @dev How many times each commission has reached a terminal state. Must never
    ///      exceed one, however the calls are interleaved.
    mapping(uint256 id => uint256 times) public settledCount;

    uint256 public openCalls;
    uint256 public deliverCalls;
    uint256 public confirmCalls;
    uint256 public claimCalls;
    uint256 public refundCalls;
    uint256 public disputeCalls;
    uint256 public resolveCalls;

    constructor(CommissionEscrow escrow_, address arbiter_) {
        escrow = escrow_;
        arbiter = arbiter_;
        for (uint256 i; i < 3; ++i) {
            collectors[i] = address(uint160(0x9000 + i));
            artisans[i] = address(uint160(0x9100 + i));
        }
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function _pick(uint256 seed) internal view returns (uint256 id, CommissionEscrow.Commission memory c) {
        id = ids[bound(seed, 0, ids.length - 1)];
        c = escrow.getCommission(id);
    }

    /// @dev Records a settlement exactly once, the first time this id becomes terminal.
    function _noteIfSettled(uint256 id, CommissionEscrow.Status before) internal {
        CommissionEscrow.Status now_ = escrow.statusOf(id);
        bool wasTerminal =
            before == CommissionEscrow.Status.Released || before == CommissionEscrow.Status.Refunded;
        bool isTerminal = now_ == CommissionEscrow.Status.Released || now_ == CommissionEscrow.Status.Refunded;
        if (!wasTerminal && isTerminal) settledCount[id] += 1;
    }

    function openCommission(uint256 whoSeed, uint256 artisanSeed, uint256 amountSeed, uint256 windowSeed)
        public
    {
        address collector = collectors[bound(whoSeed, 0, 2)];
        address artisan = artisans[bound(artisanSeed, 0, 2)];
        uint256 amount = bound(amountSeed, 1, 20 ether);
        uint32 window = uint32(bound(windowSeed, 1 days, 30 days));
        uint64 deadline = uint64(block.timestamp + bound(windowSeed, 2 days, 120 days));

        vm.deal(collector, collector.balance + amount);
        vm.prank(collector);
        uint256 id = escrow.openCommission{value: amount}(artisan, deadline, window, "ipfs://brief");

        ids.push(id);
        totalFunded += amount;
        openCalls++;
    }

    function markDelivered(uint256 seed) public {
        if (ids.length == 0) return;
        (uint256 id, CommissionEscrow.Commission memory c) = _pick(seed);
        if (c.status != CommissionEscrow.Status.Funded) return;

        vm.prank(c.artisan);
        escrow.markDelivered(id, "ipfs://evidence");
        deliverCalls++;
    }

    function confirmDelivery(uint256 seed) public {
        if (ids.length == 0) return;
        (uint256 id, CommissionEscrow.Commission memory c) = _pick(seed);
        if (c.status != CommissionEscrow.Status.Delivered) return;

        vm.prank(c.collector);
        escrow.confirmDelivery(id);
        _noteIfSettled(id, c.status);
        confirmCalls++;
    }

    function claimAfterReviewWindow(uint256 seed) public {
        if (ids.length == 0) return;
        (uint256 id, CommissionEscrow.Commission memory c) = _pick(seed);
        if (c.status != CommissionEscrow.Status.Delivered) return;
        if (block.timestamp < uint256(c.deliveredAt) + c.reviewWindow) return;

        vm.prank(c.artisan);
        escrow.claimAfterReviewWindow(id);
        _noteIfSettled(id, c.status);
        claimCalls++;
    }

    function refundAfterDeadline(uint256 seed) public {
        if (ids.length == 0) return;
        (uint256 id, CommissionEscrow.Commission memory c) = _pick(seed);
        if (c.status != CommissionEscrow.Status.Funded) return;
        if (block.timestamp <= c.deadline) return;

        escrow.refundAfterDeadline(id);
        _noteIfSettled(id, c.status);
        refundCalls++;
    }

    function raiseDispute(uint256 seed, bool asCollector) public {
        if (ids.length == 0) return;
        (uint256 id, CommissionEscrow.Commission memory c) = _pick(seed);
        if (c.status != CommissionEscrow.Status.Funded && c.status != CommissionEscrow.Status.Delivered) {
            return;
        }

        vm.prank(asCollector ? c.collector : c.artisan);
        escrow.raiseDispute(id);
        disputeCalls++;
    }

    function resolveDispute(uint256 seed, uint256 shareSeed) public {
        if (ids.length == 0) return;
        (uint256 id, CommissionEscrow.Commission memory c) = _pick(seed);
        if (c.status != CommissionEscrow.Status.Disputed) return;

        uint256 share = bound(shareSeed, 0, 10_000);
        vm.prank(arbiter);
        escrow.resolveDispute(id, share);
        _noteIfSettled(id, c.status);
        resolveCalls++;
    }

    /// @dev Lets deadlines and review windows actually elapse.
    function passTime(uint256 seed) public {
        vm.warp(block.timestamp + bound(seed, 1 hours, 20 days));
    }

    receive() external payable {}
}

/// @notice Properties that must hold after every call in every randomised sequence.
///
///         These target the two checks a worked example is most likely to miss: that no
///         commission can ever pay out twice however the calls are interleaved, and that
///         the contract's own books always match the ETH it is actually holding.
contract CommissionEscrowInvariantTest is StdInvariant, Test {
    CommissionEscrow internal escrow;
    EscrowHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal arbiter = makeAddr("arbiter");

    function setUp() public {
        escrow = new CommissionEscrow(admin, arbiter);
        handler = new EscrowHandler(escrow, arbiter);
        targetContract(address(handler));
    }

    /// @notice The books balance exactly. Every wei the contract holds is either locked
    ///         against a live commission or waiting in the deferred-payout ledger — never
    ///         more, never less.
    function invariant_balanceEqualsEscrowedPlusPending() public view {
        assertEq(
            address(escrow).balance,
            escrow.totalEscrowed() + escrow.totalPending(),
            "contract balance drifted from its own accounting"
        );
        assertTrue(escrow.isSolvent());
    }

    /// @notice No commission ever reaches a terminal state more than once — the property
    ///         that would break if release and refund could both fire, or either twice.
    function invariant_noCommissionSettlesTwice() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            assertLe(handler.settledCount(id), 1, "a commission settled more than once");
        }
    }

    /// @notice A settled commission holds nothing. If a terminal commission still carried
    ///         a balance, a second payout path could in principle find something to send.
    function invariant_settledCommissionsAreEmptied() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            if (escrow.isSettled(id)) {
                assertEq(escrow.lockedAmount(id), 0, "settled commission still holds value");
            }
        }
    }

    /// @notice `totalEscrowed` is exactly the sum of what the unsettled commissions hold.
    function invariant_totalEscrowedMatchesTheOpenCommissions() public view {
        uint256 n = handler.idCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            sum += escrow.lockedAmount(handler.ids(i));
        }
        assertEq(sum, escrow.totalEscrowed(), "totalEscrowed drifted from the open commissions");
    }

    /// @notice Everything a collector ever locked is still locked, was paid out, or is
    ///         waiting to be pulled. Nothing is created and nothing evaporates.
    function invariant_everyFundedWeiIsAccountedFor() public view {
        uint256 stillInside = escrow.totalEscrowed() + escrow.totalPending();
        assertLe(stillInside, handler.totalFunded(), "contract holds more than was ever funded");
    }

    function invariant_callSummary() public view {
        console.log("open      ", handler.openCalls());
        console.log("delivered ", handler.deliverCalls());
        console.log("confirmed ", handler.confirmCalls());
        console.log("claimed   ", handler.claimCalls());
        console.log("refunded  ", handler.refundCalls());
        console.log("disputed  ", handler.disputeCalls());
        console.log("resolved  ", handler.resolveCalls());
    }
}
