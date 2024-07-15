// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Staking {
    uint256 constant maturityTime = 15552000; // 6 months in seconds
    uint256 constant maxSlash = 1000; // 10% 
    uint256 constant minSlash = 50; // 0.5% 
    uint256 constant initialAPR = 200; 
    uint256 constant minAPR = 1; 
    uint256 constant flatAPR = 25; // Flat APR when TVL exceeds $10M
    uint256 constant thresholdTVL = 10000000 * 1e18; // $10M threshold for flat APR

    struct StakeInfo {
        uint256 amount;
        uint256 stakeInTimestamp;
        uint256 lastRewardClaimTimestamp;
    }

    ERC20 myToken;
    AggregatorV3Interface internal priceFeed;
    uint256 stakeStartTime;
    uint256 totalStaked;

    mapping(address => mapping(uint256 => StakeInfo)) public userStakes;
    mapping(address => uint256) public userStakeCount;

    constructor(address tokenAddress, address priceFeedAddress) {
        myToken = ERC20(tokenAddress);
        priceFeed = AggregatorV3Interface(priceFeedAddress);
        stakeStartTime = block.timestamp;
    }

    function stake(uint256 amount) public {
        require(block.timestamp < (stakeStartTime + maturityTime), "Staking has ended");
        require(amount > 0, "Staking amount should be greater than 0");

        myToken.transferFrom(msg.sender, address(this), amount);

        uint256 stakeId = userStakeCount[msg.sender]++;
        userStakes[msg.sender][stakeId] = StakeInfo({
            amount: amount,
            stakeInTimestamp: block.timestamp,
            lastRewardClaimTimestamp: block.timestamp
        });

        totalStaked += amount;
    }

    function unstake(uint256 stakeId, uint256 amount) public {
        require(amount > 0, "Unstaking amount should be greater than 0");

        StakeInfo storage stakeInfo = userStakes[msg.sender][stakeId];
        require(stakeInfo.amount >= amount, "Insufficient staked amount");
        claimReward(stakeId);

        uint256 slashingPercentage = calculateSlashing(stakeInfo.stakeInTimestamp);
        uint256 slashingAmount = (amount * slashingPercentage) / 100;

        uint256 transferAmount = amount - slashingAmount;

        stakeInfo.amount -= amount;
        totalStaked -= amount;
        myToken.transfer(msg.sender, transferAmount);
    }

    function checkReward(uint256 stakeId) public view returns (uint256) {
        StakeInfo storage stakeInfo = userStakes[msg.sender][stakeId];
        require(stakeInfo.amount > 0, "No stake found with this ID");

        uint256 currentAPR = getCurrentAPR();
        uint256 reward = (stakeInfo.amount * (block.timestamp - stakeInfo.lastRewardClaimTimestamp) * currentAPR) / (60 * 60 * 24 * 365 * 100);

        return reward;
    }

    function claimReward(uint256 stakeId) public {
        uint256 reward = checkReward(stakeId);
        require(reward > 0, "No rewards collected");

        StakeInfo storage stakeInfo = userStakes[msg.sender][stakeId];
        stakeInfo.lastRewardClaimTimestamp = block.timestamp; // Update timestamp after claiming reward

        myToken.transfer(msg.sender, reward);
    }

    function calculateSlashing(uint256 stakeInTimestamp) internal view returns (uint256) {
        uint256 timeStaked = block.timestamp - stakeInTimestamp;
        if (timeStaked >= maturityTime) {
            return minSlash; // No slashing after maturity time
        }

        uint256 slashingRate = maxSlash - ((maxSlash - minSlash) * timeStaked / maturityTime);

        return slashingRate;
    }

    function getTVL() public view returns (uint256) {
        (, int256 price, , ,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price feed");
        uint256 priceInUSD = uint256(price);
        return (totalStaked * priceInUSD) / 1e18;
    }

    function getCurrentAPR() public view returns (uint256) {
        uint256 tvlInUSD = getTVL();

        if (tvlInUSD >= thresholdTVL) {
            return flatAPR;
        }

        uint256 aprDecayRate = (initialAPR - minAPR) / thresholdTVL;
        uint256 currentAPR = initialAPR - (aprDecayRate * tvlInUSD);

        return currentAPR > minAPR ? currentAPR : minAPR;
    }
}

