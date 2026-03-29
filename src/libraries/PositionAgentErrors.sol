// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

error PositionAgent_Unauthorized(address caller, uint256 positionTokenId);
error PositionAgent_NotAdmin(address caller);
error PositionAgent_AlreadyRegistered(uint256 positionTokenId);
error PositionAgent_InvalidAgentId(uint256 agentId);
error PositionAgent_InvalidAgentOwner(address expected, address actual);
error PositionAgent_InvalidConfigAddress(address configAddress);
error PositionAgent_ConfigLocked();
error PositionAgent_CreateAccountAddressMismatch(address expected, address actual);
error PositionAgent_TBANotDeployed(address tbaAddress);
error PositionAgent_InvalidExternalLinkSignature();
error PositionAgent_RegistrationExpired(uint256 deadline, uint256 currentTimestamp);
error PositionAgent_InvalidRegistrationMode(uint8 expected, uint8 actual);
error PositionAgent_NotIdentityOwner(address caller, address expectedOwner);
