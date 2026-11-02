// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

/// @dev ERC-5192 minimal soulbound interface. Wallets and indexers read `locked` to show the state.
interface IERC5192 {
    event Locked(uint256 tokenId);
    event Unlocked(uint256 tokenId);

    function locked(uint256 tokenId) external view returns (bool);
}

/**
 * @title ROYALNFTv2
 * @notice Every token is soulbound until its royalty is paid. Paying buys exactly one transfer;
 *         the token locks again in the hands of whoever receives it.
 *
 * Two ways to pay, and no other way to move a token:
 *  - `brokerNFT`:  buyer pays the listed price. Royalty, split and transfer happen atomically.
 *  - `payRoyalty`: owner pays on a declared price, for gifts, wallet moves and outside venues.
 *
 * There is no owner and no admin function. Royalty terms cannot change after they are set.
 *
 * @dev The rule lives in `_update`, the single path every OpenZeppelin ERC-721 transfer goes
 *      through, so `transferFrom`, `safeTransferFrom` and approved operators are all covered.
 */
contract ROYALNFTv2 is ERC721URIStorage, IERC5192 {
    uint256 private _tokenIds;

    address payable public immutable deployer;
    uint256 public immutable deployerFixedRoyalty;
    uint256 public immutable deployerPercentRoyalty;

    struct RoyaltyInfo {
        address payable creator;
        uint256 creatorFixedRoyalty;
        uint256 creatorPercentRoyalty;
    }

    /// @dev Zero means not for sale. V1 treated zero as a price, so an unpriced token could be taken.
    mapping(uint256 => uint256) private _salePrices;
    mapping(uint256 => RoyaltyInfo) private _royalties;

    /// @dev True once a royalty is paid and until the one transfer it bought has happened.
    mapping(uint256 => bool) private _cleared;

    /// @notice ETH each address can collect through `withdraw`.
    mapping(address => uint256) public pendingWithdrawals;

    event Minted(uint256 tokenId, address creator, uint256 salePrice);
    event Sold(uint256 tokenId, address from, address to, uint256 salePrice);
    event SalePriceSet(uint256 indexed tokenId, uint256 salePrice);
    event RoyaltyPaid(
        uint256 indexed tokenId,
        address indexed payer,
        uint256 declaredPrice,
        uint256 deployerRoyalty,
        uint256 creatorRoyalty
    );
    event Withdrawn(address indexed payee, address indexed to, uint256 amount);

    error ZeroAddress();
    error PercentTooHigh(uint256 totalPercent);
    error PriceBelowRoyalty(uint256 price, uint256 royalty);
    error RoyaltyNotPaid(uint256 tokenId);
    error NotTokenOwner(uint256 tokenId, address caller);
    error NotAuthorized(uint256 tokenId, address caller);
    error NotForSale(uint256 tokenId);
    error BuyerIsOwner(uint256 tokenId);
    error IncorrectPayment(uint256 sent, uint256 required);
    error AlreadyCleared(uint256 tokenId);
    error TokenIsListed(uint256 tokenId);
    error NothingToWithdraw();
    error WithdrawFailed();

    /**
     * @param deployer_ Receives the deployer royalty. Passed explicitly so a deterministic
     *        deployment factory cannot end up as the payee.
     * @param _deployerFixedRoyalty Minimum deployer royalty per transfer, in wei.
     * @param _deployerPercentRoyalty Deployer royalty as a whole percent of the price.
     */
    constructor(address payable deployer_, uint256 _deployerFixedRoyalty, uint256 _deployerPercentRoyalty)
        ERC721("Royal NFT", "ROYALNFT")
    {
        if (deployer_ == address(0)) revert ZeroAddress();
        if (_deployerPercentRoyalty > 100) revert PercentTooHigh(_deployerPercentRoyalty);
        deployer = deployer_;
        deployerFixedRoyalty = _deployerFixedRoyalty;
        deployerPercentRoyalty = _deployerPercentRoyalty;
    }

    /**
     * @notice Mint a token to the caller, who becomes its creator. It starts soulbound.
     * @param salePriceETH Listing price in wei, or zero to leave it unlisted.
     */
    function mintNFTr(
        string memory tokenURI_,
        uint256 salePriceETH,
        uint256 _creatorFixedRoyalty,
        uint256 _creatorPercentRoyalty
    ) public returns (uint256) {
        uint256 totalPercent = deployerPercentRoyalty + _creatorPercentRoyalty;
        if (totalPercent > 100) revert PercentTooHigh(totalPercent);

        uint256 newItemId = ++_tokenIds;
        _royalties[newItemId] = RoyaltyInfo({
            creator: payable(msg.sender),
            creatorFixedRoyalty: _creatorFixedRoyalty,
            creatorPercentRoyalty: _creatorPercentRoyalty
        });
        _requireCoversRoyalty(newItemId, salePriceETH);
        _salePrices[newItemId] = salePriceETH;

        _mint(msg.sender, newItemId);
        _setTokenURI(newItemId, tokenURI_);

        emit Locked(newItemId);
        emit Minted(newItemId, msg.sender, salePriceETH);
        return newItemId;
    }

    /// @notice List the token, or pass zero to delist it. A token with a paid royalty cannot be listed.
    function setSalePrice(uint256 tokenId, uint256 salePriceETH) public {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId, msg.sender);
        if (salePriceETH != 0 && _cleared[tokenId]) revert AlreadyCleared(tokenId);
        _requireCoversRoyalty(tokenId, salePriceETH);
        _salePrices[tokenId] = salePriceETH;
        emit SalePriceSet(tokenId, salePriceETH);
    }

    /// @notice Buy a listed token for exactly its price. Payees collect through `withdraw`.
    function brokerNFT(uint256 tokenId) public payable {
        address seller = ownerOf(tokenId);
        uint256 salePrice = _salePrices[tokenId];

        if (salePrice == 0) revert NotForSale(tokenId);
        if (msg.sender == seller) revert BuyerIsOwner(tokenId);
        if (msg.value != salePrice) revert IncorrectPayment(msg.value, salePrice);

        (uint256 deployerRoyalty, uint256 creatorRoyalty) = _creditRoyalty(tokenId, salePrice);
        pendingWithdrawals[seller] += salePrice - deployerRoyalty - creatorRoyalty;

        _clear(tokenId);
        _transfer(seller, msg.sender, tokenId);

        emit Sold(tokenId, seller, msg.sender, salePrice);
    }

    /**
     * @notice Pay the royalty directly and unlock the token for one transfer.
     * @dev A listed token must be delisted first, and a cleared token cannot be listed, so one
     *      ownership change is never charged twice. The payment is not refundable.
     *
     *      `declaredPrice` is the caller's own statement, so the percentage cannot be enforced on
     *      this path. The fixed royalty is the floor that holds whatever is declared.
     * @param declaredPrice Value of the transfer in wei. Zero for a gift, which pays the fixed floor.
     */
    function payRoyalty(uint256 tokenId, uint256 declaredPrice) public payable {
        address owner = ownerOf(tokenId);
        if (!_isAuthorized(owner, msg.sender, tokenId)) revert NotAuthorized(tokenId, msg.sender);
        if (_cleared[tokenId]) revert AlreadyCleared(tokenId);
        if (_salePrices[tokenId] != 0) revert TokenIsListed(tokenId);

        (uint256 deployerDue, uint256 creatorDue) = royaltyDue(tokenId, declaredPrice);
        uint256 due = deployerDue + creatorDue;
        if (msg.value != due) revert IncorrectPayment(msg.value, due);

        _creditRoyalty(tokenId, declaredPrice);
        _clear(tokenId);
    }

    /// @notice Collect the caller's balance and send it to `to`.
    /// @dev Pull payments mean a payee that rejects ETH cannot block a sale, as it could in V1.
    function withdraw(address payable to) public {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        delete pendingWithdrawals[msg.sender];
        emit Withdrawn(msg.sender, to, amount);

        (bool success,) = to.call{value: amount}("");
        if (!success) revert WithdrawFailed();
    }

    /// @notice False only while a paid royalty is waiting for its transfer.
    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return !_cleared[tokenId];
    }

    /// @notice Royalty owed on a transfer of this token at `price`.
    function royaltyDue(uint256 tokenId, uint256 price)
        public
        view
        returns (uint256 deployerRoyalty, uint256 creatorRoyalty)
    {
        _requireOwned(tokenId);
        RoyaltyInfo storage info = _royalties[tokenId];
        deployerRoyalty = calculateRoyalty(price, deployerFixedRoyalty, deployerPercentRoyalty);
        creatorRoyalty = calculateRoyalty(price, info.creatorFixedRoyalty, info.creatorPercentRoyalty);
    }

    function getRoyaltyInfo(uint256 tokenId) public view returns (RoyaltyInfo memory) {
        _requireOwned(tokenId);
        return _royalties[tokenId];
    }

    function getSalePrice(uint256 tokenId) public view returns (uint256) {
        return _salePrices[tokenId];
    }

    function calculateRoyaltyPublic(uint256 salePrice, uint256 fixedRoyalty, uint256 percentRoyalty)
        public
        pure
        returns (uint256)
    {
        return calculateRoyalty(salePrice, fixedRoyalty, percentRoyalty);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IERC5192).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev The greater of the fixed amount and the percentage of the price, as in V1.
    function calculateRoyalty(uint256 salePrice, uint256 fixedRoyalty, uint256 percentRoyalty)
        internal
        pure
        returns (uint256)
    {
        uint256 percentRoyaltyAmount = (salePrice * percentRoyalty) / 100;
        return fixedRoyalty > percentRoyaltyAmount ? fixedRoyalty : percentRoyaltyAmount;
    }

    /// @dev The soulbound rule. Minting is free; any other move spends the clearance or reverts.
    ///      The clearance is spent before `safeTransferFrom` calls the recipient, so the recipient
    ///      holds a locked token by the time its `onERC721Received` runs.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) {
            if (!_cleared[tokenId]) revert RoyaltyNotPaid(tokenId);
            delete _cleared[tokenId];
            delete _salePrices[tokenId];
            emit Locked(tokenId);
        }
        return super._update(to, tokenId, auth);
    }

    function _clear(uint256 tokenId) private {
        _cleared[tokenId] = true;
        emit Unlocked(tokenId);
    }

    function _creditRoyalty(uint256 tokenId, uint256 price)
        private
        returns (uint256 deployerRoyalty, uint256 creatorRoyalty)
    {
        (deployerRoyalty, creatorRoyalty) = royaltyDue(tokenId, price);
        pendingWithdrawals[deployer] += deployerRoyalty;
        pendingWithdrawals[_royalties[tokenId].creator] += creatorRoyalty;
        emit RoyaltyPaid(tokenId, msg.sender, price, deployerRoyalty, creatorRoyalty);
    }

    /// @dev Replaces V1's underflow panic: a price that cannot cover the royalty is refused up front.
    function _requireCoversRoyalty(uint256 tokenId, uint256 price) private view {
        if (price == 0) return;
        RoyaltyInfo storage info = _royalties[tokenId];
        uint256 royalty = calculateRoyalty(price, deployerFixedRoyalty, deployerPercentRoyalty)
            + calculateRoyalty(price, info.creatorFixedRoyalty, info.creatorPercentRoyalty);
        if (price < royalty) revert PriceBelowRoyalty(price, royalty);
    }
}
