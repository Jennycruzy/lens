// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {StateProbe} from "../../src/source/StateProbe.sol";

interface IUniswapV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface ILido {
    function getPooledEthByShares(uint256) external view returns (uint256);
}

/**
 * @notice Proves the probe against real Ethereum mainnet state.
 *
 * The claim under test is byte-equality: what the probe emits must be exactly what a
 * direct call to the same target at the same height returns. If that ever diverges,
 * every number Lens publishes is worthless, so it is asserted rather than eyeballed.
 */
contract StateProbeMainnetTest is Test {
    address constant USDC_WETH_005 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    StateProbe probe;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_RPC"));
        probe = new StateProbe();
    }

    function _probeAndCapture(address target, bytes memory data)
        internal
        returns (bool success, bool truncated, bytes memory ret)
    {
        vm.recordLogs();
        probe.probe(target, data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one log per read");
        (success, truncated,,, ret) = abi.decode(logs[0].data, (bool, bool, uint256, uint256, bytes));
    }

    /// A time-averaged price is the feed class Lens is built for: the lag is part of
    /// what the number means, so attestation latency costs nothing.
    function test_uniswapTwapIsByteEqualToADirectCall() public {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 1800;
        secondsAgos[1] = 0;
        bytes memory data = abi.encodeCall(IUniswapV3Pool.observe, (secondsAgos));

        (bool success, bool truncated, bytes memory ret) = _probeAndCapture(USDC_WETH_005, data);

        assertTrue(success, "the real pool answered");
        assertFalse(truncated, "a two-point observation fits well inside the cap");

        (bool ok, bytes memory direct) = USDC_WETH_005.staticcall(data);
        assertTrue(ok);
        assertEq(ret, direct, "probe output must be byte-equal to the direct read");

        (int56[] memory cumulatives,) = abi.decode(ret, (int56[], uint160[]));
        int24 avgTick = int24((cumulatives[1] - cumulatives[0]) / int56(uint56(1800)));
        emit log_named_int("30m average tick, USDC/WETH 0.05%", avgTick);
        assertTrue(avgTick != 0, "a live pool has a non-zero average tick");
    }

    function test_erc20SupplyAndBalanceAreByteEqual() public {
        bytes memory supply = abi.encodeCall(IERC20.totalSupply, ());
        (bool s1,, bytes memory r1) = _probeAndCapture(USDC, supply);
        (, bytes memory d1) = _staticcall(USDC, supply);
        assertTrue(s1);
        assertEq(r1, d1);
        emit log_named_uint("USDC total supply", abi.decode(r1, (uint256)));

        bytes memory bal = abi.encodeCall(IERC20.balanceOf, (USDC_WETH_005));
        (bool s2,, bytes memory r2) = _probeAndCapture(USDC, bal);
        (, bytes memory d2) = _staticcall(USDC, bal);
        assertTrue(s2);
        assertEq(r2, d2);
        emit log_named_uint("USDC held by the 0.05% pool", abi.decode(r2, (uint256)));
    }

    /// A liquid-staking rate is a checkpointed accumulator: it moves slowly and by
    /// design, which is exactly the shape that survives an eight-minute lag.
    function test_stethRateIsByteEqual() public {
        bytes memory data = abi.encodeCall(ILido.getPooledEthByShares, (1 ether));
        (bool success,, bytes memory ret) = _probeAndCapture(STETH, data);
        (, bytes memory direct) = _staticcall(STETH, data);
        assertTrue(success);
        assertEq(ret, direct);
        uint256 rate = abi.decode(ret, (uint256));
        emit log_named_uint("stETH per 1e18 shares", rate);
        assertGt(rate, 1 ether, "stETH has accrued since launch");
    }

    /// The read that fails must be reported as failed, on real state too: asking a
    /// token for a function it does not have is the ordinary way this happens.
    function test_unsupportedFunctionOnARealTokenIsReportedAsFailure() public {
        (bool success,, bytes memory ret) = _probeAndCapture(USDC, abi.encodeWithSignature("nonexistentFunction()"));
        assertFalse(success, "must be recorded as a failed read");
        assertEq(ret.length, 0, "USDC reverts without data here");
    }

    function test_batchOfRealFeedsFitsOneTransaction() public {
        address[] memory targets = new address[](3);
        bytes[] memory datas = new bytes[](3);
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 1800;
        secondsAgos[1] = 0;

        targets[0] = USDC_WETH_005;
        datas[0] = abi.encodeCall(IUniswapV3Pool.observe, (secondsAgos));
        targets[1] = USDC;
        datas[1] = abi.encodeCall(IERC20.totalSupply, ());
        targets[2] = STETH;
        datas[2] = abi.encodeCall(ILido.getPooledEthByShares, (1 ether));

        uint256 before = gasleft();
        vm.recordLogs();
        probe.probeMany(targets, datas);
        uint256 used = before - gasleft();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3, "three feeds from one source transaction");
        emit log_named_uint("gas for three real feeds in one transaction", used);

        for (uint256 i = 0; i < 3; i++) {
            (bool ok,,,,) = abi.decode(logs[i].data, (bool, bool, uint256, uint256, bytes));
            assertTrue(ok, "every real read succeeded");
        }
    }

    function _staticcall(address t, bytes memory d) private view returns (bool ok, bytes memory ret) {
        (ok, ret) = t.staticcall(d);
    }
}
