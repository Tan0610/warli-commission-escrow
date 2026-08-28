// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CommissionEscrow} from "../src/CommissionEscrow.sol";

/// @notice Deploys the commission escrow.
///
/// @dev No key material lives in this file. The broadcasting account is supplied by the
///      forge invocation (`--account <keystore>` is preferred over `--private-key`), and
///      the RPC endpoint comes from the environment. See .env.example.
///
///      Usage:
///        forge script script/Deploy.s.sol:Deploy \
///          --rpc-url base_sepolia --account devcon --broadcast --verify
contract Deploy is Script {
    function run() external returns (CommissionEscrow escrow) {
        address admin = vm.envOr("ESCROW_ADMIN", msg.sender);

        // The neutral third party for disputes. Should be a multisig or DAO in anything
        // resembling production; it must never be a collector or an artisan, and the
        // contract enforces that at resolution time regardless.
        address arbiter = vm.envOr("ESCROW_ARBITER", msg.sender);

        vm.startBroadcast();
        escrow = new CommissionEscrow(admin, arbiter);
        vm.stopBroadcast();

        console.log("CommissionEscrow:", address(escrow));
        console.log("Admin:           ", admin);
        console.log("Arbiter:         ", arbiter);
    }
}
