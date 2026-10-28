# KEPT test properties

The existing example tests remain in place. The added tests use the vendored Foundry and OpenZeppelin libraries and require no RPC, network, FFI, environment mutation, or new dependency. Test identities and signing keys are generated locally with Foundry solely for the fixtures.

Run with the verifier's seed:

```sh
FOUNDRY_FUZZ_SEED=0xbdb775f69d744e3a6687159f976799af7204d241bbd5b21ea14b087537ffa486 forge build
FOUNDRY_FUZZ_SEED=0xbdb775f69d744e3a6687159f976799af7204d241bbd5b21ea14b087537ffa486 forge test
```

Fuzz counts and invariant settings are inline in the test contracts. Both invariant suites explicitly target only their handler selectors and set `fail-on-revert = true`. Expected failures use specific revert checks; unexpected failures cannot silently discard a handler call. Ordinary token storage is never overwritten by cheatcodes.

## Discovery and scope

The five supplied Pashov discovery perspectives were applied locally, with the Trail of Bits review criteria used to check input generation and assertions:

| Perspective | Property selected and implementation basis |
| --- | --- |
| Conservation | KEPT circulating balances plus authorized burns equal the original issuance (`KeptToken.sol:25`). Vault token custody equals pending tranches, stranded tokens and direct donations (`PledgeVault.sol:229`, `337`, `359`). IMD custody backs pledge budgets and refunds (`PledgeVault.sol:265`, `302`, `341`). Fund custody plus refunds equals donations, including direct transfers (`RefereeFund.sol:44`, `50`, `57`). |
| State transitions | Milestones can move from Pending to Kept or Burned once; settled counts match terminal milestones; closed checks hold no open price; attempts never exceed three (`PledgeVault.sol:297`, `328`, `334`, `355`). Failed calls must preserve balances, allowances, budgets and permit nonces. |
| Round trips and rounding | Transfers out and back are exact. Repeated lock/check/release/reclaim cycles return exactly the collateral and budget, with every refunded check funded externally. There are no shares or conversion formulas in these contracts, so share-price and rounding templates do not apply. |
| Adversarial value extraction | Revoked or insufficient allowances cannot transfer or burn; invalid signatures cannot approve or release; strangers cannot request checks or withdraw refunds. Other pledges cannot subsidize an empty check budget. Zero, one wei, full balances, maximum allowances, exact deadlines and grace boundaries are explicit cases. |
| Protocol-specific | ERC-20 self-transfers, finite and infinite allowances, ERC-2612 domain/nonce binding, sorted panel signatures in the system handler, terminal milestone rejection, and refund limits. Independent EIP-712 encoding avoids using a potentially incorrect implementation digest as its own oracle. |

## Stateful suites

- `invariant/KeptTokenInvariant.t.sol`: four funded holders, 256 runs of 128 calls. Interleaves transfers, approvals/revocations, delegated transfers, burns, delegated burns, permits and expected failures. Independent balance, allowance and nonce ledgers are updated from authorized inputs. Each actor's balance and every actor-pair allowance are checked, not merely aggregate supply. Authorized burns are counted separately: supply is non-increasing, rather than incorrectly assumed constant after burns.
- `invariant/PledgeSystemInvariant.t.sol`: four actors, up to twelve pledges with one to eight milestones, 256 runs of 96 calls. Interleaves creation, budget additions, donations, check requests, both verdict outcomes, time advances, missed settlement, reclaim and authorization failures. It uses both KEPT and a plain non-burnable ERC-20, with the real vault and real fund. Ghost records distinguish releases, burns, stranded tokens, paid checks, refunds, reclaimed budgets and unsolicited donations. Pending and terminal states, recipient balances, per-pledge budgets and all three token supplies are checked after every handler action.

Each suite includes a deterministic mixed sequence that proves its important actions reach successful nonzero transfers and settlement, as well as rejection paths. The system handler scans from a randomized starting position for eligible work; it only returns without action when that action has no eligible position or funds. Actors receive finite balances once at setup. No handler mints additional funding.

`KeptTokenProperties.t.sol`, `PledgeBoundaryProperties.t.sol` and `RefereeFundFailurePaths.t.sol` add unit and fuzz properties for boundary conditions, signature isolation, transfer rollback, refund pricing, multi-pledge isolation, repeated lifecycles and failed donations.

## Limits and findings

The system invariant uses a correctly paired refund fund, an honest fixed signer panel, and exact-transfer tokens. Delayed oracle changes and price changes during an open check are covered by unit tests. It models arbitrary orderings of the exposed handler actions, not every possible external token implementation or every administrative configuration. The launch factory and Uniswap pool are not present in this repository; supplied protected launch checks were read as requirements, not imported into the local suite.

Two separate scratch tests reproduced defects outside the supported passing harness configurations: a fund with the wrong currency creates unbacked IMD credits, and an optional partial burn overstates stranded custody. They are reported with full standalone proof sources in the requested `.imd-findings.json`. Neither defect is asserted as correct by a passing test. Scratch proofs are not part of the submitted Solidity suite.
