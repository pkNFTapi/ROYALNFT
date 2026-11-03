// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ROYALNFTv2, IERC5192} from "../src/ROYALNFTv2.sol";

contract RejectsETH {
    function mintOn(ROYALNFTv2 nft) external returns (uint256) {
        return nft.mintNFTr("uri", 2 ether, 0, 5);
    }

    function withdrawTo(ROYALNFTv2 nft, address payable to) external {
        nft.withdraw(to);
    }
}

/// @dev Tries to pass a token straight on during the safeTransfer callback, to reuse the clearance.
contract PassesTokenOn is IERC721Receiver {
    bool public attemptReverted;

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        try ROYALNFTv2(msg.sender).transferFrom(address(this), address(0xdead), tokenId) {}
        catch {
            attemptReverted = true;
        }
        return this.onERC721Received.selector;
    }
}

contract ReentrantWithdrawer {
    ROYALNFTv2 nft;
    uint256 public calls;

    function mintOn(ROYALNFTv2 nft_) external returns (uint256) {
        nft = nft_;
        return nft_.mintNFTr("uri", 2 ether, 0, 5);
    }

    function pull() external {
        nft.withdraw(payable(address(this)));
    }

    receive() external payable {
        calls++;
        try nft.withdraw(payable(address(this))) {} catch {}
    }
}

contract ROYALNFTv2Test is Test {
    ROYALNFTv2 nft;
    address payable deployer = payable(makeAddr("deployer"));
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address market = makeAddr("market");

    // Same fixture as the V1 suite in pkNFTapi/considerations (ROYALNFTpass6.t.sol).
    uint256 constant DEPLOYER_FIXED = 1 ether;
    uint256 constant DEPLOYER_PCT = 10;
    uint256 constant CREATOR_FIXED = 0.1 ether;
    uint256 constant CREATOR_PCT = 5;
    uint256 constant FLOOR = DEPLOYER_FIXED + CREATOR_FIXED;

    function setUp() public {
        nft = new ROYALNFTv2(deployer, DEPLOYER_FIXED, DEPLOYER_PCT);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(creator, 100 ether);
        vm.deal(market, 100 ether);
    }

    function _mint(uint256 price) internal returns (uint256) {
        vm.prank(creator);
        return nft.mintNFTr("uri", price, CREATOR_FIXED, CREATOR_PCT);
    }

    function _notPaid(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ROYALNFTv2.RoyaltyNotPaid.selector, id);
    }

    // ---------------------------------------------------------------- soulbound while unpaid

    function test_mint_startsLocked() public {
        vm.expectEmit(true, true, true, true);
        emit IERC5192.Locked(1);
        uint256 id = _mint(0);
        assertTrue(nft.locked(id));
        assertEq(nft.ownerOf(id), creator);
    }

    function test_supportsERC5192() public view {
        assertEq(type(IERC5192).interfaceId, bytes4(0xb45a3c0e));
        assertTrue(nft.supportsInterface(0xb45a3c0e));
        assertTrue(nft.supportsInterface(0x80ac58cd)); // ERC-721
        assertFalse(nft.supportsInterface(0xffffffff));
    }

    function test_locked_revertsForUnknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        nft.locked(99);
    }

    function test_unpaid_transferFromReverts() public {
        uint256 id = _mint(0);
        vm.prank(creator);
        vm.expectRevert(_notPaid(id));
        nft.transferFrom(creator, alice, id);
    }

    function test_unpaid_safeTransferFromReverts() public {
        uint256 id = _mint(0);
        vm.startPrank(creator);
        vm.expectRevert(_notPaid(id));
        nft.safeTransferFrom(creator, alice, id);
        vm.expectRevert(_notPaid(id));
        nft.safeTransferFrom(creator, alice, id, "data");
        vm.stopPrank();
    }

    function test_unpaid_approvedOperatorsCannotMoveIt() public {
        uint256 id = _mint(0);
        vm.startPrank(creator);
        nft.approve(market, id);
        nft.setApprovalForAll(bob, true);
        vm.stopPrank();

        vm.prank(market);
        vm.expectRevert(_notPaid(id));
        nft.transferFrom(creator, market, id);

        vm.prank(bob);
        vm.expectRevert(_notPaid(id));
        nft.transferFrom(creator, bob, id);
    }

    function test_listing_doesNotUnlockForTransferFrom() public {
        uint256 id = _mint(2 ether);
        vm.prank(creator);
        vm.expectRevert(_notPaid(id));
        nft.transferFrom(creator, alice, id);
    }

    function testFuzz_unpaid_noCallerOrRecipientCanMoveIt(address caller, address to) public {
        vm.assume(to != address(0));
        uint256 id = _mint(0);
        vm.prank(caller);
        vm.expectRevert();
        nft.transferFrom(creator, to, id);
        assertEq(nft.ownerOf(id), creator);
    }

    // ---------------------------------------------------------------- brokerNFT

    function test_broker_splitsAndTransfers() public {
        uint256 id = _mint(2 ether);

        vm.expectEmit(true, true, true, true);
        emit ROYALNFTv2.Sold(id, creator, alice, 2 ether);
        vm.prank(alice);
        nft.brokerNFT{value: 2 ether}(id);

        assertEq(nft.ownerOf(id), alice);
        assertEq(nft.pendingWithdrawals(deployer), 1 ether); // max(1, 10% of 2)
        assertEq(nft.pendingWithdrawals(creator), 1 ether); // royalty 0.1 + seller 0.9
        assertEq(address(nft).balance, 2 ether);
    }

    function test_broker_buyerHoldsLockedDelistedToken() public {
        uint256 id = _mint(2 ether);
        vm.prank(alice);
        nft.brokerNFT{value: 2 ether}(id);

        assertTrue(nft.locked(id));
        assertEq(nft.getSalePrice(id), 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.NotForSale.selector, id));
        nft.brokerNFT{value: 2 ether}(id);

        vm.prank(alice);
        vm.expectRevert(_notPaid(id));
        nft.transferFrom(alice, bob, id);
    }

    /// @dev testMultipleTransfers from ROYALNFTpass6.t.sol, same prices and same expected amounts.
    function test_lineage_multipleTransfers_matchV1Figures() public {
        uint256 id = _mint(1 ether + 0.1 ether);
        vm.prank(creator);
        nft.setSalePrice(id, 2 ether);

        vm.prank(alice);
        nft.brokerNFT{value: 2 ether}(id);
        assertEq(nft.ownerOf(id), alice);
        assertEq(nft.pendingWithdrawals(deployer), 1 ether);
        assertEq(nft.pendingWithdrawals(creator), 1 ether);

        vm.prank(alice);
        nft.setSalePrice(id, 3 ether);
        vm.prank(bob);
        nft.brokerNFT{value: 3 ether}(id);

        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.pendingWithdrawals(deployer), 2 ether);
        assertEq(nft.pendingWithdrawals(creator), 1.15 ether);
        assertEq(nft.pendingWithdrawals(alice), 1.85 ether);
    }

    function test_broker_rejectsWrongPayment() public {
        uint256 id = _mint(2 ether);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.IncorrectPayment.selector, 1 ether, 2 ether));
        nft.brokerNFT{value: 1 ether}(id);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.IncorrectPayment.selector, 3 ether, 2 ether));
        nft.brokerNFT{value: 3 ether}(id);
        vm.stopPrank();
    }

    function test_broker_unlistedTokenCannotBeTaken_evenWithNoFees() public {
        ROYALNFTv2 free = new ROYALNFTv2(deployer, 0, 0);
        vm.prank(creator);
        uint256 id = free.mintNFTr("uri", 0, 0, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.NotForSale.selector, id));
        free.brokerNFT{value: 0}(id);
    }

    function test_broker_ownerCannotBuyOwnToken() public {
        uint256 id = _mint(2 ether);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.BuyerIsOwner.selector, id));
        nft.brokerNFT{value: 2 ether}(id);
    }

    function test_broker_clearsStaleApproval() public {
        uint256 id = _mint(2 ether);
        vm.prank(creator);
        nft.approve(market, id);
        vm.prank(alice);
        nft.brokerNFT{value: 2 ether}(id);
        assertEq(nft.getApproved(id), address(0));
    }

    // ---------------------------------------------------------------- setSalePrice

    function test_setSalePrice_onlyOwner() public {
        uint256 id = _mint(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.NotTokenOwner.selector, id, alice));
        nft.setSalePrice(id, 2 ether);
    }

    function test_setSalePrice_rejectsPriceBelowRoyalty() public {
        uint256 id = _mint(0);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.PriceBelowRoyalty.selector, 1 ether, FLOOR));
        nft.setSalePrice(id, 1 ether);
    }

    function test_mint_rejectsPriceBelowRoyalty() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.PriceBelowRoyalty.selector, 1 ether, FLOOR));
        nft.mintNFTr("uri", 1 ether, CREATOR_FIXED, CREATOR_PCT);
    }

    function test_setSalePrice_zeroDelists() public {
        uint256 id = _mint(2 ether);
        vm.prank(creator);
        nft.setSalePrice(id, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.NotForSale.selector, id));
        nft.brokerNFT{value: 0}(id);
    }

    // ---------------------------------------------------------------- payRoyalty

    function test_payRoyalty_giftPaysFixedFloorAndBuysOneTransfer() public {
        uint256 id = _mint(0);

        vm.expectEmit(true, true, true, true);
        emit IERC5192.Unlocked(id);
        vm.prank(creator);
        nft.payRoyalty{value: FLOOR}(id, 0);
        assertFalse(nft.locked(id));

        vm.prank(creator);
        vm.expectEmit(true, true, true, true);
        emit IERC5192.Locked(id);
        nft.transferFrom(creator, alice, id);

        assertEq(nft.ownerOf(id), alice);
        assertTrue(nft.locked(id));
        assertEq(nft.pendingWithdrawals(deployer), DEPLOYER_FIXED);
        assertEq(nft.pendingWithdrawals(creator), CREATOR_FIXED);

        vm.prank(alice);
        vm.expectRevert(_notPaid(id));
        nft.transferFrom(alice, bob, id);
    }

    function test_paidToken_strangerStillCannotTakeIt() public {
        uint256 id = _mint(0);
        vm.prank(creator);
        nft.payRoyalty{value: FLOOR}(id, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, alice, id));
        nft.transferFrom(creator, alice, id);

        assertEq(nft.ownerOf(id), creator);
        assertFalse(nft.locked(id), "the failed attempt did not spend the clearance");
    }

    function test_payRoyalty_declaredPriceAppliesPercentage() public {
        uint256 id = _mint(0);
        (uint256 d, uint256 c) = nft.royaltyDue(id, 100 ether);
        assertEq(d, 10 ether);
        assertEq(c, 5 ether);

        vm.prank(creator);
        nft.payRoyalty{value: 15 ether}(id, 100 ether);
        assertEq(nft.pendingWithdrawals(deployer), 10 ether);
        assertEq(nft.pendingWithdrawals(creator), 5 ether);
    }

    function test_payRoyalty_rejectsWrongAmount() public {
        uint256 id = _mint(0);
        vm.startPrank(creator);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.IncorrectPayment.selector, FLOOR - 1, FLOOR));
        nft.payRoyalty{value: FLOOR - 1}(id, 0);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.IncorrectPayment.selector, FLOOR + 1, FLOOR));
        nft.payRoyalty{value: FLOOR + 1}(id, 0);
        vm.stopPrank();
    }

    function test_payRoyalty_strangerCannotUnlockSomeoneElsesToken() public {
        uint256 id = _mint(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.NotAuthorized.selector, id, alice));
        nft.payRoyalty{value: FLOOR}(id, 0);
    }

    function test_payRoyalty_approvedMarketplaceFlow() public {
        uint256 id = _mint(0);
        vm.prank(creator);
        nft.setApprovalForAll(market, true);

        vm.startPrank(market);
        nft.payRoyalty{value: FLOOR}(id, 0);
        nft.transferFrom(creator, bob, id);
        vm.stopPrank();

        assertEq(nft.ownerOf(id), bob);
        assertTrue(nft.locked(id));
    }

    function test_payRoyalty_cannotPayTwiceOrWhileListed() public {
        uint256 listed = _mint(2 ether);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.TokenIsListed.selector, listed));
        nft.payRoyalty{value: FLOOR}(listed, 0);

        uint256 id = _mint(0);
        vm.startPrank(creator);
        nft.payRoyalty{value: FLOOR}(id, 0);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.AlreadyCleared.selector, id));
        nft.payRoyalty{value: FLOOR}(id, 0);
        vm.stopPrank();
    }

    function test_payRoyalty_clearedTokenCannotBeListed() public {
        uint256 id = _mint(0);
        vm.startPrank(creator);
        nft.payRoyalty{value: FLOOR}(id, 0);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.AlreadyCleared.selector, id));
        nft.setSalePrice(id, 2 ether);
        vm.stopPrank();
    }

    function test_payRoyalty_clearanceCannotBeSpentTwiceInSafeTransferCallback() public {
        PassesTokenOn receiver = new PassesTokenOn();
        uint256 id = _mint(0);

        vm.startPrank(creator);
        nft.payRoyalty{value: FLOOR}(id, 0);
        nft.safeTransferFrom(creator, address(receiver), id);
        vm.stopPrank();

        assertTrue(receiver.attemptReverted());
        assertEq(nft.ownerOf(id), address(receiver));
        assertTrue(nft.locked(id));
    }

    function test_zeroRoyaltyToken_stillNeedsExplicitClearance() public {
        ROYALNFTv2 free = new ROYALNFTv2(deployer, 0, 0);
        vm.startPrank(creator);
        uint256 id = free.mintNFTr("uri", 0, 0, 0);
        vm.expectRevert(_notPaid(id));
        free.transferFrom(creator, alice, id);
        free.payRoyalty{value: 0}(id, 0);
        free.transferFrom(creator, alice, id);
        vm.stopPrank();
        assertEq(free.ownerOf(id), alice);
    }

    // ---------------------------------------------------------------- pull payments

    function test_withdraw_paysOutAndZeroes() public {
        uint256 id = _mint(2 ether);
        vm.prank(alice);
        nft.brokerNFT{value: 2 ether}(id);

        uint256 before = creator.balance;
        vm.prank(creator);
        nft.withdraw(payable(creator));
        assertEq(creator.balance, before + 1 ether);
        assertEq(nft.pendingWithdrawals(creator), 0);

        vm.prank(creator);
        vm.expectRevert(ROYALNFTv2.NothingToWithdraw.selector);
        nft.withdraw(payable(creator));
    }

    function test_withdraw_refusesZeroAddress() public {
        uint256 id = _mint(2 ether);
        vm.prank(alice);
        nft.brokerNFT{value: 2 ether}(id);

        vm.prank(creator);
        vm.expectRevert(ROYALNFTv2.ZeroAddress.selector);
        nft.withdraw(payable(address(0)));
        assertEq(nft.pendingWithdrawals(creator), 1 ether);
    }

    function test_hostileCreatorCannotBlockSale_andCanRedirectFunds() public {
        RejectsETH hostile = new RejectsETH();
        uint256 id = hostile.mintOn(nft);

        vm.prank(alice);
        nft.brokerNFT{value: 2 ether}(id);
        assertEq(nft.ownerOf(id), alice, "sale completed despite payee rejecting ETH");

        vm.expectRevert(ROYALNFTv2.WithdrawFailed.selector);
        hostile.withdrawTo(nft, payable(address(hostile)));
        assertGt(nft.pendingWithdrawals(address(hostile)), 0, "failed withdrawal keeps the balance");

        hostile.withdrawTo(nft, payable(bob));
        assertEq(nft.pendingWithdrawals(address(hostile)), 0);
    }

    function test_withdraw_reentryGetsNothingExtra() public {
        ReentrantWithdrawer attacker = new ReentrantWithdrawer();
        uint256 id = attacker.mintOn(nft);
        uint256 otherFunds = 1 ether; // deployer's royalty stays in the contract as the bait

        vm.prank(alice);
        nft.brokerNFT{value: 2 ether}(id);

        attacker.pull();

        assertEq(attacker.calls(), 1);
        assertEq(address(attacker).balance, 1 ether);
        assertEq(address(nft).balance, otherFunds);
        assertEq(nft.pendingWithdrawals(deployer), otherFunds);
    }

    // ---------------------------------------------------------------- configuration

    function test_constructor_validates() public {
        vm.expectRevert(ROYALNFTv2.ZeroAddress.selector);
        new ROYALNFTv2(payable(address(0)), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.PercentTooHigh.selector, 101));
        new ROYALNFTv2(deployer, 0, 101);
    }

    function test_mint_rejectsCombinedPercentOver100() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ROYALNFTv2.PercentTooHigh.selector, 101));
        nft.mintNFTr("uri", 0, 0, 91);
    }

    function test_creatorIsFixedAtMint() public {
        uint256 id = _mint(2 ether);
        vm.prank(alice);
        nft.brokerNFT{value: 2 ether}(id);

        ROYALNFTv2.RoyaltyInfo memory info = nft.getRoyaltyInfo(id);
        assertEq(info.creator, creator);
        assertEq(info.creatorFixedRoyalty, CREATOR_FIXED);
        assertEq(info.creatorPercentRoyalty, CREATOR_PCT);
    }

    function test_tokenURI_survivesTransfer() public {
        uint256 id = _mint(2 ether);
        vm.prank(alice);
        nft.brokerNFT{value: 2 ether}(id);
        assertEq(nft.tokenURI(id), "uri");
    }

    // ---------------------------------------------------------------- properties

    function testFuzz_calculateRoyalty_isGreaterOfFixedAndPercent(uint128 price, uint128 fixedAmt, uint8 pct) public view {
        uint256 got = nft.calculateRoyaltyPublic(price, fixedAmt, pct);
        uint256 byPct = (uint256(price) * pct) / 100;
        assertEq(got, fixedAmt > byPct ? fixedAmt : byPct);
    }

    function testFuzz_broker_conservesValue(uint96 price, uint96 creatorFixed, uint8 creatorPct) public {
        creatorPct = uint8(bound(creatorPct, 0, 90));
        uint256 minimum = FLOOR + creatorFixed;
        vm.assume(price >= minimum);

        vm.prank(creator);
        try nft.mintNFTr("uri", price, creatorFixed, creatorPct) returns (uint256 id) {
            vm.deal(alice, price);
            vm.prank(alice);
            nft.brokerNFT{value: price}(id);
            assertEq(
                nft.pendingWithdrawals(deployer) + nft.pendingWithdrawals(creator), uint256(price), "every wei credited"
            );
            assertEq(nft.ownerOf(id), alice);
            assertTrue(nft.locked(id));
        } catch (bytes memory reason) {
            // Only acceptable refusal: the royalty really does exceed the price.
            assertEq(bytes4(reason), ROYALNFTv2.PriceBelowRoyalty.selector);
        }
    }
}

/// @dev Random actors drive the contract; the invariants below must hold after every call.
contract Handler is Test {
    ROYALNFTv2 public nft;
    address[] public actors;
    uint256[] public ids;
    uint256 public royaltyPayments;
    uint256 public movesObserved;
    uint256 public unpaidMoves;

    constructor(ROYALNFTv2 nft_, address[] memory actors_) {
        nft = nft_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _id(uint256 s) internal view returns (uint256) {
        return ids[s % ids.length];
    }

    function mint(uint256 who, uint96 price, uint96 fixedAmt, uint8 pct) external {
        vm.prank(_actor(who));
        try nft.mintNFTr("uri", price, fixedAmt % 1 ether, pct % 50) returns (uint256 id) {
            ids.push(id);
        } catch {}
    }

    function list(uint256 which, uint96 price) external {
        if (ids.length == 0) return;
        uint256 id = _id(which);
        vm.prank(nft.ownerOf(id));
        try nft.setSalePrice(id, price) {} catch {}
    }

    function buy(uint256 who, uint256 which) external {
        if (ids.length == 0) return;
        uint256 id = _id(which);
        address buyer = _actor(who);
        uint256 price = nft.getSalePrice(id);
        vm.deal(buyer, price);
        vm.prank(buyer);
        try nft.brokerNFT{value: price}(id) {
            royaltyPayments++;
            movesObserved++;
        } catch {}
    }

    function pay(uint256 which, uint96 declared) external {
        if (ids.length == 0) return;
        uint256 id = _id(which);
        address owner = nft.ownerOf(id);
        (uint256 d, uint256 c) = nft.royaltyDue(id, declared);
        vm.deal(owner, d + c);
        vm.prank(owner);
        try nft.payRoyalty{value: d + c}(id, declared) {
            royaltyPayments++;
        } catch {}
    }

    function tryTransfer(uint256 which, uint256 to) external {
        if (ids.length == 0) return;
        uint256 id = _id(which);
        address owner = nft.ownerOf(id);
        bool wasLocked = nft.locked(id);
        vm.prank(owner);
        try nft.transferFrom(owner, _actor(to), id) {
            movesObserved++;
            if (wasLocked) unpaidMoves++;
        } catch {}
    }

    function withdraw(uint256 who) external {
        address a = _actor(who);
        vm.prank(a);
        try nft.withdraw(payable(a)) {} catch {}
    }
}

contract ROYALNFTv2InvariantTest is Test {
    ROYALNFTv2 nft;
    Handler handler;
    address[] actors;
    address payable deployer = payable(makeAddr("deployer"));

    function setUp() public {
        nft = new ROYALNFTv2(deployer, 0.01 ether, 5);
        actors.push(deployer);
        actors.push(makeAddr("a"));
        actors.push(makeAddr("b"));
        actors.push(makeAddr("c"));
        handler = new Handler(nft, actors);
        targetContract(address(handler));
    }

    /// @dev The whole point of the contract: a locked token never moved.
    function invariant_noTransferWithoutPayment() public view {
        assertEq(handler.unpaidMoves(), 0);
    }

    /// @dev Each move spends one payment, so moves can never outnumber payments.
    function invariant_movesNeverExceedPayments() public view {
        assertLe(handler.movesObserved(), handler.royaltyPayments());
    }

    /// @dev The contract always holds exactly what it owes.
    function invariant_solvent() public view {
        uint256 owed;
        for (uint256 i; i < actors.length; i++) {
            owed += nft.pendingWithdrawals(actors[i]);
        }
        assertEq(address(nft).balance, owed);
    }
}
