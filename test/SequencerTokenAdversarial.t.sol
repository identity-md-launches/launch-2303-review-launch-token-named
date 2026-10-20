// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SequencerToken} from "src/SequencerToken.sol";

contract SequencerTokenAdversarialTest is Test {
    SequencerToken internal token;
    address internal holder;
    address internal spender;
    address internal recipient;

    function setUp() public {
        holder = makeAddr("holder");
        spender = makeAddr("spender");
        recipient = makeAddr("recipient");
        token = new SequencerToken();
        token.transfer(holder, token.totalSupply());
    }

    function test_ZeroAddressPathsRejectEvenZeroAmount() public {
        vm.startPrank(holder);
        vm.expectRevert(SequencerToken.ZeroAddress.selector);
        token.approve(address(0), 0);
        vm.expectRevert(SequencerToken.ZeroAddress.selector);
        token.transfer(address(0), 0);
        vm.stopPrank();

        vm.startPrank(spender);
        vm.expectRevert(SequencerToken.ZeroAddress.selector);
        token.transferFrom(address(0), recipient, 0);
        vm.expectRevert(SequencerToken.ZeroAddress.selector);
        token.transferFrom(holder, address(0), 0);
        vm.stopPrank();
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(holder), token.totalSupply());
    }

    function test_ZeroTransferFromWithoutApprovalEmitsTransfer() public {
        vm.expectEmit(address(token));
        emit SequencerToken.Transfer(holder, recipient, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, 0));
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(holder), token.totalSupply());
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_ApprovalReplacementRevocationAndSpenderIsolation() public {
        vm.startPrank(holder);
        token.approve(spender, type(uint256).max);
        token.approve(spender, 1);
        vm.stopPrank();
        vm.prank(recipient);
        vm.expectRevert(SequencerToken.InsufficientAllowance.selector);
        token.transferFrom(holder, recipient, 1);
        vm.prank(spender);
        token.transferFrom(holder, recipient, 1);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(recipient), 1);
        vm.startPrank(holder);
        token.approve(spender, type(uint256).max);
        token.approve(spender, 0);
        vm.stopPrank();
        vm.prank(spender);
        vm.expectRevert(SequencerToken.InsufficientAllowance.selector);
        token.transferFrom(holder, recipient, 1);
    }

    function test_FullSupplyRoundTripViaFiniteAllowanceAndSelfTransfer() public {
        uint256 supply = token.totalSupply();
        vm.prank(holder);
        token.approve(spender, supply);
        vm.prank(spender);
        token.transferFrom(holder, holder, supply);
        assertEq(token.balanceOf(holder), supply);
        assertEq(token.allowance(holder, spender), 0, "self transfer still spends approval");
        vm.prank(holder);
        token.approve(spender, supply);
        vm.prank(spender);
        token.transferFrom(holder, recipient, supply);
        vm.prank(recipient);
        token.transfer(holder, supply);
        assertEq(token.balanceOf(holder), supply);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.totalSupply(), supply);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FailedTransferFromRollsBackFiniteAllowance(uint256 amount) public {
        amount = bound(amount, 1, token.totalSupply());
        vm.prank(holder);
        token.approve(spender, amount);
        vm.prank(spender);
        vm.expectRevert(SequencerToken.ZeroAddress.selector);
        token.transferFrom(holder, address(0), amount);
        assertEq(token.allowance(holder, spender), amount);
        assertEq(token.balanceOf(holder), token.totalSupply());

        uint256 supply = token.totalSupply();
        vm.prank(holder);
        token.transfer(recipient, supply);
        vm.prank(spender);
        vm.expectRevert(SequencerToken.InsufficientBalance.selector);
        token.transferFrom(holder, recipient, amount);
        assertEq(token.allowance(holder, spender), amount);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), token.totalSupply());
    }

    function test_MaxAmountCannotWrapBalancesOrAllowances() public {
        vm.prank(holder);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        vm.expectRevert(SequencerToken.InsufficientBalance.selector);
        token.transferFrom(holder, recipient, type(uint256).max);
        vm.prank(holder);
        vm.expectRevert(SequencerToken.InsufficientBalance.selector);
        token.transfer(recipient, type(uint256).max);
        assertEq(token.allowance(holder, spender), type(uint256).max);
        assertEq(token.balanceOf(holder), token.totalSupply());
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_NoMintUpgradeOwnerOrEtherEntryPoint() public {
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", recipient, 1);
        calls[1] = abi.encodeWithSignature("burn(uint256)", 1);
        calls[2] = abi.encodeWithSignature("transferOwnership(address)", recipient);
        calls[3] = abi.encodeWithSignature("setMinter(address)", recipient);
        calls[4] = abi.encodeWithSignature("upgradeTo(address)", recipient);
        calls[5] = abi.encodeWithSignature("initialize(address)", recipient);
        calls[6] = abi.encodeWithSignature("pause()");
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok, "unexpected administrative entry point");
        }
        (bool accepted,) = address(token).call{value: 1}("");
        assertFalse(accepted);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(holder), 1e27);
    }
}

/// @dev A closed set of holders makes conservation exact. No token deal/mint cheatcodes are used.
contract IdmTokenHandler is Test {
    SequencerToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor() {
        token = new SequencerToken();
        for (uint256 i; i < actors.length; ++i) {
            address actor = address(uint160(uint256(keccak256(abi.encode("IDM token actor", i)))));
            actors[i] = actor;
            expectedBalance[actor] = 1e27 / actors.length;
            token.transfer(actor, expectedBalance[actor]);
        }
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 amount) external {
        _approve(actors[ownerSeed % 4], actors[spenderSeed % 4], amount);
    }

    function transferFrom(uint8 fromSeed, uint8 spenderSeed, uint8 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = actors[toSeed % 4];
        uint256 allowed = expectedAllowance[from][spender];
        uint256 maximum = allowed < expectedBalance[from] ? allowed : expectedBalance[from];
        _spend(from, spender, to, bound(amountSeed, 0, maximum));
    }

    function approveAndSpend(uint8 fromSeed, uint8 spenderSeed, uint8 toSeed, uint256 amountSeed, bool unlimited)
        external
    {
        address from = actors[fromSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        _approve(from, spender, unlimited ? type(uint256).max : amount);
        _spend(from, spender, actors[toSeed % 4], amount);
    }

    function transferAll(uint8 fromSeed, uint8 toSeed) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = expectedBalance[from];
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function revokeAndReject(uint8 fromSeed, uint8 spenderSeed) external {
        address from = actors[fromSeed % 4];
        address spender = actors[spenderSeed % 4];
        _approve(from, spender, 0);
        vm.prank(spender);
        vm.expectRevert(SequencerToken.InsufficientAllowance.selector);
        token.transferFrom(from, spender, 1);
    }

    function rejectOverspend(uint8 fromSeed, uint8 toSeed) external {
        address from = actors[fromSeed % 4];
        vm.prank(from);
        vm.expectRevert(SequencerToken.InsufficientBalance.selector);
        token.transfer(actors[toSeed % 4], expectedBalance[from] + 1);
    }

    function rejectZeroRecipient(uint8 fromSeed, uint8 spenderSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        _approve(from, spender, amount);
        vm.prank(spender);
        vm.expectRevert(SequencerToken.ZeroAddress.selector);
        token.transferFrom(from, address(0), amount);
    }

    function _approve(address from, address spender, uint256 amount) internal {
        vm.prank(from);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[from][spender] = amount;
    }

    function _spend(address from, address spender, address to, uint256 amount) internal {
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (expectedAllowance[from][spender] != type(uint256).max) expectedAllowance[from][spender] -= amount;
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract SequencerTokenInvariantTest is Test {
    IdmTokenHandler internal handler;
    SequencerToken internal token;

    function setUp() public {
        handler = new IdmTokenHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.approveAndSpend.selector;
        selectors[4] = handler.transferAll.selector;
        selectors[5] = handler.revokeAndReject.selector;
        selectors[6] = handler.rejectOverspend.selector;
        selectors[7] = handler.rejectZeroRecipient.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_FixedSupplyAndEveryHolderMatchTheLedger() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 actual = token.balanceOf(actor);
            assertEq(actual, handler.expectedBalance(actor), "holder balance diverged");
            sum += actual;
        }
        assertEq(sum, 1e27);
        assertEq(token.totalSupply(), sum);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_AllowancesMatchApprovalsAndSuccessfulSpending() public view {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }
}
