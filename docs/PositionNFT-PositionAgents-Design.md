# Position NFTs & Position Agents - Design Document

**Version:** 1.0
**Module:** EqualFi Position Identity System

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Position NFTs](#position-nfts)
5. [Position Keys](#position-keys)
6. [Token-Bound Accounts (TBAs)](#token-bound-accounts-tbas)
7. [Agent Identity Registration](#agent-identity-registration)
8. [Registration Modes](#registration-modes)
9. [ERC-6900 Modular Account](#erc-6900-modular-account)
10. [Configuration & Governance](#configuration--governance)
11. [Data Models](#data-models)
12. [View Functions](#view-functions)
13. [Integration Guide](#integration-guide)
14. [Worked Examples](#worked-examples)
15. [Error Reference](#error-reference)
16. [Events](#events)
17. [Security Considerations](#security-considerations)

---

## Overview

The Position Identity System is the foundational layer of EqualFi. Every user interaction with the protocol — deposits, loans, index tokens, stEVE, rewards, EqualScale credit lines — flows through a Position NFT. Each Position NFT is an ERC-721 token that represents an isolated account container, and can optionally be bound to an on-chain agent identity via ERC-6551 Token-Bound Accounts (TBAs) and ERC-8004 identity registration.

This system provides the bridge between DeFi positions and verifiable on-chain identity, enabling features like agent-gated credit (EqualScale), EDEN rewards eligibility, and composable position ownership.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **ERC-721 Enumerable** | Fully transferable, enumerable Position NFTs |
| **Deterministic Position Keys** | Each NFT derives a unique `bytes32` key used across all protocol state |
| **ERC-6551 TBAs** | Each position can deploy a Token-Bound Account (smart contract wallet) |
| **ERC-6900 Modular Accounts** | TBAs implement the ERC-6900 modular smart account standard |
| **ERC-8004 Identity** | Agent identities registered via an on-chain identity registry |
| **Dual Registration Modes** | Canonical (TBA-owned) or External (third-party-linked) agent registration |
| **Transfer-Safe** | All position state transfers with the NFT — no migration needed |
| **Pool Membership** | Each NFT is associated with a home pool at mint time |
| **Open Offer Guard** | Transfers blocked while direct offers are outstanding |

### System Participants

| Role | Description |
|------|-------------|
| **Position Holder** | Owner of a Position NFT; can operate on all protocol features |
| **Agent** | On-chain identity (ERC-8004) bound to a position via its TBA |
| **TBA** | Token-Bound Account — a smart contract wallet owned by the Position NFT holder |
| **Minter** | Authorized address (diamond facet) that can mint new Position NFTs |
| **Governance** | Timelock/owner that configures ERC-6551 registry, implementation, and identity registry |
| **External Authorizer** | Third-party identity owner who signs an external agent link |

### Why Position NFTs?

Position NFTs solve the fundamental problem of composable DeFi identity:
- **Isolated accounts** → Each position is a separate container with its own deposits, loans, and yield
- **Transferable ownership** → Sell, gift, or transfer a position with all its state intact
- **On-chain identity** → Link positions to verifiable agent identities for credit, compliance, and reputation
- **Smart contract wallets** → TBAs enable programmable position management via ERC-6900 modules
- **Protocol-wide key** → A single `bytes32` position key indexes into every protocol mapping

---

## How It Works

### The Core Model

1. **Mint** a Position NFT for a specific pool
2. **Deposit** assets, take loans, mint index tokens — all keyed to the position
3. **Deploy** a Token-Bound Account (TBA) for the position
4. **Register** an agent identity via the TBA (canonical) or external link
5. **Use** the verified identity for agent-gated features (EqualScale credit lines)
6. **Transfer** the NFT — all state moves with it automatically

### Position Key Derivation

Every Position NFT maps to a deterministic `bytes32` key:

```solidity
positionKey = keccak256(abi.encodePacked(nftContract, tokenId))
```

This key is used across the entire protocol:
- `pool.userPrincipal[positionKey]` — deposits
- `pool.userFeeIndex[positionKey]` — fee index checkpoint
- `pool.rollingLoans[positionKey]` — rolling credit loans
- `LibEncumbrance.total(positionKey, poolId)` — encumbrance
- `accruedRewards[programId][positionKey]` — EDEN rewards

### Identity Stack

```
Position NFT (ERC-721)
    │
    ├── Position Key (bytes32) ──── Protocol State
    │
    └── Token-Bound Account (ERC-6551)
            │
            ├── ERC-6900 Modular Account
            │     ├── Validation Modules
            │     ├── Execution Modules
            │     └── Session Keys
            │
            └── Agent Identity (ERC-8004)
                  └── Identity Registry
```

---

## Architecture

### Contract Structure

```
src/nft/
└── PositionNFT.sol                         # ERC-721 Enumerable NFT with pool binding

src/agent-wallet/erc6551/
├── PositionAgentConfigFacet.sol            # Admin: registry, implementation, identity config
├── PositionAgentRegistryFacet.sol          # Agent registration: canonical + external link
├── PositionAgentTBAFacet.sol               # TBA computation and deployment
└── PositionAgentViewFacet.sol              # Read-only queries: registration, TBA, interfaces

src/agent-wallet/erc6900/
└── PositionMSCAImpl.sol                    # ERC-6900 modular account implementation for TBAs

lib/agent-wallet-core/src/
├── core/
│   ├── ERC721BoundMSCA.sol                 # ERC-721-bound modular smart contract account
│   ├── NFTBoundMSCA.sol                    # Base NFT-bound account with ERC-6551 + ERC-6900
│   └── ERC8128PolicyRegistry.sol           # Policy registry for account governance
├── adapters/
│   ├── ERC8004IdentityAdapter.sol          # Helper for ERC-8004 registration flows
│   └── ERC721OwnerResolver.sol             # Owner resolution adapter
├── interfaces/
│   ├── IERC6551Account.sol                 # ERC-6551 account interface
│   ├── IERC6551Executable.sol              # ERC-6551 execution interface
│   ├── IERC6551Registry.sol                # ERC-6551 registry interface
│   ├── IERC6900Account.sol                 # ERC-6900 modular account interface
│   └── IERC6900*Module.sol                 # ERC-6900 module interfaces
├── modules/validation/
│   ├── OwnerValidationModule.sol           # Owner-based validation
│   ├── SessionKeyValidationModule.sol      # Session key validation
│   └── SIWAValidationModule.sol            # Sign-In With Agent validation
└── libraries/
    ├── MSCAStorage.sol                     # Modular account storage
    ├── ExecutionFlowLib.sol                # Execution flow management
    ├── ValidationFlowLib.sol               # Validation flow management
    └── ModuleEntityLib.sol                 # Module entity utilities

src/libraries/
├── LibPositionNFT.sol                      # Position key derivation and NFT storage
├── LibPositionAgentStorage.sol             # Diamond storage for agent integration
└── PositionAgentErrors.sol                 # Error definitions
```

### High-Level Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                    Position Identity System                          │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐          │
│  │  Position NFT  │  │  Agent Config  │  │  Agent         │          │
│  │  (ERC-721)     │  │  Facet         │  │  Registry      │          │
│  │                │  │                │  │  Facet         │          │
│  │  • Mint        │  │  • Set 6551    │  │                │          │
│  │  • Transfer    │  │    Registry    │  │  • Canonical   │          │
│  │  • Position    │  │  • Set Impl   │  │    Register    │          │
│  │    Key         │  │  • Set ID     │  │  • External    │          │
│  │  • Pool Bind   │  │    Registry   │  │    Link        │          │
│  └────────────────┘  └────────────────┘  │  • Unlink      │          │
│         │                                │  • Revoke      │          │
│         │                                └────────────────┘          │
│         │                                        │                   │
│  ┌────────────────┐  ┌────────────────┐          │                   │
│  │  TBA Facet     │  │  Agent View    │          │                   │
│  │                │  │  Facet         │          │                   │
│  │  • Compute     │  │                │          │                   │
│  │    Address     │  │  • Registration│          │                   │
│  │  • Deploy TBA  │  │    Status      │          │                   │
│  │                │  │  • TBA Info    │          │                   │
│  │                │  │  • Interfaces  │          │                   │
│  └────────────────┘  └────────────────┘          │                   │
│         │                                        │                   │
├─────────┼────────────────────────────────────────┼───────────────────┤
│         ▼                                        ▼                   │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │              Token-Bound Account (ERC-6551 + ERC-6900)         │  │
│  │                                                                │  │
│  │  PositionMSCAImpl (ERC721BoundMSCA)                           │  │
│  │  • Owner = Position NFT holder                                │  │
│  │  • ERC-4337 UserOp validation                                 │  │
│  │  • Modular execution + validation hooks                       │  │
│  │  • ERC-1271 signature validation                              │  │
│  │  • Module installation/uninstallation                         │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                              │                                       │
│                              ▼                                       │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │              ERC-8004 Identity Registry                        │  │
│  │                                                                │  │
│  │  • Agent ID registration                                      │  │
│  │  • Ownership verification (ownerOf)                           │  │
│  │  • Agent metadata (URI, wallet)                               │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Position NFTs

### Overview

The Position NFT is an ERC-721 Enumerable token. Each token represents an isolated account container in the EqualFi protocol. All protocol state — deposits, loans, yield, encumbrances, rewards — is indexed by the position key derived from the NFT.

### Token Properties

| Property | Value |
|----------|-------|
| **Standard** | ERC-721 + ERC-721 Enumerable |
| **Name** | "EqualLend Position" |
| **Symbol** | "ELPOS" |
| **Token IDs** | Sequential, starting at 1 |
| **Transferable** | Yes (with open-offer guard) |
| **Burnable** | No (no burn function) |

### Minting

```solidity
uint256 tokenId = positionNFT.mint(to, poolId);
```

- Only the authorized minter (diamond facet) can mint
- Each NFT is bound to a pool ID at mint time
- Creation timestamp is recorded
- First NFT minted to an address becomes their `defaultPointsTokenId`

### Pool Binding

Each Position NFT is associated with a home pool:

```solidity
mapping(uint256 => uint256) public tokenToPool;
```

This pool binding is set at mint time and is immutable. The position can participate in other pools via pool membership, but the home pool is fixed.

### Metadata

Token URIs are resolved via the diamond contract:

```solidity
function tokenURI(uint256 tokenId) public view override returns (string memory) {
    return IPositionMetadataDiamond(diamond).getPositionTokenURI(tokenId);
}
```

This enables dynamic metadata that reflects the position's current state, agent registration, and pool membership.

### Transfer Behavior

When a Position NFT is transferred:
- The position key (`keccak256(nftContract, tokenId)`) does not change
- All protocol state (deposits, loans, yield, encumbrances) transfers automatically
- The new owner inherits all obligations and benefits
- `defaultPointsTokenId` is updated for both sender and receiver
- Transfers are blocked if the position has outstanding direct offers

---

## Position Keys

### Derivation

```solidity
bytes32 positionKey = keccak256(abi.encodePacked(nftContract, tokenId));
```

The position key is deterministic and depends only on the NFT contract address and token ID. It never changes, regardless of ownership transfers.

### Usage Across the Protocol

| Module | State Indexed by Position Key |
|--------|-------------------------------|
| **Pools** | `userPrincipal`, `userFeeIndex`, `userMaintenanceIndex`, `userAccruedYield` |
| **Lending** | `rollingLoans`, `fixedTermLoans`, `userFixedLoanIds` |
| **Encumbrance** | `directLocked`, `directLent`, `indexEncumbered`, `moduleEncumbered` |
| **Active Credit** | `userActiveCreditStateEncumbrance`, `userActiveCreditStateDebt` |
| **EDEN Rewards** | `positionRewardIndex`, `accruedRewards` |
| **EqualScale** | `borrowerProfiles`, `lineCommitments` |
| **stEVE** | Pool principal, lending collateral |
| **EqualIndex** | Pool principal, lending collateral |

### Why bytes32?

Using `bytes32` instead of `address` for position keys:
- Avoids collision with EOA addresses
- Deterministic from immutable inputs (contract + tokenId)
- Compatible with all Solidity mapping types
- Enables future key derivation schemes without storage migration

---

## Token-Bound Accounts (TBAs)

### Overview

Each Position NFT can have a Token-Bound Account (TBA) — a smart contract wallet deployed via the ERC-6551 registry. The TBA is owned by whoever owns the Position NFT, and can execute arbitrary transactions, hold assets, and register agent identities.

### Address Computation

TBA addresses are deterministic and can be computed before deployment:

```solidity
address tba = IERC6551Registry(registry).account(
    implementation,     // PositionMSCAImpl
    tbaSalt,           // Protocol-wide salt
    block.chainid,     // Current chain
    positionNFT,       // NFT contract address
    positionTokenId    // Token ID
);
```

### Deployment

```solidity
address tba = tbaFacet.deployTBA(positionTokenId);
```

- Only the Position NFT owner can deploy
- Deployment is idempotent (returns existing address if already deployed)
- First deployment locks the TBA configuration (registry, implementation)
- The deployed TBA implements `PositionMSCAImpl` (ERC-6900 modular account)

### Config Locking

Once any TBA is deployed, the ERC-6551 configuration becomes immutable:

```solidity
ds.tbaConfigLocked = true;
```

This prevents changing the registry or implementation after TBAs are in use, protecting existing accounts from being orphaned.

---

## Agent Identity Registration

### Overview

Agent identity registration links a Position NFT to an on-chain identity (ERC-8004 agent ID). This is required for agent-gated features like EqualScale credit line proposals.

### Two Registration Modes

| Mode | Description | Ownership Proof |
|------|-------------|-----------------|
| **Canonical** | TBA owns the agent ID in the identity registry | `registry.ownerOf(agentId) == tbaAddress` |
| **External** | Third-party owns the agent ID and signs a link authorization | EIP-712 signature from identity owner |

### Canonical Registration

The TBA registers an agent identity directly with the ERC-8004 registry, then the position owner records the registration:

```solidity
// 1. TBA executes registration on the identity registry (external transaction)
// 2. Record the registration in the diamond
registryFacet.recordAgentRegistration(positionTokenId, agentId);
```

**Verification:**
```solidity
address registryOwner = IERC8004IdentityRegistry(identityRegistry).ownerOf(agentId);
require(registryOwner == tbaAddress);  // TBA must own the agent ID
```

### External Link Registration

A third-party identity owner authorizes linking their agent ID to a position:

```solidity
registryFacet.linkExternalAgentRegistration(positionTokenId, agentId, deadline, signature);
```

**Verification:**
- The identity owner signs an EIP-712 typed message authorizing the link
- Supports both EOA signatures (ECDSA) and smart contract signatures (ERC-1271)
- Includes a nonce and deadline for replay protection

### EIP-712 Link Message

```solidity
bytes32 EXTERNAL_LINK_TYPEHASH = keccak256(
    "EqualFiExternalAgentLink(uint256 chainId,address diamond,uint256 positionTokenId,"
    "uint256 agentId,address positionOwner,address tbaAddress,uint256 nonce,uint256 deadline)"
);
```

### Unlinking and Revocation

**Position owner unlinking:**
```solidity
registryFacet.unlinkExternalAgentRegistration(positionTokenId);
```

**Identity owner revoking:**
```solidity
registryFacet.revokeExternalAgentRegistration(positionTokenId);
```

Both clear the registration, returning the position to `None` mode.

---

## Registration Modes

```solidity
enum AgentRegistrationMode {
    None,               // No agent registered
    CanonicalOwned,     // TBA owns the agent ID directly
    ExternalLinked      // Third-party linked via signature
}
```

### Registration Completeness

A registration is "complete" when the on-chain ownership proof is currently valid:

**Canonical:** `identityRegistry.ownerOf(agentId) == tbaAddress`
**External:** `identityRegistry.ownerOf(agentId) == externalAuthorizer`

Registration completeness is checked live — if the identity is transferred away from the TBA or authorizer, the registration becomes incomplete without any on-chain transaction.

### State Transitions

```
None ──── recordAgentRegistration() ────► CanonicalOwned
None ──── linkExternalAgentRegistration() ──► ExternalLinked
ExternalLinked ──── unlinkExternalAgentRegistration() ──► None
ExternalLinked ──── revokeExternalAgentRegistration() ──► None
```

Canonical registrations are permanent (no unlink function). External links can be removed by either the position owner or the identity owner.

---

## ERC-6900 Modular Account

### Overview

Position TBAs implement the ERC-6900 Modular Smart Contract Account standard via `PositionMSCAImpl`, which extends `ERC721BoundMSCA` from the agent-wallet-core library. This provides a fully programmable smart contract wallet bound to the Position NFT.

### Account Identity

```solidity
function accountId() external pure returns (string memory) {
    return "equallend.position-tba.1.0.0";
}
```

### Key Capabilities

| Capability | Standard | Description |
|------------|----------|-------------|
| **Owner Resolution** | ERC-6551 | Owner = `positionNFT.ownerOf(tokenId)` |
| **UserOp Validation** | ERC-4337 | Validates user operations via installed modules |
| **Modular Execution** | ERC-6900 | Install/uninstall execution and validation modules |
| **Signature Validation** | ERC-1271 | Smart contract signature verification |
| **Token Receiving** | ERC-721 | Can receive NFTs via `onERC721Received` |
| **Direct Execution** | ERC-6551 | `execute(target, value, data)` for direct calls |
| **Batch Execution** | ERC-6900 | `executeBatch(calls)` for multi-call |
| **Bootstrap Mode** | Custom | Initial setup mode before module installation |

### Module System

The ERC-6900 module system allows installing:

| Module Type | Purpose |
|-------------|---------|
| **Validation Modules** | Define who can execute operations (owner, session keys, SIWA) |
| **Execution Modules** | Add new callable functions to the account |
| **Execution Hook Modules** | Pre/post hooks on execution |
| **Validation Hook Modules** | Pre-validation hooks |

### Available Validation Modules

| Module | Description |
|--------|-------------|
| `OwnerValidationModule` | Validates that the caller is the NFT owner |
| `SessionKeyValidationModule` | Validates session key signatures with scoped permissions |
| `SIWAValidationModule` | Sign-In With Agent validation for web3 auth flows |

### Ownership Model

The TBA's owner is always the current owner of the Position NFT:

```solidity
function _owner() internal view returns (address) {
    (uint256 chainId, address tokenContract, uint256 tokenId) = token();
    return IERC721(tokenContract).ownerOf(tokenId);
}
```

When the NFT transfers, the TBA's owner changes automatically — no migration needed.

---

## Configuration & Governance

### ERC-6551 Configuration

Governance configures the core infrastructure addresses:

```solidity
// Set the ERC-6551 registry (e.g., the canonical 0x000...6551 registry)
configFacet.setERC6551Registry(registryAddress);

// Set the TBA implementation (PositionMSCAImpl)
configFacet.setERC6551Implementation(implementationAddress);

// Set the ERC-8004 identity registry
configFacet.setIdentityRegistry(identityRegistryAddress);
```

All three must be deployed contracts (non-zero address with code).

### Config Locking

Once any TBA is deployed, configuration becomes immutable:

```solidity
modifier _requireMutableConfig() {
    if (LibPositionAgentStorage.s().tbaConfigLocked) revert PositionAgent_ConfigLocked();
}
```

This protects deployed TBAs from having their underlying infrastructure changed.

### Access Control

| Operation | Access |
|-----------|--------|
| Set ERC-6551 registry | Governance (before lock) |
| Set ERC-6551 implementation | Governance (before lock) |
| Set identity registry | Governance (before lock) |
| Deploy TBA | Position NFT owner |
| Record canonical registration | Position NFT owner |
| Link external registration | Position NFT owner |
| Unlink external registration | Position NFT owner |
| Revoke external registration | Identity owner |

---

## Data Models

### Position NFT State

```solidity
// PositionNFT.sol
uint256 public nextTokenId;                             // Sequential ID counter (starts at 1)
mapping(uint256 => uint256) public tokenToPool;         // Token → home pool ID
mapping(uint256 => uint40) public tokenCreationTime;    // Token → creation timestamp
mapping(address => uint256) public defaultPointsTokenId;// User → default position for points
```

### Agent Storage

```solidity
struct AgentStorage {
    address erc6551Registry;                                    // ERC-6551 registry address
    address erc6551Implementation;                              // TBA implementation address
    address identityRegistry;                                   // ERC-8004 identity registry
    bytes32 tbaSalt;                                            // Protocol-wide TBA salt
    mapping(uint256 => uint256) positionToAgentId;              // Position → agent ID
    mapping(uint256 => AgentRegistrationMode) positionRegistrationMode;  // Position → mode
    mapping(uint256 => address) externalAgentAuthorizer;        // Position → external authorizer
    mapping(uint256 => uint256) externalLinkNonce;              // Position → link nonce
    mapping(uint256 => bool) tbaDeployed;                       // Position → TBA deployed flag
    bool tbaConfigLocked;                                       // Global config lock
}
```

### Registration Mode Enum

```solidity
enum AgentRegistrationMode {
    None,               // 0 — No agent registered
    CanonicalOwned,     // 1 — TBA owns the agent ID
    ExternalLinked      // 2 — Third-party linked via signature
}
```

### Position Key Derivation

```solidity
// LibPositionNFT.sol
function getPositionKey(address nftContract, uint256 tokenId) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(nftContract, tokenId));
}
```

---

## View Functions

### TBA Queries

```solidity
// Compute TBA address (deterministic, no deployment needed)
function computeTBAAddress(uint256 positionTokenId) external view returns (address);
function getTBAAddress(uint256 positionTokenId) external view returns (address);

// Check if TBA is deployed
function isTBADeployed(uint256 positionTokenId) external view returns (bool);

// Get TBA implementation and registry
function getTBAImplementation() external view returns (address);
function getERC6551Registry() external view returns (address);

// Check TBA interface support
function getTBAInterfaceSupport(uint256 positionTokenId)
    external view returns (
        bool supportsAccount,       // IERC6551Account
        bool supportsExecutable,    // IERC6551Executable
        bool supportsERC721Receiver,// IERC721Receiver
        bool supportsERC1271        // IERC1271
    );
```

### Agent Registration Queries

```solidity
// Get agent ID for a position
function getAgentId(uint256 positionTokenId) external view returns (uint256);

// Check if any agent is registered
function isAgentRegistered(uint256 positionTokenId) external view returns (bool);

// Check registration mode
function getAgentRegistrationMode(uint256 positionTokenId) external view returns (uint8);

// Check if registration is complete (live ownership verification)
function isRegistrationComplete(uint256 positionTokenId) external view returns (bool);

// Check specific link types
function isCanonicalAgentLink(uint256 positionTokenId) external view returns (bool);
function isExternalAgentLink(uint256 positionTokenId) external view returns (bool);

// Get external authorizer address
function getExternalAgentAuthorizer(uint256 positionTokenId) external view returns (address);

// Get identity registry address
function getIdentityRegistry() external view returns (address);

// Get all canonical registries
function getCanonicalRegistries()
    external view returns (address erc6551Registry, address erc6551Implementation, address identityRegistry);
```

### Position NFT Queries

```solidity
// Standard ERC-721 Enumerable queries
function ownerOf(uint256 tokenId) external view returns (address);
function balanceOf(address owner) external view returns (uint256);
function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
function totalSupply() external view returns (uint256);

// Position-specific queries
function getPositionKey(uint256 tokenId) external view returns (bytes32);
function getPoolId(uint256 tokenId) external view returns (uint256);
function getCreationTime(uint256 tokenId) external view returns (uint40);
function defaultPointsTokenId(address user) external view returns (uint256);
function tokenURI(uint256 tokenId) external view returns (string memory);
```

---

## Integration Guide

### For Users (Basic Position Setup)

#### Mint a Position

```solidity
// Minting is typically done via a protocol facet, not directly
// The facet calls positionNFT.mint(to, poolId)
uint256 positionId = positionFacet.mintPosition(poolId, maxFee);
```

#### Deploy a TBA

```solidity
// Deploy the Token-Bound Account for your position
address tba = tbaFacet.deployTBA(positionId);
// tba is now a smart contract wallet you control
```

#### Register an Agent Identity (Canonical)

```solidity
// 1. Use the TBA to register with the ERC-8004 identity registry
//    (this happens via the TBA's execute function, outside the diamond)

// 2. Record the registration in the diamond
registryFacet.recordAgentRegistration(positionId, agentId);

// 3. Verify registration is complete
bool complete = viewFacet.isRegistrationComplete(positionId);
```

#### Register an Agent Identity (External Link)

```solidity
// 1. Identity owner signs an EIP-712 authorization message
// 2. Position owner submits the link
registryFacet.linkExternalAgentRegistration(positionId, agentId, deadline, signature);
```

### For Protocol Modules (Checking Identity)

```solidity
// Check if a position has a completed agent registration
bool complete = viewFacet.isRegistrationComplete(positionId);
uint256 agentId = viewFacet.getAgentId(positionId);

// EqualScale uses this for borrower profile registration:
if (!isRegistrationComplete(positionId)) revert BorrowerIdentityNotRegistered(positionId);
```

### For Integrators (Position Key Usage)

```solidity
// Derive position key from token ID
bytes32 positionKey = positionNFT.getPositionKey(tokenId);

// Use position key to query protocol state
uint256 principal = pool.userPrincipal[positionKey];
uint256 encumbered = LibEncumbrance.total(positionKey, poolId);
uint256 rewards = accruedRewards[programId][positionKey];
```

---

## Worked Examples

### Example 1: Full Position Setup with Canonical Agent

**Scenario:** Alice creates a position, deploys a TBA, and registers an agent identity.

**Step 1: Mint Position**
```
Alice mints Position NFT #42 for USDC pool (poolId = 1)
  tokenToPool[42] = 1
  tokenCreationTime[42] = block.timestamp
  defaultPointsTokenId[alice] = 42
  positionKey = keccak256(abi.encodePacked(positionNFT, 42))
```

**Step 2: Deploy TBA**
```
Alice calls deployTBA(42):
  tbaAddress = registry.account(impl, salt, chainId, positionNFT, 42)
  registry.createAccount(impl, salt, chainId, positionNFT, 42)
  tbaDeployed[42] = true
  tbaConfigLocked = true
  
  TBA is now a PositionMSCAImpl at tbaAddress
  TBA owner = positionNFT.ownerOf(42) = alice
```

**Step 3: Register Agent via TBA**
```
Alice uses the TBA to call identityRegistry.register():
  agentId = 7 (returned by registry)
  identityRegistry.ownerOf(7) = tbaAddress ✓

Alice calls recordAgentRegistration(42, 7):
  positionToAgentId[42] = 7
  positionRegistrationMode[42] = CanonicalOwned
  
  isRegistrationComplete(42) = true ✓
```

**Step 4: Use Identity**
```
Alice can now register a borrower profile in EqualScale:
  equalScaleFacet.registerBorrowerProfile(42, treasuryWallet, bankrToken, metadataHash)
  // Succeeds because isRegistrationComplete(42) == true
```

### Example 2: External Agent Link

**Scenario:** Bob's company owns agent ID #15. Bob links it to his position.

**Step 1: Company Signs Authorization**
```
Company (identity owner of agent #15) signs EIP-712 message:
  EqualFiExternalAgentLink {
    chainId: 1,
    diamond: 0xDiamond,
    positionTokenId: 99,
    agentId: 15,
    positionOwner: bob,
    tbaAddress: computedTBA,
    nonce: 0,
    deadline: block.timestamp + 1 day
  }
```

**Step 2: Bob Submits Link**
```
Bob calls linkExternalAgentRegistration(99, 15, deadline, companySignature):
  Verify: identityRegistry.ownerOf(15) = companyAddress
  Verify: signature is valid from companyAddress
  
  positionToAgentId[99] = 15
  positionRegistrationMode[99] = ExternalLinked
  externalAgentAuthorizer[99] = companyAddress
  externalLinkNonce[99] = 1
```

**Step 3: Verify**
```
isRegistrationComplete(99):
  mode = ExternalLinked
  identityRegistry.ownerOf(15) = companyAddress
  externalAgentAuthorizer[99] = companyAddress
  companyAddress == companyAddress → true ✓
```

### Example 3: Position Transfer

**Scenario:** Alice transfers Position #42 to Carol. All state moves automatically.

**Before Transfer:**
```
Position #42:
  owner: alice
  positionKey: 0xabc...
  pool.userPrincipal[0xabc...] = 10,000 USDC
  rollingLoans[0xabc...] = active loan
  accruedRewards[0][0xabc...] = 50 EDEN
  TBA owner: alice
```

**Transfer:**
```
alice calls positionNFT.transferFrom(alice, carol, 42)
  // Open offer check passes (no outstanding offers)
  // defaultPointsTokenId[alice] updated
  // defaultPointsTokenId[carol] = 42
```

**After Transfer:**
```
Position #42:
  owner: carol
  positionKey: 0xabc... (UNCHANGED)
  pool.userPrincipal[0xabc...] = 10,000 USDC (UNCHANGED)
  rollingLoans[0xabc...] = active loan (UNCHANGED)
  accruedRewards[0][0xabc...] = 50 EDEN (UNCHANGED)
  TBA owner: carol (automatically, via ownerOf)
  
Carol now controls everything — deposits, loans, rewards, TBA, agent identity.
```

### Example 4: External Link Revocation

**Scenario:** The company revokes Bob's external agent link.

```
Company calls revokeExternalAgentRegistration(99):
  Verify: mode == ExternalLinked
  Verify: msg.sender == identityRegistry.ownerOf(positionToAgentId[99])
  
  positionToAgentId[99] = 0
  positionRegistrationMode[99] = None
  externalAgentAuthorizer[99] = address(0)
  
  isRegistrationComplete(99) = false
  Bob can no longer use agent-gated features until re-linking
```

---

## Error Reference

### Position NFT Errors

| Error | Cause |
|-------|-------|
| `InvalidTokenId(uint256)` | Token ID does not exist |
| `PositionNFTHasOpenOffers(bytes32)` | Transfer blocked due to outstanding direct offers |

### Agent Registration Errors

| Error | Cause |
|-------|-------|
| `PositionAgent_Unauthorized(address, uint256)` | Caller doesn't own the Position NFT |
| `PositionAgent_AlreadyRegistered(uint256)` | Position already has an agent registered |
| `PositionAgent_InvalidAgentId(uint256)` | Agent ID is zero |
| `PositionAgent_InvalidAgentOwner(address, address)` | TBA doesn't own the agent ID in the registry |
| `PositionAgent_InvalidExternalLinkSignature()` | External link signature verification failed |
| `PositionAgent_RegistrationExpired(uint256, uint256)` | External link deadline has passed |
| `PositionAgent_InvalidRegistrationMode(uint8, uint8)` | Operation requires a different registration mode |
| `PositionAgent_NotIdentityOwner(address, address)` | Revocation caller is not the identity owner |

### Configuration Errors

| Error | Cause |
|-------|-------|
| `PositionAgent_NotAdmin(address)` | Caller is not governance |
| `PositionAgent_ConfigLocked()` | TBA config is locked (a TBA has been deployed) |
| `PositionAgent_InvalidConfigAddress(address)` | Zero address or non-contract address |

### TBA Deployment Errors

| Error | Cause |
|-------|-------|
| `PositionAgent_CreateAccountAddressMismatch(address, address)` | Deployed address doesn't match computed address |
| `PositionAgent_TBANotDeployed(address)` | Registry returned an address with no code |

---

## Events

### Position NFT Events

```solidity
event PositionMinted(uint256 indexed tokenId, address indexed owner, uint256 indexed poolId);
event MinterUpdated(address indexed oldMinter, address indexed newMinter);
event DiamondUpdated(address indexed oldDiamond, address indexed newDiamond);
```

### Agent Registration Events

```solidity
event AgentRegistered(
    uint256 indexed positionTokenId,
    address indexed tbaAddress,
    uint256 indexed agentId
);

event ExternalAgentLinked(
    uint256 indexed positionTokenId,
    address indexed tbaAddress,
    uint256 indexed agentId,
    address authorizer
);

event ExternalAgentUnlinked(
    uint256 indexed positionTokenId,
    uint256 indexed agentId,
    address indexed authorizer
);
```

### TBA Events

```solidity
event TBADeployed(uint256 indexed positionTokenId, address indexed tbaAddress);
```

### Configuration Events

```solidity
event ERC6551RegistryUpdated(address indexed previous, address indexed current);
event ERC6551ImplementationUpdated(address indexed previous, address indexed current);
event IdentityRegistryUpdated(address indexed previous, address indexed current);
```

---

## Security Considerations

### 1. Deterministic Position Keys

Position keys are derived from immutable inputs only:

```solidity
positionKey = keccak256(abi.encodePacked(nftContract, tokenId))
```

No mutable state influences the key. This ensures position state cannot be orphaned or redirected.

### 2. Transfer Safety

Position transfers are guarded against open direct offers:

```solidity
if (IDirectOfferCanceller(diamond).hasOpenOffers(positionKey)) {
    revert PositionNFTHasOpenOffers(positionKey);
}
```

This prevents a position from being transferred while it has pending obligations that the new owner might not expect.

### 3. Config Locking

TBA configuration is permanently locked after the first TBA deployment:

```solidity
ds.tbaConfigLocked = true;
```

This prevents governance from changing the registry or implementation after TBAs are in use, which would break existing accounts.

### 4. Live Registration Verification

Registration completeness is verified live against the identity registry:

```solidity
// Canonical: registry.ownerOf(agentId) == tbaAddress
// External: registry.ownerOf(agentId) == externalAuthorizer
```

If the identity is transferred away, the registration becomes incomplete without any on-chain transaction. This provides automatic revocation when identity ownership changes.

### 5. External Link Replay Protection

External link signatures include:
- Chain ID (prevents cross-chain replay)
- Diamond address (prevents cross-deployment replay)
- Monotonic nonce (prevents same-chain replay)
- Deadline (prevents stale signatures)

```solidity
bytes32 digest = keccak256(abi.encode(
    EXTERNAL_LINK_TYPEHASH, chainId, diamond, positionTokenId,
    agentId, positionOwner, tbaAddress, nonce, deadline
));
```

### 6. Dual Signature Verification

External link signatures support both EOA and smart contract signers:

```solidity
if (signer.code.length == 0) {
    // EOA: ECDSA recovery
    (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
    return err == ECDSA.RecoverError.NoError && recovered == signer;
} else {
    // Smart contract: ERC-1271
    return IERC1271(signer).isValidSignature(digest, signature) == IERC1271.isValidSignature.selector;
}
```

### 7. Canonical Registration Permanence

Canonical registrations (TBA-owned) cannot be unlinked. This is by design — the TBA owns the identity, and the identity can only be transferred by the TBA itself. This prevents accidental loss of identity.

### 8. External Link Bilateral Control

External links can be removed by either party:
- Position owner: `unlinkExternalAgentRegistration()`
- Identity owner: `revokeExternalAgentRegistration()`

This ensures neither party is locked into a link they no longer want.

### 9. Minter Authorization

Only the authorized minter can create Position NFTs:

```solidity
require(msg.sender == minter, "PositionNFT: only minter");
```

The minter is set once and can only be changed by the current minter.

### 10. ERC-6900 Module Safety

The TBA's module system provides:
- Owner-only module installation/uninstallation
- Validation hooks before execution
- Execution hooks for pre/post processing
- Bootstrap mode for initial setup

### 11. Ownership Resolution

TBA ownership is always resolved from the NFT:

```solidity
function _owner() internal view returns (address) {
    return IERC721(tokenContract).ownerOf(tokenId);
}
```

There is no separate owner storage — ownership follows the NFT automatically.

---

## Appendix: Correctness Properties

### Property 1: Position Key Determinism
```
positionKey(nftContract, tokenId) is deterministic and immutable
positionKey does not change on NFT transfer
```

### Property 2: Transfer Completeness
```
After transfer from A to B:
  All protocol state indexed by positionKey is accessible to B
  No migration or settlement required
```

### Property 3: TBA Address Determinism
```
computeTBAAddress(tokenId) == deployTBA(tokenId) (returned address)
Address is deterministic from (implementation, salt, chainId, nftContract, tokenId)
```

### Property 4: Config Lock Irreversibility
```
Once tbaConfigLocked == true:
  setERC6551Registry() reverts
  setERC6551Implementation() reverts
  setIdentityRegistry() reverts
```

### Property 5: Registration Uniqueness
```
Each position can have at most one agent registration
recordAgentRegistration() reverts if positionToAgentId[tokenId] != 0
linkExternalAgentRegistration() reverts if positionToAgentId[tokenId] != 0
```

### Property 6: Canonical Ownership Proof
```
For CanonicalOwned registration:
  identityRegistry.ownerOf(agentId) == computeTBAAddress(tokenId)
  Verified at registration time and checked live for completeness
```

### Property 7: External Link Authorization
```
For ExternalLinked registration:
  Valid EIP-712 signature from identityRegistry.ownerOf(agentId)
  Nonce prevents replay
  Deadline prevents stale authorization
```

### Property 8: TBA Ownership Follows NFT
```
tba.owner() == positionNFT.ownerOf(tokenId)
No separate owner state — always resolved from NFT
```

### Property 9: Open Offer Transfer Guard
```
If hasOpenOffers(positionKey) == true:
  transferFrom() reverts with PositionNFTHasOpenOffers
```

### Property 10: External Link Bilateral Revocation
```
External links can be cleared by:
  Position owner: unlinkExternalAgentRegistration()
  Identity owner: revokeExternalAgentRegistration()
Both result in mode = None, agentId = 0
```

### Property 11: Sequential Token IDs
```
nextTokenId starts at 1
Each mint increments nextTokenId by 1
Token IDs are never reused
```

### Property 12: Default Points Token Consistency
```
If user has positions: defaultPointsTokenId[user] != 0
If user has no positions: defaultPointsTokenId[user] == 0
First minted position becomes the default
```

---

**Document Version:** 1.0
**Module:** Position NFTs & Position Agents — EqualFi Position Identity System