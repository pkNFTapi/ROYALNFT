// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ROYALNFT} from "royalnft-v1/ROYALNFT.sol";

contract RejectsETH {
    function mintOn(ROYALNFT nft) external returns (uint256) {
        return nft.mintNFTr("uri", 2 ether, 0, 5);
    }

    function sell(ROYALNFT nft, uint256 id, address to) external {
        nft.transferFrom(address(this), to, id);
    }
}

/// @notice Records what the untouched V1 contract does. Each passing test is a behaviour V2 changes.
contract ROYALNFTv1BaselineTest is Test {
    ROYALNFT nft;
    address deployer = makeAddr("deployer");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.prank(deployer);
        nft = new ROYALNFT(1 ether, 10);
    }

    function test_v1_transferFromSkipsRoyaltyEntirely() public {
        vm.prank(creator);
        uint256 id = nft.mintNFTr("uri", 2 ether, 0.1 ether, 5);

        vm.prank(creator);
        nft.transferFrom(creator, alice, id);

        assertEq(nft.ownerOf(id), alice);
        assertEq(deployer.balance, 0, "deployer was paid nothing");
        assertEq(creator.balance, 0, "creator was paid nothing");
    }

    function test_v1_priceSurvivesSale_soBuyerCanBeBoughtOutAtOnce() public {
        vm.prank(creator);
        uint256 id = nft.mintNFTr("uri", 2 ether, 0.1 ether, 5);
        vm.deal(alice, 2 ether);
        vm.deal(bob, 2 ether);

        vm.prank(alice);
        nft.brokerNFT{value: 2 ether}(id);
        vm.prank(bob);
        nft.brokerNFT{value: 2 ether}(id);

        assertEq(nft.ownerOf(id), bob, "alice lost the token without choosing to sell");
        assertEq(alice.balance, 0.9 ether, "alice paid 2, got back 0.9");
    }

    function test_v1_creatorThatRejectsETH_blocksEverySale() public {
        RejectsETH hostile = new RejectsETH();
        uint256 id = hostile.mintOn(nft);
        hostile.sell(nft, id, alice);

        vm.prank(alice);
        nft.setSalePrice(id, 2 ether);
        vm.deal(bob, 2 ether);

        vm.prank(bob);
        vm.expectRevert("Transfer to creator failed");
        nft.brokerNFT{value: 2 ether}(id);
    }

    function test_v1_unpricedTokenIsFreeWhenDeployerFeesAreZero() public {
        vm.prank(deployer);
        ROYALNFT free = new ROYALNFT(0, 0);
        vm.prank(creator);
        uint256 id = free.mintNFTr("uri", 0, 0, 0);

        vm.prank(alice);
        free.brokerNFT{value: 0}(id);

        assertEq(free.ownerOf(id), alice, "anyone took the token for nothing");
    }
}
