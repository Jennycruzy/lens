// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {StateProbe} from "../contracts/src/source/StateProbe.sol";

/**
 * @notice Deploys the probe to a source chain at a deterministic address.
 *
 * @dev The salt fixes the address across every chain that carries the standard
 *      deterministic deployer, so the probe has one address on Sepolia and the same one
 *      on Ethereum mainnet. That matters for more than tidiness: the registry binds each
 *      chain key to the emitter whose logs it will accept, and a single address means
 *      that binding can be set before the second chain is funded.
 *
 *      Re-running this is a no-op. The address is derived, checked for code, and only
 *      deployed if empty, so the script can be run repeatedly without producing a second
 *      probe or a failed transaction.
 */
contract DeployProbe is Script {
    bytes32 public constant SALT = keccak256("lens.state-probe.v2");

    function run() external returns (StateProbe probe) {
        address predicted = vm.computeCreate2Address(SALT, keccak256(type(StateProbe).creationCode));

        if (predicted.code.length > 0) {
            console.log("probe already deployed, nothing to do");
            console.log("  address", predicted);
            return StateProbe(predicted);
        }

        vm.startBroadcast(vm.envUint("PROBER_PRIVATE_KEY"));
        probe = new StateProbe{salt: SALT}();
        vm.stopBroadcast();

        require(address(probe) == predicted, "deployed somewhere other than predicted");
        console.log("probe deployed");
        console.log("  address", address(probe));
        console.log("  chainid", block.chainid);
    }
}
