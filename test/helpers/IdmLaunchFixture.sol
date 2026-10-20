// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SequencerHook} from "src/SequencerHook.sol";
import {SequencerToken} from "src/SequencerToken.sol";
import {QuoteCalibration as Q} from "src/QuoteCalibration.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Local test factory/LP/trader, never a deployment script or a substitute chain address.
/// launch() constructs the token/hook, initializes and seeds token-only liquidity in one transaction.
/// All settlement uses this fixture's own assets, so no callback can charge a third-party payer.
contract IdmLaunchFixture is IUnlockCallback {
    int24 public constant LOWER = -887220;
    int24 public constant UPPER = 193380;
    int256 public constant SEED_LIQUIDITY = 3e22;
    PoolManager public manager;
    SequencerToken public token;
    SequencerHook public hook;
    PoolKey private key;
    uint256 public positionLiquidity;

    function launch() external {
        require(address(manager) == address(0), "already launched");
        manager = new PoolManager(address(this));
        token = new SequencerToken();
        bytes32 hash = keccak256(
            abi.encodePacked(
                type(SequencerHook).creationCode,
                abi.encode(manager, address(token), address(this), Q.T_HAT, Q.T_GLITCH, Q.T_SNARE)
            )
        );
        uint256 salt;
        for (; salt < 300_000; ++salt) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), hash))))
            );
            if ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == 0x3040) break;
        }
        require(salt < 300_000, "salt search exhausted");
        hook = new SequencerHook{salt: bytes32(salt)}(
            manager, address(token), address(this), Q.T_HAT, Q.T_GLITCH, Q.T_SNARE
        );
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12500, 60, IHooks(address(hook)));
        // At the upper boundary this position requires only currency1 (IDM).
        manager.initialize(key, TickMath.getSqrtPriceAtTick(UPPER));
        _modify(SEED_LIQUIDITY);
    }

    receive() external payable {}

    function poolKey() external view returns (PoolKey memory) {
        return key;
    }

    function modify(int256 liquidityDelta) external returns (BalanceDelta) {
        return _modify(liquidityDelta);
    }

    function _modify(int256 liquidityDelta) private returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(true, liquidityDelta, false, uint160(0))), (BalanceDelta));
        if (liquidityDelta >= 0) positionLiquidity += uint256(liquidityDelta);
        else positionLiquidity -= uint256(-liquidityDelta);
    }

    function swap(bool zeroForOne, int256 amount, uint160 limit) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(false, amount, zeroForOne, limit)), (BalanceDelta));
    }

    function sendToken(address to, uint256 amount) external {
        require(token.transfer(to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (bool modifyLiquidity, int256 amount, bool zeroForOne, uint160 limit) =
            abi.decode(data, (bool, int256, bool, uint160));
        BalanceDelta delta;
        if (modifyLiquidity) {
            (delta,) = manager.modifyLiquidity(key, ModifyLiquidityParams(LOWER, UPPER, amount, bytes32(0)), "");
        } else {
            delta = manager.swap(key, SwapParams(zeroForOne, amount, limit), "");
        }
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
