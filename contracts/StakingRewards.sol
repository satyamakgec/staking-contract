// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

contract StakingRewards is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    error CanNotStakeZeroAmt();
    error CanNotWithdrawZeroAmt();
    error NotAllowedToWithdraw();
    error InSufficientStake();
    error StakeLimitOver();
    error StakeTimePassedOut();
    error StakingIsNotStarted();
    error StakingAlreadyInMotion();
    error FundsAreUnderLockInPeriod();
    error NotAllowedToPushFunds();
    error ZeroRewardNotAllowed();

    /* ========== STATE VARIABLES ========== */

    IERC20 public rewardsToken;
    IERC20 public stakingToken;
    uint256 public maxPoolStakeAmount;
    uint256 public rewardsDuration;
    uint256 public stakeStartTime;
    uint256 public apy;
    uint256 public remainingRewardAmt;
    uint256 public immutable minStakeAllowed;
    uint256 public immutable lockInPeriod;

    mapping(address => uint256) public stakeDate; // Map of account addresses to effective stake date.
    mapping(address => uint256) public rewardClaimed; // Map to keep already claimed rewards by the stakers.

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsWithdrawn(address indexed user, uint256 reward);
    event Recovered(address token, uint256 amount);
    event StakeDateUpdated(address indexed staker, uint256 stakeDate);
    event RewardAmountUpdated(address indexed who, uint256 newRemainingRewardAmt);
    event RewardsPushed(address staker);

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address _rewardsToken,
        address _stakingToken
    ) {
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        maxStakeAmount = 2000000 * 1e18;
        minStakeAllowed = 5000 * 1e18;
        lockInPeriod = 10 minutes;
        rewardsDuration = 20 minutes;
        apy = 3000; // 30 %
        transferOwnership(_owner);
    }

    /// @notice Allows to stake the stake token.
    /// @dev    Conditions to follow to have a successful stake.
    ///         1. Staking should be in active state.
    ///         2. Stake amount should not be zero.
    ///         3. Stake amount should be greater than the minimum stake allowed.
    ///         4. Staking is not allowed when the `current block time > stakeStartTime + lockInPeriod`.
    /// @param  amount No. of stake tokens `msg.sender` wants to stake in.
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        // Check whether the staking is started or not.
        if (stakeStartTime == uint256(0)) {
            revert StakingIsNotStarted();
        }
        // Validate the zero amount of stake.
        if (amount == 0) {
            revert CanNotStakeZeroAmt();
        }

        // Validate the minimum stake amount
        if (amount + _balances[msg.sender] < minStakeAllowed) {
            revert InSufficientStake();
        }

        if (totalSupply() + amount > maxPoolStakeAmount) {
            revert StakeLimitOver();
        }

        // User is not allowed to stake after the start time of the stake + lock in time get passed.
        if (block.timestamp >= stakeStartTime + lockInPeriod) {
            revert StakeTimePassedOut();
        }
        _updateStakeDate(msg.sender, amount);
        _totalSupply = _totalSupply + amount;
        _balances[msg.sender] = _balances[msg.sender] + amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /// @notice Allows to unstake the given amount.
    /// @dev    1. Un stake amount should be greater than zero.
    ///         2. Current block time should be > weighted stake date + lockInPeriod.
    /// @param amount No. of stake tokens user wants to unstake.
    function unstake(uint256 amount) public nonReentrant {
        if (amount == 0) {
            revert CanNotWithdrawZeroAmt();
        }
        if (stakeDate[msg.sender] + lockInPeriod > block.timestamp) {
            revert FundsAreUnderLockInPeriod();
        }
        _withdrawRewards(msg.sender);
        _totalSupply = _totalSupply - amount;
        _balances[msg.sender] = _balances[msg.sender] - amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// @notice Allows the staker to unstake there entitled reward.
    function withdrawReward() public nonReentrant {
        _withdrawRewards(msg.sender);
    }

    /// @notice Allows anyone to push reward to the given staker.
    /// @dev    Push is only possible only after the rewards maturity.
    /// @param staker Whom rewards gets pushed.
    function pushReward(address staker) external nonReentrant {
        uint256 rewardsMaturity = stakeStartTime + rewardsDuration;
        if (block.timestamp < rewardsMaturity) {
            revert NotAllowedToPushFunds();
        }
        _withdrawRewards(staker);
        uint256 amount = _balances[staker];
        _totalSupply = _totalSupply - amount;
        _balances[staker] = uint256(0);
        stakingToken.safeTransfer(staker, amount);
        emit Unstaked(staker, amount);
        emit RewardsPushed(staker);
    }

    /// @notice Anyone can update the reward amount at any time.
    /// @param _amt Amoun of rewards token.
    function updateRewardAmt(uint256 _amt) external {
        remainingRewardAmt += _amt == uint256(0)
            ? rewardsToken.balanceOf(address(this)) - totalSupply() - remainingRewardAmt
            : _transferFunds(_amt);
        emit RewardAmountUpdated(msg.sender, remainingRewardAmt);
    }

    function _transferFunds(uint256 _amt) internal returns (uint256) {
        rewardsToken.safeTransferFrom(msg.sender, address(this), _amt);
        return _amt;
    }

    /// @notice Allows owner to start staking.
    /// @dev    Owner should fund the contract with the given reward.
    /// @param  reward Amount of rewards Token that need to distributed as the reward.
    function startStaking(uint256 reward) external onlyOwner {
        if (stakeStartTime != uint256(0)) {
            revert StakingAlreadyInMotion();
        }
        if (reward == uint256(0)) {
            revert ZeroRewardNotAllowed();
        }
        stakeStartTime = block.timestamp;
        remainingRewardAmt = reward;
        IERC20(rewardsToken).safeTransferFrom(msg.sender, address(this), reward);
        emit RewardAdded(reward);
    }

    /// @notice Recover any ERC20 token from the contract.
    /// @dev    It can only be called by the owner.
    ///         If given `tokenAddress` is `stakingToken` then funds will only
    ///         get withdraw when there is no stake token present in the contract
    ///         & rewards get matured as well.
    /// @param tokenAddress Address of the ERC20 token whose funds get recovered from the contract.
    /// @param tokenAmount  Amount of funds needs to be recovered.
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        if (tokenAddress == address(stakingToken)) {
            uint256 rewardsMaturity = stakeStartTime + rewardsDuration;
            if (!(totalSupply() == uint256(0) && rewardsMaturity < block.timestamp)) revert NotAllowedToWithdraw();
        }
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    /// @notice  Updates information used to calculate unstake delay.
    /// @dev     It emits a `StakeDateUpdated` event.
    /// @param   account The Staker that deposited stakeToken.
    /// @param   amt     Amount of stakeToken the Staker has deposited.
    function _updateStakeDate(address account, uint256 amt) internal {
        uint256 prevDate = stakeDate[account];
        uint256 balance = balanceOf(account);

        // stakeDate + (now - stakeDate) * (amt / (balance + amt))
        // NOTE: prevDate = 0 implies balance = 0, and equation reduces to now.
        uint256 newDate = (balance + amt) > 0
            ? prevDate + ((block.timestamp - prevDate) * amt) / (balance + amt)
            : prevDate;

        stakeDate[account] = newDate;
        emit StakeDateUpdated(account, newDate);
    }

    /// @notice withdraw reward.
    /// @dev    Can't withdraw amount greater than the `remainingRewardAmt`.
    /// @param _who Address who is entitled to rewards.
    function _withdrawRewards(address _who) internal {
        uint256 effectiveRewardAmt = getAccumulatedRewardAmt(_who);
        if (effectiveRewardAmt > uint256(0) && remainingRewardAmt >= effectiveRewardAmt) {
            remainingRewardAmt -= effectiveRewardAmt;
            rewardClaimed[_who] += effectiveRewardAmt;
            rewardsToken.safeTransfer(_who, effectiveRewardAmt);
            emit RewardsWithdrawn(_who, effectiveRewardAmt);
        }
    }

    /// @notice Returns the accumulated rewards for the given staker.
    /// @param staker Account address whose rewards gets queried.
    function getAccumulatedRewardAmt(address staker) public view returns (uint256 reward) {
        uint256 delta = block.timestamp - stakeDate[staker];
        delta = delta > rewardsDuration ? rewardsDuration : delta;
        // Rewards calculated using the fixed APY.
        uint256 entitledTo = (apy * _balances[staker] * delta) / (365 * 24 * 60 * 60 * 10000);
        return entitledTo - rewardClaimed[staker];
    }

    /// @notice Returns total no. of funds staked at current time.
    /// @return uint256
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    /// @notice Amount of funds staked by the given `account`.
    /// @return uint256.
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }
}
