// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract ROYAL1155 is ERC1155, Ownable, ReentrancyGuard {
    uint256 private _tokenIds;

    address payable public immutable deployer;
    uint256 public immutable deployerFixedRoyalty;
    uint256 public immutable deployerPercentRoyalty;

    struct TokenSaleInfo {
        uint256 salePriceETH;
    }

    struct RoyaltyInfo {
        address payable creator;
        uint256 creatorFixedRoyalty;
        uint256 creatorPercentRoyalty;
    }

    mapping(uint256 => TokenSaleInfo) private tokenSalePrices;
    mapping(uint256 => RoyaltyInfo) private royalties;

    event Minted(uint256 tokenId, address creator, uint256 salePrice);
    event Sold(uint256 tokenId, address from, address to, uint256 salePrice);

    constructor(
        string memory uri,
        uint256 _deployerFixedRoyalty,
        uint256 _deployerPercentRoyalty
    ) ERC1155(uri) Ownable(msg.sender) { // Pass msg.sender as the argument to Ownable
        deployer = payable(msg.sender);
        deployerFixedRoyalty = _deployerFixedRoyalty;
        deployerPercentRoyalty = _deployerPercentRoyalty;
    }

    function mintRoyal(
        address recipient,
        uint256 amount,
        string memory tokenURI,
        uint256 salePriceETH,
        uint256 _creatorFixedRoyalty,
        uint256 _creatorPercentRoyalty
    ) public returns (uint256) {
        _tokenIds++;
        uint256 newItemId = _tokenIds;

        _mint(recipient, newItemId, amount, "");
        _setURI(newItemId, tokenURI);

        tokenSalePrices[newItemId] = TokenSaleInfo({
            salePriceETH: salePriceETH
        });

        royalties[newItemId] = RoyaltyInfo({
            creator: payable(msg.sender),
            creatorFixedRoyalty: _creatorFixedRoyalty,
            creatorPercentRoyalty: _creatorPercentRoyalty
        });

        emit Minted(newItemId, msg.sender, salePriceETH);

        return newItemId;
    }

    function setSalePrice(uint256 tokenId, uint256 salePriceETH) public {
        require(balanceOf(msg.sender, tokenId) > 0, "Only the owner can set the sale price");
        tokenSalePrices[tokenId].salePriceETH = salePriceETH;
    }

    function brokerRoyal(uint256 tokenId, uint256 amount) public payable nonReentrant {
        TokenSaleInfo memory saleInfo = tokenSalePrices[tokenId];
        RoyaltyInfo memory royaltyInfo = royalties[tokenId];
        address seller = msg.sender;
        uint256 salePrice = saleInfo.salePriceETH * amount;

        require(msg.value == salePrice, "Incorrect sale price");

        uint256 deployerRoyalty = calculateRoyalty(salePrice, deployerFixedRoyalty, deployerPercentRoyalty);
        uint256 creatorRoyalty = calculateRoyalty(salePrice, royaltyInfo.creatorFixedRoyalty, royaltyInfo.creatorPercentRoyalty);
        uint256 totalRoyaltyAmount = deployerRoyalty + creatorRoyalty;
        uint256 sellerAmount = salePrice - totalRoyaltyAmount;

        safeTransferFrom(seller, msg.sender, tokenId, amount, "");

        (bool successDeployer, ) = deployer.call{value: deployerRoyalty}("");
        require(successDeployer, "Transfer to deployer failed");

        (bool successCreator, ) = royaltyInfo.creator.call{value: creatorRoyalty}("");
        require(successCreator, "Transfer to creator failed");

        (bool successSeller, ) = payable(seller).call{value: sellerAmount}("");
        require(successSeller, "Transfer to seller failed");

        emit Sold(tokenId, seller, msg.sender, salePrice);
    }

    function calculateRoyalty(uint256 salePrice, uint256 fixedRoyalty, uint256 percentRoyalty) internal pure returns (uint256) {
        uint256 percentRoyaltyAmount = (salePrice * percentRoyalty) / 100;
        return fixedRoyalty > percentRoyaltyAmount ? fixedRoyalty : percentRoyaltyAmount;
    }

    function _setURI(uint256 tokenId, string memory tokenURI) internal virtual {
        // Placeholder for setting URI per tokenId if needed
    }
}
