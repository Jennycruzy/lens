// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {HistoryProbe} from "../../src/source/HistoryProbe.sol";

/// @dev A checkpointed accumulator, the class the technique covers.
contract Checkpointed {
    mapping(uint256 => uint256) public valueAt;

    function set(uint256 height, uint256 v) external {
        valueAt[height] = v;
    }

    function getPastVotes(address, uint256 height) external view returns (uint256) {
        return valueAt[height];
    }
}

contract HistoryProbeTest is Test {
    HistoryProbe probe;
    Checkpointed target;

    function setUp() public {
        probe = new HistoryProbe();
        target = new Checkpointed();
        vm.roll(1000);
    }

    function _capture() internal returns (uint256 aboutHeight, bool success, bytes memory ret) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        (aboutHeight, success,,,, ret) = abi.decode(logs[0].data, (uint256, bool, bool, uint256, uint256, bytes));
    }

    function test_answersAboutThePastAndCarriesTheHeightItIsAbout() public {
        target.set(900, 12345);
        vm.recordLogs();
        probe.probeHistory(address(target), 900, abi.encodeCall(Checkpointed.getPastVotes, (address(0xBEEF), 900)));

        (uint256 aboutHeight, bool success, bytes memory ret) = _capture();
        assertEq(aboutHeight, 900, "the height the answer is about travels with it");
        assertTrue(success);
        assertEq(abi.decode(ret, (uint256)), 12345);
    }

    /// A height that is not yet in the past is not history, whatever the target says.
    function test_refusesAHeightThatIsNotYetHistory() public {
        vm.expectRevert(abi.encodeWithSelector(HistoryProbe.NotYetHistory.selector, 1000, 1000));
        probe.probeHistory(address(target), 1000, abi.encodeCall(Checkpointed.getPastVotes, (address(0xBEEF), 1000)));

        vm.expectRevert(abi.encodeWithSelector(HistoryProbe.NotYetHistory.selector, 1500, 1000));
        probe.probeHistory(address(target), 1500, abi.encodeCall(Checkpointed.getPastVotes, (address(0xBEEF), 1500)));
    }

    function test_theHeightItIsAboutIsSeparateFromTheHeightItRanAt() public {
        target.set(900, 7);
        vm.recordLogs();
        probe.probeHistory(address(target), 900, abi.encodeCall(Checkpointed.getPastVotes, (address(0xBEEF), 900)));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 aboutHeight,,, uint256 ranAt,,) =
            abi.decode(logs[0].data, (uint256, bool, bool, uint256, uint256, bytes));
        assertEq(aboutHeight, 900, "what it is about");
        assertEq(ranAt, 1000, "when it was asked");
        assertLt(aboutHeight, ranAt, "and the first is always before the second");
    }

    function test_batchesManyHeights() public {
        target.set(700, 1);
        target.set(800, 2);
        target.set(900, 3);

        address[] memory targets = new address[](3);
        uint256[] memory heights = new uint256[](3);
        bytes[] memory datas = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            targets[i] = address(target);
            heights[i] = 700 + i * 100;
            datas[i] = abi.encodeCall(Checkpointed.getPastVotes, (address(0xBEEF), 700 + i * 100));
        }

        vm.recordLogs();
        probe.probeHistoryMany(targets, heights, datas);
        assertEq(vm.getRecordedLogs().length, 3);
    }

    function test_batchRejectsMismatchedLengths() public {
        vm.expectRevert(HistoryProbe.LengthMismatch.selector);
        probe.probeHistoryMany(new address[](2), new uint256[](2), new bytes[](1));
    }

    function test_cannotMutateSourceState() public {
        uint256 before = target.valueAt(900);
        probe.probeHistory(address(target), 900, abi.encodeCall(Checkpointed.set, (900, 999)));
        assertEq(target.valueAt(900), before, "static only, as with any probe");
    }
}
