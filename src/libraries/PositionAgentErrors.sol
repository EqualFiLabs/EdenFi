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
