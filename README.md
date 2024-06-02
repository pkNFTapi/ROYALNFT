# ROYALNFT
immutable erc-721 NFT creator royalty broker with built in marketplace as owner controlled sale price<br /> 
empowering creators as owners<br />

The ROYALNFT.sol contract effectively enables a decentralized marketplace for unique digital assets using the ERC721 standard. It emphasizes the role of every owner as an active participant in the marketplace one mint away from becoming a creator.  Included within the asset is the capability to set the sale price as a decentralized event. 

# utility and functions:

The ROYALNFT contract is an EVM-based smart contract developed for handling ERC721 tokens which represent unique data assets. OpenZeppelin libraries are used to ensure robust security and functionality. This contract integrates features such as token minting, dynamic pricing, secure sales transactions, and royalty distributions, catering to a decentralized marketplace where creators and deployers can derive ongoing value from secondary sales. Here is an external documentation detailing the structure and utility of the ROYALNFT contract:

# Utility and Use Cases

ROYALNFT is particularly suited for digital marketplaces dealing in unique digital assets incluing data collections and other digital commodoties. ROYALNFT provides artists and creators with a platform to monetize their through initial sales with the option of an ongoing royalties from subsequent transactions. The secure and decentralized trading mechanism empowers owners as creators maintaining the integrity of transactions facilitating a robust digital economy around data transfer.

# Utility of the Contract

    Royalty System: Ensures creators and deployers earn from each asset sale, supporting a sustainable revenue model that incentivizes ongoing creation and participation. This is especially useful in markets where assets like data sets or creative prompts are continually reused and retain intrinsic value.

    Decentralized Trading: Allows NFT owners to act as exchange agents who directly manage sales and negotiations within the asset framework, eliminating the need for intermediary brokers and central platforms.

# Contract Summary

1. ERC721URIStorage Extension:

    The contract extends ERC721URIStorage, an ERC721 token implementation that includes methods for storing and managing token URI metadata. This feature is crucial for linking each token to a unique set of metadata that describes the digital asset.

2. Ownership and Security:

    Ownable module ensures that certain administrative actions, such as updating contract settings, are restricted to the contract owner.
    ReentrancyGuard prevents reentrant calls to functions, a critical security feature for functions that involve transferring Ether.

# Key Features
Immutable Variables:

    deployer: The address of the contract creator, set to be immutable and payable.
    deployerFixedRoyalty and deployerPercentRoyalty: Immutable values specifying the royalties that the deployer receives from each transaction, both as a fixed amount and as a percentage of the sale price.

Structs for Managing Sales and Royalties:

    TokenSaleInfo: Holds information about the sale price of each token.
    RoyaltyInfo: Records royalty details for each token, specifying the creator’s address and their royalty terms (fixed and percentage).

Mappings:

    tokenSalePrices: Maps token IDs to their respective TokenSaleInfo.
    royalties: Maps token IDs to their respective RoyaltyInfo.

Events:

    Minted: Triggered when a new token is minted, indicating the token ID, creator's address, and the sale price.
    Sold: Emitted upon the sale of a token, showing the transaction details including seller, buyer, and sale price.

Constructor:

    Sets up the NFT contract with a name and symbol and initializes the deployer’s address and royalty information.

Core Functions
mintNFTr:

    Allows users to mint a new NFT by providing a URI and sale price. The function automatically assigns a new token ID, sets the token URI, and records the sale and royalty information.
    Emits the Minted event upon successful minting.

setSalePrice:

    Permits the current token owner to update the sale price of their NFT, ensuring that only the token owner can make this change.

brokerNFT:

    Facilitates the secure sale of an NFT. It verifies the payment matches the sale price, transfers the NFT to the buyer, and handles the distribution of funds, including the payment of royalties to the creator and deployer.
    Emits the Sold event, marking the completion of a sale.

calculateRoyalty:

    Computes the royalty to be paid on a transaction, deciding the greater amount between a fixed sum and a percentage of the sale price.

Helper Functions:

    calculateRoyaltyPublic: Exposes the royalty calculation logic for transparency and testing.
    getSalePrice: Provides public access to the sale price of a specific NFT, useful for buyers and third-party interfaces to verify pricing.

    Owner Economy: Facilitates an environment where every owner can dynamically set sale prices and directly benefit from market activities. This decentralized control promotes a more resilient and flexible marketplace.

    Mint function: every owner can mint a new NFT and become a creator. Creator can set fixed royalty and percent royalty at mint. Owner can then use the built in sale price that will be triggered in the event that a buyer sends the price to the owner. This creates a truly decentralized marketplace where the NFT itself is the royalty broker.

Core Functions

    Minting: Owners can mint new NFTs, setting initial sale prices and embedding royalty information, ensuring that they and the deployer receive dues from future transactions.

    Price Management: Owners can adjust the sale prices of their NFTs, enabling them to respond to market conditions or personal financial needs.

    Secure Transactions: Implements safe, non-reentrant transactions for asset sales, including automatic royalty calculations and payouts, which support a fair distribution of revenue among all stakeholders involved in the asset lifecycle.

By integrating these features, the ROYALNFT contract facilitates a truly decentralized and owner-driven marketplace empowering owners as creators enhancing economic autonomy and participation in a royalty empowered data driven knowledge economy. ROYALNFT is designed to the platform contract of the <a href="https://github.com/pkNFTapi/">pkNFTapi</a> suite of utility tools to foster royalty based data exchange within a completely decentralized immutable creator royalty.
