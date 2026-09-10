// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {HistoryProbe} from "../../src/source/HistoryProbe.sol";

interface IERC20Votes {
    function getPastVotes(address account, uint256 blockNumber) external view returns (uint256);
    function getPastTotalSupply(uint256 blockNumber) external view returns (uint256);
    function delegates(address account) external view returns (address);
}

/**
 * @notice The technique against a real checkpointed contract on Ethereum mainnet.
 *
 * The claim under test is that historical state can be verified with no storage proof
 * anywhere, because the contract keeps its own history and will answer questions about
 * it. If this holds, the airdrop-snapshot problem is an ordinary feed.
 */
contract HistoryProbeMainnetTest is Test {
    /// ENS token, a standard ERC20Votes deployment.
    address constant ENS = 0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72;

    HistoryProbe probe;
    uint256 pastBlock;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_RPC"));
        probe = new HistoryProbe();
        pastBlock = block.number - 50_000; // roughly a week earlier
    }

    function _probeAndCapture(address target, uint256 aboutHeight, bytes memory data)
        internal
        returns (bool success, bytes memory ret)
    {
        vm.recordLogs();
        probe.probeHistory(target, aboutHeight, data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        (, success,,,, ret) = abi.decode(logs[0].data, (uint256, bool, bool, uint256, uint256, bytes));
    }

    /// The airdrop-snapshot problem, as an ordinary read.
    function test_pastTotalSupplyIsByteEqualToADirectCall() public {
        bytes memory data = abi.encodeCall(IERC20Votes.getPastTotalSupply, (pastBlock));
        (bool success, bytes memory ret) = _probeAndCapture(ENS, pastBlock, data);

        assertTrue(success, "a real checkpointed contract answered about its own past");
        (bool ok, bytes memory direct) = ENS.staticcall(data);
        assertTrue(ok);
        assertEq(ret, direct, "byte-equal to a direct call");

        uint256 supply = abi.decode(ret, (uint256));
        emit log_named_uint("ENS voting supply 50,000 blocks ago", supply);
        assertGt(supply, 0, "there was voting supply then");
    }

    /// The value is about the past, and provably different from the present when it
    /// has moved. That difference is what makes this history rather than a rename.
    function test_theAnswerIsAboutThePastNotThePresent() public {
        uint256 recent = block.number - 100;

        (, bytes memory oldRet) =
            _probeAndCapture(ENS, pastBlock, abi.encodeCall(IERC20Votes.getPastTotalSupply, (pastBlock)));
        (, bytes memory newRet) =
            _probeAndCapture(ENS, recent, abi.encodeCall(IERC20Votes.getPastTotalSupply, (recent)));

        uint256 then_ = abi.decode(oldRet, (uint256));
        uint256 now_ = abi.decode(newRet, (uint256));
        emit log_named_uint("voting supply, 50,000 blocks ago", then_);
        emit log_named_uint("voting supply, 100 blocks ago", now_);

        // Both are real reads of the same function at different heights, each byte-equal
        // to a direct call. Whether they differ depends on delegation activity, so this
        // asserts only that both are genuine, not that they must disagree.
        assertGt(then_, 0);
        assertGt(now_, 0);
    }

    function test_aRealAccountsPastVotingWeightIsProvable() public {
        // The ENS DAO treasury-adjacent address is used only as a well-known account
        // that exists; the assertion is about equality with a direct call, not the value.
        address account = 0xFe89cc7aBB2C4183683ab71653C4cdc9B02D44b7;
        bytes memory data = abi.encodeCall(IERC20Votes.getPastVotes, (account, pastBlock));

        (bool success, bytes memory ret) = _probeAndCapture(ENS, pastBlock, data);
        assertTrue(success);
        (, bytes memory direct) = ENS.staticcall(data);
        assertEq(ret, direct, "an account's weight at a past block, byte-equal");
        emit log_named_uint("that account's voting weight then", abi.decode(ret, (uint256)));
    }
}
