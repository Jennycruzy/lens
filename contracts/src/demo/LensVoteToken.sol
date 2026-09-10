// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/**
 * @title LensVoteToken
 * @notice A governance token on Sepolia, so the governance path can be shown working.
 *
 * @dev **Why this exists, stated plainly.** `VotePort` reads a holder's weight from a
 *      token's own checkpoints on the source chain. Ethereum mainnet has many such
 *      tokens; Sepolia has few, and the one that exists — the UNI deployment — is not
 *      held by anybody who could demonstrate with it.
 *
 *      So this is a real OpenZeppelin `ERC20Votes` deployment, not a mock. Its
 *      checkpoints are genuine, written by the same code every governance token uses,
 *      and anyone may hold, delegate and be read from it.
 *
 *      **What is and is not being claimed.** The token is ours; nothing else in the path
 *      is. The read happens on Sepolia, the log is attested by Creditcoin's validators,
 *      the proof is checked by the precompile, and the registry applies every one of its
 *      checks. Substituting a widely-held token changes one constructor argument and
 *      nothing else.
 *
 *      It is kept apart from `src/` proper, in a directory named for what it is, so
 *      nobody mistakes a demonstration token for part of the protocol.
 */
contract LensVoteToken is ERC20, ERC20Permit, ERC20Votes {
    /// @notice Anyone may take a fixed allocation once, so a stranger can try the flow.
    uint256 public constant FAUCET_AMOUNT = 1000e18;
    mapping(address => bool) public claimed;

    error AlreadyClaimed(address who);

    constructor(address initialHolder, uint256 initialSupply) ERC20("Lens Vote", "LVOTE") ERC20Permit("Lens Vote") {
        _mint(initialHolder, initialSupply);
    }

    /**
     * @notice Take an allocation and start accruing voting weight immediately.
     * @dev Self-delegates on the caller's behalf. Without a delegation an ERC20Votes
     *      balance produces no checkpoints at all, so weight would read as zero however
     *      many tokens were held — the single most common way this flow is got wrong.
     */
    function claim() external {
        if (claimed[msg.sender]) revert AlreadyClaimed(msg.sender);
        claimed[msg.sender] = true;
        _mint(msg.sender, FAUCET_AMOUNT);
        if (delegates(msg.sender) == address(0)) _delegate(msg.sender, msg.sender);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
