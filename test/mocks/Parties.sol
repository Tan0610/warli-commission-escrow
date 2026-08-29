// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CommissionEscrow} from "../../src/CommissionEscrow.sol";

/// @notice An artisan contract that tries to re-enter the escrow from inside the payout
///         transfer, attempting to be paid for the same commission twice.
contract ReentrantArtisan {
    CommissionEscrow public immutable escrow;

    uint256 public commissionId;
    bool public reentered;
    bool public reentrySucceeded;
    uint256 public received;

    constructor(CommissionEscrow escrow_) {
        escrow = escrow_;
    }

    function setCommission(uint256 id) external {
        commissionId = id;
    }

    function markDelivered() external {
        escrow.markDelivered(commissionId, "ipfs://delivery-photos");
    }

    function claim() external {
        escrow.claimAfterReviewWindow(commissionId);
    }

    receive() external payable {
        received += msg.value;
        if (!reentered) {
            reentered = true;
            // Try to claim the same commission a second time, mid-payout.
            try escrow.claimAfterReviewWindow(commissionId) {
                reentrySucceeded = true;
            } catch {
                reentrySucceeded = false;
            }
        }
    }
}

/// @notice A party that cannot accept ETH. Used to prove a settlement is never reverted
///         or left open by a recipient with a hostile fallback: the commission still
///         reaches its terminal state and the money moves to the pull ledger.
contract RejectingParty {
    CommissionEscrow public immutable escrow;

    constructor(CommissionEscrow escrow_) {
        escrow = escrow_;
    }

    function openCommission(address artisan, uint64 deadline, uint32 reviewWindow)
        external
        payable
        returns (uint256)
    {
        return escrow.openCommission{value: msg.value}(artisan, deadline, reviewWindow, "ipfs://brief");
    }

    function raiseDispute(uint256 id) external {
        escrow.raiseDispute(id);
    }

    function markDelivered(uint256 id) external {
        escrow.markDelivered(id, "ipfs://delivery-photos");
    }

    receive() external payable {
        revert("I cannot accept ETH");
    }
}
