// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.4;

import { ERC20 } from "./lib/ERC20.sol";
import { SafeTransferLib } from "./lib/SafeTransferLib.sol";

import {Ownable} from "./lib/Ownable.sol";
import {FullMath} from "./lib/FullMath.sol";

/// @title StakingRewardsV2
/// @author bakii.eth
/// @notice A modern, gas optimized staking pool contract for rewarding ERC20 stakers
/// with ERC20 tokens periodically and continuously
contract StakingRewardsV2 is Ownable {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for ERC20;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error Error_NotRewardDistributor();
    error Error_AmountTooLarge();
    error Error_FundsAreUnderLockDuration();

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event StakeDateUpdated(address indexed staker, uint256 stakeDate);

    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    uint256 internal constant PRECISION = 1e30;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    /// @notice The last Unix timestamp (in seconds) when rewardPerTokenStored was updated
    uint64 public lastUpdateTime;
    /// @notice The Unix timestamp (in seconds) at which the current reward period ends
    uint64 public periodFinish;

    /// @notice The per-second rate at which rewardPerToken increases
    uint256 public rewardRate;
    /// @notice The last stored rewardPerToken value
    uint256 public rewardPerTokenStored;
    /// @notice The total tokens staked in the pool
    uint256 public totalSupply;
    /// @notice The lock period for a given stake.
    uint256 public immutable lockInDuration;

    /// @notice Tracks if an address can call notifyReward()
    mapping(address => bool) public isRewardDistributor;
    /// @notice Map of account addresses to effective stake date.
    mapping(address => uint256) public stakeDate;

    /// @notice The amount of tokens staked by an account
    mapping(address => uint256) public balanceOf;
    /// @notice The rewardPerToken value when an account last staked/withdrew/withdrew rewards
    mapping(address => uint256) public userRewardPerTokenPaid;
    /// @notice The earned() value when an account last staked/withdrew/withdrew rewards
    mapping(address => uint256) public rewards;

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    /// @notice The token being rewarded to stakers
    function rewardToken() public pure returns (ERC20 rewardToken_) {
        uint256 offset = _getImmutableVariablesOffset();
        assembly {
            rewardToken_ := shr(0x60, calldataload(offset))
        }
    }

    /// @notice The token being staked in the pool
    function stakeToken() public pure returns (ERC20 stakeToken_) {
        uint256 offset = _getImmutableVariablesOffset();
        assembly {
            stakeToken_ := shr(0x60, calldataload(add(offset, 0x14)))
        }
    }

    /// @notice The length of each reward period, in seconds
    function DURATION() public pure returns (uint64 DURATION_) {
        uint256 offset = _getImmutableVariablesOffset();
        assembly {
            DURATION_ := shr(0xc0, calldataload(add(offset, 0x28)))
        }
    }

    /// -----------------------------------------------------------------------
    /// Initialization
    /// -----------------------------------------------------------------------

    /// @notice Initializes the owner.
    /// @param initialOwner The initial owner of the contract
    constructor(address initialOwner, uint256 _lockInDuration) {
        lockInDuration = _lockInDuration;
        _transferOwnership(initialOwner);
    }

    /// -----------------------------------------------------------------------
    /// User actions
    /// -----------------------------------------------------------------------

    /// @notice Stakes tokens in the pool to earn rewards
    /// @param amount The amount of tokens to stake
    function stake(uint256 amount) external {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        if (amount == 0) {
            return;
        }

        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        uint256 accountBalance = balanceOf[msg.sender];
        uint64 lastTimeRewardApplicable_ = lastTimeRewardApplicable();
        uint256 totalSupply_ = totalSupply;
        uint256 rewardPerToken_ = _rewardPerToken(
            totalSupply_,
            lastTimeRewardApplicable_,
            rewardRate
        );

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue rewards
        rewardPerTokenStored = rewardPerToken_;
        lastUpdateTime = lastTimeRewardApplicable_;
        rewards[msg.sender] = _earned(
            msg.sender,
            accountBalance,
            rewardPerToken_,
            rewards[msg.sender]
        );
        userRewardPerTokenPaid[msg.sender] = rewardPerToken_;

        // stake
        totalSupply = totalSupply_ + amount;
        balanceOf[msg.sender] = accountBalance + amount;
        _updateStakeDate(msg.sender, amount);

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        stakeToken().safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    /// @notice Withdraws staked tokens from the pool
    /// @param amount The amount of tokens to withdraw
    function withdraw(uint256 amount) external {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        if (amount == 0) {
            return;
        }

        if (block.timestamp <= stakeDate[msg.sender] + lockInDuration) {
            return Error_FundsAreUnderLockDuration();
        }

        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        uint256 accountBalance = balanceOf[msg.sender];
        uint64 lastTimeRewardApplicable_ = lastTimeRewardApplicable();
        uint256 totalSupply_ = totalSupply;
        uint256 rewardPerToken_ = _rewardPerToken(
            totalSupply_,
            lastTimeRewardApplicable_,
            rewardRate
        );

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue rewards
        rewardPerTokenStored = rewardPerToken_;
        lastUpdateTime = lastTimeRewardApplicable_;
        rewards[msg.sender] = _earned(
            msg.sender,
            accountBalance,
            rewardPerToken_,
            rewards[msg.sender]
        );
        userRewardPerTokenPaid[msg.sender] = rewardPerToken_;

        // withdraw stake
        balanceOf[msg.sender] = accountBalance - amount;
        // total supply has 1:1 relationship with staked amounts
        // so can't ever underflow
        unchecked {
            totalSupply = totalSupply_ - amount;
        }

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        stakeToken().safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Withdraws all staked tokens and earned rewards
    function exit() external {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        uint256 accountBalance = balanceOf[msg.sender];
        if (accountBalance == 0) {
            return;
        }

        if (block.timestamp <= stakeDate[msg.sender] + lockInDuration) {
            return Error_FundsAreUnderLockDuration();
        }

        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        uint64 lastTimeRewardApplicable_ = lastTimeRewardApplicable();
        uint256 totalSupply_ = totalSupply;
        uint256 rewardPerToken_ = _rewardPerToken(
            totalSupply_,
            lastTimeRewardApplicable_,
            rewardRate
        );

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // give rewards
        uint256 reward = _earned(
            msg.sender,
            accountBalance,
            rewardPerToken_,
            rewards[msg.sender]
        );
        if (reward > 0) {
            rewards[msg.sender] = 0;
        }

        // accrue rewards
        rewardPerTokenStored = rewardPerToken_;
        lastUpdateTime = lastTimeRewardApplicable_;
        userRewardPerTokenPaid[msg.sender] = rewardPerToken_;

        // withdraw stake
        balanceOf[msg.sender] = 0;
        // total supply has 1:1 relationship with staked amounts
        // so can't ever underflow
        unchecked {
            totalSupply = totalSupply_ - accountBalance;
        }

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        // transfer stake
        stakeToken().safeTransfer(msg.sender, accountBalance);
        emit Withdrawn(msg.sender, accountBalance);

        // transfer rewards
        if (reward > 0) {
            rewardToken().safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @notice Withdraws all earned rewards
    function getReward() external {

        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        if (block.timestamp <= stakeDate[msg.sender] + lockInDuration) {
            return Error_FundsAreUnderLockDuration();
        }

        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        uint256 accountBalance = balanceOf[msg.sender];
        uint64 lastTimeRewardApplicable_ = lastTimeRewardApplicable();
        uint256 totalSupply_ = totalSupply;
        uint256 rewardPerToken_ = _rewardPerToken(
            totalSupply_,
            lastTimeRewardApplicable_,
            rewardRate
        );

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        uint256 reward = _earned(
            msg.sender,
            accountBalance,
            rewardPerToken_,
            rewards[msg.sender]
        );

        // accrue rewards
        rewardPerTokenStored = rewardPerToken_;
        lastUpdateTime = lastTimeRewardApplicable_;
        userRewardPerTokenPaid[msg.sender] = rewardPerToken_;

        // withdraw rewards
        if (reward > 0) {
            rewards[msg.sender] = 0;

            /// -----------------------------------------------------------------------
            /// Effects
            /// -----------------------------------------------------------------------

            rewardToken().safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// -----------------------------------------------------------------------
    /// Getters
    /// -----------------------------------------------------------------------

    /// @notice The latest time at which stakers are earning rewards.
    function lastTimeRewardApplicable() public view returns (uint64) {
        return
            block.timestamp < periodFinish
                ? uint64(block.timestamp)
                : periodFinish;
    }

    /// @notice The amount of reward tokens each staked token has earned so far
    function rewardPerToken() external view returns (uint256) {
        return
            _rewardPerToken(
                totalSupply,
                lastTimeRewardApplicable(),
                rewardRate
            );
    }

    /// @notice The amount of reward tokens an account has accrued so far. Does not
    /// include already withdrawn rewards.
    function earned(address account) external view returns (uint256) {
        return
            _earned(
                account,
                balanceOf[account],
                _rewardPerToken(
                    totalSupply,
                    lastTimeRewardApplicable(),
                    rewardRate
                ),
                rewards[account]
            );
    }

    /// -----------------------------------------------------------------------
    /// Owner actions
    /// -----------------------------------------------------------------------

    /// @notice Lets a reward distributor start a new reward period. The reward tokens must have already
    /// been transferred to this contract before calling this function. If it is called
    /// when a reward period is still active, a new reward period will begin from the time
    /// of calling this function, using the leftover rewards from the old reward period plus
    /// the newly sent rewards as the reward.
    /// @dev If the reward amount will cause an overflow when computing rewardPerToken, then
    /// this function will revert.
    /// @param reward The amount of reward tokens to use in the new reward period.
    function notifyRewardAmount(uint256 reward) external {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        if (reward == 0) {
            return;
        }
        if (!isRewardDistributor[msg.sender]) {
            revert Error_NotRewardDistributor();
        }

        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        uint256 rewardRate_ = rewardRate;
        uint64 periodFinish_ = periodFinish;
        uint64 lastTimeRewardApplicable_ = block.timestamp < periodFinish_
            ? uint64(block.timestamp)
            : periodFinish_;
        uint64 DURATION_ = DURATION();
        uint256 totalSupply_ = totalSupply;

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // accrue rewards
        rewardPerTokenStored = _rewardPerToken(
            totalSupply_,
            lastTimeRewardApplicable_,
            rewardRate_
        );
        lastUpdateTime = lastTimeRewardApplicable_;

        // record new reward
        uint256 newRewardRate;
        if (block.timestamp >= periodFinish_) {
            newRewardRate = reward / DURATION_;
        } else {
            uint256 remaining = periodFinish_ - block.timestamp;
            uint256 leftover = remaining * rewardRate_;
            newRewardRate = (reward + leftover) / DURATION_;
        }
        // prevent overflow when computing rewardPerToken
        if (newRewardRate >= ((type(uint256).max / PRECISION) / DURATION_)) {
            revert Error_AmountTooLarge();
        }
        rewardRate = newRewardRate;
        lastUpdateTime = uint64(block.timestamp);
        periodFinish = uint64(block.timestamp + DURATION_);

        emit RewardAdded(reward);
    }

    /// @notice Lets the owner add/remove accounts from the list of reward distributors.
    /// Reward distributors can call notifyRewardAmount()
    /// @param rewardDistributor The account to add/remove
    /// @param isRewardDistributor_ True to add the account, false to remove the account
    function setRewardDistributor(
        address rewardDistributor,
        bool isRewardDistributor_
    ) external onlyOwner {
        isRewardDistributor[rewardDistributor] = isRewardDistributor_;
    }

    /// -----------------------------------------------------------------------
    /// Internal functions
    /// -----------------------------------------------------------------------

    /// @notice  Updates information used to calculate unstake delay.
    /// @dev     It emits a `StakeDateUpdated` event.
    /// @param   account The Staker that deposited stakeToken.
    /// @param   amt     Amount of stakeToken the Staker has deposited.
    function _updateStakeDate(address account, uint256 amt) internal {
        uint256 prevDate = stakeDate[account];
        uint256 balance = balanceOf[account];

        // stakeDate + (now - stakeDate) * (amt / (balance + amt))
        // NOTE: prevDate = 0 implies balance = 0, and equation reduces to now.
        uint256 newDate = (balance + amt) > 0
            ? prevDate + ((block.timestamp - prevDate) * amt) / (balance + amt)
            : prevDate;

        stakeDate[account] = newDate;
        emit StakeDateUpdated(account, newDate);
    }

    function _earned(
        address account,
        uint256 accountBalance,
        uint256 rewardPerToken_,
        uint256 accountRewards
    ) internal view returns (uint256) {
        return
            FullMath.mulDiv(
                accountBalance,
                rewardPerToken_ - userRewardPerTokenPaid[account],
                PRECISION
            ) + accountRewards;
    }

    function _rewardPerToken(
        uint256 totalSupply_,
        uint256 lastTimeRewardApplicable_,
        uint256 rewardRate_
    ) internal view returns (uint256) {
        if (totalSupply_ == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            FullMath.mulDiv(
                (lastTimeRewardApplicable_ - lastUpdateTime) * PRECISION,
                rewardRate_,
                totalSupply_
            );
    }

    function _getImmutableVariablesOffset()
        internal
        pure
        returns (uint256 offset)
    {
        assembly {
            offset := sub(
                calldatasize(),
                add(shr(240, calldataload(sub(calldatasize(), 2))), 2)
            )
        }
    }
}