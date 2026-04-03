// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAccess} from "src/libraries/LibAccess.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";

/// @notice Owner or timelock governed config writes for the clean EqualLend Direct surface.
contract EqualLendDirectConfigFacet {
    event DirectConfigUpdated(
        uint16 platformFeeBps,
        uint16 interestLenderBps,
        uint16 platformFeeLenderBps,
        uint16 defaultLenderBps,
        uint40 minInterestDuration
    );

    event DirectRollingConfigUpdated(
        uint32 minPaymentIntervalSeconds,
        uint16 maxPaymentCount,
        uint16 maxUpfrontPremiumBps,
        uint16 minRollingApyBps,
        uint16 maxRollingApyBps,
        uint16 defaultPenaltyBps,
        uint16 minPaymentBps
    );

    function setDirectConfig(LibEqualLendDirectStorage.DirectConfig calldata config) external {
        LibAccess.enforceOwnerOrTimelock();
        LibEqualLendDirectStorage.validateDirectConfig(config);
        LibEqualLendDirectStorage.s().config = config;

        emit DirectConfigUpdated(
            config.platformFeeBps,
            config.interestLenderBps,
            config.platformFeeLenderBps,
            config.defaultLenderBps,
            config.minInterestDuration
        );
    }

    function setRollingConfig(LibEqualLendDirectStorage.DirectRollingConfig calldata config) external {
        LibAccess.enforceOwnerOrTimelock();
        LibEqualLendDirectStorage.validateRollingConfig(config);
        LibEqualLendDirectStorage.s().rollingConfig = config;

        emit DirectRollingConfigUpdated(
            config.minPaymentIntervalSeconds,
            config.maxPaymentCount,
            config.maxUpfrontPremiumBps,
            config.minRollingApyBps,
            config.maxRollingApyBps,
            config.defaultPenaltyBps,
            config.minPaymentBps
        );
    }
}