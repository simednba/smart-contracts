// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "../YakStrategyV2.sol";
import "../interfaces/IPair.sol";
import "../lib/DexLibrary.sol";

/**
 * @notice Adapter strategy for MasterChef.
 */
abstract contract MasterChefStrategy is YakStrategyV2 {
    using SafeMath for uint256;

    struct StrategySettings {
        uint256 minTokensToReinvest;
        uint256 adminFeeBips;
        uint256 devFeeBips;
        uint256 reinvestRewardBips;
    }

    uint256 public immutable PID;
    address private stakingContract;
    address private poolRewardToken;
    IPair private swapPairPoolReward;

    constructor(
        string memory _name,
        address _depositToken,
        address _ecosystemToken,
        address _poolRewardToken,
        address _swapPairPoolReward,
        address _stakingContract,
        address _timelock,
        uint256 _pid,
        StrategySettings memory _strategySettings
    ) Ownable() {
        name = _name;
        depositToken = IERC20(_depositToken);
        rewardToken = IERC20(_ecosystemToken);
        PID = _pid;
        devAddr = msg.sender;
        stakingContract = _stakingContract;

        assignSwapPairSafely(_ecosystemToken, _poolRewardToken, _swapPairPoolReward);
        setAllowances();
        updateMinTokensToReinvest(_strategySettings.minTokensToReinvest);
        updateAdminFee(_strategySettings.adminFeeBips);
        updateDevFee(_strategySettings.devFeeBips);
        updateReinvestReward(_strategySettings.reinvestRewardBips);
        updateDepositsEnabled(true);
        transferOwnership(_timelock);
        emit Reinvest(0, 0);
    }

    /**
     * @notice Initialization helper for Pair deposit tokens
     * @dev Checks that selected Pairs are valid for trading reward tokens
     * @dev Assigns values to IPair(swapPairToken0) and IPair(swapPairToken1)
     */
    function assignSwapPairSafely(
        address _ecosystemToken,
        address _poolRewardToken,
        address _swapPairPoolReward
    ) private {
        if (_poolRewardToken == IPair(_swapPairPoolReward).token0()) {
            require(
                IPair(_swapPairPoolReward).token1() == _ecosystemToken,
                "Swap pair 'swapPairPoolReward' does not contain ecosystem token"
            );
        } else if (_poolRewardToken == IPair(_swapPairPoolReward).token1()) {
            require(
                IPair(_swapPairPoolReward).token0() == _ecosystemToken,
                "Swap pair 'swapPairPoolReward' does not contain ecosystem token"
            );
        } else {
            revert("Swap pair 'swapPairPoolReward' does not contain pool reward token");
        }
        poolRewardToken = _poolRewardToken;
        swapPairPoolReward = IPair(_swapPairPoolReward);
    }

    /**
     * @notice Approve tokens for use in Strategy
     * @dev Restricted to avoid griefing attacks
     */
    function setAllowances() public override onlyOwner {
        depositToken.approve(stakingContract, type(uint256).max);
    }

    /**
     * @notice Deposit tokens to receive receipt tokens
     * @param amount Amount of tokens to deposit
     */
    function deposit(uint256 amount) external override {
        _deposit(msg.sender, amount);
    }

    /**
     * @notice Deposit using Permit
     * @param amount Amount of tokens to deposit
     * @param deadline The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        depositToken.permit(msg.sender, address(this), amount, deadline, v, r, s);
        _deposit(msg.sender, amount);
    }

    function depositFor(address account, uint256 amount) external override {
        _deposit(account, amount);
    }

    function _deposit(address account, uint256 amount) internal {
        require(DEPOSITS_ENABLED == true, "MasterChefStrategyV1::_deposit");
        if (MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST > 0) {
            (uint256 poolTokenAmount, uint256 rewardTokenBalance, uint256 estimatedTotalReward) = _checkReward();
            if (estimatedTotalReward > MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST) {
                _reinvest(rewardTokenBalance, poolTokenAmount);
            }
        }
        require(depositToken.transferFrom(msg.sender, address(this), amount), "MasterChefStrategyV1::transfer failed");
        _stakeDepositTokens(amount);
        uint256 depositFeeBips = _getDepositFeeBips(PID);
        uint256 depositFee = amount.mul(depositFeeBips).div(_bip());
        _mint(account, getSharesForDepositTokens(amount.sub(depositFee)));
        emit Deposit(account, amount);
    }

    function withdraw(uint256 amount) external override {
        uint256 depositTokenAmount = getDepositTokensForShares(amount);
        if (depositTokenAmount > 0) {
            _withdrawDepositTokens(depositTokenAmount);
            uint256 withdrawFeeBips = _getWithdrawFeeBips(PID);
            uint256 withdrawFee = depositTokenAmount.mul(withdrawFeeBips).div(_bip());
            _safeTransfer(address(depositToken), msg.sender, depositTokenAmount.sub(withdrawFee));
            _burn(msg.sender, amount);
            emit Withdraw(msg.sender, depositTokenAmount);
        }
    }

    function _withdrawDepositTokens(uint256 amount) private {
        require(amount > 0, "MasterChefStrategyV1::_withdrawDepositTokens");
        _withdrawMasterchef(PID, amount);
    }

    function reinvest() external override onlyEOA {
        (uint256 poolTokenAmount, uint256 rewardTokenBalance, uint256 estimatedTotalReward) = _checkReward();
        require(estimatedTotalReward >= MIN_TOKENS_TO_REINVEST, "MasterChefStrategyV1::reinvest");
        _reinvest(rewardTokenBalance, poolTokenAmount);
    }

    function _convertPoolTokensIntoReward(uint256 poolTokenAmount) private returns (uint256) {
        return DexLibrary.swap(poolTokenAmount, address(poolRewardToken), address(rewardToken), swapPairPoolReward);
    }

    /**
     * @notice Reinvest rewards from staking contract to deposit tokens
     * @dev Reverts if the expected amount of tokens are not returned from `MasterChef`
     */
    function _reinvest(uint256 rewardTokenBalance, uint256 poolTokenAmount) private {
        _getRewards(PID);
        uint256 amount = rewardTokenBalance.add(_convertPoolTokensIntoReward(poolTokenAmount));

        uint256 devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
        if (devFee > 0) {
            _safeTransfer(address(rewardToken), devAddr, devFee);
        }

        uint256 adminFee = amount.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
        if (adminFee > 0) {
            _safeTransfer(address(rewardToken), owner(), adminFee);
        }

        uint256 reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
        if (reinvestFee > 0) {
            _safeTransfer(address(rewardToken), msg.sender, reinvestFee);
        }

        uint256 depositTokenAmount = _convertRewardTokenToDepositToken(
            amount.sub(devFee).sub(adminFee).sub(reinvestFee)
        );
        _stakeDepositTokens(depositTokenAmount);
        emit Reinvest(totalDeposits(), totalSupply);
    }

    function _stakeDepositTokens(uint256 amount) private {
        require(amount > 0, "MasterChefStrategyV1::_stakeDepositTokens");
        _depositMasterchef(PID, amount);
    }

    /**
     * @notice Safely transfer using an anonymosu ERC20 token
     * @dev Requires token to return true on transfer
     * @param token address
     * @param to recipient address
     * @param value amount
     */
    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        require(IERC20(token).transfer(to, value), "MasterChefStrategyV1::TRANSFER_FROM_FAILED");
    }

    function _checkReward()
        internal
        view
        returns (
            uint256 _poolTokenAmount,
            uint256 _rewardTokenBalance,
            uint256 _estimatedTotalReward
        )
    {
        uint256 poolTokenBalance = IERC20(poolRewardToken).balanceOf(address(this));
        uint256 pendingPoolTokenAmount = _pendingRewards(PID, address(this));
        uint256 poolTokenAmount = poolTokenBalance.add(pendingPoolTokenAmount);
        uint256 pendingRewardTokenAmount = DexLibrary.estimateConversionThroughPair(
            poolTokenAmount,
            poolRewardToken,
            address(rewardToken),
            swapPairPoolReward
        );
        uint256 rewardTokenBalance = rewardToken.balanceOf(address(this));
        uint256 estimatedTotalReward = rewardTokenBalance.add(pendingRewardTokenAmount);
        return (poolTokenAmount, rewardTokenBalance, estimatedTotalReward);
    }

    function checkReward() public view override returns (uint256) {
        (, , uint256 estimatedTotalReward) = _checkReward();
        return estimatedTotalReward;
    }

    /**
     * @notice Estimate recoverable balance after withdraw fee
     * @return deposit tokens after withdraw fee
     */
    function estimateDeployedBalance() external view override returns (uint256) {
        return _totalDeposits();
    }

    function totalDeposits() public view override returns (uint256) {
        return _totalDeposits();
    }

    function _totalDeposits() internal view returns (uint256) {
        uint256 depositBalance = _getDepositBalance(PID, address(this));
        uint256 withdrawFeeBips = _getWithdrawFeeBips(PID);
        uint256 withdrawFee = depositBalance.mul(withdrawFeeBips).div(_bip());
        return depositBalance.sub(withdrawFee);
    }

    function rescueDeployedFunds(uint256 minReturnAmountAccepted, bool disableDeposits) external override onlyOwner {
        uint256 balanceBefore = depositToken.balanceOf(address(this));
        _emergencyWithdraw(PID);
        uint256 balanceAfter = depositToken.balanceOf(address(this));
        require(
            balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted,
            "MasterChefStrategyV1::rescueDeployedFunds"
        );
        emit Reinvest(totalDeposits(), totalSupply);
        if (DEPOSITS_ENABLED == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
    }

    /* VIRTUAL */
    function _convertRewardTokenToDepositToken(uint256 fromAmount) internal virtual returns (uint256 toAmount);

    function _depositMasterchef(uint256 pid, uint256 amount) internal virtual;

    function _withdrawMasterchef(uint256 pid, uint256 amount) internal virtual;

    function _emergencyWithdraw(uint256 pid) internal virtual;

    function _getRewards(uint256 pid) internal virtual;

    function _pendingRewards(uint256 pid, address user) internal view virtual returns (uint256 poolTokenAmount);

    function _getDepositBalance(uint256 pid, address user) internal view virtual returns (uint256 amount);

    function _getDepositFeeBips(uint256 pid) internal view virtual returns (uint256);

    function _getWithdrawFeeBips(uint256 pid) internal view virtual returns (uint256);

    function _bip() internal view virtual returns (uint256);
}
