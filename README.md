# keptonchain (KEPT) — promises the swarm enforces

A custom token launch on Ethereum (chain id 1), paired with IMD: the **KEPT** token plus the
application the brief's site describes (keptmd.vercel.app). Every launch hands a team most of its
token supply, and buyers have to hope the team builds what it promised. KEPT turns the roadmap into
a contract: a team locks its tokens behind public milestones, the IMD swarm checks each one at its
deadline and signs a verdict on chain, kept tranches unlock to the team and missed ones burn.

## Contracts

| Solidity name | Role | Constructor arguments |
| --- | --- | --- |
| `KeptToken` | The token: `keptonchain` / `KEPT`, 18 decimals, 1,000,000,000 supply minted once to `msg.sender` (the launch factory). Plain ERC-20 with `burn` (ERC20Burnable) and `permit` (ERC-2612). No owner, no mint, no pause, no blocklist, no transfer rule. | none |
| `PledgeVault` | Locks any plain ERC-20 behind up to eight milestones; verifies the swarm's EIP-712 verdicts; releases kept tranches, burns missed ones; holds IMD check budgets; owner-configured oracle behind a seven-day notice. | `address owner_` (`$owner`), `address imd_` (IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`) |
| `RefereeFund` | Holds donated IMD and refunds the check of every kept milestone, when it can. Only the vault may draw; nobody may withdraw. | `address imd_` (IMD as above), `address vault_` (`$contract:PledgeVault`) |

Deployment order: `KeptToken`, `PledgeVault`, `RefereeFund`. No constructor calls another contract
or requires code at an address. Supply in minor units: `1000000000000000000000000000`.

## How the vault works

**Creating a pledge.** `createPledge(token, beneficiary, label, milestones, budget)` pulls every
tranche of `token` and `budget` IMD from the caller (approve first; KEPT supports `permit`). A
pledge carries 1 to 8 milestones, each with a check (the yes/no question text, up to 512 bytes), a
deadline (strictly ascending, in the future) and a tranche amount. The label is at most 64 bytes.
The token must be a plain ERC-20: the vault measures what arrived and reverts with `NotPlainToken`
if it is less than what was sent. IMD itself cannot be locked. Pledges can be created before the
oracle is configured, so KEPT's own roadmap can be locked the day the vault deploys.

**Asking the swarm.** The beneficiary calls `requestCheck(pledgeId, milestone)`. It costs
`checkPrice` IMD (at most 0.5 IMD) from the pledge's budget, paid to the swarm's `intake`, and emits
`CheckRequested` with the exact question. The vault writes the question itself (`question(id, m)`),
so a team sees it exactly as the swarm will before signing anything. One check may be open per
milestone, at most three attempts per milestone (one check, two retries), from creation until three
days after the deadline. Anyone may `addBudget`.

**Verdicts.** Anyone may call `submitVerdict(pledgeId, milestone, attempt, kept, expiry, signatures)`.
The signatures are EIP-712 (`Verdict(uint256 pledgeId,uint256 milestone,uint8 attempt,bool kept,uint256 expiry)`,
domain `KEPT Pledge Vault` / `1`) from distinct panel members in ascending address order; at least
`quorum` of them, and every one a current signer. A verdict is refused once `expiry` has passed,
once the milestone's grace period (deadline + 3 days) is over, for a closed or wrong attempt, or
for a settled milestone, so no verdict can be replayed.

- **Kept:** the tranche transfers to the beneficiary and the milestone settles. If a Referee Fund is
  set, the vault asks it to refund the check; whatever the fund can pay goes back into the pledge's
  budget. Keeping a promise costs nothing while the fund is solvent.
- **Not kept:** the attempt is consumed, the tokens stay locked, and the beneficiary may retry while
  attempts and budget remain.

**Missed deadlines.** Once a milestone is three days past its deadline and still pending, anyone
may call `settleMissed`. The tranche burns through the token's own `burn(uint256)`. If the token has
no working burn (the call fails or the balance does not fall by the full tranche), the tranche stays
in the vault forever and is counted in `stranded[token]`; `TrancheBurned` reports which happened.

**Budgets.** `reclaimBudget(pledgeId)` returns the unused IMD to the creator once every milestone has
settled (kept or burned). Anyone may trigger it.

**What nobody can do.** There is no withdrawal, pause, upgrade or cancellation. Locked tokens move
only on a kept verdict (to the beneficiary) or a missed deadline (burn). The owner cannot touch
locked tokens or budgets. The contracts contain no `delegatecall`, `callcode` or `selfdestruct`.

## Ownership and trust assumptions

- The vault's owner is the launch's owner (`owner_`, filled by the manifest with `$owner`). It is
  `Ownable2Step`: ownership moves only when the new owner accepts.
- The owner chooses the oracle: `intake` (where check payments go), `checkPrice`, the signer
  `panel` (1 to 16 addresses) and `quorum`. Verdicts are only as honest as that panel. A pledge's
  tokens are therefore trusted to the IMD swarm's panel as configured by the owner.
- Changes to the oracle wait seven days (`NOTICE`): the owner schedules, anyone applies after the
  notice, the owner may cancel before. The first configuration from unset applies at once, because
  there is nothing to protect yet and no check can run until it exists. Existing pledges cannot exit
  during the notice; there is no exit at all.
- `RefereeFund` is set once (`setRefereeFund`); the fund must name this vault. It has no owner.
- The token has no owner and no privileged function of any kind.

## After launch

The owner must set these before the first check can run; until then `requestCheck` reverts with
`OracleNotConfigured`, while pledges can already be created and funded.

| Setting | Setter | Set it to | Where it comes from |
| --- | --- | --- | --- |
| `intake`, `checkPrice`, panel, `quorum` | `PledgeVault.scheduleOracleConfig(intake, checkPrice, signers, quorum)` then `applyOracleConfig()` | The IMD swarm's intake address, the check price (at most `0.5e18`, the 0.5 IMD the site quotes), the panel's signer addresses and the quorum | The IMD swarm / oracle operator publishes its intake address and panel |
| Referee Fund | `PledgeVault.setRefereeFund(address)` | The launched `RefereeFund` address | The launch record (`$contract:RefereeFund`) |
| Fund balance | `RefereeFund.donate(amount)` (anyone) | IMD to refund kept checks | Whoever funds it; see "Not in this launch" |

## Choices the brief left open (named constants in `PledgeVault`)

| Constant | Value | Why |
| --- | --- | --- |
| `MAX_MILESTONES` | 8 | The site: "up to eight milestones". |
| `MAX_ATTEMPTS` | 3 | The site: "the three check attempts" (one check, two retries). |
| `GRACE` | 3 days | The site: "not proven within three days of the deadline: it burns". |
| `NOTICE` | 7 days | The site: "intake, action and signer changes wait seven days". |
| `MAX_CHECK_PRICE` | 0.5 IMD | The site: "each check costs 0.5 IMD"; the owner may set a lower price, never higher. |
| `MAX_PANEL` | 16 | Bounds the signature loop; large enough for any realistic panel. |
| `MAX_LABEL_LENGTH` | 64 bytes | The site: "up to 64 characters". |
| `MAX_CHECK_LENGTH` | 512 bytes | Keeps questions readable and events cheap. |

Checks may be requested from pledge creation onward, not only at the deadline: a milestone delivered
early can be proven early. The question text tells the swarm to answer for delivery by the deadline.

## Not in this launch

- **Pool-fee funding of the Referee Fund.** The site describes feeding the fund from a share of each
  KEPT/IMD trade (20% at launch falling to 1%). That is a dynamic pool fee, which needs a Uniswap v4
  hook; this launch deploys no hook and opens the pool at the policy's fixed 1.25% fee. The fund is
  therefore donation-funded (`donate`). A later hook launch can route fees to it without changing
  these contracts.
- **The IMD intake's own interface.** The vault pays the check price to `intake` with a plain IMD
  transfer and emits `CheckRequested` with the question; the swarm reads the event. If the intake
  needs a contract call instead, that adapter is outside these contracts.

## Operational responsibilities

- **Owner:** configure the oracle after launch and keep the panel current (rotations wait seven
  days); set the Referee Fund once; hold the owner key in a multisig.
- **Oracle operator (IMD swarm):** watch `CheckRequested`, answer within the milestone's grace
  period, sign verdicts with a short `expiry`, and submit them (anyone may).
- **Teams:** approve the vault, create the pledge with a budget of about one check per milestone
  (two for a retry), request checks before the grace period ends, and reclaim leftover budget once
  everything settles. Use only plain ERC-20 tokens.
- **Anyone:** `settleMissed` after a grace period, `applyOracleConfig` after a notice,
  `reclaimBudget` after settlement, `donate` to the fund.

## Development

```
forge build
forge test
forge fmt --check
```

Compiler pinned to `solc = "0.8.26"`, optimizer on, `bytecode_hash = "none"`, no `ffi`, no
filesystem permissions. Dependencies are vendored as plain files under `lib/`: forge-std 1.9.7 and
OpenZeppelin Contracts 5.1.0. Tests read no environment variables and run in any order.

Tests passing are not a security audit. The vault holds other people's tokens and needs an
independent adversarial review before anything of value is locked in it. Slither was not available
on this machine; the code avoids the patterns it rejects (no `selfdestruct`, `transferFrom` only from
`msg.sender`, no upgrade path, no `abi.encodePacked` of adjacent dynamic values).
