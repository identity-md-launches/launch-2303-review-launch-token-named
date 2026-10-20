// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SequencerHook} from "src/SequencerHook.sol";
import {SequencerToken} from "src/SequencerToken.sol";
import {PulseTreasury} from "src/PulseTreasury.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IdmLaunchFixture} from "./helpers/IdmLaunchFixture.sol";

/// @dev Arbitrary-range LP and trader that settles only from its own balance.
contract AnchorLp is IUnlockCallback {
    IPoolManager public immutable manager;
    SequencerToken public immutable token;
    PoolKey private key;

    constructor(IPoolManager manager_, SequencerToken token_, PoolKey memory key_) {
        manager = manager_;
        token = token_;
        key = key_;
    }

    receive() external payable {}

    function modify(int24 lower, int24 upper, int256 liquidity) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(true, lower, upper, liquidity, false, uint160(0))), (BalanceDelta));
    }

    function swap(bool zeroForOne, int256 amount, uint160 limit) external returns (BalanceDelta) {
        return
            abi.decode(manager.unlock(abi.encode(false, int24(0), int24(0), amount, zeroForOne, limit)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (bool isModify, int24 lower, int24 upper, int256 amount, bool zeroForOne, uint160 limit) =
            abi.decode(data, (bool, int24, int24, int256, bool, uint160));
        BalanceDelta delta;
        if (isModify) (delta,) = manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, amount, 0), "");
        else delta = manager.swap(key, SwapParams(zeroForOne, amount, limit), "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                require(token.transfer(address(manager), amount));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(uint128(delta)));
        }
    }
}

/// @dev Targeted priceAnchor() cases the implementation's own suite does not reach: gaps spanning several
///      bitmap words, liquidity only above the price, a random park height, and buys that end exactly on a tick.
contract PulseTreasuryAnchorTest is Test {
    using StateLibrary for IPoolManager;

    IdmLaunchFixture internal fixture;
    PulseTreasury internal treasury;
    SequencerToken internal token;
    SequencerHook internal hook;
    IPoolManager internal manager;
    AnchorLp internal lp;
    int24 internal upper;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        fixture = new IdmLaunchFixture();
        fixture.launch();
        token = fixture.token();
        hook = fixture.hook();
        manager = IPoolManager(address(fixture.manager()));
        upper = fixture.UPPER();
        treasury = new PulseTreasury(fixture.manager(), fixture.poolKey(), address(hook), address(token));
        vm.deal(address(treasury), 1 ether);
        vm.deal(address(fixture), 100 ether);
        lp = new AnchorLp(manager, token, fixture.poolKey());
        fixture.sendToken(address(lp), 1e26);
        vm.deal(address(lp), 100 ether);
    }

    function _slot0() internal view returns (uint160 price, int24 tick) {
        (price, tick,,) = manager.getSlot0(hook.poolId());
    }

    function _idle() internal {
        vm.warp(vm.getBlockTimestamp() + 900);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev Pulses and checks the 1% bound is measured from `anchor`, whatever slot0 was before.
    function _pulseFrom(uint160 anchor) internal returns (uint256 paid, uint256 got) {
        (bool ready, uint256 quoted,,) = treasury.nextPulse();
        assertTrue(ready, "nextPulse not ready");
        uint256 swapsBefore = hook.state().swapCount;
        (paid, got) = treasury.pulse();
        assertGt(got, 0);
        assertGt(paid, 0);
        assertLe(paid, quoted);
        (uint160 after_,) = _slot0();
        assertLe(after_, anchor, "pulse ended above its anchor");
        assertGe(after_, uint160(uint256(anchor) * 9900 / 10_000), "pulse passed 1% under the anchor");
        assertEq(hook.state().swapCount, swapsBefore + 1);
    }

    function _assertNoFillUntouched() internal {
        (bool ready,,,) = treasury.nextPulse();
        assertFalse(ready, "nextPulse ready with nothing reachable");
        (uint256 a, uint256 b) = hook.raw();
        (uint160 price,) = _slot0();
        uint256 eth = address(treasury).balance;
        vm.expectRevert(PulseTreasury.NoFill.selector);
        treasury.pulse();
        (uint256 a2, uint256 b2) = hook.raw();
        (uint160 price2,) = _slot0();
        assertEq(a2, a);
        assertEq(b2, b);
        assertEq(price2, price);
        assertEq(address(treasury).balance, eth);
    }

    /// @dev At launch the price sits on the seed's upper tick, where v4 counts the position as inactive:
    ///      the pool's liquidity is 0 and the anchor comes from the bitmap. It must equal slot0 there.
    function test_LaunchStateAnchorIsTheOpeningPrice() public {
        assertEq(manager.getLiquidity(hook.poolId()), 0);
        (uint160 price, int24 tick) = _slot0();
        assertEq(tick, upper);
        (uint160 anchor, bool found) = treasury.priceAnchor();
        assertTrue(found);
        assertEq(anchor, price);
        _idle();
        _pulseFrom(anchor);
    }

    /// @dev Any park height above the seed: the anchor stays the seed's top and the pulse still buys.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_AnyParkHeightAnchorsToTheSeedTop(uint256 limitSeed, uint256 amountSeed) public {
        uint160 top = TickMath.getSqrtPriceAtTick(upper);
        uint160 limit = uint160(bound(limitSeed, uint256(top) + 1, TickMath.MAX_SQRT_PRICE - 1));
        BalanceDelta d = fixture.swap(false, -int256(bound(amountSeed, 1, 1e24)), limit);
        assertEq(d.amount0(), 0, "free sell paid ETH");
        assertEq(d.amount1(), 0, "free sell took IDM");
        (uint160 parked,) = _slot0();
        assertEq(parked, limit);
        (uint160 anchor, bool found) = treasury.priceAnchor();
        assertTrue(found);
        assertEq(anchor, top);
        _idle();
        _pulseFrom(top);
    }

    /// @dev Two positions below the price with a gap of several bitmap words (256 * 60 ticks each) between
    ///      them. Draining the upper one leaves the price in the gap with no liquidity; the anchor must be the
    ///      lower position's top, found by walking down across empty words.
    function test_AnchorWalksAcrossEmptyBitmapWordsToTheNextPosition() public {
        fixture.modify(-int256(fixture.positionLiquidity()));
        int24 hiLower = upper - 6000;
        int24 loUpper = upper - 120_000; // ~7.8 bitmap words below hiLower
        int24 loLower = loUpper - 6000;
        lp.modify(hiLower, upper, 1e20);
        lp.modify(loLower, loUpper, 1e22);
        // Buy everything in the upper position, stopping exactly on its lower tick.
        lp.swap(true, -100 ether, TickMath.getSqrtPriceAtTick(hiLower));
        (uint160 p, int24 t) = _slot0();
        assertEq(p, TickMath.getSqrtPriceAtTick(hiLower));
        assertEq(t, hiLower - 1, "zeroForOne crossing lands one tick below");
        assertEq(manager.getLiquidity(hook.poolId()), 0);
        (uint160 anchor, bool found) = treasury.priceAnchor();
        assertTrue(found);
        assertEq(anchor, TickMath.getSqrtPriceAtTick(loUpper));
        _idle();
        _pulseFrom(anchor);
    }

    /// @dev Liquidity only above the price is ETH-only: a buy (price down) can never reach it.
    function test_LiquidityOnlyAboveThePriceIsNotReachable() public {
        fixture.modify(-int256(fixture.positionLiquidity()));
        lp.modify(upper + 600, upper + 6000, 1e20);
        assertEq(manager.getLiquidity(hook.poolId()), 0);
        (, bool found) = treasury.priceAnchor();
        assertFalse(found);
        _idle();
        _assertNoFillUntouched();
    }

    /// @dev A pool whose price was pushed under every position: nothing at or below the price.
    function test_PriceBelowEveryPositionIsNotReachable() public {
        fixture.modify(-int256(fixture.positionLiquidity()));
        lp.modify(upper - 600, upper, 1e18);
        lp.swap(true, -100 ether, TickMath.getSqrtPriceAtTick(upper - 1200)); // drains it and walks on
        (, int24 t) = _slot0();
        assertLt(t, upper - 600);
        assertEq(manager.getLiquidity(hook.poolId()), 0);
        (, bool found) = treasury.priceAnchor();
        assertFalse(found);
        _idle();
        _assertNoFillUntouched();
    }

    /// @dev A buy that stops exactly on the seed's top from a parked price crosses it: the pool is back in
    ///      range and the anchor is slot0 again (no double-count of the walked distance).
    function test_ReturnFromParkOntoTheTopTickIsAnOrdinaryPulse() public {
        uint160 top = TickMath.getSqrtPriceAtTick(upper);
        fixture.swap(false, -1e18, TickMath.MAX_SQRT_PRICE - 1);
        fixture.swap(true, -1 ether, top);
        (uint160 p, int24 t) = _slot0();
        assertEq(p, top);
        assertEq(t, upper - 1);
        assertGt(manager.getLiquidity(hook.poolId()), 0);
        (uint160 anchor, bool found) = treasury.priceAnchor();
        assertTrue(found);
        assertEq(anchor, top);
        _idle();
        _pulseFrom(top);
    }

    /// @dev The recovery path for any parked state the anchor cannot see through: one real buy brings the
    ///      price back to liquidity, and after the next silence the pulse is ordinary.
    function test_AnyBuyAfterADustParkRestoresThePulse() public {
        int24 parkTick = upper + 6000;
        fixture.swap(false, -1e18, TickMath.getSqrtPriceAtTick(parkTick));
        lp.modify(parkTick - 60, parkTick + 60, 1); // dust spanning the parked price
        lp.swap(true, -0.001 ether, TickMath.MIN_SQRT_PRICE + 1);
        (, int24 t) = _slot0();
        assertLt(t, upper);
        (uint160 anchor,) = treasury.priceAnchor();
        (uint160 slot,) = _slot0();
        assertEq(anchor, slot);
        _idle();
        _pulseFrom(anchor);
    }
}

/// @dev Random trades that park the price anywhere above the seed, re-enter it, or stop on its top tick;
///      liquidity removed and restored; time passing. Pulses are checked against an independent anchor
///      oracle built from the one known position, not from the tick bitmap.
contract AnchorHandler is Test {
    using StateLibrary for IPoolManager;

    IdmLaunchFixture public immutable fixture;
    PulseTreasury public immutable treasury;
    SequencerHook public immutable hook;
    SequencerToken public immutable token;
    IPoolManager public immutable manager;
    uint256 public ethSpent;
    uint256 public idmBought;
    uint256 public swaps;
    uint256 public pulses;
    uint256 public parks;
    uint256 public parkedPulses;

    constructor(IdmLaunchFixture fixture_, PulseTreasury treasury_) {
        fixture = fixture_;
        treasury = treasury_;
        hook = fixture_.hook();
        token = fixture_.token();
        manager = IPoolManager(address(fixture_.manager()));
    }

    function _slot0() internal view returns (uint160 price, int24 tick) {
        (price, tick,,) = manager.getSlot0(hook.poolId());
    }

    /// @dev Anchor from the single [LOWER, UPPER) position the fixture can hold.
    function oracle() public view returns (uint160 anchor, bool found) {
        (uint160 price, int24 tick) = _slot0();
        if (manager.getLiquidity(hook.poolId()) != 0) return (price, true);
        if (fixture.positionLiquidity() == 0 || tick < fixture.LOWER()) return (0, false);
        if (tick >= fixture.UPPER()) return (TickMath.getSqrtPriceAtTick(fixture.UPPER()), true);
        revert("in range with zero liquidity");
    }

    function park(uint256 limitSeed, uint256 amountSeed) external {
        (uint160 price,) = _slot0();
        if (price >= TickMath.MAX_SQRT_PRICE - 1) return;
        uint160 limit = uint160(bound(limitSeed, uint256(price) + 1, TickMath.MAX_SQRT_PRICE - 1));
        fixture.swap(false, -int256(bound(amountSeed, 1, 1e25)), limit);
        ++swaps;
        if (manager.getLiquidity(hook.poolId()) == 0) ++parks;
    }

    function buy(uint256 amountSeed, uint256 limitSeed, bool toTop) external {
        // Without the seed a buy walks free to its limit, and restoring the seed there would need unbounded ETH.
        if (fixture.positionLiquidity() == 0) return;
        (uint160 price,) = _slot0();
        uint160 top = TickMath.getSqrtPriceAtTick(fixture.UPPER());
        uint160 limit;
        if (toTop && price > top) limit = top;
        else if (price <= TickMath.MIN_SQRT_PRICE + 1) return;
        else limit = uint160(bound(limitSeed, TickMath.MIN_SQRT_PRICE + 1, uint256(price) - 1));
        fixture.swap(true, -int256(bound(amountSeed, 1, 0.05 ether)), limit);
        ++swaps;
    }

    function setLiquidity(bool active) external {
        uint256 current = fixture.positionLiquidity();
        if (active && current == 0) fixture.modify(fixture.SEED_LIQUIDITY());
        else if (!active && current > 0) fixture.modify(-int256(current));
    }

    function elapse(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 3600));
        vm.roll(vm.getBlockNumber() + 1);
    }

    function pulse() external {
        (bool ready, uint256 quoted, uint256 idle,) = treasury.nextPulse();
        (uint160 anchor, bool found) = treasury.priceAnchor();
        (uint160 expected, bool expectedFound) = oracle();
        assertEq(found, expectedFound, "anchor found disagrees with oracle");
        if (found) assertEq(anchor, expected, "anchor disagrees with oracle");
        // Liveness: silence + budget + reachable seed => the pulse is offered.
        if (idle >= 900 && quoted > 0) assertEq(ready, found, "nextPulse disagrees with reachability");
        (uint160 before, int24 tick) = _slot0();
        bool wasParked = manager.getLiquidity(hook.poolId()) == 0 && tick >= fixture.UPPER();
        (uint256 a, uint256 b) = hook.raw();
        uint256 eth = address(treasury).balance;
        if (!ready) {
            vm.expectRevert(
                idle < 900
                    ? abi.encodeWithSelector(PulseTreasury.NotIdle.selector, idle)
                    : quoted == 0
                        ? abi.encodeWithSelector(PulseTreasury.NoBudget.selector)
                        : abi.encodeWithSelector(PulseTreasury.NoFill.selector)
            );
            treasury.pulse();
            (uint256 a2, uint256 b2) = hook.raw();
            (uint160 after_,) = _slot0();
            assertEq(a2, a);
            assertEq(b2, b);
            assertEq(after_, before);
            assertEq(address(treasury).balance, eth);
            return;
        }
        uint256 idmBefore = token.balanceOf(address(treasury));
        (uint256 paid, uint256 got) = treasury.pulse();
        assertGt(got, 0);
        assertGt(paid, 0);
        assertLe(paid, quoted);
        assertEq(address(treasury).balance + paid, eth);
        assertEq(token.balanceOf(address(treasury)), idmBefore + got);
        (uint160 after2,) = _slot0();
        assertLe(after2, anchor);
        assertGe(after2, uint160(uint256(anchor) * 9900 / 10_000));
        assertEq(hook.state().lastTs, vm.getBlockTimestamp());
        ethSpent += paid;
        idmBought += got;
        ++swaps;
        ++pulses;
        if (wasParked) ++parkedPulses;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PulseTreasuryAnchorInvariantTest is Test {
    using StateLibrary for IPoolManager;

    IdmLaunchFixture internal fixture;
    PulseTreasury internal treasury;
    AnchorHandler internal handler;
    SequencerToken internal token;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        fixture = new IdmLaunchFixture();
        fixture.launch();
        token = fixture.token();
        treasury = new PulseTreasury(fixture.manager(), fixture.poolKey(), address(fixture.hook()), address(token));
        vm.deal(address(treasury), 1 ether);
        vm.deal(address(fixture), 100 ether);
        handler = new AnchorHandler(fixture, treasury);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.park.selector;
        selectors[1] = handler.buy.selector;
        selectors[2] = handler.setLiquidity.selector;
        selectors[3] = handler.elapse.selector;
        selectors[4] = handler.pulse.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_TreasuryEthAndIdmMatchPulses() public view {
        assertEq(address(treasury).balance + handler.ethSpent(), 1 ether);
        assertEq(token.balanceOf(address(treasury)), handler.idmBought());
        assertLe(handler.ethSpent(), handler.pulses() * 0.002 ether);
    }

    function invariant_AnchorMatchesOracleAndEverySwapIsFiled() public view {
        (uint160 anchor, bool found) = treasury.priceAnchor();
        (uint160 expected, bool expectedFound) = handler.oracle();
        assertEq(found, expectedFound);
        if (found) assertEq(anchor, expected);
        assertEq(fixture.hook().state().swapCount, handler.swaps());
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(fixture.hook())), 0);
        assertEq(address(fixture.hook()).balance, 0);
    }

    /// @dev Non-vacuity witness: a parked pulse, a re-entered pulse, and a no-liquidity refusal.
    function test_AnchorHandlerVisitsParkedAndOrdinaryPulses() public {
        handler.park(type(uint256).max, 1e18);
        handler.elapse(900);
        handler.pulse(); // parked -> anchored at the seed top
        handler.buy(0.01 ether, 0, false);
        handler.elapse(900);
        handler.pulse(); // ordinary, inside liquidity
        handler.park(type(uint256).max, 1e25); // drains the ETH side and parks again
        handler.setLiquidity(false);
        handler.elapse(900);
        handler.pulse(); // NoFill
        handler.setLiquidity(true);
        handler.pulse(); // anchored at the restored top
        assertEq(handler.pulses(), 3);
        assertEq(handler.parkedPulses(), 2);
        assertGe(handler.parks(), 2);
        invariant_TreasuryEthAndIdmMatchPulses();
        invariant_AnchorMatchesOracleAndEverySwapIsFiled();
    }
}
