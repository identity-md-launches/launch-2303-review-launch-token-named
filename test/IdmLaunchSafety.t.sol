// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SequencerHook} from "src/SequencerHook.sol";
import {SequencerToken} from "src/SequencerToken.sol";
import {QuoteCalibration as Q} from "src/QuoteCalibration.sol";
import {PulseTreasury} from "src/PulseTreasury.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IdmLaunchFixture} from "./helpers/IdmLaunchFixture.sol";

/// @dev Nested calls are deliberately one transaction: tstore/tload must survive between them.
contract IdmPulseBatchProbe {
    function twice(PulseTreasury treasury) external returns (bytes memory secondReason) {
        treasury.pulse();
        try treasury.pulse() {
            revert("second pulse succeeded");
        } catch (bytes memory reason) {
            return reason;
        }
    }

    function recoverFromNoFill(PulseTreasury treasury, IdmLaunchFixture fixture)
        external
        returns (bytes memory firstReason, uint256 paid, uint256 got)
    {
        try treasury.pulse() {
            revert("empty pool pulse succeeded");
        } catch (bytes memory reason) {
            firstReason = reason;
        }
        fixture.modify(fixture.SEED_LIQUIDITY());
        (paid, got) = treasury.pulse();
    }
}

contract IdmLaunchSafetyTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IdmLaunchFixture internal fixture;
    PoolManager internal manager;
    SequencerToken internal token;
    SequencerHook internal hook;
    SequencerHook internal fresh;
    PoolKey internal key;
    PoolKey internal freshKey;
    PulseTreasury internal treasury;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        fixture = new IdmLaunchFixture();
        fixture.launch();
        manager = fixture.manager();
        token = fixture.token();
        hook = fixture.hook();
        key = fixture.poolKey();
        fresh = _deployFreshHook();
        freshKey = PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, IHooks(address(fresh)));
        treasury = new PulseTreasury(manager, key, address(hook), address(token));
    }

    function _initCodeHash() internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(SequencerHook).creationCode,
                abi.encode(manager, address(token), address(fixture), Q.T_HAT, Q.T_GLITCH, Q.T_SNARE)
            )
        );
    }

    function _predict(uint256 salt, bytes32 hash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), hash)))));
    }

    function _deployFreshHook() internal returns (SequencerHook) {
        bytes32 hash = _initCodeHash();
        for (uint256 i; i < 300_000; ++i) {
            if ((uint160(_predict(i, hash)) & Hooks.ALL_HOOK_MASK) == 0x3040) {
                return new SequencerHook{salt: bytes32(i)}(
                    manager, address(token), address(fixture), Q.T_HAT, Q.T_GLITCH, Q.T_SNARE
                );
            }
        }
        revert("salt search exhausted");
    }

    function test_TokenOnlyLaunchFirstBuySellFeeCollectAndExit() public {
        assertEq(block.chainid, 4663);
        assertEq(address(manager).balance, 0, "seed must not pre-fund ETH");
        assertEq(address(fixture).balance, 0);
        assertGt(token.balanceOf(address(manager)), 0);
        assertEq(hook.factory(), address(fixture));
        assertEq(hook.quote(), address(0));
        assertTrue(hook.quoteIs0());
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x3040);

        vm.deal(address(fixture), 0.01 ether);
        uint256 tokensBefore = token.balanceOf(address(fixture));
        BalanceDelta buy = fixture.swap(true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1);
        assertEq(buy.amount0(), -int256(0.01 ether));
        assertGt(buy.amount1(), 0);
        assertEq(token.balanceOf(address(fixture)), tokensBefore + uint128(buy.amount1()));
        assertEq(address(manager).balance, 0.01 ether);
        assertEq(hook.state().swapCount, 1);

        BalanceDelta sell =
            fixture.swap(false, -int256(buy.amount1()) / 2, TickMath.getSqrtPriceAtTick(fixture.UPPER()));
        assertGt(sell.amount0(), 0);
        assertLt(sell.amount1(), 0);
        assertEq(hook.state().swapCount, 2);
        (uint256 a, uint256 b) = hook.raw();
        BalanceDelta fees = fixture.modify(0);
        assertGt(fees.amount0(), 0, "buy LP fees collectible");
        assertGt(fees.amount1(), 0, "sell LP fees collectible");
        fixture.modify(-fixture.SEED_LIQUIDITY());
        (uint256 afterA, uint256 afterB) = hook.raw();
        assertEq(afterA, a);
        assertEq(afterB, b);
        assertEq(fixture.positionLiquidity(), 0);
        assertEq(token.balanceOf(address(fixture)) + token.balanceOf(address(manager)), token.totalSupply());
        assertEq(address(fixture).balance + address(manager).balance, 0.01 ether);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_InvalidInitializationCannotBindOrPoisonAValidLaunch(uint8 field, uint24 badValue) public {
        PoolKey memory invalid = freshKey;
        uint8 choice = field % 6;
        if (choice == 0) {
            invalid.fee = badValue == 12500 ? 0 : badValue;
        } else if (choice == 1) {
            invalid.tickSpacing = int24(badValue == 60 ? 0 : badValue);
        } else if (choice == 2) {
            invalid.hooks = IHooks(address(hook));
        } else if (choice == 3) {
            invalid.currency0 = freshKey.currency1;
            invalid.currency1 = freshKey.currency0;
        } else if (choice == 4) {
            invalid.currency0 = invalid.currency1;
        } else {
            // Deliberately invalid test pair: neither currency is the launch token.
            invalid.currency0 = Currency.wrap(address(1));
            invalid.currency1 = Currency.wrap(address(2));
        }
        vm.prank(address(manager));
        vm.expectRevert(SequencerHook.InvalidPool.selector);
        fresh.beforeInitialize(address(fixture), invalid, uint160(1 << 96));
        vm.prank(address(manager));
        vm.expectRevert(SequencerHook.InvalidPool.selector);
        fresh.afterInitialize(address(fixture), invalid, uint160(1 << 96), 0);
        for (uint256 i; i < 4; ++i) {
            assertEq(vm.load(address(fresh), bytes32(i)), bytes32(0));
        }
        assertFalse(fresh.initialized());
        vm.prank(address(fixture));
        manager.initialize(freshKey, uint160(1 << 96));
        assertTrue(fresh.initialized());
        assertEq(PoolId.unwrap(fresh.poolId()), PoolId.unwrap(freshKey.toId()));
    }

    function test_UninitializedSwapRejectedEvenFromManager() public {
        vm.prank(address(manager));
        vm.expectRevert(SequencerHook.InvalidPool.selector);
        fresh.afterSwap(
            address(fixture), freshKey, SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1), toBalanceDelta(-1, 1), ""
        );
        (uint256 a, uint256 b) = fresh.raw();
        assertEq(a, 0);
        assertEq(b, 0);
        assertFalse(fresh.initialized());
    }

    function test_RealSwapOnlyWritesTheTwoPackedStateWords() public {
        vm.deal(address(fixture), 0.01 ether);
        vm.record();
        fixture.swap(true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1);
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        bool wroteSlot0;
        bool wroteSlot1;
        for (uint256 i; i < writes.length; ++i) {
            assertLe(uint256(writes[i]), 1, "swap wrote outside the sequencer words");
            if (writes[i] == bytes32(0)) wroteSlot0 = true;
            if (writes[i] == bytes32(uint256(1))) wroteSlot1 = true;
        }
        assertTrue(wroteSlot0 && wroteSlot1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ForeignCallersCannotDriveAnyEnabledCallback(address caller, int128 amount0, int128 amount1)
        public
    {
        if (caller == address(manager)) caller = address(this);
        (uint256 a, uint256 b) = hook.raw();
        vm.startPrank(caller);
        vm.expectRevert(SequencerHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(fixture), key, uint160(1 << 96));
        vm.expectRevert(SequencerHook.OnlyPoolManager.selector);
        hook.afterInitialize(address(fixture), key, uint160(1 << 96), 0);
        vm.expectRevert(SequencerHook.OnlyPoolManager.selector);
        hook.afterSwap(address(fixture), key, SwapParams(true, -1, 1), toBalanceDelta(amount0, amount1), "");
        vm.stopPrank();
        (uint256 afterA, uint256 afterB) = hook.raw();
        assertEq(afterA, a);
        assertEq(afterB, b);
    }

    /// @dev The documented input is actual BalanceDelta, not hookData or the requested trade direction/size.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_HookDataAndRequestedAmountsCannotChangeTheActualDeltaMutation(
        int128 amount0,
        int128 amount1,
        int256 requested,
        uint160 limit,
        bool direction,
        bytes memory data
    ) public {
        uint256 snapshot = vm.snapshotState();
        vm.prank(address(manager));
        (bytes4 selector, int128 returned) = hook.afterSwap(
            address(fixture), key, SwapParams(direction, requested, limit), toBalanceDelta(amount0, amount1), data
        );
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(returned, 0);
        (uint256 a, uint256 b) = hook.raw();
        assertTrue(vm.revertToState(snapshot));
        vm.prank(address(manager));
        hook.afterSwap(address(this), key, SwapParams(!direction, 0, 0), toBalanceDelta(amount0, amount1), "");
        (uint256 afterA, uint256 afterB) = hook.raw();
        assertEq(afterA, a);
        assertEq(afterB, b);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_ConstructorRejectsAddressWithIncorrectPermissionBits() public {
        bytes32 hash = _initCodeHash();
        uint256 salt;
        while ((uint160(_predict(salt, hash)) & Hooks.ALL_HOOK_MASK) == 0x3040) ++salt;
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, _predict(salt, hash)));
        new SequencerHook{salt: bytes32(salt)}(
            manager, address(token), address(fixture), Q.T_HAT, Q.T_GLITCH, Q.T_SNARE
        );
    }

    function test_InitializationCallbackPreventsPoolOpeningAtAnUndeployedHook() public {
        PoolKey memory unbuilt = key;
        // Match the permission bits but deliberately leave the address without code.
        address undeployed = address(uint160(0x12343040));
        assertEq(undeployed.code.length, 0);
        unbuilt.hooks = IHooks(undeployed);
        vm.prank(address(fixture));
        vm.expectRevert();
        manager.initialize(unbuilt, uint160(1 << 96));
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(unbuilt.toId());
        assertEq(price, 0);
    }

    function test_HookHasNoAdminFundOrUpgradeSurface() public {
        bytes[] memory calls = new bytes[](8);
        calls[0] = abi.encodeWithSignature("owner()");
        calls[1] = abi.encodeWithSignature("transferOwnership(address)", address(this));
        calls[2] = abi.encodeWithSignature("setFee(uint24)", 1);
        calls[3] = abi.encodeWithSignature("upgradeTo(address)", address(this));
        calls[4] = abi.encodeWithSignature("withdraw(address,uint256)", address(token), 1);
        calls[5] = abi.encodeWithSignature("pause()");
        calls[6] = abi.encodeWithSignature("setSigner(address)", address(this));
        calls[7] = abi.encodeWithSignature("setPoolManager(address)", address(this));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(hook).call(calls[i]);
            assertFalse(ok);
        }
        (bool paid,) = address(hook).call{value: 1}("");
        assertFalse(paid);
        _assertImmutableRuntime(address(hook));
        _assertImmutableRuntime(address(token));
    }

    function _assertImmutableRuntime(address deployed) internal view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "mutable runtime escape hatch");
            }
        }
    }

    function test_TransientGuardClearsAfterSuccessWithinOneTransaction() public {
        vm.deal(address(treasury), 1 ether);
        IdmPulseBatchProbe probe = new IdmPulseBatchProbe();
        bytes memory reason = probe.twice(treasury);
        assertEq(reason, abi.encodeWithSelector(PulseTreasury.NotIdle.selector, uint256(0)));
        assertEq(hook.state().swapCount, 1);
    }

    function test_NoFillRevertCanRecoverWithinTheSameTransaction() public {
        vm.deal(address(treasury), 1 ether);
        fixture.modify(-fixture.SEED_LIQUIDITY());
        IdmPulseBatchProbe probe = new IdmPulseBatchProbe();
        (bytes memory reason, uint256 paid, uint256 got) = probe.recoverFromNoFill(treasury, fixture);
        assertEq(reason, abi.encodeWithSelector(PulseTreasury.NoFill.selector));
        assertGt(got, 0);
        assertEq(address(treasury).balance + paid, 1 ether);
        assertEq(token.balanceOf(address(treasury)), got);
        assertEq(hook.state().swapCount, 1, "failed swap must not advance sequencer");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_PulseSizingIsBoundedAndMonotone(uint256 ema, uint256 balance, uint256 other) public view {
        uint256 amount = treasury.pulseSize(ema, balance);
        assertLe(amount, 0.002 ether);
        assertLe(amount, balance / 100);
        if (balance < 0.0025 ether) assertEq(amount, 0);
        else assertGe(amount, 0.000025 ether);
        uint256 low = ema < other ? ema : other;
        uint256 high = ema < other ? other : ema;
        assertLe(treasury.pulseSize(low, balance), treasury.pulseSize(high, balance));
        low = balance < other ? balance : other;
        high = balance < other ? other : balance;
        assertLe(treasury.pulseSize(ema, low), treasury.pulseSize(ema, high));
    }
}
