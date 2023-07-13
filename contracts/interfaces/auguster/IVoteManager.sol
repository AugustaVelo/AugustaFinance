// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IVoteManager {
    // function stakeFor(uint256 _veTokenId, uint32 _duration, address _onBehalfOf) external;
    // function redeem(uint256 _veTokenId) external;

    function add(uint256 _veTokenId, uint32 _epoch, address _onBehalfOf) external;
    function remove(uint256 _veTokenId, uint32 _epoch) external;

    function vote(address[] calldata _poolVote, uint256[] calldata _weights) external;

    function getTotalStaked() external view returns (uint256);
    function getUserStaked(address _user) external view returns (uint256);
}
