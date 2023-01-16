// SPDX-License-Identifier: MIT

pragma solidity =0.6.12;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./interfaces/IMojitoToken.sol";
import "./interfaces/IMojitoSwapLottery.sol";
import "./Schedule.sol";

contract MojitoLotteryPool is Schedule, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // The Mojito token
    IMojitoToken public mojito;
    uint256 public startBlock;
    uint256 public totalAllocPoint = 0;

    address public operator;

    struct PoolInfo {
        IMojitoSwapLottery lottery;
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 pendingAmount; // pending MJT
        uint256 totalInject; // inject MJT
    }

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(uint256 => uint256)) injectInfo;

    event AdminTokenRecovery(address token, uint256 amount);
    event OperatorUpdate(address indexed from, address to);
    event InjectPool(uint256 indexed pid, uint256 lotteryId, uint256 amount);
    event InjectPending(uint256 indexed pid, uint256 amount);

    constructor(
        IMojitoToken _mojito,
        uint256 _mojitoPerBlock,
        uint256 _startBlock
    ) public Schedule(_mojitoPerBlock) {
        mojito = _mojito;
        startBlock = _startBlock;
    }

    modifier onlyOwnerOrOperator() {
        require(owner() == _msgSender() || operator == _msgSender(), "not owner or operator");
        _;
    }

    function setOperator(address _operator) public onlyOwner {
        require(_operator != address(0), "setOperator:zero address");
        address pre = operator;
        operator = _operator;
        emit OperatorUpdate(pre, operator);
    }

    function setMojitoPerBlock(uint256 _mojitoPerBlock) public virtual override onlyOwner {
        massUpdatePools();
        super.setMojitoPerBlock(_mojitoPerBlock);
    }

    function add(IMojitoSwapLottery _lottery, uint256 _allocPoint, bool withUpdate) public onlyOwner {
        checkPoolDuplicate(_lottery);

        if (withUpdate) {
            massUpdatePools();
        }

        mojito.approve(address(_lottery), uint256(- 1));

        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        poolInfo.push(PoolInfo({
        lottery : _lottery,
        allocPoint : _allocPoint,
        lastRewardBlock : lastRewardBlock,
        pendingAmount : 0,
        totalInject : 0
        }));
    }

    function set(uint256 _pid, uint256 _allocPoint) public onlyOwner {
        massUpdatePools();
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        uint256 blockReward = mintable(pool.lastRewardBlock);
        uint256 mojitoReward = blockReward.mul(pool.allocPoint).div(totalAllocPoint);
        mojito.mint(address(this), mojitoReward);
        pool.pendingAmount = pool.pendingAmount.add(mojitoReward);
        pool.lastRewardBlock = block.number;
    }

    function injectPending(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        mojito.transferFrom(_msgSender(), address(this), _amount);
        pool.pendingAmount = pool.pendingAmount.add(_amount);
        emit InjectPending(_pid, _amount);
    }

    function injectPool(uint256 _pid, bool withUpdate) public onlyOwnerOrOperator {
        if (withUpdate) {
            // update pendingAmount
            updatePool(_pid);
        }

        PoolInfo storage pool = poolInfo[_pid];

        uint256 currentLotteryId = pool.lottery.viewCurrentLotteryId();
        pool.lottery.injectFunds(currentLotteryId, pool.pendingAmount);

        uint256 prePending = pool.pendingAmount;
        pool.totalInject = pool.totalInject.add(pool.pendingAmount);
        injectInfo[_pid][currentLotteryId] = injectInfo[_pid][currentLotteryId].add(pool.pendingAmount);

        pool.pendingAmount = 0;
        emit InjectPool(_pid, currentLotteryId, prePending);
    }

    function checkPoolDuplicate(IMojitoSwapLottery _lottery) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].lottery != _lottery, "existing pool");
        }
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function withdrawExtraToken() public onlyOwner {
        uint256 pending = totalPending();
        uint256 balance = mojito.balanceOf(address(this));
        // balance >= pending
        uint256 amount = balance.sub(pending);
        mojito.transfer(_msgSender(), amount);
        emit AdminTokenRecovery(address(mojito), amount);
    }

    function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        require(_tokenAddress != address(mojito), "cannot be mojito token");

        IERC20(_tokenAddress).safeTransfer(_msgSender(), _tokenAmount);

        emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
    }

    function totalPending() public view returns (uint256) {
        uint256 pending;
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            pending = pending.add(poolInfo[pid].pendingAmount);
        }

        return pending;
    }
}

