# ROYALNFT v2

Every token is soulbound until its royalty is paid. Paying buys exactly one transfer, and the token
locks again in the hands of whoever receives it.

V1 at the repo root is untouched. This is a new contract, not an upgrade, and V1 tokens do not migrate.

## How a token moves

```
             mint
              │
              ▼
      ┌──────────────┐   brokerNFT: buyer pays listed price
      │    LOCKED    │───────────────────────────────┐
      │  (soulbound) │                               │ royalty split and
      └──────────────┘                               │ transfer, atomically
          ▲       │ payRoyalty: owner pays on        │
          │       │ a declared price                 │
          │       ▼                                  │
          │  ┌──────────┐  transferFrom /            │
          │  │ UNLOCKED │  safeTransferFrom          │
          │  └──────────┘  to any recipient          │
          │       │                                  │
          └───────┴──────────────────────────────────┘
                 next owner holds it locked
```

| Path | Who calls it | Royalty is charged on |
|---|---|---|
| `brokerNFT(id)` | Buyer, with exactly the listed price | The listed price |
| `payRoyalty(id, declaredPrice)`, then any transfer | Owner or approved operator | The declared price; zero for a gift pays the fixed floor |

The rule sits in `_update`, which every OpenZeppelin ERC-721 transfer passes through, so
`transferFrom`, `safeTransferFrom` and approved operators are all covered. `locked(id)` implements
ERC-5192, so wallets and indexers can read the state.

## What it can and cannot enforce

**The token cannot leave its address unless a royalty was paid.** That is what the contract guarantees.
These limits remain, and no contract can remove them:

- **The percentage is only as honest as the price.** A seller can list at the minimum, or declare a
  low value, and settle the rest privately. **The fixed royalty is the only floor that always holds**,
  so set it to the least you would accept per transfer. V1's `max(fixed, percent)` is what makes this
  work.
- **Control can change without a transfer.** Selling the key to a wallet, or a smart account or wrapper
  contract that holds the token, moves control while the token stays put.
- **Outside marketplaces only work with a prepaid royalty.** Their fills revert on a locked token. The
  seller must call `payRoyalty` and approve the venue first. Most venues will not guide users through
  this, so expect `brokerNFT` to be the main route.
- **A lost key means a stuck token.** Moving to a new wallet costs the royalty, paid from the old key.

ERC-2981 is left out on purpose. It allows one receiver and a pure percentage, so it cannot express
this split or the fixed floor, and a venue honouring it would charge a second royalty on top of the
one already paid.

A creator who sets a very high fixed royalty gets a token that is soulbound in practice forever. Terms
are public through `getRoyaltyInfo` and `royaltyDue`, so buyers can check before paying.

## Changes from V1

| | V1 `ROYALNFT.sol` | V2 |
|---|---|---|
| `transferFrom` without paying | Works, royalty skipped | Reverts `RoyaltyNotPaid` |
| Price after a sale | Stays, so anyone can buy the new owner out at once | Cleared, token delisted |
| Price of zero | A price: token is free if deployer fees are zero | Means not for sale |
| Payee rejects ETH | Blocks every sale of the token | Cannot block; payees use `withdraw(to)` |
| Royalty above price | Arithmetic panic at sale time | Refused when listing, `PriceBelowRoyalty` |
| Percentages | Unbounded | Deployer plus creator capped at 100 |
| `Ownable` | Inherited, no owner-only function | Removed; no admin exists |

Unchanged: `mintNFTr`, `setSalePrice`, `brokerNFT`, `getSalePrice`, `calculateRoyaltyPublic`, the
`Minted` and `Sold` events, and the royalty formula.

**Integration changes:** the constructor gains a first argument, `deployer_`, and proceeds are
collected with `withdraw(to)` rather than arriving automatically.

## Build and test

```bash
cd v2
npm ci
forge test
```

`test/ROYALNFTv1Baseline.t.sol` runs against the real V1 file and records the V1 behaviours in the
table above. `test/ROYALNFTv2.t.sol` includes the prices and amounts from V1's
`testMultipleTransfers`, unit and fuzz tests, and three invariants: no transfer without payment, moves
never exceed payments, and the contract always holds exactly what it owes.

**Status:** not audited and not deployed. Get an independent review before using it on mainnet: the
contract has no admin, so a bug cannot be patched after deployment.
