// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ILendPool} from "./interfaces/ILendPool.sol";
import {ILendPoolAddressesProvider} from "./interfaces/ILendPoolAddressesProvider.sol";
import {IVoteManager} from "./interfaces/auguster/IVoteManager.sol";

import {Errors} from "./libraries/helpers/Errors.sol";

// import {IERC721ReceiverUpgradeable} from
//     "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";

contract VoteManager is IVoteManager {
    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    uint8 internal constant _not_entered = 1;
    uint8 internal constant _entered = 2;
    uint8 internal _entered_state = 1;

    modifier nonReentrant() {
        require(_entered_state == _not_entered);
        _entered_state = _entered;
        _;
        _entered_state = _not_entered;
    }

    struct VeTokenCheckPoint {
        uint32 startTime;
        uint32 size;
        uint32 votePointer; //用于在vote时方便从最新的checkpoint copy tokenId
        mapping(uint256 => uint32) token2Index;
        mapping(uint32 => uint256) index2Token;
    }

    modifier onlyLendPool() {
        require(msg.sender == address(_getLendPool()), Errors.CT_CALLER_MUST_BE_LEND_POOL);
        _;
    }

    ILendPoolAddressesProvider internal addressesProvider;

    uint32 public batchSize = 10;
    uint32 public latestEpoch;

    uint256 public totalStaked;
    mapping(address => uint256) public userStaked;

    mapping(uint32 => VeTokenCheckPoint) public checkPointAtEpoch;

    mapping(uint256 => address) public onBehalfOf;

    mapping(uint32 => mapping(uint256 => bool)) hasVoteAtEpoch;
    mapping(uint32 => mapping(uint256 => bool)) hasClaimRewardsAtEpoch;

    function add(uint256 _veTokenId, uint32 _epoch, address _user) external onlyLendPool {
        onBehalfOf[_veTokenId] = _user;
        userStaked[_user] += 1;

        if (checkPointAtEpoch[_epoch].size == 0) {
            //new checkpoint
            checkPointAtEpoch[_epoch].startTime = _epoch;
            checkPointAtEpoch[_epoch].size = 1;
            checkPointAtEpoch[_epoch].token2Index[_veTokenId] = 1;
            checkPointAtEpoch[_epoch].index2Token[1] = _veTokenId;
            checkPointAtEpoch[_epoch].votePointer = 1;
        } else {
            //update checkpoint
            uint32 index = checkPointAtEpoch[_epoch].size;
            index += 1;
            checkPointAtEpoch[_epoch].size = index;
            checkPointAtEpoch[_epoch].token2Index[_veTokenId] = index;
            checkPointAtEpoch[_epoch].index2Token[index] = _veTokenId;
            checkPointAtEpoch[_epoch].votePointer = index;
        }
    }

    function remove(uint256 _veTokenId, uint32 _epoch) external onlyLendPool {
        uint32 preEpoch = _epoch - 1 weeks;
        require(checkRemoveable(preEpoch, _veTokenId), "VoteManager#remove veNFT can not be remove.");
        uint32 replaceIdx = checkPointAtEpoch[_epoch].token2Index[_veTokenId];
        if (replaceIdx == 0) {
            return;
        } else {
            uint32 lastIndex = checkPointAtEpoch[_epoch].size;
            uint256 lastToken = checkPointAtEpoch[_epoch].index2Token[lastIndex];
            checkPointAtEpoch[_epoch].token2Index[lastToken] = replaceIdx;
            checkPointAtEpoch[_epoch].index2Token[replaceIdx] = lastToken;
            checkPointAtEpoch[_epoch].size -= 1;
            checkPointAtEpoch[_epoch].votePointer -= 1;
        }

        onBehalfOf[_veTokenId] = address(0);
        address user = onBehalfOf[_veTokenId];
        userStaked[user] -= 1;
    }

    struct BallMeta {
        //当前票箱size
        uint32 size;
        //copy进度，用于记录epoch(n)从 epoch(n_1) copy的进度
        uint32 copiedPointer;
    }

    //epoch => idx => tokenId
    mapping(uint32 => mapping(uint32 => uint256)) internal ballAtEpoch;

    //epoch => BallMeta
    mapping(uint32 => BallMeta) internal ballMetaAtEpoch;

    function vote(address[] calldata _poolVote, uint256[] calldata _weights) external nonReentrant {
        uint32 epoch = uint32(block.timestamp / 1 weeks * 1 weeks);
        uint32 voteEpoch = epoch - 1 weeks;
        uint32 votePreEpoch = voteEpoch - 1 weeks;

        uint256[] memory veTokens = _buildBall(voteEpoch, votePreEpoch);
        if (veTokens.length == 0) {
            return;
        }
        doVote(voteEpoch, veTokens, _poolVote, _weights);
    }

    function _buildBall(uint32 voteEpoch, uint32 votePreEpoch) internal returns (uint256[] memory) {
        BallMeta memory preBallMeta = ballMetaAtEpoch[votePreEpoch];
        if (0 == preBallMeta.copiedPointer) {
            //上个周期的票均已处理
            //todo:上个周期的新增vote还未投入到本期票箱
            return new uint256[](0);
        }

        // uint256[] memory candidateVeTokens = new uint256[](10);

        BallMeta memory ballMeta = ballMetaAtEpoch[voteEpoch];
        if (ballMeta.size == 0) {
            //新增本期票箱
            uint32 i = 0;
            for (; i < preBallMeta.size && i < 10; ++i) {
                uint256 veTokenId = ballAtEpoch[votePreEpoch][i];
                if (checkVeTokenValid(veTokenId)) {
                    //voTeken有效，则直接加入到本期票箱
                    ballAtEpoch[voteEpoch][i] = veTokenId;
                } else {
                    //从新增的checkpoint中从后向前挑选token替换无效的veToken
                    uint32 pointer = checkPointAtEpoch[voteEpoch].votePointer;
                    if (pointer > 0) {
                        ballAtEpoch[voteEpoch][i] = checkPointAtEpoch[voteEpoch].index2Token[pointer];
                        checkPointAtEpoch[voteEpoch].votePointer = pointer - 1;
                    }
                }
            }
            ballMetaAtEpoch[voteEpoch] = BallMeta(i, 0);
            ballMetaAtEpoch[votePreEpoch].copiedPointer = i; //更新votePreEpoch的copy进度
        } else {
            uint32 size = ballMeta.size;
            uint32 i = preBallMeta.copiedPointer; //从上次copy进度开始
            uint256 iterCounter = 0;
            for (; i < preBallMeta.size && iterCounter < 10; ++i) {
                uint256 veTokenId = ballAtEpoch[votePreEpoch][i];
                if (checkVeTokenValid(veTokenId)) {
                    ballAtEpoch[voteEpoch][size] = veTokenId;
                    ++size;
                } else {
                    //从新增的checkpoint中从后向前挑选token替换无效的veToken
                    uint32 pointer = checkPointAtEpoch[voteEpoch].votePointer;
                    if (pointer > 0) {
                        ballAtEpoch[voteEpoch][size] = checkPointAtEpoch[voteEpoch].index2Token[pointer];
                        checkPointAtEpoch[voteEpoch].votePointer = pointer - 1;
                    }
                }
            }
            ballMetaAtEpoch[voteEpoch].size = size;
            ballMetaAtEpoch[votePreEpoch].copiedPointer = i; //更新votePreEpoch的copy进度
        }

        //将剩余在checkPointAtEpoch[voteEpoch]还未搬移到票箱的整体搬移过来
        copyLeave(voteEpoch, ballMetaAtEpoch[voteEpoch].size, ballMetaAtEpoch[votePreEpoch].copiedPointer);
    }

    function copyLeave(uint32 voteEpoch, uint32 size, uint32 startIndex) internal {
        uint32 i = startIndex;
        uint32 iterCounter = 0;
        for (; i > 0 && iterCounter < 10; --i) {
            ++iterCounter;
            ballAtEpoch[voteEpoch][size] = checkPointAtEpoch[voteEpoch].index2Token[i];
        }
        checkPointAtEpoch[voteEpoch].votePointer = i;
        ballMetaAtEpoch[voteEpoch].size += iterCounter;
    }

    struct RewardsCheckPoint {
        uint32 claimedIndex;
        uint256 totalWeight;
        mapping(address => uint256) userWeight;
    }

    mapping(uint32 => RewardsCheckPoint) internal rewardsAtEpoch;

    function claimRewards() external nonReentrant {
        uint32 epoch = uint32(block.timestamp / 1 weeks * 1 weeks);
        uint32 rewardEpoch = epoch - 2 weeks;
        require(_rewardClaimable(rewardEpoch), "VoteManager#claimRewards None rewards could be claimed.");

        RewardsCheckPoint storage rewardsCheckPoint = rewardsAtEpoch[rewardEpoch];
        BallMeta memory ballMeta = ballMetaAtEpoch[rewardEpoch];

        uint32 i = rewardsCheckPoint.claimedIndex;
        for (; i < ballMeta.size && i < 10; ++i) {
            uint256 veToken = ballAtEpoch[rewardEpoch][i];
            _updateRewardsCheckPoint(veToken, rewardEpoch);

            // claim rewards
            _claimInternalRewards(veToken);
            __claimExternalRewards(veToken);
        }

        rewardsCheckPoint.claimedIndex = i;
    }

    function _updateRewardsCheckPoint(uint256 tokenId, uint32 epoch) internal {
        (address user, uint256 weight) = _getWeightOfVeToken(tokenId);

        rewardsAtEpoch[epoch].totalWeight += weight;
        rewardsAtEpoch[epoch].userWeight[user] += weight;
    }

    function _getWeightOfVeToken(uint256 tokenId) internal view returns (address, uint256) {
        address user = onBehalfOf[tokenId];
        uint256 weight = 0; //todo:根据tokenId查询最新的weight值
        return (user, weight);
    }

    function _claimInternalRewards(uint256 tokenId) internal {}

    function __claimExternalRewards(uint256 tokenId) internal {}

    function _rewardClaimable(uint32 _epoch) internal view returns (bool) {
        return rewardsAtEpoch[_epoch].claimedIndex < ballMetaAtEpoch[_epoch].size;
    }

    function checkRemoveable(uint32 _epoch, uint256 _veTokenId) internal view returns (bool) {
        if (hasVoteAtEpoch[_epoch][_veTokenId] && !hasClaimRewardsAtEpoch[_epoch][_veTokenId]) {
            return false;
        }
        return true;
    }

    function checkVeTokenValid(uint256 veToken) internal view returns (bool) {
        //若veToken赎回、清算、失效的情况，返回false
        return true;
    }

    function doVote(
        uint32 _preEpoch,
        uint256[] memory _veTokens,
        address[] calldata _poolVote,
        uint256[] calldata _weights
    ) internal {
        for (uint32 i = 0; i < _veTokens.length; i++) {
            // vote for single veToken
            uint256 veTokenId = _veTokens[i];
            hasVoteAtEpoch[_preEpoch][veTokenId] = true;
        }
    }

    function _getLendPool() internal view returns (ILendPool) {
        return ILendPool(addressesProvider.getLendPool());
    }

    function getTotalStaked() external view returns (uint256) {
        return totalStaked;
    }

    function getUserStaked(address _user) external view returns (uint256) {
        return userStaked[_user];
    }
}
