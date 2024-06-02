Hodl721.sol is a custom ERC-721 contract implementation that can own other ERC-721 tokens. This contract allows for receiving, storing, and transferring owned ERC-721 tokens. The functionalities are restricted to ensure that only the contract owner can mint new tokens and transfer owned NFTs.
Features

    Minting Tokens: Only the contract owner can mint new tokens.
    Setting Owned NFTs: Allows the contract owner to set owned NFTs for a parent token.
    Getting Owned NFT Information: Retrieve information about owned NFTs for a given parent token.
    Transferring Owned NFTs: Only the contract owner can transfer owned NFTs to another address.
    Receiving ERC-721 Tokens: The contract can receive ERC-721 tokens.
