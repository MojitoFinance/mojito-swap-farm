// SPDX-License-Identifier: MIT

pragma solidity =0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IMojitoToken.sol";
import "./interfaces/IRewarder.sol";
import "./libraries/BoringERC20.sol";
import "./Schedule.sol";

// MasterChefV2 is the master of Mojito. He can make Mojito and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once Mojito is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChefV2 is Schedule, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of MJTs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accMojitoPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accMojitoPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;             // Address of LP token contract.
        uint256 allocPoint;         // How many allocation points assigned to this pool. MJTs to distribute per block.
        uint256 lastRewardBlock;    // Last block number that MJTs distribution occurs.
        uint256 accMojitoPerShare;  // Accumulated MJTs per share, times 1e12. See below.
        IRewarder rewarder;
    }

    // The Mojito token
    IMojitoToken public mojito;
    // Bonus muliplier for early mojito makers.
    uint256 public BONUS_MULTIPLIER = 1;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when Mojito mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        IMojitoToken _mojito,
        uint256 _mojitoPerBlock,
        uint256 _startBlock,
        IRewarder _rewarder
    ) public Schedule(_mojitoPerBlock) {
        mojito = _mojito;
        startBlock = _startBlock;

        // Sanity check if we add a rewarder
        if (address(_rewarder) != address(0)) {
            _rewarder.onMojitoReward(address(0), 0);
        }

        // staking pool
        poolInfo.push(PoolInfo({
        lpToken : _mojito,
        allocPoint : 1000,
        lastRewardBlock : startBlock,
        accMojitoPerShare : 0,
        rewarder : _rewarder
        }));

        totalAllocPoint = 1000;

    }

    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // DO NOT add the same LP token more than once
    function checkPoolDuplicate(IERC20 _lpToken) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].lpToken != _lpToken, "MasterChefV2::add: existing pool");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate, IRewarder _rewarder) public onlyOwner {
        checkPoolDuplicate(_lpToken);

        if (_withUpdate) {
            massUpdatePools();
        }

        // Sanity check if we add a rewarder
        if (address(_rewarder) != address(0)) {
            _rewarder.onMojitoReward(address(0), 0);
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
        lpToken : _lpToken,
        allocPoint : _allocPoint,
        lastRewardBlock : lastRewardBlock,
        accMojitoPerShare : 0,
        rewarder : _rewarder
        }));
        updateStakingPool();
    }

    // Update the given pool's Mojito allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, IRewarder _rewarder, bool overwrite) public onlyOwner {
        massUpdatePools();
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            updateStakingPool();
        }

        if (overwrite) {
            _rewarder.onMojitoReward(address(0), 0);
            // sanity check
            poolInfo[_pid].rewarder = _rewarder;
        }
    }

    function updateStakingPool() internal {
        uint256 length = poolInfo.length;
        uint256 points = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            points = points.add(poolInfo[pid].allocPoint);
        }
        if (points != 0) {
            points = points.div(3);
            totalAllocPoint = totalAllocPoint.sub(poolInfo[0].allocPoint).add(points);
            poolInfo[0].allocPoint = points;
        }
    }

    function setMojitoPerBlock(uint256 _mojitoPerBlock) public virtual override onlyOwner {
        massUpdatePools();
        super.setMojitoPerBlock(_mojitoPerBlock);
    }

    // View function to see pending MJTs on frontend.
    function pendingMojito(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accMojitoPerShare = pool.accMojitoPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 blockReward = mintable(pool.lastRewardBlock);
            uint256 mojitoReward = blockReward.mul(pool.allocPoint).div(totalAllocPoint);
            accMojitoPerShare = accMojitoPerShare.add(mojitoReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accMojitoPerShare).div(1e12).sub(user.rewardDebt);
    }

    function pendingReward(uint256 _pid, address _user)
    external
    view
    returns (
        address bonusTokenAddress,
        string memory bonusTokenSymbol,
        uint256 pendingBonusToken
    ) {
        PoolInfo storage pool = poolInfo[_pid];
        // If it's a double reward farm, we return info about the bonus token
        if (address(pool.rewarder) != address(0)) {
            bonusTokenAddress = address(pool.rewarder.rewardToken());
            bonusTokenSymbol = BoringERC20.safeSymbol(IERC20(pool.rewarder.rewardToken()));
            pendingBonusToken = pool.rewarder.pendingTokens(_user);
        }
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 blockReward = mintable(pool.lastRewardBlock);
        uint256 mojitoReward = blockReward.mul(pool.allocPoint).div(totalAllocPoint);
        mojito.mint(address(this), mojitoReward);
        pool.accMojitoPerShare = pool.accMojitoPerShare.add(mojitoReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChefV2.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        require(_pid != 0, "MasterChefV2::deposit: _pid can only be farm pool");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accMojitoPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeMojitoTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMojitoPerShare).div(1e12);

        // Interactions
        IRewarder _rewarder = pool.rewarder;
        if (address(_rewarder) != address(0)) {
            _rewarder.onMojitoReward(msg.sender, user.amount);
        }

        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChefV2.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        require(_pid != 0, "MasterChefV2::withdraw: _pid can only be farm pool");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "MasterChefV2::withdraw: _amount not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accMojitoPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeMojitoTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);

            // Interactions
            IRewarder _rewarder = pool.rewarder;
            if (address(_rewarder) != address(0)) {
                _rewarder.onMojitoReward(msg.sender, user.amount);
            }

            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMojitoPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Stake MJT tokens to MasterChefV2
    function enterStaking(uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        updatePool(0);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accMojitoPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeMojitoTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMojitoPerShare).div(1e12);

        emit Deposit(msg.sender, 0, _amount);
    }

    // Withdraw MJT tokens from MasterChefV2.
    function leaveStaking(uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        require(user.amount >= _amount, "MasterChefV2::leaveStaking: _amount not good");
        updatePool(0);
        uint256 pending = user.amount.mul(pool.accMojitoPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeMojitoTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMojitoPerShare).div(1e12);

        emit Withdraw(msg.sender, 0, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe mojito transfer function, just in case if rounding error causes pool to not have enough MJTs.
    function safeMojitoTransfer(address _to, uint256 _amount) internal {
        uint256 mojitoBal = mojito.balanceOf(address(this));
        if (_amount > mojitoBal) {
            mojito.transfer(_to, mojitoBal);
        } else {
            mojito.transfer(_to, _amount);
        }
    }
}