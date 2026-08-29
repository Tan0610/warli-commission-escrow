// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CommissionEscrow
/// @notice Escrow for a commissioned artwork, written for the case where neither side
///         can afford to trust a middleman: a collector in Berlin who does not want to
///         wire money for a painting that does not exist yet, and Kalpana in a village
///         three hours from Nashik who has twice watched an agent keep the advance.
///
///         The money itself holds the promise. It is locked in this contract the moment
///         the commission is opened, it can only reach the artisan after delivery has
///         been confirmed on-chain, and if the deadline passes with nothing delivered it
///         goes back to the collector. No agent ever holds it.
///
/// @dev The lifecycle, and the guarantee each step provides:
///
///        openCommission()  --[collector locks msg.value]-->  Funded
///        Funded            --[artisan: markDelivered]------>  Delivered
///        Delivered         --[collector: confirmDelivery]-->  Released   (artisan paid)
///        Delivered         --[artisan: claim after review]->  Released   (silent collector)
///        Funded            --[anyone, after deadline]------->  Refunded  (collector repaid)
///        Funded/Delivered  --[either party: raiseDispute]-->  Disputed
///        Disputed          --[neutral arbiter only]--------->  Released or Refunded
///
///      Released and Refunded are terminal. Every state-changing entry point loads the
///      commission through `_open`, which reverts on an already-settled commission, so a
///      commission that has paid out cannot pay out again.
///
///      Value only ever leaves this contract from `_payOut`, which is called *after* the
///      commission has already been written to a terminal state and its stored amount
///      zeroed. A malicious receiver that re-enters therefore finds a settled commission
///      and nothing left to claim; `nonReentrant` on every external entry point is a
///      second, independent barrier.
contract CommissionEscrow is AccessControl, ReentrancyGuard {
    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice The neutral third party who can settle a disputed commission. Deliberately
    ///         a role rather than a fixed address, so it can be a multisig or a DAO.
    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE");

    /// @notice Denominator for a split dispute outcome. 10000 bps == 100%.
    uint256 public constant TOTAL_BPS = 10_000;

    /// @notice Bounds on how long the collector has to inspect delivered work before the
    ///         artisan may claim payment anyway.
    uint32 public constant MIN_REVIEW_WINDOW = 1 days;
    uint32 public constant MAX_REVIEW_WINDOW = 30 days;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum Status {
        None, // never opened
        Funded, // money locked, work in progress
        Delivered, // artisan says the work is delivered, awaiting the collector
        Disputed, // someone disagrees; only a neutral arbiter can settle it
        Released, // TERMINAL: the artisan was paid
        Refunded // TERMINAL: the collector got their money back
    }

    /// @param collector   Who paid, and who is refunded if the deal falls through.
    /// @param artisan     Who is paid on confirmed delivery.
    /// @param amount      Locked value. Set from msg.value at creation; zeroed on payout.
    /// @param deadline    After this, an undelivered commission can be refunded.
    /// @param deliveredAt When the artisan marked delivery; starts the review window.
    /// @param reviewWindow How long the collector has to confirm or dispute before the
    ///                    artisan can claim, so a silent collector cannot strand payment.
    /// @param status      Where in the lifecycle this commission is.
    /// @param briefURI    Pointer to the brief (IPFS or https). Reference only.
    struct Commission {
        address collector;
        address artisan;
        uint256 amount;
        uint64 deadline;
        uint64 deliveredAt;
        uint32 reviewWindow;
        Status status;
        string briefURI;
        /// @dev What the artisan actually submitted as proof of delivery: photographs of
        ///      the finished cloth, a courier consignment number, a handover receipt.
        ///      Pinned off-chain, referenced here. Required, immutable once written, and
        ///      timestamped by `deliveredAt` — so "delivered" is a claim on the record
        ///      that the collector and an arbiter can inspect and contest, not a bare
        ///      boolean the artisan can flip with nothing behind it.
        string deliveryEvidenceURI;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    mapping(uint256 commissionId => Commission commission) private _commissions;

    /// @notice Next id to be issued. Ids start at 1, so 0 always means "does not exist".
    uint256 public nextCommissionId = 1;

    /// @notice Fallback ledger. If a payout transfer fails (a party using a contract
    ///         wallet that reverts on receive), the commission still settles and the
    ///         money is credited here for them to pull, rather than the settlement
    ///         reverting and the funds sitting locked forever.
    mapping(address account => uint256 amount) public pendingWithdrawals;

    /// @notice Total value currently locked across all open commissions.
    uint256 public totalEscrowed;

    /// @notice Total value sitting in the deferred-payout ledger. Tracked separately from
    ///         `totalEscrowed` because a deferred payout has already left escrow: the
    ///         commission it came from is settled, the money is simply awaiting a pull.
    uint256 public totalPending;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event CommissionOpened(
        uint256 indexed commissionId,
        address indexed collector,
        address indexed artisan,
        uint256 amount,
        uint64 deadline,
        uint32 reviewWindow,
        string briefURI
    );
    event DeliveryMarked(
        uint256 indexed commissionId, address indexed artisan, uint64 deliveredAt, string evidenceURI
    );
    event DeliveryConfirmed(uint256 indexed commissionId, address indexed collector);
    event CommissionReleased(uint256 indexed commissionId, address indexed artisan, uint256 amount);
    event CommissionRefunded(uint256 indexed commissionId, address indexed collector, uint256 amount);
    event DisputeRaised(uint256 indexed commissionId, address indexed raisedBy, Status previousStatus);
    event DisputeResolved(
        uint256 indexed commissionId,
        address indexed arbiter,
        uint256 artisanShareBps,
        uint256 toArtisan,
        uint256 toCollector
    );
    event PayoutDeferred(address indexed account, uint256 amount);
    event PendingWithdrawn(address indexed account, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error NoValueLocked();
    error ArtisanCannotBeCollector();
    error DeadlineNotInFuture(uint64 deadline, uint256 nowTs);
    error ReviewWindowOutOfRange(uint32 provided, uint32 min, uint32 max);
    error CommissionDoesNotExist(uint256 commissionId);
    error CommissionAlreadySettled(uint256 commissionId, Status status);
    error WrongStatus(uint256 commissionId, Status actual, Status required);
    error DeliveryEvidenceRequired(uint256 commissionId);
    error NotTheArtisan(address caller);
    error NotTheCollector(address caller);
    error NotAParty(address caller);
    error DeadlineNotReached(uint64 deadline, uint256 nowTs);
    error ReviewWindowNotElapsed(uint256 claimableAt, uint256 nowTs);
    error ArbiterMustBeNeutral(address arbiter);
    error InvalidShare(uint256 bps, uint256 total);
    error NothingPending(address account);
    error TransferFailed(address to, uint256 amount);

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    /// @param admin   Manages the arbiter role.
    /// @param arbiter The initial neutral third party for dispute resolution.
    constructor(address admin, address arbiter) {
        if (admin == address(0) || arbiter == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ARBITER_ROLE, arbiter);
    }

    // ---------------------------------------------------------------------
    // 1. Opening a commission: the money is locked here, at this moment
    // ---------------------------------------------------------------------

    /// @notice Open a commission for a specific artisan, locking the payment now.
    /// @dev The escrowed amount is taken from `msg.value`. There is deliberately no
    ///      amount argument: the recorded figure is exactly what was transferred in, so
    ///      a commission can never claim to hold value it does not hold.
    /// @param artisan      The artisan who will be paid on confirmed delivery.
    /// @param deadline     Unix time by which the work must be delivered.
    /// @param reviewWindow Seconds the collector gets to confirm delivery before the
    ///                     artisan may claim payment themselves.
    /// @param briefURI     Pointer to the commission brief.
    function openCommission(address artisan, uint64 deadline, uint32 reviewWindow, string calldata briefURI)
        external
        payable
        returns (uint256 commissionId)
    {
        // Check 1: nothing is created unless value actually moved into custody.
        if (msg.value == 0) revert NoValueLocked();
        if (artisan == address(0)) revert ZeroAddress();
        if (artisan == msg.sender) revert ArtisanCannotBeCollector();
        if (deadline <= block.timestamp) revert DeadlineNotInFuture(deadline, block.timestamp);
        if (reviewWindow < MIN_REVIEW_WINDOW || reviewWindow > MAX_REVIEW_WINDOW) {
            revert ReviewWindowOutOfRange(reviewWindow, MIN_REVIEW_WINDOW, MAX_REVIEW_WINDOW);
        }

        commissionId = nextCommissionId++;

        _commissions[commissionId] = Commission({
            collector: msg.sender,
            artisan: artisan,
            // The stored amount IS the value received. Not a caller-supplied number.
            amount: msg.value,
            deadline: deadline,
            deliveredAt: 0,
            reviewWindow: reviewWindow,
            status: Status.Funded,
            briefURI: briefURI,
            deliveryEvidenceURI: "" // written by the artisan at markDelivered
        });

        totalEscrowed += msg.value;

        emit CommissionOpened(commissionId, msg.sender, artisan, msg.value, deadline, reviewWindow, briefURI);
    }

    // ---------------------------------------------------------------------
    // 2. Delivery, and the confirmation that gates every payout
    // ---------------------------------------------------------------------

    /// @notice The artisan marks the work delivered, submitting evidence of it. This does
    ///         NOT move money: it sets the delivery-confirmation state that every release
    ///         path requires.
    /// @dev Evidence is mandatory, and this is the point of the function rather than an
    ///      extra. A delivery flag the artisan can flip with nothing attached would leave
    ///      the collector exactly where they started — wiring money abroad on trust, with
    ///      a nicer interface. Requiring a non-empty `evidenceURI` means the claim is on
    ///      the record before the review window starts running: the collector has
    ///      something specific to inspect and dispute, and if it does go to dispute the
    ///      arbiter has the artisan's own submission, timestamped, to judge against.
    ///
    ///      This contract cannot verify that the evidence is truthful — no contract can.
    ///      What it can do is make the claim costly to make falsely: it is permanent,
    ///      attributable, and the thing an arbiter will be shown.
    /// @param evidenceURI Pointer to proof of delivery (IPFS CID, courier tracking record,
    ///                    signed handover receipt).
    function markDelivered(uint256 commissionId, string calldata evidenceURI) external {
        Commission storage c = _open(commissionId);
        if (msg.sender != c.artisan) revert NotTheArtisan(msg.sender);
        if (c.status != Status.Funded) revert WrongStatus(commissionId, c.status, Status.Funded);
        if (bytes(evidenceURI).length == 0) revert DeliveryEvidenceRequired(commissionId);

        c.status = Status.Delivered;
        c.deliveredAt = uint64(block.timestamp);
        c.deliveryEvidenceURI = evidenceURI;

        emit DeliveryMarked(commissionId, msg.sender, uint64(block.timestamp), evidenceURI);
    }

    /// @notice The collector confirms the work arrived, releasing payment to the artisan.
    /// @dev Reachable only from `Delivered`. The collector cannot pay out from `Funded`,
    ///      and there is no function anywhere that releases funds without the delivery
    ///      state having been set first.
    function confirmDelivery(uint256 commissionId) external nonReentrant {
        Commission storage c = _open(commissionId);
        if (msg.sender != c.collector) revert NotTheCollector(msg.sender);
        if (c.status != Status.Delivered) revert WrongStatus(commissionId, c.status, Status.Delivered);

        emit DeliveryConfirmed(commissionId, msg.sender);
        _release(commissionId, c);
    }

    /// @notice After the review window, the artisan may claim payment for work they
    ///         marked delivered and the collector never confirmed or disputed.
    /// @dev Still gated on the delivery state: unreachable unless `markDelivered` ran.
    ///      This is what stops a silent collector from stranding a finished painting.
    function claimAfterReviewWindow(uint256 commissionId) external nonReentrant {
        Commission storage c = _open(commissionId);
        if (msg.sender != c.artisan) revert NotTheArtisan(msg.sender);
        if (c.status != Status.Delivered) revert WrongStatus(commissionId, c.status, Status.Delivered);

        uint256 claimUnlockAt = uint256(c.deliveredAt) + c.reviewWindow;
        if (block.timestamp < claimUnlockAt) revert ReviewWindowNotElapsed(claimUnlockAt, block.timestamp);

        _release(commissionId, c);
    }

    // ---------------------------------------------------------------------
    // 3. The timeout path: money never gets stuck
    // ---------------------------------------------------------------------

    /// @notice After the deadline passes with nothing delivered, return the locked funds
    ///         to the collector.
    /// @dev Callable by anyone, because the funds can only ever go to the collector. That
    ///      keeps the refund reachable even if the collector cannot send the transaction
    ///      themselves. Only reachable from `Funded`: once the artisan has marked
    ///      delivery, the collector must confirm, dispute, or let the review window run,
    ///      rather than waiting out the clock on finished work.
    function refundAfterDeadline(uint256 commissionId) external nonReentrant {
        Commission storage c = _open(commissionId);
        if (c.status != Status.Funded) revert WrongStatus(commissionId, c.status, Status.Funded);
        if (block.timestamp <= c.deadline) revert DeadlineNotReached(c.deadline, block.timestamp);

        _refund(commissionId, c);
    }

    // ---------------------------------------------------------------------
    // 4. Disputes: never settled by either party alone
    // ---------------------------------------------------------------------

    /// @notice Either party can flag a disagreement about whether delivery happened.
    ///         Raising a dispute moves no money; it hands the decision to the arbiter.
    function raiseDispute(uint256 commissionId) external {
        Commission storage c = _open(commissionId);
        if (msg.sender != c.collector && msg.sender != c.artisan) revert NotAParty(msg.sender);
        if (c.status != Status.Funded && c.status != Status.Delivered) {
            revert WrongStatus(commissionId, c.status, Status.Delivered);
        }

        Status previous = c.status;
        c.status = Status.Disputed;

        emit DisputeRaised(commissionId, msg.sender, previous);
    }

    /// @notice A neutral arbiter settles a disputed commission, splitting the locked
    ///         value between artisan and collector.
    /// @dev Two independent guards make it impossible for a party to settle their own
    ///      dispute: `ARBITER_ROLE`, and an explicit neutrality check that rejects the
    ///      caller if they are the collector or the artisan on this commission — even if
    ///      they somehow hold the role.
    /// @param artisanShareBps Share of the escrow to the artisan, in basis points.
    ///                        0 refunds the collector in full; TOTAL_BPS pays the artisan
    ///                        in full; anything between splits it.
    function resolveDispute(uint256 commissionId, uint256 artisanShareBps)
        external
        nonReentrant
        onlyRole(ARBITER_ROLE)
    {
        Commission storage c = _open(commissionId);
        if (c.status != Status.Disputed) revert WrongStatus(commissionId, c.status, Status.Disputed);
        if (msg.sender == c.collector || msg.sender == c.artisan) revert ArbiterMustBeNeutral(msg.sender);
        if (artisanShareBps > TOTAL_BPS) revert InvalidShare(artisanShareBps, TOTAL_BPS);

        uint256 amount = c.amount;
        uint256 toArtisan = (amount * artisanShareBps) / TOTAL_BPS;
        uint256 toCollector = amount - toArtisan;

        address artisan = c.artisan;
        address collector = c.collector;

        // --- effects: terminal state written and the balance zeroed, before any call ---
        c.status = toArtisan == 0 ? Status.Refunded : Status.Released;
        c.amount = 0;
        totalEscrowed -= amount;

        emit DisputeResolved(commissionId, msg.sender, artisanShareBps, toArtisan, toCollector);
        if (toArtisan == 0) {
            emit CommissionRefunded(commissionId, collector, toCollector);
        } else {
            emit CommissionReleased(commissionId, artisan, toArtisan);
        }

        // --- interactions ---
        if (toArtisan != 0) _payOut(artisan, toArtisan);
        if (toCollector != 0) _payOut(collector, toCollector);
    }

    // ---------------------------------------------------------------------
    // Deferred payouts
    // ---------------------------------------------------------------------

    /// @notice Pull a payout that could not be delivered by direct transfer.
    function withdrawPending() external nonReentrant returns (uint256 amount) {
        amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingPending(msg.sender);

        // Effects before the interaction: a re-entrant caller reads zero.
        pendingWithdrawals[msg.sender] = 0;
        totalPending -= amount;
        emit PendingWithdrawn(msg.sender, amount);

        // forge-lint: disable-next-line(reentrancy-eth, low-level-calls)
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getCommission(uint256 commissionId) external view returns (Commission memory) {
        return _commissions[commissionId];
    }

    function statusOf(uint256 commissionId) external view returns (Status) {
        return _commissions[commissionId].status;
    }

    /// @notice What the artisan submitted as proof of delivery, and when. Empty until
    ///         `markDelivered` runs. This is what the collector inspects before
    ///         confirming, and what an arbiter is shown in a dispute.
    function deliveryEvidence(uint256 commissionId)
        external
        view
        returns (string memory evidenceURI, uint64 submittedAt)
    {
        Commission storage c = _commissions[commissionId];
        return (c.deliveryEvidenceURI, c.deliveredAt);
    }

    /// @notice True once the commission has paid out or refunded and can never move
    ///         value again.
    function isSettled(uint256 commissionId) public view returns (bool) {
        Status s = _commissions[commissionId].status;
        return s == Status.Released || s == Status.Refunded;
    }

    /// @notice The value still provably locked in escrow for this commission.
    function lockedAmount(uint256 commissionId) external view returns (uint256) {
        return _commissions[commissionId].amount;
    }

    /// @notice Whether `refundAfterDeadline` would succeed right now.
    function isRefundable(uint256 commissionId) external view returns (bool) {
        Commission storage c = _commissions[commissionId];
        return c.status == Status.Funded && block.timestamp > c.deadline;
    }

    /// @notice When the artisan may claim delivered work the collector has ignored.
    function claimableAt(uint256 commissionId) external view returns (uint256) {
        Commission storage c = _commissions[commissionId];
        if (c.status != Status.Delivered) return 0;
        return uint256(c.deliveredAt) + c.reviewWindow;
    }

    /// @notice Every wei held is either locked against an open commission or waiting in
    ///         the deferred-payout ledger. Nothing is unaccounted for.
    function isSolvent() external view returns (bool) {
        return address(this).balance >= totalEscrowed + totalPending;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Loads a commission that exists and has not already settled. Every
    ///      state-changing entry point goes through here, which is what makes a second
    ///      release or refund on the same commission impossible.
    function _open(uint256 commissionId) private view returns (Commission storage c) {
        c = _commissions[commissionId];
        if (c.status == Status.None) revert CommissionDoesNotExist(commissionId);
        if (c.status == Status.Released || c.status == Status.Refunded) {
            revert CommissionAlreadySettled(commissionId, c.status);
        }
    }

    /// @dev Pay the artisan. State is written to terminal and the balance zeroed here,
    ///      before `_payOut` makes any external call.
    function _release(uint256 commissionId, Commission storage c) private {
        uint256 amount = c.amount;
        address artisan = c.artisan;

        // --- effects ---
        c.status = Status.Released;
        c.amount = 0;
        totalEscrowed -= amount;

        emit CommissionReleased(commissionId, artisan, amount);

        // --- interaction, strictly after the state is settled ---
        _payOut(artisan, amount);
    }

    /// @dev Return the escrow to the collector, same ordering.
    function _refund(uint256 commissionId, Commission storage c) private {
        uint256 amount = c.amount;
        address collector = c.collector;

        // --- effects ---
        c.status = Status.Refunded;
        c.amount = 0;
        totalEscrowed -= amount;

        emit CommissionRefunded(commissionId, collector, amount);

        // --- interaction, strictly after the state is settled ---
        _payOut(collector, amount);
    }

    /// @dev Send value out. If the recipient rejects it, the commission stays settled and
    ///      the money is credited to a pull ledger instead of reverting the settlement.
    ///      A recipient can never use a reverting fallback to keep a commission open.
    function _payOut(address to, uint256 amount) private {
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) {
            pendingWithdrawals[to] += amount;
            totalPending += amount;
            emit PayoutDeferred(to, amount);
        }
    }
}
