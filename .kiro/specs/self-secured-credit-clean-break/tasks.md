# Tasks

## Task 1: Establish the Native SSC Storage and Type System

- [x] 1. Create the canonical SSC-native storage layer
  - [x] 1.1 Define SSC line state for outstanding debt, required lock, active
        status, and ACI routing mode
  - [x] 1.2 Define source-separated SSC ACI claim state and debt-paydown
        accounting state
  - [x] 1.3 Define SSC preview and view structs for draw, repay, service, and
        terminal settlement
  - [x] 1.4 Add storage-isolation tests for the SSC namespace

## Task 2: Lock in Shared SSC Accounting Invariants

- [x] 2. Write shared SSC accounting helpers before building the public facet
  - [x] 2.1 Centralize outstanding-debt increases and decreases
  - [x] 2.2 Centralize same-asset debt mutations through the canonical pool
        path
  - [x] 2.3 Centralize debt-side ACI origination and cleanup
  - [x] 2.4 Centralize required-lock recomputation from pool LTV
  - [x] 2.5 Centralize canonical `lockedCapital` increase and decrease for SSC
  - [x] 2.6 Add invariant tests proving outstanding debt, same-asset debt, and
        required lock remain aligned

## Task 3: Rebuild the Core SSC Draw / Repay / Close Lifecycle

- [x] 3. Implement the public SSC lifecycle on the clean accounting model
  - [x] 3.1 Implement draw from a Position NFT-owned pool position
  - [x] 3.2 Enforce min draw, tracked-liquidity, and deterministic LTV checks
  - [x] 3.3 Implement repay with tracked-liquidity restoration
  - [x] 3.4 Implement full closeout when debt reaches zero
  - [x] 3.5 Preserve Position NFT transfer semantics for active SSC lines
  - [x] 3.6 Add real-flow tests for deposit, draw, repay, close, withdraw, and
        transfer behavior

## Task 4: Preserve Maintenance-Driven Active Management

- [x] 4. Integrate SSC with maintenance-aware settlement discipline
  - [x] 4.1 Ensure SSC operations settle maintenance before debt-sensitive
        changes
  - [x] 4.2 Add previews for free equity, required lock, and remaining borrow
        runway after maintenance
  - [x] 4.3 Add regression tests showing maintenance pressure reduces safe SSC
        headroom over time
  - [x] 4.4 Add regression tests showing high-LTV SSC positions cannot ignore
        maintenance indefinitely

## Task 5: Split FI Yield and SSC ACI Yield Accounting

- [x] 5. Introduce source-explicit accounting for SSC ACI routing
  - [x] 5.1 Keep FI claim accounting intact for passive yield
  - [x] 5.2 Add SSC-specific claimable ACI accounting rather than relying on a
        blended accrued-yield bucket
  - [x] 5.3 Expose audit-friendly reads for claimable FI, claimable SSC ACI,
        and total ACI applied to debt
  - [x] 5.4 Add tests proving FI behavior remains correct outside SSC ACI
        self-pay flows

## Task 6: Build the ACI Routing Toggle

- [x] 6. Implement the prospective SSC ACI routing-mode surface
  - [x] 6.1 Add yield mode and self-pay mode to SSC line state
  - [x] 6.2 Implement owner-controlled mode switching for active SSC lines
  - [x] 6.3 Ensure mode switching settles under the old mode before the new
        mode takes effect
  - [x] 6.4 Reject any implementation path that retroactively reclassifies
        already accrued ACI
  - [x] 6.5 Add live-flow tests for switching from yield mode to self-pay mode
        and back during an active line

## Task 7: Implement SSC Self-Pay Servicing

- [x] 7. Implement deterministic ACI-to-debt servicing
  - [x] 7.1 Add a service path that settles maintenance, FI, and ACI for an SSC
        line
  - [x] 7.2 In self-pay mode, apply future settled SSC ACI to debt reduction
  - [x] 7.3 Recompute required lock and release excess lock after self-pay
  - [x] 7.4 Define and implement overflow handling when self-pay ACI exceeds
        outstanding debt
  - [x] 7.5 Add live-flow tests proving self-pay reduces debt, increases free
        equity, and restores FI fee base over time

## Task 8: Build Deterministic Terminal Self-Settlement

- [x] 8. Implement the SSC unhappy-path resolution model
  - [x] 8.1 Detect when a settled SSC line can no longer support required lock
  - [x] 8.2 Implement deterministic principal consumption against locked SSC
        backing
  - [x] 8.3 Reduce debt, same-asset debt, ACI debt state, and canonical lock
        symmetrically
  - [x] 8.4 Close the line or leave it in a smaller safe residual state
  - [x] 8.5 Add live-flow tests for terminal self-settlement without oracle or
        auction mechanics

## Task 9: Rebuild the SSC View and Preview Surface

- [x] 9. Add a clean SSC-native view facet
  - [x] 9.1 Expose line state, required lock, free equity, and max draw reads
  - [x] 9.2 Expose preview functions for draw, repay, service, and terminal
        self-settlement
  - [x] 9.3 Expose current ACI routing mode and pending self-pay effect
  - [x] 9.4 Expose source-separated claimable FI and claimable SSC ACI reads
  - [x] 9.5 Add round-trip tests for all SSC view surfaces

## Task 10: Wire SSC into the Diamond and Launch Flow

- [x] 10. Integrate the rebuilt SSC surface into EqualFi launch wiring
  - [x] 10.1 Register selector groups for SSC lifecycle and SSC views
  - [x] 10.2 Add deployment and selector wiring tests
  - [x] 10.3 Confirm no legacy monolithic SSC implementation path remains
        active beside the clean rebuild

## Task 11: Harden Real-Flow and Invariant Coverage

- [x] 11. Add regression and invariant coverage for the completed SSC system
  - [x] 11.1 Prove same-asset debt matches SSC outstanding debt through draw,
        repay, self-pay, and terminal settlement
  - [x] 11.2 Prove required lock matches the configured LTV formula at every
        lifecycle step
  - [x] 11.3 Prove canonical `lockedCapital` reflects SSC withdrawal safety
        correctly
  - [x] 11.4 Prove prospective mode switches do not retroactively reclassify
        ACI
  - [x] 11.5 Prove SSC ACI reward handling does not double-count debt-side and
        encumbrance-side active credit
