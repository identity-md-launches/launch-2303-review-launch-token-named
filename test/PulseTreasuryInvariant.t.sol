// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SequencerHook} from "src/SequencerHook.sol";
import {SequencerToken} from "src/SequencerToken.sol";
import {SequencerState as S} from "src/SequencerState.sol";
import {PulseTreasury} from "src/PulseTreasury.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IdmLaunchFixture} from "./helpers/IdmLaunchFixture.sol";

/// @dev Expected failures are checked explicitly; unexpected reverts fail the campaign.
/// Ghost totals come from transfers and returned swap amounts, not from the balances under test.
contract IdmTreasuryHandler is Test {
    using StateLibrary for IPoolManager;

    IdmLaunchFixture public immutable fixture;
    SequencerHook public immutable hook;
    SequencerToken public immutable token;
    PulseTreasury public immutable treasury;
    address[3] public actors;
    uint256 public ethDeposited;
    uint256 public ethSpent;
    uint256 public idmDeposited;
    uint256 public idmBought;
    uint256 public idmBurned;
    uint256 public swaps;
    uint256 public pulses;

    constructor(IdmLaunchFixture fixture_, PulseTreasury treasury_) {
        fixture = fixture_;
        hook = fixture_.hook();
        token = fixture_.token();
        treasury = treasury_;
        ethDeposited = address(treasury_).balance;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("IDM keeper", i)))));
            vm.deal(actors[i], 10 ether);
            fixture_.sendToken(actors[i], 1e24);
        }
    }

    function donateEth(uint8 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 0, actor.balance);
        vm.prank(actor);
        (bool ok,) = address(treasury).call{value: amount}("");
        assertTrue(ok);
        ethDeposited += amount;
    }

    function donateIdm(uint8 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(actor));
        vm.prank(actor);
        assertTrue(token.transfer(address(treasury), amount));
        idmDeposited += amount;
    }

    function elapse(uint256 secondsSeed) external {
        // Includes same-block calls and both the 900s pulse and 3600s silence boundaries.
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 7200));
        vm.roll(vm.getBlockNumber() + 1);
    }

    function pulse(uint8 actorSeed) external {
        address actor = actors[actorSeed % 3];
        (bool ready, uint256 quoted, uint256 idle,) = treasury.nextPulse();
        (uint256 a, uint256 b) = hook.raw();
        uint256 ethBefore = address(treasury).balance;
        uint256 tokenBefore = token.balanceOf(address(treasury));
        uint256 keeperEth = actor.balance;
        uint256 keeperIdm = token.balanceOf(actor);
        IPoolManager manager = IPoolManager(address(fixture.manager()));
        uint256 managerEth = address(manager).balance;
        uint256 managerIdm = token.balanceOf(address(manager));
        (uint160 priceBefore,,,) = manager.getSlot0(hook.poolId());
        if (!ready || fixture.positionLiquidity() == 0) {
            bytes memory reason = idle < 900
                ? abi.encodeWithSelector(PulseTreasury.NotIdle.selector, idle)
                : quoted == 0
                    ? abi.encodeWithSelector(PulseTreasury.NoBudget.selector)
                    : abi.encodeWithSelector(PulseTreasury.NoFill.selector);
            vm.prank(actor);
            vm.expectRevert(reason);
            treasury.pulse();
            _unchanged(a, b, ethBefore, tokenBefore);
            assertEq(address(manager).balance, managerEth);
            assertEq(token.balanceOf(address(manager)), managerIdm);
            (uint160 priceAfter,,,) = manager.getSlot0(hook.poolId());
            assertEq(priceAfter, priceBefore, "reverted swap moved pool price");
        } else {
            vm.prank(actor);
            (uint256 paid, uint256 got) = treasury.pulse();
            assertGt(paid, 0);
            assertGt(got, 0);
            assertLe(paid, quoted);
            assertLe(paid, 0.002 ether);
            assertLe(paid, ethBefore / 100);
            assertEq(address(treasury).balance + paid, ethBefore);
            assertEq(token.balanceOf(address(treasury)), tokenBefore + got);
            assertEq(address(manager).balance, managerEth + paid);
            assertEq(token.balanceOf(address(manager)) + got, managerIdm);
            (uint160 priceAfter,,,) = manager.getSlot0(hook.poolId());
            assertLe(priceAfter, priceBefore);
            assertGe(priceAfter, uint256(priceBefore) * 9900 / 10_000);
            assertEq(hook.state().lastTs, vm.getBlockTimestamp());
            ethSpent += paid;
            idmBought += got;
            ++swaps;
            ++pulses;
        }
        assertEq(actor.balance, keeperEth, "keeper took ETH");
        assertEq(token.balanceOf(actor), keeperIdm, "keeper took IDM");
    }

    function burn(uint8 actorSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 before = token.balanceOf(address(treasury));
        uint256 deadBefore = token.balanceOf(treasury.DEAD());
        uint256 ethBefore = address(treasury).balance;
        uint256 actorBefore = token.balanceOf(actor);
        (uint256 a, uint256 b) = hook.raw();
        if (before == 0) {
            vm.prank(actor);
            vm.expectRevert(PulseTreasury.NothingToBurn.selector);
            treasury.burn();
        } else {
            vm.prank(actor);
            assertEq(treasury.burn(), before);
            idmBurned += before;
        }
        assertEq(token.balanceOf(address(treasury)), 0);
        assertEq(token.balanceOf(treasury.DEAD()), deadBefore + before);
        assertEq(address(treasury).balance, ethBefore);
        assertEq(token.balanceOf(actor), actorBefore);
        _wordsUnchanged(a, b);
    }

    function trade(bool buy, uint256 amountSeed) external {
        // These trades alter EMA/idle/heat through the real hook, without writing storage.
        // Empty-pool swaps can move straight to the caller's limit without exchanging assets.
        // Treasury no-fill rollback is tested in pulse(); this handler generates filled trades.
        if (fixture.positionLiquidity() == 0) return;
        uint160 upperPrice = TickMath.getSqrtPriceAtTick(fixture.UPPER());
        (uint160 currentPrice,,,) = IPoolManager(address(fixture.manager())).getSlot0(hook.poolId());
        if (!buy && currentPrice >= upperPrice) return;
        uint256 amount = buy ? bound(amountSeed, 1, 0.05 ether) : bound(amountSeed, 1, 1e24);
        uint256 before = token.balanceOf(address(fixture));
        uint256 ethBefore = address(fixture).balance;
        BalanceDelta delta = fixture.swap(buy, -int256(amount), buy ? TickMath.MIN_SQRT_PRICE + 1 : upperPrice);
        assertEq(int256(token.balanceOf(address(fixture))) - int256(before), int256(delta.amount1()));
        assertEq(int256(address(fixture).balance) - int256(ethBefore), int256(delta.amount0()));
        ++swaps;
    }

    function setLiquidity(bool active) external {
        (uint256 a, uint256 b) = hook.raw();
        uint256 current = fixture.positionLiquidity();
        if (active && current == 0) fixture.modify(fixture.SEED_LIQUIDITY());
        else if (!active && current > 0) fixture.modify(-int256(current));
        _wordsUnchanged(a, b);
    }

    function collectFees() external {
        (uint256 a, uint256 b) = hook.raw();
        // The launch factory collects with zero liquidity delta (v4's removal path).
        if (fixture.positionLiquidity() == 0) {
            vm.expectRevert(Position.CannotUpdateEmptyPosition.selector);
            fixture.modify(0);
        } else {
            BalanceDelta delta = fixture.modify(0);
            assertGe(delta.amount0(), 0);
            assertGe(delta.amount1(), 0);
        }
        _wordsUnchanged(a, b);
    }

    function forgedCallback(uint8 actorSeed, uint256 amount, uint160 limit) external {
        (uint256 a, uint256 b) = hook.raw();
        uint256 ethBefore = address(treasury).balance;
        uint256 tokenBefore = token.balanceOf(address(treasury));
        vm.prank(actors[actorSeed % 3]);
        vm.expectRevert(PulseTreasury.OnlyPoolManager.selector);
        treasury.unlockCallback(abi.encode(amount, limit));
        _unchanged(a, b, ethBefore, tokenBefore);
    }

    function _unchanged(uint256 a, uint256 b, uint256 ethBefore, uint256 tokenBefore) private view {
        _wordsUnchanged(a, b);
        assertEq(address(treasury).balance, ethBefore);
        assertEq(token.balanceOf(address(treasury)), tokenBefore);
    }

    function _wordsUnchanged(uint256 a, uint256 b) private view {
        (uint256 afterA, uint256 afterB) = hook.raw();
        assertEq(afterA, a);
        assertEq(afterB, b);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract PulseTreasuryInvariantTest is Test {
    using PoolIdLibrary for PoolKey;

    IdmLaunchFixture internal fixture;
    PulseTreasury internal treasury;
    IdmTreasuryHandler internal handler;
    SequencerToken internal token;
    SequencerHook internal hook;
    bytes32 internal binding;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        fixture = new IdmLaunchFixture();
        fixture.launch();
        token = fixture.token();
        hook = fixture.hook();
        treasury = new PulseTreasury(fixture.manager(), fixture.poolKey(), address(hook), address(token));
        vm.deal(address(treasury), 1 ether);
        vm.deal(address(fixture), 100 ether);
        handler = new IdmTreasuryHandler(fixture, treasury);
        binding = vm.load(address(hook), bytes32(uint256(3)));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.donateEth.selector;
        selectors[1] = handler.donateIdm.selector;
        selectors[2] = handler.elapse.selector;
        selectors[3] = handler.pulse.selector;
        selectors[4] = handler.burn.selector;
        selectors[5] = handler.trade.selector;
        selectors[6] = handler.setLiquidity.selector;
        selectors[7] = handler.collectFees.selector;
        selectors[8] = handler.forgedCallback.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_TreasuryAssetsReconcileWithAllDepositsPulsesAndBurns() public view {
        assertEq(address(treasury).balance + handler.ethSpent(), handler.ethDeposited());
        assertEq(token.balanceOf(address(treasury)) + handler.idmBurned(), handler.idmDeposited() + handler.idmBought());
        assertEq(token.balanceOf(treasury.DEAD()), handler.idmBurned());
        assertLe(handler.ethSpent(), handler.pulses() * 0.002 ether);
    }

    function invariant_FixedSupplyIsAccountedForAndHookHasNoSwapRevenue() public view {
        uint256 sum = token.balanceOf(address(fixture)) + token.balanceOf(address(fixture.manager()))
            + token.balanceOf(address(treasury)) + token.balanceOf(treasury.DEAD());
        for (uint256 i; i < 3; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.allowance(address(treasury), address(fixture.manager())), 0);
    }

    function invariant_OnlySuccessfulSwapsAdvanceTheBoundSequencer() public view {
        S.State memory state = hook.state();
        assertEq(state.swapCount, handler.swaps());
        assertTrue(hook.initialized());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(fixture.poolKey().toId()));
        assertEq(hook.quote(), address(0));
        assertTrue(hook.quoteIs0());
        assertEq(vm.load(address(hook), bytes32(uint256(3))), binding, "pool binding changed");
        assertLe(state.heat, 15);
        assertLe(state.intervalEma, 900);
        assertGe(state.bpm, 72);
        assertLe(state.bpm, 118);
        assertGe(state.pressure, -16000);
        assertLe(state.pressure, 16000);
        assertLe(state.root, 11);
        assertLe(state.mode, 3);
        assertEq(state.releaseCount, 0);
        assertGe(state.sizeLogEma, 710);
        assertLe(state.sizeLogEma, 1045);
        (uint256 a, uint256 b) = hook.raw();
        assertEq(a >> 232, 0);
        assertEq(b >> 192, 0);
        assertEq(vm.load(address(hook), bytes32(0)), bytes32(a));
        assertEq(vm.load(address(hook), bytes32(uint256(1))), bytes32(b));
    }

    /// @dev A deterministic non-vacuity witness alongside the randomly ordered campaign.
    function test_HandlerLifecycleVisitsSuccessFailureAndRecovery() public {
        handler.pulse(0);
        handler.pulse(1); // too soon
        handler.burn(2);
        handler.burn(1); // empty
        handler.setLiquidity(false);
        handler.elapse(900);
        handler.pulse(2); // no fill; transient flag and hook mutation must roll back
        handler.setLiquidity(true);
        handler.pulse(2);
        handler.donateIdm(0, 1);
        handler.donateEth(1, 1 ether);
        handler.trade(false, 1e20);
        handler.collectFees();
        handler.forgedCallback(0, type(uint256).max, 0);
        invariant_TreasuryAssetsReconcileWithAllDepositsPulsesAndBurns();
        invariant_FixedSupplyIsAccountedForAndHookHasNoSwapRevenue();
        invariant_OnlySuccessfulSwapsAdvanceTheBoundSequencer();
        assertEq(handler.pulses(), 2);
        assertGt(handler.idmBurned(), 0);
    }
}
