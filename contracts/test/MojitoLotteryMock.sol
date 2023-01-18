// SPDX-License-Identifier: MIT

pragma solidity =0.6.12;

import "../interfaces/IMojitoToken.sol";

contract MojitoLotteryMock {
    uint256 lotteryId;
    IMojitoToken mojito;

    constructor(IMojitoToken _mojito) public {
        mojito = _mojito;
    }

    function viewCurrentLotteryId() external view returns (uint256) {
        return lotteryId;
    }

    function startLottery(
        uint256 _endTime,
        uint256 _priceTicketInMJT,
        uint256 _discountDivisor,
        uint256[6] calldata _rewardsBreakdown,
        uint256 _treasuryFee
    ) external {
        _endTime;
        _priceTicketInMJT;
        _discountDivisor;
        uint256 length = _rewardsBreakdown.length;
        length;
        _treasuryFee;
        lotteryId++;
    }

    function injectFunds(uint256 _lotteryId, uint256 _amount) external {
        _lotteryId;
        mojito.transferFrom(address(msg.sender), address(this), _amount);
    }
}
